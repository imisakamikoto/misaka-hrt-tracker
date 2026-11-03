//! What the record would look like if one thing changed.
//!
//! Adherence questions are not hypotheticals for the person asking them: what
//! happens if I miss Thursday, if I take two on Friday, if I stop for a
//! fortnight before surgery. The engine already knows how to draw the curve —
//! this module draws it twice, once as recorded and once with the change
//! applied, and reports the difference rather than the absolute numbers.
//!
//! A change is only ever applied to doses that have not happened yet. Editing
//! the past to make a scenario look better is the one thing a what-if tool must
//! not do, so anything at or before `nowH` is left exactly as logged.

use serde::{Deserialize, Serialize};

use crate::engine::{run_simulation_grid, SimGrid};
use crate::model::*;
use crate::stats::{simulation_stats, CurveStats};

/// How far ahead a scenario is read, in hours. Four weeks covers several
/// intervals of every route the model supports.
pub const DEFAULT_HORIZON_H: f64 = 24.0 * 28.0;

/// A single change to apply to the not-yet-taken part of the record.
#[derive(Debug, Clone, Deserialize)]
#[serde(tag = "kind", rename_all = "camelCase")]
pub enum Scenario {
    /// Leave the record alone. Always worth having as the reference row.
    Baseline,
    /// Drop the next scheduled dose.
    SkipNextDose,
    /// Take twice the next scheduled dose.
    DoubleNextDose,
    /// Take half the next scheduled dose.
    HalveNextDose,
    /// Move the next dose later.
    DelayNextDose {
        #[serde(default = "default_delay_h")]
        hours: f64,
    },
    /// Take nothing for a while, then resume the schedule as planned.
    StopFor { hours: f64 },
}

fn default_delay_h() -> f64 {
    12.0
}

impl Scenario {
    /// Machine-readable code, also used as the row id.
    pub fn code(&self) -> &'static str {
        match self {
            Scenario::Baseline => "baseline",
            Scenario::SkipNextDose => "skipNextDose",
            Scenario::DoubleNextDose => "doubleNextDose",
            Scenario::HalveNextDose => "halveNextDose",
            Scenario::DelayNextDose { .. } => "delayNextDose",
            Scenario::StopFor { .. } => "stopFor",
        }
    }

    fn label(&self) -> String {
        match self {
            Scenario::Baseline => "As recorded".into(),
            Scenario::SkipNextDose => "Skip the next dose".into(),
            Scenario::DoubleNextDose => "Double the next dose".into(),
            Scenario::HalveNextDose => "Halve the next dose".into(),
            Scenario::DelayNextDose { hours } => format!("Delay the next dose by {hours:.0} h"),
            Scenario::StopFor { hours } => format!("Stop for {hours:.0} h"),
        }
    }
}

/// The scenarios offered when the caller does not name any.
pub fn default_scenarios() -> Vec<Scenario> {
    vec![
        Scenario::Baseline,
        Scenario::SkipNextDose,
        Scenario::DoubleNextDose,
        Scenario::DelayNextDose { hours: 12.0 },
    ]
}

#[derive(Debug, Clone, Serialize)]
#[serde(rename_all = "camelCase")]
pub struct ScenarioReport {
    pub id: &'static str,
    pub label: String,
    /// False when the record had nothing for the change to act on.
    pub applied: bool,
    /// How many doses the change touched.
    pub changes: usize,
    pub curve: Option<CurveStats>,
    /// Percent change of the time-weighted mean against the baseline.
    pub mean_delta_pct: Option<f64>,
    pub trough_delta_pct: Option<f64>,
    pub peak_delta_pct: Option<f64>,
    /// `reference`, `same`, `lower`, `higher`, `dipsBelowTarget`, `noChange`
    /// or `noCurve`.
    pub verdict: &'static str,
    pub note: &'static str,
}

#[derive(Debug, Clone, Serialize)]
#[serde(rename_all = "camelCase")]
pub struct WhatIfReport {
    pub analyte: &'static str,
    pub start_h: f64,
    pub horizon_h: f64,
    pub target: Option<TargetRange>,
    pub baseline: Option<CurveStats>,
    pub scenarios: Vec<ScenarioReport>,
    pub note: &'static str,
}

pub struct WhatIfInput<'a> {
    pub events: &'a [DoseEvent],
    pub params: &'a PkParams,
    pub weight: f64,
    pub birth_year: Option<f64>,
    pub now_h: f64,
    pub clearance_mult: f64,
    /// `e2`, `t`, `cpa` or `spiro`. Defaults to `e2`.
    pub analyte: Option<&'a str>,
    pub horizon_h: Option<f64>,
    pub scenarios: Vec<Scenario>,
    pub e2_target: Option<TargetRange>,
    pub t_target: Option<TargetRange>,
}

