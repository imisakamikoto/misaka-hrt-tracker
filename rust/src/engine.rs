//! Pharmacokinetic engine.
//!
//! A faithful port of the TypeScript model the browser app used: sequential
//! first-order absorption (`k1`) → ester hydrolysis (`k2`) → elimination
//! (`k3`), solved analytically so a single dose is a closed-form expression
//! rather than an ODE integration. Coincident rate constants are handled with
//! divided differences, which stay finite in the limit where two or three
//! rates meet — a case the naive sum-of-exponentials form would turn into 0/0.

use std::collections::HashMap;

use crate::model::*;

const LN2: f64 = std::f64::consts::LN_2;

const VD_PER_KG_E2: f64 = 2.0;
const VD_PER_KG_CPA: f64 = 14.0;
const VD_PER_KG_T: f64 = 1.0;
/// Canrenone distributes widely; this volume puts 100 mg/day at the
/// 200–400 ng/mL steady state reported for that dose.
const VD_PER_KG_SPIRO: f64 = 2.8;

const AGE_REF_YEARS: f64 = 54.0;
const AGE_MIN: f64 = 19.0;
const AGE_MAX: f64 = 75.0;
const HOURS_PER_YEAR: f64 = 365.2425 * 24.0;

/// How long a patch must be on before a removal may end it.
const PATCH_MIN_WEAR_H: f64 = 1.0;
const PATCH_REMOVAL_GRACE_H: f64 = 24.0;
const PATCH_MAX_OVERWEAR_H: f64 = 240.0;

const SL_MAX_HOLD_MIN: f64 = 60.0;

fn age_clearance_slope_t() -> f64 {
    (1821.0f64 / 1390.0).ln() / (67.0 - 27.0)
}

fn age_clearance_slope_e2() -> f64 {
    (1.0f64 / 0.75).ln() / (79.0 - 27.0)
}

pub fn age_at_h(birth_year: f64, time_h: f64) -> f64 {
    1970.0 + time_h / HOURS_PER_YEAR - (birth_year + 0.5)
}

/// Multiplier on clearance at a given time. Ageing slows clearance, so a
/// person older than 54 clears estradiol and testosterone more slowly.
pub fn age_clearance_multiplier(hormone: &str, birth_year: Option<f64>, time_h: f64) -> f64 {
    let Some(year) = birth_year else { return 1.0 };
    let age = age_at_h(year, time_h).clamp(AGE_MIN, AGE_MAX);
    let slope = if hormone == "t" {
        age_clearance_slope_t()
    } else {
        age_clearance_slope_e2()
    };
    (-slope * (age - AGE_REF_YEARS)).exp()
}

// --- Rate constants -------------------------------------------------------

fn e2_frac_fast(ester: Ester) -> f64 {
    match ester {
        Ester::EB => 0.9,
        Ester::EV => 0.4,
        Ester::EC => 0.229164549,
        Ester::EN => 0.05,
        Ester::EU => 0.08,
        Ester::E2 => 1.0,
        _ => 0.5,
    }
}

fn e2_k1_fast(ester: Ester) -> f64 {
    match ester {
        Ester::EB => 0.144,
        Ester::EV => 0.0216,
        Ester::EC => 0.005035046,
        Ester::EN => 0.001,
        Ester::EU => 0.006,
        Ester::E2 => 0.5,
        _ => 0.1,
    }
}

fn e2_k1_slow(ester: Ester) -> f64 {
    match ester {
        Ester::EB => 0.114,
        Ester::EV => 0.0138,
        Ester::EC => 0.004510574,
        Ester::EN => 0.005,
        Ester::EU => 0.0022,
        Ester::E2 => 0.0,
        _ => 0.01,
    }
}

fn e2_hydrolysis_k2(ester: Ester) -> f64 {
    match ester {
        Ester::EB => 0.09,
        Ester::EV => 0.07,
        Ester::EC => 0.045,
        Ester::EN => 0.015,
        Ester::EU => 0.012,
        _ => 0.0,
    }
}

fn t_frac_fast(ester: Ester) -> f64 {
    match ester {
        Ester::TC => 0.35,
        Ester::TE => 0.4,
        Ester::TU => 0.0,
        _ => 0.35,
    }
}

fn t_k1_fast(ester: Ester) -> f64 {
    match ester {
        Ester::TC => 0.025,
        Ester::TE => 0.035,
        Ester::TU => LN2 / (50.0 * 24.0),
        _ => 0.025,
    }
}

fn t_k1_slow(ester: Ester) -> f64 {
    match ester {
        Ester::TC => 0.005,
        Ester::TE => 0.008,
        Ester::TU => LN2 / (50.0 * 24.0),
        _ => 0.005,
    }
}

fn t_hydrolysis_k2(ester: Ester) -> f64 {
    match ester {
        Ester::TC | Ester::TE => 0.2,
        Ester::TU => 0.036,
        _ => 0.2,
    }
}

const T_GEL_K1: f64 = 0.05;
const T_PATCH_K1: f64 = 0.03;
const T_PATCH_F: f64 = 1.0;
const E2_GEL_K1: f64 = 0.0193;
const E2_PATCH_K1: f64 = 0.0075;

const ORAL_KA_E2: f64 = 0.32;
const ORAL_KA_EV: f64 = 0.05;
const ORAL_KA_SL: f64 = 1.8;
fn oral_ke1_pool() -> f64 {
    LN2 / 14.36
}

const SL_TIERS: [(&str, f64); 4] = [
    ("quick", 2.0),
    ("casual", 5.0),
    ("standard", 10.0),
    ("strict", 15.0),
];

// --- Cyproterone acetate, by mouth only ----------------------------------

struct CpaOral;

