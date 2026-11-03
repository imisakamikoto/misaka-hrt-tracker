//! Descriptive statistics over a curve.
//!
//! A chart needs a whole array; a person reading a card needs five numbers.
//! These are computed from the same samples the chart is drawn from, so the
//! summary can never disagree with the curve beside it.

use serde::{Deserialize, Serialize};

use crate::model::{SimulationResult, TargetRange};

/// Peak, trough and exposure over one window.
#[derive(Debug, Clone, Default, Serialize, Deserialize)]
#[serde(rename_all = "camelCase")]
pub struct CurveStats {
    pub n: usize,
    /// Highest modelled concentration in the window.
    pub peak: f64,
    pub peak_h: f64,
    /// Lowest modelled concentration in the window.
    pub trough: f64,
    pub trough_h: f64,
    /// Time-weighted mean, i.e. `auc / span`.
    pub mean: f64,
    /// Trapezoidal area under the curve, concentration × hour.
    pub auc: f64,
    /// Hours spent inside the target range, and that as a percentage of the
    /// window. Both are zero when no range was given.
    pub time_in_range_h: f64,
    pub time_in_range_pct: f64,
    /// `(peak − trough) / trough`, in percent. Zero when the trough is zero.
    pub fluctuation_pct: f64,
    pub span_h: f64,
}

/// The four curves' statistics for one window.
#[derive(Debug, Clone, Default, Serialize, Deserialize)]
#[serde(rename_all = "camelCase")]
pub struct SimulationStats {
    pub e2: Option<CurveStats>,
    pub t: Option<CurveStats>,
    pub cpa: Option<CurveStats>,
    /// Canrenone, the active metabolite of spironolactone.
    pub spiro: Option<CurveStats>,
    pub window_start_h: f64,
    pub window_end_h: f64,
}

fn peak_and_trough(times: &[f64], values: &[f64]) -> (f64, f64, f64, f64) {
    let mut peak = f64::NEG_INFINITY;
    let mut trough = f64::INFINITY;
    let mut peak_h = times[0];
    let mut trough_h = times[0];
    for (t, v) in times.iter().zip(values.iter()) {
        if !v.is_finite() {
            continue;
        }
        if *v > peak {
            peak = *v;
            peak_h = *t;
        }
        if *v < trough {
            trough = *v;
            trough_h = *t;
        }
    }
    (peak, peak_h, trough, trough_h)
}

fn trapezoid(times: &[f64], values: &[f64]) -> f64 {
    let mut auc = 0.0;
    for i in 1..times.len().min(values.len()) {
        let dt = times[i] - times[i - 1];
        if dt > 0.0 {
            auc += 0.5 * (values[i] + values[i - 1]) * dt;
        }
    }
    auc
}

/// Hours spent inside `range`.
///
/// The curve is linear between samples, so the exact duration is the overlap
/// of that segment with the band. Solving for the two crossing fractions
/// handles a segment that dips through the range and comes back out between
/// two samples, which a per-sample comparison would miss entirely.
fn time_in_range(times: &[f64], values: &[f64], range: TargetRange) -> f64 {
    let mut total = 0.0;
    for i in 1..times.len().min(values.len()) {
        let dt = times[i] - times[i - 1];
        if dt <= 0.0 {
            continue;
        }
        let (a, b) = (values[i - 1], values[i]);
        if !a.is_finite() || !b.is_finite() {
            continue;
        }
        let span = b - a;
        if span.abs() < 1e-12 {
            if range.contains(a) {
                total += dt;
            }
            continue;
        }
        let f_low = (range.low - a) / span;
        let f_high = (range.high - a) / span;
        let lo = f_low.min(f_high).clamp(0.0, 1.0);
        let hi = f_low.max(f_high).clamp(0.0, 1.0);
        if hi > lo {
            total += dt * (hi - lo);
        }
    }
    total
}