fn curve_for(stats: &crate::stats::SimulationStats, analyte: &str) -> Option<CurveStats> {
    match analyte {
        "e2" => stats.e2.clone(),
        "t" => stats.t.clone(),
        "cpa" => stats.cpa.clone(),
        "spiro" => stats.spiro.clone(),
        _ => None,
    }
}

/// Index of the first dose strictly after `now_h`, if any.
fn next_index(events: &[DoseEvent], now_h: f64) -> Option<usize> {
    let mut best: Option<(usize, f64)> = None;
    for (i, e) in events.iter().enumerate() {
        if e.time_h > now_h && best.map_or(true, |(_, t)| e.time_h < t) {
            best = Some((i, e.time_h));
        }
    }
    best.map(|(i, _)| i)
}

/// Apply one scenario and count what it touched.
fn apply(scenario: &Scenario, events: &[DoseEvent], now_h: f64) -> (Vec<DoseEvent>, usize) {
    let mut out: Vec<DoseEvent> = events.to_vec();
    let next = next_index(&out, now_h);
    let mut changes = 0;

    match scenario {
        Scenario::Baseline => {}
        Scenario::SkipNextDose => {
            if let Some(i) = next {
                out.remove(i);
                changes = 1;
            }
        }
        Scenario::DoubleNextDose => {
            if let Some(i) = next {
                out[i].dose_mg *= 2.0;
                changes = 1;
            }
        }
        Scenario::HalveNextDose => {
            if let Some(i) = next {
                out[i].dose_mg *= 0.5;
                changes = 1;
            }
        }
        Scenario::DelayNextDose { hours } => {
            if let Some(i) = next {
                let shift = if hours.is_finite() { *hours } else { 0.0 };
                out[i].time_h += shift;
                changes = if shift != 0.0 { 1 } else { 0 };
            }
        }
        Scenario::StopFor { hours } => {
            let window = if hours.is_finite() && *hours > 0.0 {
                *hours
            } else {
                0.0
            };
            let before = out.len();
            out.retain(|e| !(e.time_h > now_h && e.time_h <= now_h + window));
            changes = before - out.len();
        }
    }

    (out, changes)
}

fn pct_delta(value: f64, reference: f64) -> Option<f64> {
    if !value.is_finite() || !reference.is_finite() || reference.abs() < 1e-9 {
        return None;
    }
    Some((value - reference) / reference * 100.0)
}

fn verdict_for(
    applied: bool,
    base: Option<&CurveStats>,
    cur: Option<&CurveStats>,
    target: Option<TargetRange>,
) -> &'static str {
    if !applied {
        return "noChange";
    }
    let (Some(base), Some(cur)) = (base, cur) else {
        return "noCurve";
    };
    if let Some(range) = target.and_then(|r| r.normalized()) {
        let dipped = cur.trough < range.low && base.trough >= range.low;
        if dipped {
            return "dipsBelowTarget";
        }
    }
    match pct_delta(cur.mean, base.mean) {
        Some(d) if d <= -5.0 => "lower",
        Some(d) if d >= 5.0 => "higher",
        Some(_) => "same",
        None => "noCurve",
    }
}

fn note_for(verdict: &'static str) -> &'static str {
    match verdict {
        "lower" => "Lowers exposure over the window without taking it out of range.",
        "higher" => {
            "Raises exposure over the window. With a slow ester the extra dose also arrives \
             when the previous one is still being absorbed, so the peak climbs more than the \
             trough does."
        }
        "dipsBelowTarget" => {
            "Takes the trough below the target range before the next dose. This is the case \
             worth changing the schedule for rather than the dose."
        }
        "same" => "Moves the mean by less than 5%, which is inside the model's own error.",
        "reference" => "The record as logged, read over the same window as every other row.",
        "noChange" => "Nothing in the record was scheduled after now, so nothing was changed.",
        _ => "No curve was produced for this scenario.",
    }
}

/// Fold whatever the caller typed into one of the four curve codes.
fn normalize_analyte(raw: Option<&str>) -> &'static str {
    match raw.map(|s| s.trim().to_ascii_lowercase()).as_deref() {
        Some("t") | Some("testosterone") => "t",
        Some("cpa") | Some("cyproterone") => "cpa",
        Some("spiro") | Some("canrenone") => "spiro",
        _ => "e2",
    }
}

