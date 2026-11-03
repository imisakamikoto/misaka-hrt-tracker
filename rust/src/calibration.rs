//! Fitting the curve to a person's own blood tests.
//!
//! Three methods, as in the browser app:
//!   * `mipd` — population-style grid search over personal clearance, with the
//!     amplitude solved in closed form for each candidate.
//!   * `ekf` — a scalar Kalman filter on the log residual, updated per lab.
//!   * `ou_kalman` — an Ornstein–Uhlenbeck style weighting, where a lab's
//!     influence decays with its distance in time from the point being shown.
//!
//! A lab is only informative where the model is non-zero, so a point taken
//! before the first dose is dropped rather than allowed to drag the scale to
//! infinity.

use serde::{Deserialize, Serialize};

use crate::engine::run_simulation;
use crate::model::*;

#[derive(Debug, Clone, Serialize, Deserialize)]
#[serde(rename_all = "camelCase")]
pub struct CalibrationPoint {
    pub time_h: f64,
    /// Observed value in the model's unit (pg/mL or ng/dL).
    pub obs: f64,
    /// Model value at the same moment, before calibration.
    pub model: f64,
    /// `obs / model`.
    pub ratio: f64,
    /// "e2" or "t"
    pub hormone: String,
}

#[derive(Debug, Clone, Serialize, Deserialize)]
#[serde(rename_all = "camelCase")]
pub struct FactorSegment {
    pub time_h: f64,
    pub factor: f64,
}

#[derive(Debug, Clone, Serialize, Deserialize)]
#[serde(rename_all = "camelCase")]
pub struct CalibrationResult {
    pub method: String,
    /// Amplitude correction at the most recent lab.
    pub scale: f64,
    /// Personal clearance multiplier, fed back into the simulation.
    pub clearance_mult: f64,
    pub half_life_delta_pct: f64,
    pub n: usize,
    pub fit_err_pct: Option<f64>,
    pub points: Vec<CalibrationPoint>,
    pub segments: Vec<FactorSegment>,
}

impl CalibrationResult {
    fn identity(method: &str, points: Vec<CalibrationPoint>) -> Self {
        CalibrationResult {
            method: method.to_string(),
            scale: 1.0,
            clearance_mult: 1.0,
            half_life_delta_pct: 0.0,
            n: points.len(),
            fit_err_pct: None,
            points,
            segments: Vec::new(),
        }
    }
}

const LOG_SCALE_CLAMP: f64 = 3.0;

fn clamp_factor(f: f64) -> f64 {
    if !f.is_finite() {
        return 1.0;
    }
    f.clamp((-LOG_SCALE_CLAMP).exp(), LOG_SCALE_CLAMP.exp())
}

/// Collect the lab/model pairs that can be compared.
pub fn calibration_points(sim: &SimulationResult, labs: &[LabResult]) -> Vec<CalibrationPoint> {
    let mut sorted: Vec<&LabResult> = labs.iter().collect();
    sorted.sort_by(|a, b| {
        a.time_h
            .partial_cmp(&b.time_h)
            .unwrap_or(std::cmp::Ordering::Equal)
    });

    sorted
        .into_iter()
        .filter_map(|lab| {
            let model = if lab.unit.is_testosterone() {
                sim.t_at(lab.time_h)?
            } else {
                sim.e2_at(lab.time_h)?
            };
            let obs = lab.unit.to_model_unit(lab.conc_value);
            if !(model > 1e-9) || !(obs > 0.0) || !model.is_finite() || !obs.is_finite() {
                return None;
            }
            Some(CalibrationPoint {
                time_h: lab.time_h,
                obs,
                model,
                ratio: obs / model,
                hormone: if lab.unit.is_testosterone() {
                    "t".to_string()
                } else {
                    "e2".to_string()
                },
            })
        })
        .collect()
}

fn rms_err_pct(points: &[CalibrationPoint], factors: impl Fn(f64) -> f64) -> Option<f64> {
    if points.is_empty() {
        return None;
    }
    let sum: f64 = points
        .iter()
        .map(|p| {
            let predicted = p.model * factors(p.time_h);
            if predicted <= 0.0 {
                return 0.0;
            }
            let rel = (predicted - p.obs) / p.obs;
            rel * rel
        })
        .sum();
    Some((sum / points.len() as f64).sqrt() * 100.0)
}

