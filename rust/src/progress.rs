//! Progress over a day, a month and a year, in the most conservative direction.
//!
//! "Conservative" here has a definition, not a mood. Two numbers are reported:
//!
//! * **Testosterone suppression** — the share of measured testosterone values
//!   below the female ceiling, reported as the one-sided 95% Wilson lower
//!   bound rather than the raw share. One lab under the ceiling is not 100%
//!   suppression, and the bound says so.
//! * **Treatment effectiveness** — the modelled share of the window inside the
//!   oestrogen target range, and the share of the planned doses that were
//!   actually logged, reported as the *lower* of the two. A regimen that is
//!   perfect on paper but taken half the time is half effective; a regimen
//!   taken perfectly but sitting above the range is the same.
//!
//! Three independent sources feed this: the logs (coverage), the model (time
//! in range) and the lab results (measured suppression). Where they disagree,
//! the weaker one wins, which is the whole point of calling it conservative.
//!
//! It deliberately does not credit any compound with suppression it has not
//! been shown to cause. Testosterone suppression is measured from labs, never
//! inferred from the presence of an anti-androgen.

use serde::Serialize;

use crate::engine::{run_simulation_grid, SimGrid};
use crate::model::*;
use crate::planning::adherence;
use crate::stats::simulation_stats;

/// The upper end of the female reference range for total testosterone, ng/dL.
pub const T_CEILING_NG_DL: f64 = 50.0;

/// One-sided 95% normal quantile, for the Wilson lower bound.
const Z_ONE_SIDED: f64 = 1.644_853_6;

#[derive(Debug, Clone, Serialize)]
#[serde(rename_all = "camelCase")]
pub struct WindowProgress {
    /// `day`, `month` or `year`.
    pub label: &'static str,
    pub hours: f64,
    pub start_h: f64,
    pub end_h: f64,
    pub labs_n: usize,
    pub t_labs_n: usize,
    pub e2_labs_n: usize,
    /// Mean of the measured values in the window, in model units.
    pub t_mean_ng_dl: Option<f64>,
    pub e2_mean_pg_ml: Option<f64>,
    pub t_below_ceiling: usize,
    pub t_ceiling_ng_dl: f64,
    /// Conservative share of testosterone labs under the ceiling, in percent.
    pub t_suppression_pct: Option<f64>,
    /// Modelled share of the window inside the oestrogen target range.
    pub time_in_range_pct: Option<f64>,
    /// Logged doses over expected doses, capped at 100.
    pub coverage_pct: Option<f64>,
    /// `min(time_in_range, coverage)` — the number to quote.
    pub effectiveness_pct: Option<f64>,
}

#[derive(Debug, Clone, Serialize)]
#[serde(rename_all = "camelCase")]
pub struct ProgressReport {
    pub windows: Vec<WindowProgress>,
    pub t_ceiling_ng_dl: f64,
    pub note: &'static str,
}

pub struct ProgressInput<'a> {
    pub events: &'a [DoseEvent],
    pub labs: &'a [LabResult],
    pub params: &'a PkParams,
    pub weight: f64,
    pub birth_year: Option<f64>,
    pub now_h: f64,
    pub clearance_mult: f64,
    pub e2_target: Option<TargetRange>,
    pub t_target: Option<TargetRange>,
}

/// Lower bound of the Wilson score interval for a proportion.
///
/// With one observation the interval starts near zero, which is the honest
/// reading of a single lab result. With no observations there is no bound at
/// all, and the caller gets `None` rather than zero.
pub fn wilson_lower(successes: usize, n: usize, z: f64) -> Option<f64> {
    if n == 0 {
        return None;
    }
    let nn = n as f64;
    let p = successes as f64 / nn;
    let z2 = z * z;
    let denominator = 1.0 + z2 / nn;
    let centre = p + z2 / (2.0 * nn);
    let margin = z * (p * (1.0 - p) / nn + z2 / (4.0 * nn * nn)).sqrt();
    Some(((centre - margin) / denominator).clamp(0.0, 1.0))
}

fn mean(values: &[f64]) -> Option<f64> {
    if values.is_empty() {
        return None;
    }
    Some(values.iter().sum::<f64>() / values.len() as f64)
}

