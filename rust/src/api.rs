//! The C ABI.
//!
//! One convention, everywhere: a function takes a UTF-8 JSON object and
//! returns a UTF-8 JSON object, always shaped
//!
//! ```json
//! {"ok": true,  "result": …}
//! {"ok": false, "error": "human readable", "code": "machineReadable"}
//! ```
//!
//! The returned string is owned by the library and must be released with
//! [`hrt_free`]. No panic crosses the boundary — a malformed backup becomes an
//! error object, not a crash in the host process.

use std::ffi::{CStr, CString};
use std::os::raw::c_char;
use std::panic::{catch_unwind, AssertUnwindSafe};

use serde::de::DeserializeOwned;
use serde::Deserialize;
use serde_json::{json, Value};

use crate::analysis;
use crate::blockade::{self, BlockadeInput};
use crate::body::{self, BodyInput, CupSystem, Measurement};
use crate::compare::{self, CompareArm, CompareInput};
use crate::calibration::{calibrate, CalibrationInput};
use crate::catalog;
use crate::labsreview::{self, LabsInput};
use crate::engine::{self, run_simulation_grid, SimGrid};
use crate::model::*;
use crate::planning::{self, Objective, Schedule};
use crate::progress::{self, ProgressInput};
use crate::reminders;
use crate::safety::{self, SafetyInput};
use crate::stats::{self, SimulationStats};
use crate::units::{self, Analyte};
use crate::whatif::{self, Scenario, WhatIfInput};

pub const ABI_VERSION: i32 = 2;

// --- Envelope -------------------------------------------------------------

fn ok(value: Value) -> Value {
    json!({ "ok": true, "result": value })
}

fn err(code: &str, message: impl std::fmt::Display) -> Value {
    json!({ "ok": false, "code": code, "error": message.to_string() })
}

fn parse<T: DeserializeOwned>(text: &str) -> Result<T, Value> {
    serde_json::from_str(text).map_err(|e| err("badRequest", format!("bad request: {e}")))
}

fn into_c_string(value: Value) -> *mut c_char {
    let text = serde_json::to_string(&value)
        .unwrap_or_else(|_| "{\"ok\":false,\"code\":\"encode\",\"error\":\"encode\"}".into());
    match CString::new(text) {
        Ok(c) => c.into_raw(),
        Err(_) => CString::new("{\"ok\":false,\"code\":\"nul\",\"error\":\"nul byte\"}")
            .expect("static string is valid")
            .into_raw(),
    }
}

unsafe fn read_input<'a>(ptr: *const c_char) -> Result<&'a str, Value> {
    if ptr.is_null() {
        return Err(err("nullInput", "input is a null pointer"));
    }
    CStr::from_ptr(ptr)
        .to_str()
        .map_err(|_| err("notUtf8", "input is not UTF-8"))
}

// --- Shared request fields ------------------------------------------------

#[derive(Debug, Clone, Deserialize)]
#[serde(rename_all = "camelCase")]
struct CommonRequest {
    #[serde(default)]
    events: Vec<DoseEvent>,
    #[serde(default)]
    body_weight_kg: f64,
    #[serde(default)]
    birth_year: Option<f64>,
    #[serde(default)]
    params: Option<PkParams>,
    #[serde(default)]
    now_h: f64,
    #[serde(default)]
    clearance_mult: Option<f64>,
    #[serde(default)]
    start_h: Option<f64>,
    #[serde(default)]
    end_h: Option<f64>,
    #[serde(default)]
    step_h: Option<f64>,
    #[serde(default)]
    e2_target: Option<TargetRange>,
    #[serde(default)]
    t_target: Option<TargetRange>,
    #[serde(default)]
    include_stats: bool,
    #[serde(default)]
    labs: Vec<LabResult>,
}

impl CommonRequest {
    fn params(&self) -> PkParams {
        self.params.unwrap_or_default().sanitized()
    }

    fn clearance(&self) -> f64 {
        self.clearance_mult.unwrap_or(1.0).clamp(0.1, 10.0)
    }

    fn weight(&self) -> f64 {
        if self.body_weight_kg.is_finite() && self.body_weight_kg > 0.0 {
            self.body_weight_kg
        } else {
            70.0
        }
    }

    fn grid(&self) -> SimGrid {
        SimGrid {
            start_h: self.start_h,
            end_h: self.end_h,
            step_h: self.step_h.filter(|s| *s > 0.0),
            max_points: 100_000,
        }
    }

    fn stats_for(&self, sim: &SimulationResult, window: Option<(f64, f64)>) -> SimulationStats {
        stats::simulation_stats(sim, window, self.e2_target, self.t_target)
    }
}

// --- Handlers -------------------------------------------------------------

fn handle_simulate(text: &str) -> Value {
    let req: CommonRequest = match parse(text) {
        Ok(r) => r,
        Err(e) => return e,
    };
    let params = req.params();
    let sim = run_simulation_grid(
        &req.events,
        req.weight(),
        req.birth_year,
        &params,
        req.now_h,
        req.clearance(),
        &req.grid(),
    );
    match sim {
        None => ok(Value::Null),
        Some(sim) => {
            let mut out = json!({ "ok": true, "result": sim });
            if req.include_stats {
                if let Some(map) = out.as_object_mut() {
                    map.insert("stats".into(), json!(req.stats_for(&sim, None)));
                }
            }
            out
        }
    }
}