/// Grid search over clearance; amplitude is the mean log residual for each
/// candidate, which is its least-squares optimum.
fn mipd_fit(
    events: &[DoseEvent],
    weight: f64,
    birth_year: Option<f64>,
    params: &PkParams,
    points: &[CalibrationPoint],
    now_h: f64,
) -> (f64, f64) {
    let mut best = (1.0f64, 0.0f64, f64::INFINITY); // (clearance_mult, log_amp, sse)
    let k_min: f64 = -0.5;
    let k_max: f64 = 0.5;
    let steps = 21;
    for i in 0..steps {
        let k = k_min + (k_max - k_min) * i as f64 / (steps - 1) as f64;
        let mult = k.exp();
        let Some(sim) = run_simulation(events, weight, birth_year, params, now_h, mult) else {
            continue;
        };
        let mut residuals = Vec::with_capacity(points.len());
        let mut ok = true;
        for p in points {
            let model = if p.hormone == "t" {
                sim.t_at(p.time_h)
            } else {
                sim.e2_at(p.time_h)
            };
            match model {
                Some(m) if m > 1e-9 => residuals.push((p.obs / m).ln()),
                _ => {
                    ok = false;
                    break;
                }
            }
        }
        if !ok || residuals.is_empty() {
            continue;
        }
        let mean = residuals.iter().sum::<f64>() / residuals.len() as f64;
        let sse: f64 = residuals.iter().map(|r| (r - mean) * (r - mean)).sum();
        if sse < best.2 {
            best = (mult, mean, sse);
        }
    }
    (best.0, best.1.exp())
}

/// Recursive scalar Kalman filter on log amplitude.
fn ekf_fit(points: &[CalibrationPoint], until: usize) -> f64 {
    let mut x = 0.0f64; // log amplitude
    let mut p = 1.0f64; // variance
    let q = 1.0e-6; // process noise per hour
    let r = 0.04; // ~20% assay + model noise, variance
    let mut prev_t = points.first().map(|p| p.time_h).unwrap_or(0.0);

    for point in points.iter().take(until) {
        let dt = (point.time_h - prev_t).abs().max(1.0);
        prev_t = point.time_h;
        p += q * dt;
        let k = p / (p + r);
        let residual = (point.obs / point.model).ln() - x;
        x += k * residual;
        p *= 1.0 - k;
    }
    x.exp()
}

/// Ornstein–Uhlenbeck weighting: each lab pulls the estimate, and its pull
/// decays exponentially with age. 14 days is roughly one gel/injection cycle.
fn ou_fit(points: &[CalibrationPoint], at_time: f64, horizon_h: f64) -> f64 {
    if points.is_empty() {
        return 1.0;
    }
    let mut num = 0.0;
    let mut den = 0.0;
    for p in points {
        let w = (-(at_time - p.time_h).abs() / horizon_h).exp();
        num += w * (p.obs / p.model).ln();
        den += w;
    }
    if den <= 0.0 {
        return 1.0;
    }
    (num / den).exp().clamp(0.05, 20.0)
}

pub struct CalibrationInput<'a> {
    pub events: &'a [DoseEvent],
    pub weight: f64,
    pub birth_year: Option<f64>,
    pub params: &'a PkParams,
    pub labs: &'a [LabResult],
    pub method: &'a str,
    pub history_mode: &'a str,
    pub now_h: f64,
}

