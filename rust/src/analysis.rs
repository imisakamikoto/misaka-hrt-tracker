//! "What if I am wrong about this?"
//!
//! Every number in the model is an estimate. A person deciding whether to
//! change a schedule deserves to know which estimates the answer is sensitive
//! to: if a 20% error in clearance moves the trough by 4%, the plan is robust;
//! if it moves it by 40%, the plan is a guess wearing a number.

use serde::Serialize;

use crate::engine::run_simulation;
use crate::model::*;
use crate::stats::simulation_stats;

#[derive(Debug, Clone, Serialize)]
#[serde(rename_all = "camelCase")]
pub struct SensitivityPoint {
    /// `clearance`, `weight` or `dose`.
    pub parameter: String,
    /// The perturbation applied, in percent.
    pub delta_pct: f64,
    pub peak_change_pct: f64,
    pub trough_change_pct: f64,
    pub auc_change_pct: f64,
}

fn relative_change(base: f64, perturbed: f64) -> f64 {
    if base.abs() < 1e-9 {
        return 0.0;
    }
    (perturbed - base) / base * 100.0
}

fn measure(
    events: &[DoseEvent],
    weight: f64,
    birth_year: Option<f64>,
    params: &PkParams,
    now_h: f64,
    clearance_mult: f64,
    window: Option<(f64, f64)>,
    e2_range: Option<TargetRange>,
    t_range: Option<TargetRange>,
) -> Option<(f64, f64, f64)> {
    let sim = run_simulation(events, weight, birth_year, params, now_h, clearance_mult)?;
    let stats = simulation_stats(&sim, window, e2_range, t_range);
    let curve = stats.e2.or(stats.t)?;
    Some((curve.peak, curve.trough, curve.auc))
}

/// Perturb one parameter up and down and report how much the curve moves.
///
/// `parameter` is `clearance` (the personal multiplier the calibration
/// produces), `weight` (volume of distribution) or `dose` (every logged
/// amount, which is the "what if I have been drawing 0.2 mL more" question).
pub fn sensitivity(
    events: &[DoseEvent],
    weight: f64,
    birth_year: Option<f64>,
    params: &PkParams,
    now_h: f64,
    clearance_mult: f64,
    parameter: &str,
    pct: f64,
    window: Option<(f64, f64)>,
    e2_range: Option<TargetRange>,
    t_range: Option<TargetRange>,
) -> Vec<SensitivityPoint> {
    let key = parameter.trim().to_ascii_lowercase();
    if !matches!(key.as_str(), "clearance" | "weight" | "dose") || !(pct > 0.0) || pct > 90.0 {
        return Vec::new();
    }

    let Some((base_peak, base_trough, base_auc)) = measure(
        events,
        weight,
        birth_year,
        params,
        now_h,
        clearance_mult,
        window,
        e2_range,
        t_range,
    ) else {
        return Vec::new();
    };

    let mut out = Vec::with_capacity(2);
    for sign in [1.0, -1.0] {
        let factor = 1.0 + sign * pct / 100.0;
        let scaled: Vec<DoseEvent>;
        let (use_events, use_weight, use_clearance) = match key.as_str() {
            "weight" => (events, weight * factor, clearance_mult),
            "dose" => {
                scaled = events
                    .iter()
                    .map(|e| DoseEvent {
                        dose_mg: e.dose_mg * factor,
                        ..e.clone()
                    })
                    .collect();
                (scaled.as_slice(), weight, clearance_mult)
            }
            _ => (events, weight, clearance_mult * factor),
        };
        let Some((peak, trough, auc)) = measure(
            use_events,
            use_weight,
            birth_year,
            params,
            now_h,
            use_clearance,
            window,
            e2_range,
            t_range,
        ) else {
            continue;
        };
        out.push(SensitivityPoint {
            parameter: key.clone(),
            delta_pct: sign * pct,
            peak_change_pct: relative_change(base_peak, peak),
            trough_change_pct: relative_change(base_trough, trough),
            auc_change_pct: relative_change(base_auc, auc),
        });
    }
    out
}

#[cfg(test)]
mod tests {
    use super::*;
    use std::collections::HashMap;

    #[test]
    fn doubling_clearance_lowers_the_curve() {
        let events: Vec<DoseEvent> = (0..30)
            .map(|d| DoseEvent {
                id: format!("d{d}"),
                route: Route::Injection,
                time_h: d as f64 * 168.0,
                dose_mg: 4.0,
                ester: Ester::EV,
                extras: HashMap::new(),
                updated_at: None,
            })
            .collect();
        let params = PkParams::default();
        let points = sensitivity(
            &events,
            70.0,
            None,
            &params,
            30.0 * 168.0,
            1.0,
            "clearance",
            50.0,
            Some((8.0 * 168.0, 30.0 * 168.0)),
            None,
            None,
        );
        assert_eq!(points.len(), 2);
        let up = points.iter().find(|p| p.delta_pct > 0.0).unwrap();
        assert!(up.trough_change_pct < 0.0, "{}", up.trough_change_pct);
    }
}