fn handle_stats(text: &str) -> Value {
    let req: CommonRequest = match parse(text) {
        Ok(r) => r,
        Err(e) => return e,
    };
    let params = req.params();
    let window = match (req.start_h, req.end_h) {
        (Some(from), Some(to)) if to > from => Some((from, to)),
        _ => None,
    };
    let sim = match run_simulation_grid(
        &req.events,
        req.weight(),
        req.birth_year,
        &params,
        req.now_h,
        req.clearance(),
        &req.grid(),
    ) {
        Some(sim) => sim,
        None => return ok(Value::Null),
    };
    ok(json!(req.stats_for(&sim, window)))
}

fn handle_calibrate(text: &str) -> Value {
    #[derive(Deserialize)]
    #[serde(rename_all = "camelCase")]
    struct CalibrateRequest {
        events: Vec<DoseEvent>,
        body_weight_kg: f64,
        #[serde(default)]
        birth_year: Option<f64>,
        #[serde(default)]
        params: Option<PkParams>,
        #[serde(default)]
        labs: Vec<LabResult>,
        #[serde(default = "default_method")]
        method: String,
        #[serde(default = "default_history")]
        history_mode: String,
        now_h: f64,
    }

    fn default_method() -> String {
        "mipd".to_string()
    }
    fn default_history() -> String {
        "retrospective".to_string()
    }

    let req: CalibrateRequest = match parse(text) {
        Ok(r) => r,
        Err(e) => return e,
    };
    let params = req.params.unwrap_or_default().sanitized();
    let out = calibrate(CalibrationInput {
        events: &req.events,
        weight: if req.body_weight_kg > 0.0 {
            req.body_weight_kg
        } else {
            70.0
        },
        birth_year: req.birth_year,
        params: &params,
        labs: &req.labs,
        method: &req.method,
        history_mode: &req.history_mode,
        now_h: req.now_h,
    });
    ok(json!(out))
}

fn handle_steady_state(text: &str) -> Value {
    #[derive(Deserialize)]
    #[serde(rename_all = "camelCase")]
    struct SteadyRequest {
        schedule: Schedule,
        body_weight_kg: f64,
        #[serde(default)]
        birth_year: Option<f64>,
        #[serde(default)]
        params: Option<PkParams>,
        #[serde(default)]
        max_cycles: Option<usize>,
        #[serde(default)]
        e2_target: Option<TargetRange>,
        #[serde(default)]
        t_target: Option<TargetRange>,
        #[serde(default)]
        include_series: bool,
    }

    let req: SteadyRequest = match parse(text) {
        Ok(r) => r,
        Err(e) => return e,
    };
    let params = req.params.unwrap_or_default().sanitized();
    match planning::steady_state(
        &req.schedule,
        if req.body_weight_kg > 0.0 {
            req.body_weight_kg
        } else {
            70.0
        },
        req.birth_year,
        &params,
        req.max_cycles.unwrap_or(128),
        req.e2_target,
        req.t_target,
        req.include_series,
    ) {
        Some(report) => ok(json!(report)),
        None => ok(Value::Null),
    }
}

fn handle_plan_dose(text: &str) -> Value {
    #[derive(Deserialize)]
    #[serde(rename_all = "camelCase")]
    struct PlanRequest {
        schedule: Schedule,
        body_weight_kg: f64,
        #[serde(default)]
        birth_year: Option<f64>,
        #[serde(default)]
        params: Option<PkParams>,
        #[serde(default = "default_objective")]
        objective: String,
        target: TargetRange,
        #[serde(default)]
        max_cycles: Option<usize>,
    }

    fn default_objective() -> String {
        "trough".to_string()
    }

    let req: PlanRequest = match parse(text) {
        Ok(r) => r,
        Err(e) => return e,
    };
    let params = req.params.unwrap_or_default().sanitized();
    match planning::solve_dose(
        &req.schedule,
        if req.body_weight_kg > 0.0 {
            req.body_weight_kg
        } else {
            70.0
        },
        req.birth_year,
        &params,
        Objective::parse(&req.objective),
        req.target,
        req.max_cycles.unwrap_or(128),
    ) {
        Some(solution) => ok(json!(solution)),
        None => ok(Value::Null),
    }
}

fn handle_reminders(text: &str) -> Value {
    #[derive(Deserialize)]
    #[serde(rename_all = "camelCase")]
    struct ReminderRequest {
        #[serde(default)]
        events: Vec<DoseEvent>,
        body_weight_kg: f64,
        #[serde(default)]
        birth_year: Option<f64>,
        #[serde(default)]
        params: Option<PkParams>,
        #[serde(default)]
        now_h: f64,
        #[serde(default)]
        clearance_mult: Option<f64>,
        /// Lower bound of the target range.
        low: f64,
        #[serde(default = "default_horizon")]
        horizon_h: f64,
        #[serde(default = "default_lead")]
        lead_h: f64,
        #[serde(default = "default_gap")]
        min_gap_h: f64,
    }

    fn default_horizon() -> f64 {
        24.0 * 14.0
    }
    fn default_lead() -> f64 {
        12.0
    }
    fn default_gap() -> f64 {
        6.0
    }

    let req: ReminderRequest = match parse(text) {
        Ok(r) => r,
        Err(e) => return e,
    };
    let params = req.params.unwrap_or_default().sanitized();
    let end = req.now_h + req.horizon_h;
    let grid = SimGrid {
        start_h: Some(req.now_h),
        end_h: Some(end),
        step_h: Some(0.5),
        max_points: 20_000,
    };
    let Some(sim) = run_simulation_grid(
        &req.events,
        if req.body_weight_kg > 0.0 {
            req.body_weight_kg
        } else {
            70.0
        },
        req.birth_year,
        &params,
        req.now_h,
        req.clearance_mult.unwrap_or(1.0).clamp(0.1, 10.0),
        &grid,
    ) else {
        return ok(json!({"reminders": [], "hoursBelow": 0.0}));
    };
    let drops = reminders::predicted_drops(
        &sim,
        req.low,
        req.now_h,
        req.horizon_h,
        req.lead_h,
        req.min_gap_h,
    );
    let below = reminders::hours_below(&sim, req.low, req.now_h, end);
    ok(json!({
        "reminders": drops,
        "hoursBelow": below,
        "horizonH": req.horizon_h,
        "low": req.low,
    }))
}