impl CpaOral {
    const F: f64 = 0.88;
    const KA: f64 = 0.5;
    const ALPHA: f64 = 0.25;
    fn beta() -> f64 {
        LN2 / 43.9
    }
    const W_FAST: f64 = 5.2786;
    fn exposure_h() -> f64 {
        14.0 / (0.0035 * 60.0)
    }
    fn w_slow() -> f64 {
        (Self::exposure_h() - Self::W_FAST / Self::ALPHA) * Self::beta()
    }
}

// --- Numerically stable divided differences ------------------------------

/// First divided difference of `s ↦ e^(−sτ)` at `x` and `y`.
fn exp_div_diff1(x: f64, y: f64, tau: f64) -> f64 {
    let z = (y - x).abs() * tau / 2.0;
    if z > 1.0 {
        return ((-x * tau).exp() - (-y * tau).exp()) / (x - y);
    }
    let sinhc = if z == 0.0 { 1.0 } else { z.sinh() / z };
    -tau * (-((x + y) / 2.0) * tau).exp() * sinhc
}

/// Second divided difference of `s ↦ e^(−sτ)` at `a`, `b` and `c`.
fn exp_div_diff2(a_in: f64, b_in: f64, c_in: f64, tau: f64) -> f64 {
    let mut v = [a_in, b_in, c_in];
    v.sort_by(|x, y| x.partial_cmp(y).unwrap_or(std::cmp::Ordering::Equal));
    let (a, b, c) = (v[0], v[1], v[2]);

    if (c - a) * tau >= 0.5 {
        return (exp_div_diff1(b, c, tau) - exp_div_diff1(a, b, tau)) / (c - a);
    }
    let mean = (a + b + c) / 3.0;
    let ua = (mean - a) * tau;
    let ub = (mean - b) * tau;
    let uc = (mean - c) * tau;

    let mut h1 = 1.0;
    let mut h2 = 1.0;
    let mut h3 = 1.0;
    let mut fact = 2.0;
    let mut sum = 0.5;
    for j in 1..20 {
        h1 *= ua;
        h2 = h1 + ub * h2;
        h3 = h2 + uc * h3;
        fact *= (j + 2) as f64;
        sum += h3 / fact;
    }
    tau * tau * (-mean * tau).exp() * sum
}

/// Two-compartment Bateman response: absorption `ka` into elimination `ke`.
fn analytic2c(tau: f64, dose_mg: f64, f: f64, ka: f64, ke: f64) -> f64 {
    if ka <= 0.0 || dose_mg <= 0.0 {
        return 0.0;
    }
    -dose_mg * f * ka * exp_div_diff1(ka, ke, tau)
}

/// Three-compartment chain: absorption `k1` → hydrolysis `k2` → elimination `k3`.
fn analytic3c(tau: f64, dose_mg: f64, f: f64, k1: f64, k2: f64, k3: f64) -> f64 {
    if k1 <= 0.0 || dose_mg <= 0.0 {
        return 0.0;
    }
    dose_mg * f * k1 * k2 * exp_div_diff2(k1, k2, k3, tau)
}

// --- Parameter resolution ------------------------------------------------

#[derive(Debug, Clone, Copy)]
pub struct ResolvedParams {
    pub frac_fast: f64,
    pub k1_fast: f64,
    pub k1_slow: f64,
    pub k2: f64,
    pub k2_slow: Option<f64>,
    pub k3: f64,
    pub f: f64,
    pub rate_mg_h: f64,
    pub f_fast: f64,
    pub f_slow: f64,
}

impl ResolvedParams {
    fn zero(k3: f64) -> Self {
        ResolvedParams {
            frac_fast: 0.0,
            k1_fast: 0.0,
            k1_slow: 0.0,
            k2: 0.0,
            k2_slow: None,
            k3,
            f: 0.0,
            rate_mg_h: 0.0,
            f_fast: 0.0,
            f_slow: 0.0,
        }
    }
}

fn sl_theta(params: &PkParams, tier: u8) -> f64 {
    match tier {
        0 => params.e2_sl_quick,
        1 => params.e2_sl_casual,
        3 => params.e2_sl_strict,
        _ => params.e2_sl_standard,
    }
}

fn sl_tier_index(extras: &HashMap<String, f64>) -> u8 {
    extras
        .get(EXTRA_SL_TIER)
        .copied()
        .filter(|v| v.is_finite())
        .map(|v| v.round().clamp(0.0, 3.0) as u8)
        .unwrap_or(2)
}

/// Fraction of a sublingual dose absorbed through the mucosa while it is held.
pub fn sublingual_theta_from_hold(params: &PkParams, hold_min: f64) -> f64 {
    if !(hold_min > 0.0) {
        return 0.0;
    }
    let mut points: Vec<(f64, f64)> = SL_TIERS
        .iter()
        .enumerate()
        .map(|(i, (_, hold))| (*hold, sl_theta(params, i as u8)))
        .collect();
    points.sort_by(|a, b| a.0.partial_cmp(&b.0).unwrap());

    let h = hold_min.max(1.0);
    let (last_hold, last_theta) = points[points.len() - 1];
    if h >= last_hold {
        return theta_past_tiers(h, last_hold, last_theta).min(1.0);
    }
    for w in points.windows(2) {
        let (h1, t1) = w[0];
        let (h2, t2) = w[1];
        if h >= h1 && h <= h2 {
            let frac = (h - h1) / if (h2 - h1) == 0.0 { 1.0 } else { h2 - h1 };
            return (t1 + (t2 - t1) * frac).clamp(0.0, 1.0);
        }
    }
    let slope = (points[1].1 - points[0].1)
        / if (points[1].0 - points[0].0) == 0.0 {
            1.0
        } else {
            points[1].0 - points[0].0
        };
    (points[0].1 + (h - points[0].0) * slope).clamp(0.0, 1.0)
}