/// Median spacing between doses of one analyte, used as the adherence interval.
fn median_interval(times: &[f64]) -> Option<f64> {
    if times.len() < 2 {
        return None;
    }
    let mut gaps: Vec<f64> = times
        .windows(2)
        .map(|w| w[1] - w[0])
        .filter(|g| g.is_finite() && *g > 0.0)
        .collect();
    if gaps.is_empty() {
        return None;
    }
    gaps.sort_by(|a, b| a.partial_cmp(b).unwrap_or(std::cmp::Ordering::Equal));
    let mid = gaps.len() / 2;
    let median = if gaps.len() % 2 == 0 {
        (gaps[mid - 1] + gaps[mid]) / 2.0
    } else {
        gaps[mid]
    };
    Some(median.clamp(2.0, 24.0 * 60.0))
}

fn window(label: &'static str, hours: f64, input: &ProgressInput<'_>) -> WindowProgress {
    let start = input.now_h - hours;
    let end = input.now_h;

    let mut t_values: Vec<f64> = Vec::new();
    let mut e2_values: Vec<f64> = Vec::new();
    for lab in input.labs {
        if lab.time_h < start || lab.time_h > end {
            continue;
        }
        if lab.unit.is_testosterone() {
            t_values.push(lab.unit.to_model_unit(lab.conc_value));
        } else {
            e2_values.push(lab.unit.to_model_unit(lab.conc_value));
        }
    }
    let t_below = t_values.iter().filter(|v| **v < T_CEILING_NG_DL).count();

    // Time in range, from the model, over exactly this window.
    let sim = run_simulation_grid(
        input.events,
        if input.weight > 0.0 { input.weight } else { 70.0 },
        input.birth_year,
        input.params,
        input.now_h,
        input.clearance_mult,
        &SimGrid {
            start_h: Some(start),
            end_h: Some(end),
            step_h: Some(0.5),
            max_points: 40_000,
        },
    );
    let time_in_range = sim.as_ref().and_then(|s| {
        let stats = simulation_stats(s, None, input.e2_target, input.t_target);
        stats.e2.and_then(|e| {
            if e.span_h > 0.0 {
                Some(e.time_in_range_pct)
            } else {
                None
            }
        })
    });

    // Coverage, from the log: the oestrogen doses are what the oestrogen
    // target range depends on, so they set the interval.
    let mut oestrogen_times: Vec<f64> = input
        .events
        .iter()
        .filter(|e| e.ester.is_estradiol() && e.dose_mg > 0.0 && e.time_h <= end)
        .map(|e| e.time_h)
        .collect();
    oestrogen_times.sort_by(|a, b| a.partial_cmp(b).unwrap_or(std::cmp::Ordering::Equal));
    let coverage = median_interval(&oestrogen_times)
        .and_then(|interval| adherence(input.events, interval, start, end))
        .map(|r| r.coverage_pct);

    let effectiveness = match (time_in_range, coverage) {
        (Some(a), Some(b)) => Some(a.min(b)),
        (Some(a), None) => Some(a),
        (None, Some(b)) => Some(b),
        (None, None) => None,
    };

    WindowProgress {
        label,
        hours,
        start_h: start,
        end_h: end,
        labs_n: t_values.len() + e2_values.len(),
        t_labs_n: t_values.len(),
        e2_labs_n: e2_values.len(),
        t_mean_ng_dl: mean(&t_values),
        e2_mean_pg_ml: mean(&e2_values),
        t_below_ceiling: t_below,
        t_ceiling_ng_dl: T_CEILING_NG_DL,
        t_suppression_pct: wilson_lower(t_below, t_values.len(), Z_ONE_SIDED)
            .map(|v| v * 100.0),
        time_in_range_pct: time_in_range,
        coverage_pct: coverage,
        effectiveness_pct: effectiveness,
    }
}