fn handle_adherence(text: &str) -> Value {
    #[derive(Deserialize)]
    #[serde(rename_all = "camelCase")]
    struct AdherenceRequest {
        events: Vec<DoseEvent>,
        interval_h: f64,
        from_h: f64,
        to_h: f64,
    }
    let req: AdherenceRequest = match parse(text) {
        Ok(r) => r,
        Err(e) => return e,
    };
    match planning::adherence(&req.events, req.interval_h, req.from_h, req.to_h) {
        Some(report) => ok(json!(report)),
        None => ok(Value::Null),
    }
}

fn handle_supply(text: &str) -> Value {
    #[derive(Deserialize)]
    #[serde(rename_all = "camelCase")]
    struct SupplyRequest {
        #[serde(rename = "onHandMG", alias = "onHandMg")]
        on_hand_mg: f64,
        schedule: Schedule,
        #[serde(default)]
        as_of_h: f64,
    }
    let req: SupplyRequest = match parse(text) {
        Ok(r) => r,
        Err(e) => return e,
    };
    match planning::supply(req.on_hand_mg, &req.schedule, req.as_of_h) {
        Some(report) => ok(json!(report)),
        None => ok(Value::Null),
    }
}

fn handle_convert(text: &str) -> Value {
    #[derive(Deserialize)]
    #[serde(rename_all = "camelCase")]
    struct ConvertRequest {
        #[serde(default = "default_kind")]
        kind: String,
        #[serde(default)]
        value: f64,
        #[serde(default)]
        from: Option<String>,
        #[serde(default)]
        to: Option<String>,
        #[serde(default)]
        analyte: Option<String>,
        #[serde(rename = "doseMG", alias = "doseMg", default)]
        dose_mg: f64,
        #[serde(default)]
        from_ester: Option<String>,
        #[serde(default)]
        to_ester: Option<String>,
    }

    fn default_kind() -> String {
        "concentration".to_string()
    }

    let req: ConvertRequest = match parse(text) {
        Ok(r) => r,
        Err(e) => return e,
    };

    match req.kind.trim().to_ascii_lowercase().as_str() {
        "dose" | "equivalent" => {
            let Some(from) = req.from_ester.as_deref().and_then(Ester::from_code) else {
                return err("badRequest", "fromEster is missing or unknown");
            };
            let to = req
                .to_ester
                .as_deref()
                .and_then(Ester::from_code)
                .unwrap_or(Ester::E2);
            let dose = if req.dose_mg > 0.0 {
                req.dose_mg
            } else {
                req.value
            };
            ok(json!({
                "doseMG": dose,
                "activeMG": units::active_mg(dose, from),
                "equivalentMG": units::dose_equivalent(dose, from, to),
                "fromEster": from.code(),
                "toEster": to.code(),
            }))
        }
        "active" => {
            let Some(ester) = req.from_ester.as_deref().and_then(Ester::from_code) else {
                return err("badRequest", "fromEster is missing or unknown");
            };
            ok(json!({
                "doseMG": req.dose_mg,
                "activeMG": units::active_mg(req.dose_mg, ester),
                "ester": ester.code(),
            }))
        }
        _ => {
            let Some(from) = req.from.as_deref().and_then(LabUnit::from_code) else {
                return err("badRequest", "from is missing or unknown");
            };
            let Some(to) = req.to.as_deref().and_then(LabUnit::from_code) else {
                return err("badRequest", "to is missing or unknown");
            };
            let analyte = req.analyte.as_deref().and_then(Analyte::parse).unwrap_or(
                if from.is_testosterone() {
                    Analyte::Testosterone
                } else {
                    Analyte::Estradiol
                },
            );
            let value = if req.value != 0.0 {
                req.value
            } else {
                req.dose_mg
            };
            ok(json!({
                "value": units::convert_concentration(value, from, to, analyte),
                "from": from.code(),
                "to": to.code(),
                "analyte": analyte.code(),
            }))
        }
    }
}

fn handle_catalog(_text: &str) -> Value {
    ok(json!(catalog::catalog()))
}

fn handle_sublingual(text: &str) -> Value {
    #[derive(Deserialize)]
    #[serde(rename_all = "camelCase")]
    struct SublingualRequest {
        #[serde(default)]
        params: Option<PkParams>,
        #[serde(default)]
        hold_min: Option<f64>,
        #[serde(default)]
        theta: Option<f64>,
    }
    let req: SublingualRequest = match parse(text) {
        Ok(r) => r,
        Err(e) => return e,
    };
    let params = req.params.unwrap_or_default().sanitized();
    let hold = match (req.hold_min, req.theta) {
        (Some(h), _) => h,
        (None, Some(theta)) => engine::sublingual_hold_from_theta(&params, theta.clamp(0.0, 1.0)),
        (None, None) => 10.0,
    };
    let theta = req
        .theta
        .map(|t| t.clamp(0.0, 1.0))
        .unwrap_or_else(|| engine::sublingual_theta_from_hold(&params, hold));
    let tiers = [
        ("quick", 2.0),
        ("casual", 5.0),
        ("standard", 10.0),
        ("strict", 15.0),
    ];
    let nearest = tiers
        .iter()
        .min_by(|a, b| {
            (a.1 - hold)
                .abs()
                .partial_cmp(&(b.1 - hold).abs())
                .unwrap_or(std::cmp::Ordering::Equal)
        })
        .map(|(name, h)| json!({"name": name, "holdMin": h}))
        .unwrap_or(Value::Null);
    ok(json!({
        "holdMin": hold,
        "theta": theta,
        "nearestTier": nearest,
        "effectiveBioavailability": theta + (1.0 - theta) * params.e2_oral_bio,
    }))
}