/// Inverse of `sublingual_theta_from_hold`, for redisplaying a custom θ.
pub fn sublingual_hold_from_theta(params: &PkParams, theta: f64) -> f64 {
    let mut points: Vec<(f64, f64)> = SL_TIERS
        .iter()
        .enumerate()
        .map(|(i, (_, hold))| (*hold, sl_theta(params, i as u8)))
        .collect();
    points.sort_by(|a, b| a.0.partial_cmp(&b.0).unwrap());
    let (last_hold, last_theta) = points[points.len() - 1];

    if theta > last_theta {
        if theta >= theta_past_tiers(SL_MAX_HOLD_MIN, last_hold, last_theta) {
            return SL_MAX_HOLD_MIN;
        }
        let (mut lo, mut hi) = (last_hold, SL_MAX_HOLD_MIN);
        for _ in 0..60 {
            let mid = (lo + hi) / 2.0;
            if theta_past_tiers(mid, last_hold, last_theta) < theta {
                lo = mid;
            } else {
                hi = mid;
            }
        }
        return (lo + hi) / 2.0;
    }
    for w in points.windows(2) {
        let (h1, t1) = w[0];
        let (h2, t2) = w[1];
        if theta >= t1.min(t2) && theta <= t1.max(t2) {
            let frac = (theta - t1) / if (t2 - t1) == 0.0 { 1.0 } else { t2 - t1 };
            return h1 + (h2 - h1) * frac;
        }
    }
    let slope = (points[1].0 - points[0].0)
        / if (points[1].1 - points[0].1) == 0.0 {
            1.0
        } else {
            points[1].1 - points[0].1
        };
    (points[0].0 + (theta - points[0].1) * slope).max(1.0)
}

/// Dissolution-then-swallow model (Algorithm Explanation §6.2, middle case).
fn sl_theta_model(hold_min: f64) -> f64 {
    let k_diss = LN2 / (5.0 / 60.0);
    let k_out = ORAL_KA_SL + 1.8;
    let t = hold_min / 60.0;
    ((ORAL_KA_SL * k_diss) / (k_diss - k_out))
        * ((1.0 - (-k_out * t).exp()) / k_out - (1.0 - (-k_diss * t).exp()) / k_diss)
}

fn theta_past_tiers(hold_min: f64, last_hold: f64, last_theta: f64) -> f64 {
    let denom = sl_theta_model(last_hold);
    if denom <= 0.0 {
        return last_theta;
    }
    (last_theta * sl_theta_model(hold_min) / denom).min(1.0)
}

fn gel_bio(params: &PkParams, site: &str) -> f64 {
    match site {
        "thigh" => params.e2_gel_thigh,
        "scrotal" => params.e2_gel_scrotal,
        _ => params.e2_gel_arm,
    }
}

fn t_gel_bio(params: &PkParams, site: &str) -> f64 {
    match site {
        "thigh" => params.t_gel_thigh,
        "scrotal" => params.t_gel_scrotal,
        _ => params.t_gel_arm,
    }
}

fn e2_injection_formation(params: &PkParams, ester: Ester) -> f64 {
    match ester {
        Ester::EB => params.e2_ff_eb,
        Ester::EV => params.e2_ff_ev,
        Ester::EC => params.e2_ff_ec,
        Ester::EN => params.e2_ff_en,
        Ester::EU => params.e2_ff_eu,
        Ester::E2 => 1.0,
        _ => 0.08,
    }
}

fn t_injection_formation(params: &PkParams, ester: Ester) -> f64 {
    match ester {
        Ester::TC => params.t_ff_tc,
        Ester::TE => params.t_ff_te,
        Ester::TU => params.t_ff_tu,
        _ => params.t_ff_te,
    }
}

/// Fraction of the logged amount that reaches the blood as active hormone.
pub fn bioavailability(params: &PkParams, event: &DoseEvent) -> f64 {
    let mw_factor = event.ester.to_active_factor();

    if event.ester == Ester::CPA {
        return if event.route == Route::Oral {
            CpaOral::F
        } else {
            0.0
        };
    }

    if event.ester == Ester::SPIRO {
        // Already a fraction of the dose reaching canrenone: absorption and
        // hepatic conversion together. No molecular-weight factor applies,
        // because the reported curve is the metabolite itself.
        return if event.route == Route::Oral {
            params.spiro_f_canrenone
        } else {
            0.0
        };
    }

    if event.ester.is_testosterone() {
        return match event.route {
            Route::Injection => {
                if event.ester == Ester::T {
                    0.0
                } else {
                    t_injection_formation(params, event.ester) * mw_factor
                }
            }
            Route::Gel => t_gel_bio(params, event.gel_site()) * mw_factor,
            Route::PatchApply => T_PATCH_F * mw_factor,
            _ => 0.0,
        };
    }

    match event.route {
        Route::Injection => e2_injection_formation(params, event.ester) * mw_factor,
        Route::Oral => params.e2_oral_bio * mw_factor,
        Route::Sublingual => {
            let theta = match event.extra(EXTRA_SL_THETA) {
                Some(v) => v.clamp(0.0, 1.0),
                None => sl_theta(params, sl_tier_index(&event.extras)),
            };
            (theta + (1.0 - theta) * params.e2_oral_bio) * mw_factor
        }
        Route::Gel => gel_bio(params, event.gel_site()) * mw_factor,
        Route::PatchApply => mw_factor,
        Route::PatchRemove => 0.0,
    }
}