/// Calibrate the model against labs.
pub fn calibrate(input: CalibrationInput<'_>) -> CalibrationResult {
    let Some(base_sim) = run_simulation(
        input.events,
        input.weight,
        input.birth_year,
        input.params,
        input.now_h,
        1.0,
    ) else {
        return CalibrationResult::identity(input.method, Vec::new());
    };

    let points = calibration_points(&base_sim, input.labs);
    if input.method == "off" || points.is_empty() {
        return CalibrationResult::identity(input.method, points);
    }

    match input.method {
        "ou_kalman" => {
            let horizon = 14.0 * 24.0;
            let anchor = points.last().map(|p| p.time_h).unwrap_or(input.now_h);
            let factor = ou_fit(&points, anchor, horizon);
            let segments: Vec<FactorSegment> = if input.history_mode == "forward" {
                points
                    .iter()
                    .map(|p| FactorSegment {
                        time_h: p.time_h,
                        factor: ou_fit(&points, p.time_h, horizon),
                    })
                    .collect()
            } else {
                vec![FactorSegment {
                    time_h: 0.0,
                    factor,
                }]
            };
            let fit = if segments.len() > 1 {
                rms_err_pct(&points, |t| {
                    let mut v = segments[0].factor;
                    for s in &segments {
                        if s.time_h <= t {
                            v = s.factor;
                        }
                    }
                    v
                })
            } else {
                rms_err_pct(&points, |_| factor)
            };
            CalibrationResult {
                method: input.method.to_string(),
                scale: factor,
                clearance_mult: 1.0,
                half_life_delta_pct: 0.0,
                n: points.len(),
                fit_err_pct: fit,
                points,
                segments,
            }
        }
        "ekf" => {
            let segments: Vec<FactorSegment> = if input.history_mode == "forward" {
                (0..points.len())
                    .map(|i| FactorSegment {
                        time_h: points[i].time_h,
                        factor: ekf_fit(&points, i + 1),
                    })
                    .collect()
            } else {
                vec![FactorSegment {
                    time_h: 0.0,
                    factor: ekf_fit(&points, points.len()),
                }]
            };
            let scale = segments.last().map(|s| s.factor).unwrap_or(1.0);
            let fit = if segments.len() > 1 {
                rms_err_pct(&points, |t| {
                    let mut v = segments[0].factor;
                    for s in &segments {
                        if s.time_h <= t {
                            v = s.factor;
                        }
                    }
                    v
                })
            } else {
                rms_err_pct(&points, |_| scale)
            };
            CalibrationResult {
                method: input.method.to_string(),
                scale,
                clearance_mult: 1.0,
                half_life_delta_pct: 0.0,
                n: points.len(),
                fit_err_pct: fit,
                points,
                segments,
            }
        }
        _ => {
            // One lab, or several taken close together, cannot separate
            // clearance from amplitude: the fit would trade one against the
            // other and land anywhere. With no identifiable clearance the
            // correction is the geometric mean of the observed ratios.
            let span_h = points.last().map(|p| p.time_h).unwrap_or(0.0)
                - points.first().map(|p| p.time_h).unwrap_or(0.0);
            if points.len() < 2 || span_h < 48.0 {
                let mean = points.iter().map(|p| (p.obs / p.model).ln()).sum::<f64>()
                    / points.len() as f64;
                let factor = clamp_factor(mean.exp());
                let segments = vec![FactorSegment {
                    time_h: 0.0,
                    factor,
                }];
                return CalibrationResult {
                    method: "mipd".to_string(),
                    scale: factor,
                    clearance_mult: 1.0,
                    half_life_delta_pct: 0.0,
                    n: points.len(),
                    fit_err_pct: rms_err_pct(&points, |_| factor),
                    points,
                    segments,
                };
            }
            let (clearance_mult, scale) = mipd_fit(
                input.events,
                input.weight,
                input.birth_year,
                input.params,
                &points,
                input.now_h,
            );
            let factor = clamp_factor(scale);
            let segments = vec![FactorSegment {
                time_h: 0.0,
                factor,
            }];
            CalibrationResult {
                method: "mipd".to_string(),
                scale: factor,
                clearance_mult,
                half_life_delta_pct: (1.0 / clearance_mult - 1.0) * 100.0,
                n: points.len(),
                fit_err_pct: rms_err_pct(&points, |_| factor),
                points,
                segments,
            }
        }
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    use std::collections::HashMap;

    #[test]
    fn a_single_doubled_lab_scales_the_curve() {
        let params = PkParams::default();
        let start = 24.0 * 400.0;
        let events: Vec<DoseEvent> = (0..40)
            .map(|d| DoseEvent {
                id: format!("d{d}"),
                route: Route::Gel,
                time_h: start + d as f64 * 24.0,
                dose_mg: 1.5,
                ester: Ester::E2,
                extras: HashMap::new(),
                updated_at: None,
            })
            .collect();
        let sim = run_simulation(&events, 70.0, None, &params, start + 40.0 * 24.0, 1.0).unwrap();
        let modelled = sim.e2_at(start + 39.0 * 24.0).unwrap();
        let labs = vec![LabResult {
            id: "l1".into(),
            time_h: start + 39.0 * 24.0,
            conc_value: modelled * 2.0,
            unit: LabUnit::PgMl,
            assay: None,
            updated_at: None,
        }];
        let result = calibrate(CalibrationInput {
            events: &events,
            weight: 70.0,
            birth_year: None,
            params: &params,
            labs: &labs,
            method: "mipd",
            history_mode: "retrospective",
            now_h: start + 40.0 * 24.0,
        });
        assert_eq!(result.n, 1);
        assert!(
            result.scale > 1.4 && result.scale < 2.6,
            "scale {}",
            result.scale
        );
    }
}