fn handle_patches(text: &str) -> Value {
    #[derive(Deserialize)]
    struct PatchRequest {
        events: Vec<DoseEvent>,
    }
    let req: PatchRequest = match parse(text) {
        Ok(r) => r,
        Err(e) => return e,
    };
    let pairs = engine::patch_pairs(&req.events);
    let mut out: Vec<Value> = Vec::new();
    for (idx, event) in req.events.iter().enumerate() {
        if event.route != Route::PatchApply {
            continue;
        }
        let removed_at = pairs.get(&idx).copied();
        let wear = removed_at
            .filter(|t| *t > event.time_h)
            .map(|t| t - event.time_h);
        out.push(json!({
            "index": idx,
            "id": event.id,
            "applyH": event.time_h,
            "removeH": removed_at,
            "wearH": wear,
            "plannedWearH": event.planned_wear_h(),
            "overWearH": match (wear, event.planned_wear_h()) {
                (Some(w), Some(p)) => Some((w - p).max(0.0)),
                _ => None,
            },
        }));
    }
    ok(json!(out))
}

fn handle_safety(text: &str) -> Value {
    let req: CommonRequest = match parse(text) {
        Ok(r) => r,
        Err(e) => return e,
    };
    let params = req.params();
    let sim = run_simulation_grid(
        &req.events,
        req.weight(),
        req.birth_year,
        &params,
        req.now_h,
        req.clearance(),
        &req.grid(),
    );
    let stats = sim.as_ref().map(|s| req.stats_for(s, None));
    let warnings = safety::check(SafetyInput {
        events: &req.events,
        labs: &req.labs,
        params: &params,
        stats: stats.as_ref(),
        e2_range: req.e2_target,
        t_range: req.t_target,
        weight: req.weight(),
        now_h: req.now_h,
    });
    ok(json!(warnings))
}

fn handle_sensitivity(text: &str) -> Value {
    #[derive(Deserialize)]
    #[serde(rename_all = "camelCase")]
    struct SensitivityRequest {
        #[serde(default)]
        events: Vec<DoseEvent>,
        #[serde(default)]
        body_weight_kg: f64,
        #[serde(default)]
        birth_year: Option<f64>,
        #[serde(default)]
        params: Option<PkParams>,
        #[serde(default)]
        now_h: f64,
        #[serde(default)]
        clearance_mult: Option<f64>,
        #[serde(default = "default_parameter")]
        parameter: String,
        #[serde(default = "default_pct")]
        pct: f64,
        #[serde(default)]
        start_h: Option<f64>,
        #[serde(default)]
        end_h: Option<f64>,
        #[serde(default)]
        e2_target: Option<TargetRange>,
        #[serde(default)]
        t_target: Option<TargetRange>,
    }

    fn default_parameter() -> String {
        "clearance".to_string()
    }
    fn default_pct() -> f64 {
        20.0
    }

    let req: SensitivityRequest = match parse(text) {
        Ok(r) => r,
        Err(e) => return e,
    };
    let params = req.params.unwrap_or_default().sanitized();
    let window = match (req.start_h, req.end_h) {
        (Some(from), Some(to)) if to > from => Some((from, to)),
        _ => None,
    };
    let points = analysis::sensitivity(
        &req.events,
        if req.body_weight_kg > 0.0 {
            req.body_weight_kg
        } else {
            70.0
        },
        req.birth_year,
        &params,
        req.now_h,
        req.clearance_mult.unwrap_or(1.0).clamp(0.1, 10.0),
        &req.parameter,
        req.pct,
        window,
        req.e2_target,
        req.t_target,
    );
    ok(json!(points))
}

fn handle_blockade(text: &str) -> Value {
    #[derive(Deserialize)]
    #[serde(rename_all = "camelCase")]
    struct BlockadeRequest {
        #[serde(default)]
        events: Vec<DoseEvent>,
        #[serde(default)]
        body_weight_kg: f64,
        #[serde(default)]
        birth_year: Option<f64>,
        #[serde(default)]
        params: Option<PkParams>,
        #[serde(default)]
        now_h: f64,
        #[serde(default)]
        clearance_mult: Option<f64>,
        #[serde(default)]
        window_days: Option<f64>,
    }

    let req: BlockadeRequest = match parse(text) {
        Ok(r) => r,
        Err(e) => return e,
    };
    let params = req.params.unwrap_or_default().sanitized();
    let report = blockade::assess(BlockadeInput {
        events: &req.events,
        params: &params,
        weight: if req.body_weight_kg > 0.0 {
            req.body_weight_kg
        } else {
            70.0
        },
        birth_year: req.birth_year,
        now_h: req.now_h,
        clearance_mult: req.clearance_mult.unwrap_or(1.0).clamp(0.1, 10.0),
        window_days: req.window_days.unwrap_or(blockade::DEFAULT_WINDOW_DAYS),
    });
    ok(json!(report))
}