fn resolve_params(
    params: &PkParams,
    event: &DoseEvent,
    birth_year: Option<f64>,
    clearance_mult: f64,
) -> ResolvedParams {
    let e2_clear = if event.route.is_injection() {
        params.e2_k_clear_inj
    } else {
        params.e2_k_clear
    };
    let default_k3 =
        e2_clear * age_clearance_multiplier("e2", birth_year, event.time_h) * clearance_mult;

    if event.ester.is_testosterone() {
        let t_clear = if event.route.is_injection() {
            params.t_k_clear_inj
        } else {
            params.t_k_clear
        };
        let tk3 =
            t_clear * age_clearance_multiplier("t", birth_year, event.time_h) * clearance_mult;
        return match event.route {
            Route::Injection => {
                if event.ester == Ester::T {
                    return ResolvedParams::zero(tk3);
                }
                let f = bioavailability(params, event);
                ResolvedParams {
                    frac_fast: t_frac_fast(event.ester),
                    k1_fast: t_k1_fast(event.ester),
                    k1_slow: t_k1_slow(event.ester),
                    k2: t_hydrolysis_k2(event.ester),
                    k2_slow: None,
                    k3: tk3,
                    f,
                    rate_mg_h: 0.0,
                    f_fast: f,
                    f_slow: f,
                }
            }
            Route::Gel => {
                let f = bioavailability(params, event);
                ResolvedParams {
                    frac_fast: 1.0,
                    k1_fast: T_GEL_K1,
                    k1_slow: 0.0,
                    k2: 0.0,
                    k2_slow: None,
                    k3: tk3,
                    f,
                    rate_mg_h: 0.0,
                    f_fast: f,
                    f_slow: f,
                }
            }
            Route::PatchApply => {
                let f = bioavailability(params, event);
                let rate = match event.extra(EXTRA_RELEASE_RATE) {
                    Some(ug) if ug > 0.0 => (ug / 24.0 / 1000.0) * f,
                    _ => 0.0,
                };
                if rate > 0.0 {
                    return ResolvedParams {
                        frac_fast: 1.0,
                        k1_fast: 0.0,
                        k1_slow: 0.0,
                        k2: 0.0,
                        k2_slow: None,
                        k3: tk3,
                        f,
                        rate_mg_h: rate,
                        f_fast: f,
                        f_slow: f,
                    };
                }
                ResolvedParams {
                    frac_fast: 1.0,
                    k1_fast: T_PATCH_K1,
                    k1_slow: 0.0,
                    k2: 0.0,
                    k2_slow: None,
                    k3: tk3,
                    f,
                    rate_mg_h: 0.0,
                    f_fast: f,
                    f_slow: f,
                }
            }
            _ => ResolvedParams::zero(tk3),
        };
    }

    if event.ester == Ester::CPA && event.route != Route::Oral {
        return ResolvedParams::zero(default_k3);
    }

    match event.route {
        Route::Injection => {
            let f = bioavailability(params, event);
            ResolvedParams {
                frac_fast: e2_frac_fast(event.ester),
                k1_fast: e2_k1_fast(event.ester),
                k1_slow: e2_k1_slow(event.ester),
                k2: e2_hydrolysis_k2(event.ester),
                k2_slow: None,
                k3: default_k3,
                f,
                rate_mg_h: 0.0,
                f_fast: f,
                f_slow: f,
            }
        }
        Route::Sublingual => {
            let theta = match event.extra(EXTRA_SL_THETA) {
                Some(v) => v.clamp(0.0, 1.0),
                None => sl_theta(params, sl_tier_index(&event.extras)),
            };
            let to_active = event.ester.to_active_factor();
            let f_fast = to_active;
            let f_slow = params.e2_oral_bio * to_active;
            ResolvedParams {
                frac_fast: theta,
                k1_fast: ORAL_KA_SL,
                k1_slow: if event.ester == Ester::EV {
                    ORAL_KA_EV
                } else {
                    ORAL_KA_E2
                },
                k2: e2_hydrolysis_k2(event.ester),
                k2_slow: if event.ester == Ester::EV {
                    None
                } else {
                    Some(oral_ke1_pool())
                },
                k3: default_k3,
                f: theta * f_fast + (1.0 - theta) * f_slow,
                rate_mg_h: 0.0,
                f_fast,
                f_slow,
            }
        }
        Route::Gel => {
            let f = bioavailability(params, event);
            ResolvedParams {
                frac_fast: 1.0,
                k1_fast: E2_GEL_K1,
                k1_slow: 0.0,
                k2: 0.0,
                k2_slow: None,
                k3: default_k3,
                f,
                rate_mg_h: 0.0,
                f_fast: f,
                f_slow: f,
            }
        }
        Route::PatchApply => {
            let f = bioavailability(params, event);
            let rate = match event.extra(EXTRA_RELEASE_RATE) {
                Some(ug) if ug > 0.0 => (ug / 24.0 / 1000.0) * f,
                _ => 0.0,
            };
            if rate > 0.0 {
                return ResolvedParams {
                    frac_fast: 1.0,
                    k1_fast: 0.0,
                    k1_slow: 0.0,
                    k2: 0.0,
                    k2_slow: None,
                    k3: default_k3,
                    f,
                    rate_mg_h: rate,
                    f_fast: f,
                    f_slow: f,
                };
            }
            ResolvedParams {
                frac_fast: 1.0,
                k1_fast: E2_PATCH_K1,
                k1_slow: 0.0,
                k2: 0.0,
                k2_slow: None,
                k3: default_k3,
                f,
                rate_mg_h: 0.0,
                f_fast: f,
                f_slow: f,
            }
        }
        Route::PatchRemove => ResolvedParams::zero(default_k3),
        Route::Oral => {
            if event.ester == Ester::CPA {
                return ResolvedParams {
                    frac_fast: 1.0,
                    k1_fast: CpaOral::KA,
                    k1_slow: 0.0,
                    k2: 0.0,
                    k2_slow: None,
                    k3: CpaOral::beta(),
                    f: CpaOral::F,
                    rate_mg_h: 0.0,
                    f_fast: CpaOral::F,
                    f_slow: CpaOral::F,
                };
            }
            if event.ester == Ester::SPIRO {
                // `f` is absorption × conversion, so the amount that reaches
                // the canrenone compartment already includes both losses.
                return ResolvedParams {
                    frac_fast: 1.0,
                    k1_fast: params.spiro_k_abs,
                    k1_slow: 0.0,
                    k2: params.spiro_k_convert,
                    k2_slow: None,
                    k3: params.spiro_k_clear,
                    f: params.spiro_f_canrenone,
                    rate_mg_h: 0.0,
                    f_fast: params.spiro_f_canrenone,
                    f_slow: params.spiro_f_canrenone,
                };
            }
            let to_active = event.ester.to_active_factor();
            let f = params.e2_oral_bio * to_active;
            ResolvedParams {
                frac_fast: 1.0,
                k1_fast: if event.ester == Ester::EV {
                    ORAL_KA_EV
                } else {
                    ORAL_KA_E2
                },
                k1_slow: 0.0,
                k2: if event.ester == Ester::EV {
                    0.0
                } else {
                    oral_ke1_pool()
                },
                k2_slow: None,
                k3: default_k3,
                f,
                rate_mg_h: 0.0,
                f_fast: f,
                f_slow: f,
            }
        }
    }
}