pub fn what_if(input: WhatIfInput) -> WhatIfReport {
    let analyte = normalize_analyte(input.analyte);
    let horizon = input
        .horizon_h
        .filter(|h| h.is_finite() && *h > 0.0)
        .unwrap_or(DEFAULT_HORIZON_H);
    let start = input.now_h;
    let target = match analyte {
        "t" => input.t_target,
        _ => input.e2_target,
    };
    let step = (horizon / 480.0).clamp(0.02, 6.0);

    let read = |events: &[DoseEvent]| -> Option<CurveStats> {
        let grid = SimGrid::uniform(start, start + horizon, step);
        let sim = run_simulation_grid(
            events,
            input.weight,
            input.birth_year,
            input.params,
            start,
            input.clearance_mult,
            &grid,
        )?;
        let stats = simulation_stats(&sim, Some((start, start + horizon)), input.e2_target, input.t_target);
        curve_for(&stats, analyte)
    };

    let base_curve = read(input.events);

    let scenarios: Vec<ScenarioReport> = input
        .scenarios
        .iter()
        .take(8)
        .map(|scenario| {
            let (events, changes) = apply(scenario, input.events, start);
            let curve = read(&events);
            let verdict = if matches!(scenario, Scenario::Baseline) {
                "reference"
            } else {
                verdict_for(
                    changes > 0,
                    base_curve.as_ref(),
                    curve.as_ref(),
                    target,
                )
            };
            ScenarioReport {
                id: scenario.code(),
                label: scenario.label(),
                applied: changes > 0 || matches!(scenario, Scenario::Baseline),
                changes,
                mean_delta_pct: curve
                    .as_ref()
                    .zip(base_curve.as_ref())
                    .and_then(|(c, b)| pct_delta(c.mean, b.mean)),
                trough_delta_pct: curve
                    .as_ref()
                    .zip(base_curve.as_ref())
                    .and_then(|(c, b)| pct_delta(c.trough, b.trough)),
                peak_delta_pct: curve
                    .as_ref()
                    .zip(base_curve.as_ref())
                    .and_then(|(c, b)| pct_delta(c.peak, b.peak)),
                curve,
                verdict,
                note: note_for(verdict),
            }
        })
        .collect();

    WhatIfReport {
        analyte,
        start_h: start,
        horizon_h: horizon,
        target: target.and_then(|r| r.normalized()),
        baseline: base_curve,
        scenarios,
        note: "Only doses after `nowH` are altered; the logged past is never rewritten. \
               Every row is read over the same window, so the deltas are comparable.",
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    fn weekly(count: usize) -> Vec<DoseEvent> {
        (0..count)
            .map(|i| DoseEvent {
                id: format!("d{i}"),
                route: Route::Injection,
                time_h: i as f64 * 168.0,
                dose_mg: 4.0,
                ester: Ester::EV,
                extras: Default::default(),
                updated_at: None,
            })
            .collect()
    }

    fn run(scenarios: Vec<Scenario>) -> WhatIfReport {
        let events = weekly(6);
        what_if(WhatIfInput {
            events: &events,
            params: &PkParams::default(),
            weight: 70.0,
            birth_year: None,
            now_h: 168.0 * 3.0 + 12.0,
            clearance_mult: 1.0,
            analyte: Some("e2"),
            horizon_h: Some(168.0 * 4.0),
            scenarios,
            e2_target: Some(TargetRange::new(100.0, 200.0)),
            t_target: None,
        })
    }

    #[test]
    fn skipping_the_next_dose_lowers_the_trough() {
        let report = run(vec![Scenario::Baseline, Scenario::SkipNextDose]);
        let base = report.baseline.as_ref().expect("baseline");
        let skip = &report.scenarios[1];
        assert!(skip.applied);
        assert_eq!(skip.changes, 1);
        let curve = skip.curve.as_ref().expect("skip curve");
        assert!(curve.trough < base.trough, "{} vs {}", curve.trough, base.trough);
        assert!(skip.trough_delta_pct.expect("delta") < 0.0);
    }

    #[test]
    fn doubling_the_next_dose_raises_the_peak() {
        let report = run(vec![Scenario::Baseline, Scenario::DoubleNextDose]);
        let base = report.baseline.as_ref().expect("baseline");
        let double = report.scenarios[1].curve.as_ref().expect("curve");
        assert!(double.peak > base.peak);
    }

    #[test]
    fn a_change_with_nothing_to_act_on_is_reported_as_untouched() {
        let events = weekly(2);
        let report = what_if(WhatIfInput {
            events: &events,
            params: &PkParams::default(),
            weight: 70.0,
            birth_year: None,
            now_h: 10_000.0,
            clearance_mult: 1.0,
            analyte: Some("e2"),
            horizon_h: Some(168.0),
            scenarios: vec![Scenario::SkipNextDose],
            e2_target: None,
            t_target: None,
        });
        assert_eq!(report.scenarios[0].verdict, "noChange");
        assert!(!report.scenarios[0].applied);
    }

    #[test]
    fn the_past_is_never_rewritten() {
        let events = weekly(6);
        let (after, changes) = apply(&Scenario::SkipNextDose, &events, 168.0 * 3.0 + 12.0);
        assert_eq!(changes, 1);
        // The first four doses (t = 0, 168, 336, 504) are all at or before now,
        // so only the dose at 672 is dropped.
        assert_eq!(after.len(), 5);
        assert!(after.iter().all(|e| e.time_h <= 168.0 * 3.0 + 12.0 || e.time_h > 672.0));
    }
}