fn handle_progress(text: &str) -> Value {
    #[derive(Deserialize)]
    #[serde(rename_all = "camelCase")]
    struct ProgressRequest {
        #[serde(default)]
        events: Vec<DoseEvent>,
        #[serde(default)]
        labs: Vec<LabResult>,
        #[serde(default)]
        body_weight_kg: f64,
        #[serde(default)]
        birth_year: Option<f64>,
        #[serde(default)]
        params: Option<PkParams>,
        #[serde(default)]
        now_h: f64,
        #[serde(default)]
        clearance_mult: Option<f64>,
        #[serde(default)]
        e2_target: Option<TargetRange>,
        #[serde(default)]
        t_target: Option<TargetRange>,
    }

    let req: ProgressRequest = match parse(text) {
        Ok(r) => r,
        Err(e) => return e,
    };
    let params = req.params.unwrap_or_default().sanitized();
    let report = progress::assess(ProgressInput {
        events: &req.events,
        labs: &req.labs,
        params: &params,
        weight: if req.body_weight_kg > 0.0 {
            req.body_weight_kg
        } else {
            70.0
        },
        birth_year: req.birth_year,
        now_h: req.now_h,
        clearance_mult: req.clearance_mult.unwrap_or(1.0).clamp(0.1, 10.0),
        e2_target: req.e2_target,
        t_target: req.t_target,
    });
    ok(json!(report))
}

fn handle_compare(text: &str) -> Value {
    #[derive(Deserialize)]
    #[serde(rename_all = "camelCase")]
    struct CompareRequest {
        #[serde(default)]
        arms: Vec<CompareArm>,
        #[serde(default)]
        body_weight_kg: f64,
        #[serde(default)]
        birth_year: Option<f64>,
        #[serde(default)]
        params: Option<PkParams>,
        #[serde(default)]
        e2_target: Option<TargetRange>,
        #[serde(default)]
        t_target: Option<TargetRange>,
        #[serde(default)]
        max_cycles: Option<usize>,
    }

    let req: CompareRequest = match parse(text) {
        Ok(r) => r,
        Err(e) => return e,
    };
    if req.arms.is_empty() {
        return err("badRequest", "compare needs at least one arm");
    }
    let params = req.params.unwrap_or_default().sanitized();
    let report = compare::compare(CompareInput {
        arms: req.arms,
        weight: if req.body_weight_kg > 0.0 {
            req.body_weight_kg
        } else {
            70.0
        },
        birth_year: req.birth_year,
        params,
        e2_target: req.e2_target,
        t_target: req.t_target,
        max_cycles: req.max_cycles.unwrap_or(128),
    });
    ok(json!(report))
}

fn handle_what_if(text: &str) -> Value {
    #[derive(Deserialize)]
    #[serde(rename_all = "camelCase")]
    struct WhatIfRequest {
        #[serde(default)]
        events: Vec<DoseEvent>,
        #[serde(default)]
        body_weight_kg: f64,
        #[serde(default)]
        birth_year: Option<f64>,
        #[serde(default)]
        params: Option<PkParams>,
        #[serde(default)]
        now_h: f64,
        #[serde(default)]
        clearance_mult: Option<f64>,
        #[serde(default)]
        e2_target: Option<TargetRange>,
        #[serde(default)]
        t_target: Option<TargetRange>,
        #[serde(default)]
        analyte: Option<String>,
        #[serde(default)]
        horizon_h: Option<f64>,
        #[serde(default)]
        scenarios: Option<Vec<Scenario>>,
    }

    let req: WhatIfRequest = match parse(text) {
        Ok(r) => r,
        Err(e) => return e,
    };
    if req.events.is_empty() {
        return err("badRequest", "whatIf needs at least one dose on record");
    }
    let params = req.params.unwrap_or_default().sanitized();
    let report = whatif::what_if(WhatIfInput {
        events: &req.events,
        params: &params,
        weight: if req.body_weight_kg > 0.0 {
            req.body_weight_kg
        } else {
            70.0
        },
        birth_year: req.birth_year,
        now_h: req.now_h,
        clearance_mult: req.clearance_mult.unwrap_or(1.0).clamp(0.1, 10.0),
        analyte: req.analyte.as_deref(),
        horizon_h: req.horizon_h,
        scenarios: req.scenarios.unwrap_or_else(whatif::default_scenarios),
        e2_target: req.e2_target,
        t_target: req.t_target,
    });
    ok(json!(report))
}

fn handle_lab_review(text: &str) -> Value {
    #[derive(Deserialize)]
    #[serde(rename_all = "camelCase")]
    struct LabReviewRequest {
        #[serde(default)]
        labs: Vec<LabResult>,
        #[serde(default)]
        now_h: f64,
        #[serde(default)]
        e2_target: Option<TargetRange>,
        #[serde(default)]
        t_target: Option<TargetRange>,
        #[serde(default)]
        cadence_days: Option<f64>,
    }

    let req: LabReviewRequest = match parse(text) {
        Ok(r) => r,
        Err(e) => return e,
    };
    let report = labsreview::review(LabsInput {
        labs: &req.labs,
        now_h: req.now_h,
        e2_target: req.e2_target,
        t_target: req.t_target,
        cadence_days: req.cadence_days,
    });
    ok(json!(report))
}