// --- Patch pairing -------------------------------------------------------

/// Pair every patch application with the removal that ended it.
///
/// Nothing on a removal says which application it ends, so the pairing is
/// inferred: each removal, in time order, closes the oldest still-open patch of
/// the same hormone that its own planned wear allows. Returns a map from the
/// event index to the hour it came off.
fn patch_removal_times(events: &[DoseEvent]) -> HashMap<usize, f64> {
    let mut pairs: HashMap<usize, f64> = HashMap::new();

    let mut applies: Vec<usize> = (0..events.len())
        .filter(|i| events[*i].route == Route::PatchApply)
        .collect();
    applies.sort_by(|a, b| {
        let (ea, eb) = (&events[*a], &events[*b]);
        ea.time_h
            .partial_cmp(&eb.time_h)
            .unwrap_or(std::cmp::Ordering::Equal)
            .then_with(|| {
                ea.planned_wear_h()
                    .unwrap_or(f64::INFINITY)
                    .partial_cmp(&eb.planned_wear_h().unwrap_or(f64::INFINITY))
                    .unwrap_or(std::cmp::Ordering::Equal)
            })
            .then_with(|| {
                ea.dose_mg
                    .partial_cmp(&eb.dose_mg)
                    .unwrap_or(std::cmp::Ordering::Equal)
            })
            .then_with(|| {
                let ra = ea.extra(EXTRA_RELEASE_RATE).unwrap_or(0.0);
                let rb = eb.extra(EXTRA_RELEASE_RATE).unwrap_or(0.0);
                ra.partial_cmp(&rb).unwrap_or(std::cmp::Ordering::Equal)
            })
            .then_with(|| format!("{:?}", ea.ester).cmp(&format!("{:?}", eb.ester)))
            .then_with(|| ea.id.cmp(&eb.id))
    });

    let mut removals: Vec<usize> = (0..events.len())
        .filter(|i| events[*i].route == Route::PatchRemove)
        .collect();
    let rank = |e: &DoseEvent| match e.hormone() {
        Some("e2") => 0,
        Some("t") => 1,
        _ => 2,
    };
    removals.sort_by(|a, b| {
        events[*a]
            .time_h
            .partial_cmp(&events[*b].time_h)
            .unwrap_or(std::cmp::Ordering::Equal)
            .then_with(|| rank(&events[*a]).cmp(&rank(&events[*b])))
    });

    let mut open: Vec<usize> = Vec::new();
    let mut next = 0usize;

    for r_idx in removals {
        let r = &events[r_idx];
        while next < applies.len() && events[applies[next]].time_h <= r.time_h - PATCH_MIN_WEAR_H {
            open.push(applies[next]);
            next += 1;
        }
        open.retain(|a| {
            let ap = &events[*a];
            match ap.planned_wear_h() {
                None => true,
                Some(wear) => ap.time_h + wear + PATCH_REMOVAL_GRACE_H >= r.time_h,
            }
        });

        let hormone = r.hormone();
        let fits = |a: usize| match hormone {
            None => true,
            Some(h) => events[a].hormone() == Some(h),
        };

        if let Some(pos) = open.iter().position(|a| fits(*a)) {
            let a = open.remove(pos);
            pairs.insert(a, r.time_h);
            continue;
        }

        // No patch fits by its plan: end the newest one of that hormone that
        // is still unpaired and not worn absurdly past its plan.
        let mut last: i64 = next as i64 - 1;
        while last >= 0 && !fits(applies[last as usize]) {
            last -= 1;
        }
        if last < 0 {
            continue;
        }
        let last_u = last as usize;
        let mut first = last_u;
        while first > 0 && events[applies[first - 1]].time_h == events[applies[last_u]].time_h {
            first -= 1;
        }
        for i in first..=last_u {
            let a = applies[i];
            if !fits(a) || pairs.contains_key(&a) {
                continue;
            }
            let planned = events[a].planned_wear_h().unwrap_or(0.0);
            if r.time_h > events[a].time_h + planned + PATCH_MAX_OVERWEAR_H {
                continue;
            }
            pairs.insert(a, r.time_h);
            break;
        }
    }
    pairs
}

/// The pairing between patch applications and the removals that ended them.
///
/// Exposed because a client showing "this patch has been on for 78 hours"
/// should use the same inference the curve does, not a second implementation.
pub fn patch_pairs(events: &[DoseEvent]) -> HashMap<usize, f64> {
    patch_removal_times(events)
}