/// Summarise one series. `None` when there is nothing to summarise.
pub fn curve_stats(
    times: &[f64],
    values: &[f64],
    range: Option<TargetRange>,
) -> Option<CurveStats> {
    if times.len() < 2 || values.len() < 2 {
        return None;
    }
    let (peak, peak_h, trough, trough_h) = peak_and_trough(times, values);
    if !peak.is_finite() || !trough.is_finite() {
        return None;
    }
    let span = times[times.len() - 1] - times[0];
    if !(span > 0.0) {
        return None;
    }
    let auc = trapezoid(times, values);
    let tir = range
        .and_then(|r| r.normalized())
        .map(|r| time_in_range(times, values, r))
        .unwrap_or(0.0);
    Some(CurveStats {
        n: times.len(),
        peak,
        peak_h,
        trough,
        trough_h,
        mean: auc / span,
        auc,
        time_in_range_h: tir,
        time_in_range_pct: if span > 0.0 { tir / span * 100.0 } else { 0.0 },
        fluctuation_pct: if trough > 0.0 {
            (peak - trough) / trough * 100.0
        } else {
            0.0
        },
        span_h: span,
    })
}

/// Keep only the samples inside `[from_h, to_h]`.
pub fn clip(sim: &SimulationResult, from_h: f64, to_h: f64) -> SimulationResult {
    let mut out = SimulationResult::default();
    for (i, t) in sim.time_h.iter().enumerate() {
        if *t < from_h || *t > to_h {
            continue;
        }
        out.time_h.push(*t);
        out.e2_pg_ml
            .push(sim.e2_pg_ml.get(i).copied().unwrap_or(0.0));
        out.cpa_ng_ml
            .push(sim.cpa_ng_ml.get(i).copied().unwrap_or(0.0));
        out.t_ng_dl.push(sim.t_ng_dl.get(i).copied().unwrap_or(0.0));
        out.spiro_ng_ml
            .push(sim.spiro_ng_ml.get(i).copied().unwrap_or(0.0));
    }
    out.auc = trapezoid(&out.time_h, &out.e2_pg_ml);
    out.spiro_auc = trapezoid(&out.time_h, &out.spiro_ng_ml);
    out
}

/// Summarise all three curves.
pub fn simulation_stats(
    sim: &SimulationResult,
    window: Option<(f64, f64)>,
    e2_range: Option<TargetRange>,
    t_range: Option<TargetRange>,
) -> SimulationStats {
    let clipped;
    let view = match window {
        Some((from, to)) if to > from => {
            clipped = clip(sim, from, to);
            &clipped
        }
        _ => sim,
    };

    let first = view.time_h.first().copied().unwrap_or(0.0);
    let last = view.time_h.last().copied().unwrap_or(0.0);

    let e2 = curve_stats(&view.time_h, &view.e2_pg_ml, e2_range).filter(|s| s.peak > 1e-9);
    let t = curve_stats(&view.time_h, &view.t_ng_dl, t_range).filter(|s| s.peak > 1e-9);
    let cpa = curve_stats(&view.time_h, &view.cpa_ng_ml, None).filter(|s| s.peak > 1e-9);
    let spiro = curve_stats(&view.time_h, &view.spiro_ng_ml, None).filter(|s| s.peak > 1e-9);

    SimulationStats {
        e2,
        t,
        cpa,
        spiro,
        window_start_h: first,
        window_end_h: last,
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn trapezoid_matches_a_rectangle() {
        let times = vec![0.0, 1.0, 2.0];
        let values = vec![10.0, 10.0, 10.0];
        assert!((trapezoid(&times, &values) - 20.0).abs() < 1e-9);
    }

    #[test]
    fn time_in_range_splits_a_crossing() {
        // 100 → 0 over one hour, range 40..60: exactly half the hour counts.
        let times = vec![0.0, 1.0];
        let values = vec![100.0, 0.0];
        let hours = time_in_range(&times, &values, TargetRange::new(40.0, 60.0));
        assert!((hours - 0.2).abs() < 1e-6, "hours {hours}");
    }

    #[test]
    fn stats_find_the_peak_at_its_time() {
        let times: Vec<f64> = (0..25).map(|h| h as f64).collect();
        let values: Vec<f64> = times
            .iter()
            .map(|h| 100.0 * (-((h - 5.0) / 3.0).powi(2)).exp())
            .collect();
        let stats = curve_stats(&times, &values, None).unwrap();
        assert!((stats.peak - 100.0).abs() < 1e-6);
        assert_eq!(stats.peak_h, 5.0);
    }
}