fn handle_body(text: &str) -> Value {
    #[derive(Deserialize)]
    #[serde(rename_all = "camelCase")]
    struct BodyRequest {
        #[serde(default)]
        measurements: Vec<Measurement>,
        #[serde(default)]
        system: Option<String>,
        #[serde(default)]
        height_cm: Option<f64>,
        #[serde(default)]
        weight_kg: Option<f64>,
    }

    let req: BodyRequest = match parse(text) {
        Ok(r) => r,
        Err(e) => return e,
    };
    let report = body::assess(BodyInput {
        measurements: &req.measurements,
        system: Some(
            req.system
                .as_deref()
                .and_then(CupSystem::parse)
                .unwrap_or(CupSystem::Eu),
        ),
        height_cm: req.height_cm,
        weight_kg: req.weight_kg,
    });
    ok(json!(report))
}

fn handle_batch(text: &str) -> Value {
    #[derive(Deserialize)]
    struct BatchRequest {
        calls: Vec<BatchCall>,
    }
    #[derive(Deserialize)]
    struct BatchCall {
        function: String,
        #[serde(default)]
        input: Value,
    }

    let req: BatchRequest = match parse(text) {
        Ok(r) => r,
        Err(e) => return e,
    };
    let mut results: Vec<Value> = Vec::with_capacity(req.calls.len());
    for call in req.calls.iter().take(64) {
        let payload = match &call.input {
            Value::Null => "{}".to_string(),
            Value::String(s) => s.clone(),
            other => other.to_string(),
        };
        results.push(dispatch(&call.function, &payload));
    }
    ok(json!({ "results": results }))
}

// --- Dispatch -------------------------------------------------------------

fn dispatch(name: &str, input: &str) -> Value {
    match name {
        "simulate" => handle_simulate(input),
        "stats" => handle_stats(input),
        "calibrate" => handle_calibrate(input),
        "steadyState" => handle_steady_state(input),
        "planDose" => handle_plan_dose(input),
        "reminders" => handle_reminders(input),
        "adherence" => handle_adherence(input),
        "supply" => handle_supply(input),
        "convert" => handle_convert(input),
        "catalog" => handle_catalog(input),
        "sublingual" => handle_sublingual(input),
        "patches" => handle_patches(input),
        "safety" => handle_safety(input),
        "sensitivity" => handle_sensitivity(input),
        "blockade" => handle_blockade(input),
        "progress" => handle_progress(input),
        "compare" => handle_compare(input),
        "whatIf" => handle_what_if(input),
        "labReview" => handle_lab_review(input),
        "body" => handle_body(input),
        "batch" => handle_batch(input),
        "version" => ok(json!(env!("CARGO_PKG_VERSION"))),
        "capabilities" => ok(capabilities()),
        other => err("unknownFunction", format!("unknown function: {other}")),
    }
}

fn capabilities() -> Value {
    json!({
        "abi": ABI_VERSION,
        "version": env!("CARGO_PKG_VERSION"),
        "functions": [
            {"name": "simulate", "summary": "Concentration curves for a set of doses.",
             "input": ["events", "bodyWeightKg", "nowH", "birthYear", "params", "clearanceMult", "startH", "endH", "stepH", "includeStats", "e2Target", "tTarget"]},
            {"name": "stats", "summary": "Peak, trough, mean, AUC and time in range for a window.",
             "input": ["events", "bodyWeightKg", "nowH", "startH", "endH", "stepH", "e2Target", "tTarget"]},
            {"name": "calibrate", "summary": "Fit the model to lab results (mipd, ekf, ou_kalman).",
             "input": ["events", "labs", "bodyWeightKg", "nowH", "method", "historyMode", "birthYear", "params"]},
            {"name": "steadyState", "summary": "Where a repeated schedule settles, and how many doses it takes.",
             "input": ["schedule", "bodyWeightKg", "maxCycles", "birthYear", "params", "e2Target", "tTarget", "includeSeries"]},
            {"name": "planDose", "summary": "Dose that puts a trough, peak or mean inside a target range.",
             "input": ["schedule", "target", "objective", "bodyWeightKg", "maxCycles", "birthYear", "params"]},
            {"name": "reminders", "summary": "Times the level falls through a lower bound, shifted earlier by a lead time.",
             "input": ["events", "low", "nowH", "horizonH", "leadH", "minGapH", "bodyWeightKg", "birthYear", "params"]},
            {"name": "adherence", "summary": "Coverage, on-time percentage and gaps against a fixed interval.",
             "input": ["events", "intervalH", "fromH", "toH"]},
            {"name": "supply", "summary": "How long the supply lasts at the planned rate.",
             "input": ["onHandMG", "schedule", "asOfH"]},
            {"name": "convert", "summary": "Concentration units and ester dose equivalence.",
             "input": ["kind", "value", "from", "to", "analyte", "doseMG", "fromEster", "toEster"]},
            {"name": "catalog", "summary": "Esters, routes, units and default targets as data.", "input": []},
            {"name": "sublingual", "summary": "Hold time and mucosal fraction, either direction.",
             "input": ["holdMin", "theta", "params"]},
            {"name": "patches", "summary": "Which removal ended which application, and how long it was worn.",
             "input": ["events"]},
            {"name": "safety", "summary": "Doses the model ignores, and curve/range conflicts.",
             "input": ["events", "labs", "bodyWeightKg", "nowH", "e2Target", "tTarget", "params"]},
            {"name": "sensitivity", "summary": "How much the curve moves when clearance, weight or dose is off by a percentage.",
             "input": ["events", "parameter", "pct", "bodyWeightKg", "nowH", "startH", "endH"]},
            {"name": "blockade", "summary": "Anti-androgen dose bands, coverage, modelled level and the next dose due.",
             "input": ["events", "bodyWeightKg", "nowH", "windowDays", "birthYear", "params", "clearanceMult"]},
            {"name": "progress", "summary": "Conservative testosterone suppression and treatment effectiveness over a day, a month and a year.",
             "input": ["events", "labs", "bodyWeightKg", "nowH", "e2Target", "tTarget", "birthYear", "params", "clearanceMult"]},
            {"name": "compare", "summary": "Several regimens settled side by side, with the steadiest, the highest and the cheapest called out.",
             "input": ["arms", "bodyWeightKg", "birthYear", "params", "e2Target", "tTarget", "maxCycles"]},
            {"name": "whatIf", "summary": "The record with one dose changed: skip, double, delay or stop, against the record as logged.",
             "input": ["events", "bodyWeightKg", "nowH", "analyte", "horizonH", "scenarios", "e2Target", "tTarget", "birthYear", "params", "clearanceMult"]},
            {"name": "labReview", "summary": "Read a lab panel back: in range, trend, and how overdue the next one is.",
             "input": ["labs", "nowH", "e2Target", "tTarget", "cadenceDays"]},
            {"name": "body", "summary": "Bust, underbust and the cup size they imply in each sizing system.",
             "input": ["measurements", "system", "heightCm", "weightKg"]},
            {"name": "batch", "summary": "Several calls in one crossing of the FFI boundary.",
             "input": ["calls"]},
            {"name": "version", "summary": "Semantic version of the library.", "input": []},
            {"name": "capabilities", "summary": "This list.", "input": []}
        ]
    })
}