fn resolve_patch_wear_h(index: usize, events: &[DoseEvent], pairs: &HashMap<usize, f64>) -> f64 {
    let e = &events[index];
    if let Some(remove_at) = pairs.get(&index) {
        if *remove_at > e.time_h {
            return remove_at - e.time_h;
        }
    }
    e.planned_wear_h().unwrap_or(f64::MAX)
}

// --- Per-event model -----------------------------------------------------

enum Shape {
    Injection,
    OralOrGel,
    CpaOral,
    /// Oral spironolactone: absorption → hepatic conversion to canrenone →
    /// canrenone elimination. Three steps, because the metabolite is what
    /// accumulates and what the effect follows.
    SpiroOral,
    Sublingual,
    /// `zero_order` is true when a labelled release rate drives the input.
    Patch {
        wear_h: f64,
        zero_order: bool,
    },
    None,
}

struct EventModel {
    start_h: f64,
    dose_mg: f64,
    shape: Shape,
    p: ResolvedParams,
}

impl EventModel {
    fn new(event: &DoseEvent, params: &ResolvedParams, wear_h: f64) -> Self {
        let shape = match event.route {
            Route::Injection => Shape::Injection,
            Route::Gel => Shape::OralOrGel,
            Route::Oral => {
                if event.ester == Ester::CPA {
                    Shape::CpaOral
                } else if event.ester == Ester::SPIRO {
                    Shape::SpiroOral
                } else {
                    Shape::OralOrGel
                }
            }
            Route::Sublingual => Shape::Sublingual,
            Route::PatchApply => Shape::Patch {
                wear_h,
                zero_order: params.rate_mg_h > 0.0,
            },
            Route::PatchRemove => Shape::None,
        };
        EventModel {
            start_h: event.time_h,
            dose_mg: event.dose_mg,
            shape,
            p: *params,
        }
    }

    fn amount(&self, time_h: f64) -> f64 {
        let tau = time_h - self.start_h;
        if tau < 0.0 {
            return 0.0;
        }
        let p = &self.p;
        let dose = self.dose_mg;
        match self.shape {
            Shape::None => 0.0,
            Shape::Injection => {
                let dose_fast = dose * p.frac_fast;
                let dose_slow = dose * (1.0 - p.frac_fast);
                if p.k2 > 0.0 {
                    analytic3c(tau, dose_fast, p.f, p.k1_fast, p.k2, p.k3)
                        + analytic3c(tau, dose_slow, p.f, p.k1_slow, p.k2, p.k3)
                } else {
                    analytic2c(tau, dose_fast, p.f, p.k1_fast, p.k3)
                        + analytic2c(tau, dose_slow, p.f, p.k1_slow, p.k3)
                }
            }
            Shape::CpaOral => {
                analytic2c(
                    tau,
                    dose,
                    CpaOral::F * CpaOral::W_FAST,
                    CpaOral::KA,
                    CpaOral::ALPHA,
                ) + analytic2c(
                    tau,
                    dose,
                    CpaOral::F * CpaOral::w_slow(),
                    CpaOral::KA,
                    CpaOral::beta(),
                )
            }
            Shape::SpiroOral => analytic3c(tau, dose, p.f, p.k1_fast, p.k2, p.k3),
            Shape::OralOrGel => {
                if p.k2 > 0.0 {
                    analytic3c(tau, dose, p.f, p.k1_fast, p.k2, p.k3)
                } else {
                    analytic2c(tau, dose, p.f, p.k1_fast, p.k3)
                }
            }
            Shape::Sublingual => {
                let dose_fast = dose * p.frac_fast;
                let dose_slow = dose * (1.0 - p.frac_fast);
                let fast = if p.k2 > 0.0 {
                    analytic3c(tau, dose_fast, p.f_fast, p.k1_fast, p.k2, p.k3)
                } else {
                    analytic2c(tau, dose_fast, p.f_fast, p.k1_fast, p.k3)
                };
                let slow = match p.k2_slow {
                    Some(k2s) if k2s > 0.0 => {
                        analytic3c(tau, dose_slow, p.f_slow, p.k1_slow, k2s, p.k3)
                    }
                    _ => analytic2c(tau, dose_slow, p.f_slow, p.k1_slow, p.k3),
                };
                fast + slow
            }
            Shape::Patch { wear_h, zero_order } => {
                if zero_order {
                    if tau <= wear_h {
                        (p.rate_mg_h / p.k3) * (1.0 - (-p.k3 * tau).exp())
                    } else {
                        let at_removal = (p.rate_mg_h / p.k3) * (1.0 - (-p.k3 * wear_h).exp());
                        at_removal * (-p.k3 * (tau - wear_h)).exp()
                    }
                } else {
                    if tau <= wear_h {
                        analytic2c(tau, dose, p.f, p.k1_fast, p.k3)
                    } else {
                        let at_removal = analytic2c(wear_h, dose, p.f, p.k1_fast, p.k3);
                        at_removal * (-p.k3 * (tau - wear_h)).exp()
                    }
                }
            }
        }
    }

    fn max_lifetime_h(&self) -> f64 {
        if let Shape::Patch { wear_h, .. } = self.shape {
            if wear_h >= f64::MAX {
                return f64::INFINITY;
            }
            let decay = if self.p.k3 > 0.0 {
                (13.816 / self.p.k3).ceil()
            } else {
                10000.0
            };
            return wear_h + decay;
        }
        let mut rates: Vec<f64> = Vec::new();
        for r in [
            self.p.k1_fast,
            self.p.k1_slow,
            self.p.k2,
            self.p.k2_slow.unwrap_or(0.0),
            self.p.k3,
        ] {
            if r > 0.0 {
                rates.push(r);
            }
        }
        if rates.is_empty() {
            return f64::INFINITY;
        }
        let k_min = rates.iter().cloned().fold(f64::INFINITY, f64::min);
        (13.816 / k_min).ceil()
    }
}