pub fn assess(input: ProgressInput<'_>) -> ProgressReport {
    ProgressReport {
        windows: vec![
            window("day", 24.0, &input),
            window("month", 24.0 * 30.0, &input),
            window("year", 24.0 * 365.0, &input),
        ],
        t_ceiling_ng_dl: T_CEILING_NG_DL,
        note: "Suppression is measured, not inferred: it is the share of your \
               own testosterone results below 50 ng/dL, reported as a 95% lower \
               bound, so a single result cannot read as certainty. Effectiveness \
               is the weaker of two numbers — modelled time inside the oestrogen \
               range and the share of planned doses actually logged — because a \
               regimen only works as well as the worse of the two.",
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    use std::collections::HashMap;

    fn lab(unit: LabUnit, value: f64, time_h: f64) -> LabResult {
        LabResult {
            id: format!("{time_h}"),
            time_h,
            conc_value: value,
            unit,
            assay: None,
            updated_at: None,
        }
    }

    fn dose(ester: Ester, mg: f64, time_h: f64) -> DoseEvent {
        DoseEvent {
            id: format!("{time_h}"),
            route: Route::Oral,
            time_h,
            dose_mg: mg,
            ester,
            extras: HashMap::new(),
            updated_at: None,
        }
    }

    #[test]
    fn one_lab_below_the_ceiling_is_not_full_suppression() {
        let bound = wilson_lower(1, 1, Z_ONE_SIDED).expect("a bound");
        assert!(bound > 0.2 && bound < 0.3, "got {bound}");
        assert!(wilson_lower(0, 0, Z_ONE_SIDED).is_none());
        // Ten out of ten is still not 100%.
        let ten = wilson_lower(10, 10, Z_ONE_SIDED).expect("a bound");
        assert!(ten > 0.7 && ten < 1.0, "got {ten}");
    }

    #[test]
    fn a_year_of_labs_is_summarised_per_window() {
        let now = 1000.0 * 24.0;
        let mut labs = Vec::new();
        for i in 0..12 {
            // Monthly testosterone results, all suppressed.
            labs.push(lab(LabUnit::NgDl, 25.0, now - i as f64 * 30.0 * 24.0));
        }
        labs.push(lab(LabUnit::PgMl, 150.0, now - 10.0));

        let events: Vec<DoseEvent> = (0..365)
            .map(|d| dose(Ester::E2, 2.0, now - (365 - d) as f64 * 24.0))
            .collect();

        let report = assess(ProgressInput {
            events: &events,
            labs: &labs,
            params: &PkParams::default(),
            weight: 70.0,
            birth_year: None,
            now_h: now,
            clearance_mult: 1.0,
            e2_target: Some(TargetRange::new(100.0, 200.0)),
            t_target: Some(TargetRange::new(400.0, 700.0)),
        });

        let day = &report.windows[0];
        let year = &report.windows[2];
        assert_eq!(day.label, "day");
        assert!(day.t_labs_n >= 1);
        assert!(year.t_labs_n >= 12);
        assert!(year.t_suppression_pct.expect("bound") > 70.0);
        assert!(year.effectiveness_pct.is_some());
        // A year of daily doses is fully covered.
        assert!(year.coverage_pct.expect("coverage") >= 99.0);
    }

    #[test]
    fn effectiveness_takes_the_weaker_of_model_and_log() {
        let now = 1000.0 * 24.0;
        // Ten days of doses, then a long silence: coverage must drag the
        // effectiveness below the modelled time in range.
        let events: Vec<DoseEvent> = (0..10)
            .map(|d| dose(Ester::E2, 2.0, now - (30 - d) as f64 * 24.0))
            .collect();
        let report = assess(ProgressInput {
            events: &events,
            labs: &[],
            params: &PkParams::default(),
            weight: 70.0,
            birth_year: None,
            now_h: now,
            clearance_mult: 1.0,
            e2_target: Some(TargetRange::new(100.0, 200.0)),
            t_target: None,
        });
        let month = &report.windows[1];
        let tir = month.time_in_range_pct.expect("tir");
        let coverage = month.coverage_pct.expect("coverage");
        let effectiveness = month.effectiveness_pct.expect("effectiveness");
        assert!(coverage < 100.0, "ten doses cannot cover a month");
        assert!(tir < 100.0, "twenty days without a dose leave the range");
        assert!((effectiveness - tir.min(coverage)).abs() < 1e-9);
        assert!(effectiveness < 100.0);
    }
}