// --- Exported symbols -----------------------------------------------------

fn respond(name: &str, input: *const c_char) -> *mut c_char {
    let result = catch_unwind(AssertUnwindSafe(|| {
        let text = match unsafe { read_input(input) } {
            Ok(text) => text,
            Err(e) => return e,
        };
        dispatch(name, text)
    }));

    match result {
        Ok(value) => into_c_string(value),
        Err(_) => into_c_string(err("panic", "the engine panicked on this input")),
    }
}

macro_rules! exported {
    ($(#[$meta:meta])* $name:ident => $key:literal) => {
        $(#[$meta])*
        #[no_mangle]
        pub extern "C" fn $name(input: *const c_char) -> *mut c_char {
            respond($key, input)
        }
    };
}

exported!(
    /// Simulate concentration curves.
    hrt_simulate => "simulate"
);
exported!(
    /// Peak/trough/mean/AUC/time-in-range for a window.
    hrt_stats => "stats"
);
exported!(
    /// Fit the model to lab results.
    hrt_calibrate => "calibrate"
);
exported!(
    /// Where a repeated schedule settles.
    hrt_steady_state => "steadyState"
);
exported!(
    /// Solve for a dose that lands in a target range.
    hrt_plan_dose => "planDose"
);
exported!(
    /// Predict when the level will leave the target range.
    hrt_reminders => "reminders"
);
exported!(
    /// Coverage and gaps against a planned interval.
    hrt_adherence => "adherence"
);
exported!(
    /// Supply runway at the planned rate.
    hrt_supply => "supply"
);
exported!(
    /// Unit and dose-equivalence conversion.
    hrt_convert => "convert"
);
exported!(
    /// The built-in catalogue of esters, routes and units.
    hrt_catalog => "catalog"
);
exported!(
    /// Sublingual hold time ↔ mucosal fraction.
    hrt_sublingual => "sublingual"
);
exported!(
    /// Patch application/removal pairing.
    hrt_patches => "patches"
);
exported!(
    /// Plausibility warnings about a record.
    hrt_safety => "safety"
);
exported!(
    /// Parameter sensitivity of the curve.
    hrt_sensitivity => "sensitivity"
);
exported!(
    /// Anti-androgen dose bands, coverage and the next dose due.
    hrt_blockade => "blockade"
);
exported!(
    /// Conservative suppression and effectiveness over day, month and year.
    hrt_progress => "progress"
);
exported!(
    /// Several regimens settled side by side.
    hrt_compare => "compare"
);
exported!(
    /// The record with one dose changed, against the record as logged.
    hrt_what_if => "whatIf"
);
exported!(
    /// Read a lab panel back: in range, moving, overdue.
    hrt_lab_review => "labReview"
);
exported!(
    /// Bust, underbust and the cup size they imply.
    hrt_body => "body"
);
exported!(
    /// Several calls in one crossing.
    hrt_batch => "batch"
);

/// Free a string returned by any of the functions above.
///
/// # Safety
///
/// `ptr` must be a pointer returned by this library and not yet freed, or null.
#[no_mangle]
pub unsafe extern "C" fn hrt_free(ptr: *mut c_char) {
    if ptr.is_null() {
        return;
    }
    drop(CString::from_raw(ptr));
}

/// The ABI version. A caller that expects a different number should refuse to
/// use the library rather than misread a newer payload.
#[no_mangle]
pub extern "C" fn hrt_abi_version() -> i32 {
    ABI_VERSION
}

/// Human-readable core version, as JSON.
#[no_mangle]
pub extern "C" fn hrt_version() -> *mut c_char {
    into_c_string(ok(json!(env!("CARGO_PKG_VERSION"))))
}

/// Every entry point with the fields it accepts, as JSON.
#[no_mangle]
pub extern "C" fn hrt_capabilities() -> *mut c_char {
    into_c_string(ok(capabilities()))
}

#[cfg(test)]
mod tests {
    use super::*;

    fn call(name: &str, input: &str) -> Value {
        dispatch(name, input)
    }

    #[test]
    fn unknown_functions_are_reported_not_ignored() {
        let v = call("nope", "{}");
        assert_eq!(v["ok"], json!(false));
        assert_eq!(v["code"], json!("unknownFunction"));
    }

    #[test]
    fn malformed_json_is_an_error_object() {
        let v = call("simulate", "{not json");
        assert_eq!(v["ok"], json!(false));
        assert_eq!(v["code"], json!("badRequest"));
    }

    #[test]
    fn simulate_returns_a_curve_for_a_real_schedule() {
        let input = r#"{
            "events": [{"id":"a","route":"injection","timeH":0,"doseMG":4,"ester":"EV"}],
            "bodyWeightKg": 70, "nowH": 72
        }"#;
        let v = call("simulate", input);
        assert_eq!(v["ok"], json!(true));
        let curve = &v["result"];
        assert!(curve["timeH"].as_array().unwrap().len() > 100);
        let peak = curve["e2PgMl"]
            .as_array()
            .unwrap()
            .iter()
            .filter_map(|x| x.as_f64())
            .fold(0.0, f64::max);
        assert!(peak > 20.0, "peak {peak}");
    }

    #[test]
    fn catalog_lists_the_esters() {
        let v = call("catalog", "{}");
        let esters = v["result"]["esters"].as_array().unwrap();
        assert_eq!(esters.len(), 17);
        assert_eq!(v["result"]["abi"], json!(ABI_VERSION));
    }

    #[test]
    fn batch_runs_several_calls_in_one_go() {
        let input = r#"{"calls":[
            {"function":"version"},
            {"function":"convert","input":{"kind":"dose","doseMG":2,"fromEster":"EV","toEster":"E2"}}
        ]}"#;
        let v = call("batch", input);
        let results = v["result"]["results"].as_array().unwrap();
        assert_eq!(results.len(), 2);
        assert_eq!(results[0]["ok"], json!(true));
        assert!((results[1]["result"]["equivalentMG"].as_f64().unwrap() - 1.53).abs() < 0.02);
    }

    #[test]
    fn time_unit_round_trips() {
        let v = call(
            "convert",
            r#"{"kind":"concentration","value":100,"from":"pg/ml","to":"pmol/l","analyte":"e2"}"#,
        );
        let pmol = v["result"]["value"].as_f64().unwrap();
        assert!((pmol - 367.1).abs() < 0.2, "{pmol}");
    }

    #[test]
    fn compare_settles_every_arm() {
        let input = r#"{
            "arms": [
                {"label":"weekly","schedule":{"route":"injection","ester":"EV","doseMG":4,"intervalH":168}},
                {"label":"daily","schedule":{"route":"oral","ester":"E2","doseMG":0.5,"intervalH":24}}
            ],
            "bodyWeightKg": 70, "e2Target": {"low":100,"high":200}
        }"#;
        let v = call("compare", input);
        assert_eq!(v["ok"], json!(true));
        let arms = v["result"]["arms"].as_array().unwrap();
        assert_eq!(arms.len(), 2);
        assert!(arms[0]["curve"]["peak"].as_f64().unwrap() > 0.0);
        assert!(v["result"]["steadiest"].is_string());
    }

    #[test]
    fn what_if_reports_a_delta_per_scenario() {
        let input = r#"{
            "events": [{"id":"a","route":"injection","timeH":0,"doseMG":4,"ester":"EV"},
                       {"id":"b","route":"injection","timeH":168,"doseMG":4,"ester":"EV"}],
            "bodyWeightKg": 70, "nowH": 100, "horizonH": 672,
            "e2Target": {"low":100,"high":200}
        }"#;
        let v = call("whatIf", input);
        assert_eq!(v["ok"], json!(true));
        let rows = v["result"]["scenarios"].as_array().unwrap();
        assert_eq!(rows[0]["id"], json!("baseline"));
        assert_eq!(rows[0]["verdict"], json!("reference"));
        assert!(rows.iter().any(|r| r["id"] == json!("skipNextDose")));
    }

    #[test]
    fn lab_review_flags_an_out_of_range_value() {
        let input = r#"{
            "labs": [{"id":"a","timeH":4560,"concValue":320,"unit":"pg/ml"}],
            "nowH": 4800, "e2Target": {"low":100,"high":200}
        }"#;
        let v = call("labReview", input);
        assert_eq!(v["result"]["above"], json!(1));
        assert_eq!(v["result"]["readings"][0]["status"], json!("above"));
    }

    #[test]
    fn body_returns_a_label_per_system() {
        let input = r#"{
            "measurements": [{"timeH":0,"bustCm":91,"underbustCm":76}],
            "system": "cn"
        }"#;
        let v = call("body", input);
        assert_eq!(v["ok"], json!(true));
        assert_eq!(v["result"]["system"], json!("cn"));
        let sizes = v["result"]["sizes"].as_array().unwrap();
        assert_eq!(sizes.len(), 4);
        assert_eq!(sizes[0]["label"], json!("75C"));
    }

    #[test]
    fn sensitivity_returns_two_directions() {
        let input = r#"{
            "events": [{"id":"a","route":"injection","timeH":0,"doseMG":4,"ester":"EV"},
                       {"id":"b","route":"injection","timeH":168,"doseMG":4,"ester":"EV"}],
            "bodyWeightKg": 70, "nowH": 200, "parameter": "clearance", "pct": 20
        }"#;
        let v = call("sensitivity", input);
        assert_eq!(v["result"].as_array().unwrap().len(), 2);
    }
}