/// How the output grid is chosen.
///
/// With no overrides the grid spans a day before the first dose to two weeks
/// after the last one (or a day past `now_h`), with extra samples right after
/// every dose so a peak is never missed. A caller that wants a uniform grid —
/// for statistics, for a chart with a fixed window — sets `start_h`, `end_h`
/// and `step_h`, and the refinement samples are dropped.
#[derive(Debug, Clone, Copy)]
pub struct SimGrid {
    pub start_h: Option<f64>,
    pub end_h: Option<f64>,
    pub step_h: Option<f64>,
    pub max_points: usize,
}

impl Default for SimGrid {
    fn default() -> Self {
        SimGrid {
            start_h: None,
            end_h: None,
            step_h: None,
            max_points: 100_000,
        }
    }
}

impl SimGrid {
    /// A uniform grid over `[start_h, end_h]` with roughly `step_h` spacing.
    pub fn uniform(start_h: f64, end_h: f64, step_h: f64) -> Self {
        SimGrid {
            start_h: Some(start_h),
            end_h: Some(end_h),
            step_h: Some(step_h),
            ..SimGrid::default()
        }
    }

    pub fn with_max_points(mut self, max_points: usize) -> Self {
        self.max_points = max_points;
        self
    }
}

/// Run the model over a time grid and return E2, CPA and T curves.
///
/// `now_h` is passed in rather than read from the clock so results are
/// reproducible in tests and background jobs.
pub fn run_simulation(
    events: &[DoseEvent],
    body_weight_kg: f64,
    birth_year: Option<f64>,
    params: &PkParams,
    now_h: f64,
    clearance_mult: f64,
) -> Option<SimulationResult> {
    run_simulation_grid(
        events,
        body_weight_kg,
        birth_year,
        params,
        now_h,
        clearance_mult,
        &SimGrid::default(),
    )
}

/// Same as [`run_simulation`], with control over the output window and step.
pub fn run_simulation_grid(
    events: &[DoseEvent],
    body_weight_kg: f64,
    birth_year: Option<f64>,
    params: &PkParams,
    now_h: f64,
    clearance_mult: f64,
    grid: &SimGrid,
) -> Option<SimulationResult> {
    let mut usable: Vec<DoseEvent> = events
        .iter()
        .filter(|e| !e.ester.is_unmodelled())
        .filter(|e| e.dose_mg.is_finite() && e.time_h.is_finite())
        .cloned()
        .collect();

    if usable.is_empty() || !(body_weight_kg > 0.0) {
        return None;
    }
    usable.sort_by(|a, b| {
        a.time_h
            .partial_cmp(&b.time_h)
            .unwrap_or(std::cmp::Ordering::Equal)
    });

    let pairs = patch_removal_times(&usable);

    struct Prepared {
        model: EventModel,
        ester: Ester,
        start_h: f64,
        max_lifetime: f64,
    }

    let prepared: Vec<Prepared> = usable
        .iter()
        .enumerate()
        .filter(|(_, e)| e.route != Route::PatchRemove)
        .map(|(i, e)| {
            let p = resolve_params(params, e, birth_year, clearance_mult);
            let wear = if e.route == Route::PatchApply {
                resolve_patch_wear_h(i, &usable, &pairs)
            } else {
                f64::MAX
            };
            let model = EventModel::new(e, &p, wear);
            let max_lifetime = model.max_lifetime_h();
            Prepared {
                model,
                ester: e.ester,
                start_h: e.time_h,
                max_lifetime,
            }
        })
        .collect();

    if prepared.is_empty() {
        return None;
    }

    let default_start = usable[0].time_h - 24.0;
    let last_time = usable[usable.len() - 1].time_h;
    let default_end = (last_time + 24.0 * 14.0).max(now_h + 24.0);

    let start_time = grid.start_h.unwrap_or(default_start);
    let end_time = match grid.end_h {
        Some(end) => end.max(start_time + 1.0),
        None => default_end,
    };
    if !(end_time > start_time) || !end_time.is_finite() || !start_time.is_finite() {
        return None;
    }

    let max_points = grid.max_points.clamp(16, 1_000_000);
    let total_hours = end_time - start_time;
    let steps = match grid.step_h.filter(|s| *s > 0.0 && s.is_finite()) {
        Some(step) => ((total_hours / step).ceil() as usize + 1).clamp(2, max_points),
        None => (total_hours.ceil() as i64).clamp(2000, 100_000) as usize,
    };

    let plasma_e2 = VD_PER_KG_E2 * body_weight_kg * 1000.0;
    let plasma_cpa = VD_PER_KG_CPA * body_weight_kg * 1000.0;
    let plasma_t = VD_PER_KG_T * body_weight_kg * 1000.0;
    let plasma_spiro = VD_PER_KG_SPIRO * body_weight_kg * 1000.0;

    let step = (end_time - start_time) / (steps - 1).max(1) as f64;
    let mut times: Vec<f64> = (0..steps).map(|i| start_time + i as f64 * step).collect();

    // Dense samples right after a dose catch the peak of a fast route; a
    // caller-provided step already asks for its own resolution, so they are
    // only added for the automatic grid.
    if grid.step_h.is_none() {
        let offsets = [0.25, 0.5, 1.0, 2.0, 4.0, 6.0, 8.0, 12.0, 24.0, 48.0];
        for pc in &prepared {
            for off in offsets {
                if off > pc.max_lifetime {
                    break;
                }
                let t = pc.start_h + off;
                if t >= start_time && t <= end_time {
                    times.push(t);
                }
            }
        }
        for e in &usable {
            times.push(e.time_h);
        }
    }
    if now_h >= start_time && now_h <= end_time {
        times.push(now_h);
    }

    times.sort_by(|a, b| a.partial_cmp(b).unwrap_or(std::cmp::Ordering::Equal));
    times.dedup_by(|a, b| *a == *b);

    let mut out = SimulationResult {
        time_h: Vec::with_capacity(times.len()),
        e2_pg_ml: Vec::with_capacity(times.len()),
        cpa_ng_ml: Vec::with_capacity(times.len()),
        t_ng_dl: Vec::with_capacity(times.len()),
        spiro_ng_ml: Vec::with_capacity(times.len()),
        auc: 0.0,
        spiro_auc: 0.0,
    };

    let mut activate_idx = 0usize;
    let mut active: Vec<usize> = Vec::new();

    for (i, t) in times.iter().enumerate() {
        while activate_idx < prepared.len() && prepared[activate_idx].start_h <= *t {
            active.push(activate_idx);
            activate_idx += 1;
        }
        let mut j = 0;
        while j < active.len() {
            let idx = active[j];
            if *t - prepared[idx].start_h > prepared[idx].max_lifetime {
                active.swap_remove(j);
            } else {
                j += 1;
            }
        }

        let mut amount_e2 = 0.0;
        let mut amount_cpa = 0.0;
        let mut amount_t = 0.0;
        let mut amount_spiro = 0.0;
        for idx in &active {
            let pc = &prepared[*idx];
            let a = pc.model.amount(*t);
            if pc.ester == Ester::CPA {
                amount_cpa += a;
            } else if pc.ester == Ester::SPIRO {
                amount_spiro += a;
            } else if pc.ester.is_testosterone() {
                amount_t += a;
            } else {
                amount_e2 += a;
            }
        }

        let e2 = (amount_e2 * 1e9) / plasma_e2;
        let cpa = (amount_cpa * 1e6) / plasma_cpa;
        let tconc = (amount_t * 1e8) / plasma_t;
        let spiro = (amount_spiro * 1e6) / plasma_spiro;

        if i > 0 {
            let dt = t - times[i - 1];
            let prev = *out.e2_pg_ml.last().unwrap_or(&0.0);
            out.auc += 0.5 * (e2 + prev) * dt;
            let prev_spiro = *out.spiro_ng_ml.last().unwrap_or(&0.0);
            out.spiro_auc += 0.5 * (spiro + prev_spiro) * dt;
        }

        out.time_h.push(*t);
        out.e2_pg_ml.push(e2);
        out.cpa_ng_ml.push(cpa);
        out.t_ng_dl.push(tconc);
        out.spiro_ng_ml.push(spiro);
    }

    Some(out)
}

#[cfg(test)]
mod tests {
    use super::*;

    fn ev(route: Route, ester: Ester, dose: f64, time_h: f64) -> DoseEvent {
        DoseEvent {
            id: format!("{}-{}-{:?}", time_h, dose, ester),
            route,
            time_h,
            dose_mg: dose,
            ester,
            extras: HashMap::new(),
            updated_at: None,
        }
    }

    #[test]
    fn divided_differences_match_limit() {
        let tau = 3.0;
        let exact = exp_div_diff1(0.5, 0.5, tau);
        assert!((exact - (-tau * (-0.5f64 * tau).exp())).abs() < 1e-9);
    }

    #[test]
    fn oral_estradiol_peaks_in_a_plausible_band() {
        let params = PkParams::default();
        let start = 24.0 * 400.0;
        let mut events = Vec::new();
        for d in 0..60 {
            events.push(ev(Route::Oral, Ester::E2, 2.0, start + d as f64 * 24.0));
        }
        let sim = run_simulation(&events, 70.0, None, &params, start + 59.0 * 24.0 + 6.0, 1.0)
            .expect("simulation");
        let peak = sim.e2_pg_ml.iter().cloned().fold(0.0, f64::max);
        // 2 mg/day oral estradiol sits in the tens of pg/mL after first pass.
        assert!(peak > 20.0 && peak < 120.0, "peak was {peak}");
    }

    #[test]
    fn weekly_valerate_injection_reaches_a_steady_state() {
        let params = PkParams::default();
        let start = 24.0 * 400.0;
        let events: Vec<_> = (0..12)
            .map(|w| {
                ev(
                    Route::Injection,
                    Ester::EV,
                    4.0,
                    start + w as f64 * 24.0 * 7.0,
                )
            })
            .collect();
        let sim = run_simulation(&events, 70.0, None, &params, start + 11.0 * 168.0, 1.0).unwrap();
        let peak = sim.e2_pg_ml.iter().cloned().fold(0.0, f64::max);
        assert!(peak > 80.0 && peak < 900.0, "peak was {peak}");
    }

    #[test]
    fn sublingual_theta_rises_with_hold_time() {
        let p = PkParams::default();
        let a = sublingual_theta_from_hold(&p, 2.0);
        let b = sublingual_theta_from_hold(&p, 15.0);
        assert!(a < b);
        assert!((sublingual_hold_from_theta(&p, b) - 15.0).abs() < 0.5);
    }

    #[test]
    fn patch_pairs_with_its_removal() {
        let start = 1000.0;
        let mut apply = ev(Route::PatchApply, Ester::E2, 0.0, start);
        apply.extras.insert(EXTRA_RELEASE_RATE.to_string(), 100.0);
        let remove = ev(Route::PatchRemove, Ester::E2, 0.0, start + 84.0);
        let events = vec![apply, remove];
        let pairs = patch_removal_times(&events);
        assert_eq!(pairs.get(&0), Some(&(start + 84.0)));
    }
}
