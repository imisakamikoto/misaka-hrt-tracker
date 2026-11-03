//! Regimens side by side.
//!
//! "Should I switch to injections" is the question this module exists for, and
//! it is a bad question to answer from peak values alone. Two regimens that
//! both peak at 200 pg/mL are not equivalent if one troughs at 180 and the
//! other at 40, and neither is equivalent to one that costs three times the
//! milligrams to get there. So every arm is settled to steady state first, and
//! then described by the same five numbers: peak, trough, mean, fluctuation and
//! time in range.
//!
//! Nothing here ranks the arms into a winner. It reports which arm is
//! steadiest, which runs highest, and which spends the fewest milligrams per
//! week — three different questions that rarely have the same answer.

use serde::{Deserialize, Serialize};

use crate::model::*;
use crate::planning::{steady_state, Schedule};
use crate::stats::{CurveStats, SimulationStats};

/// How many arms a comparison accepts. Beyond a handful the table stops being
/// readable, and the cost is a steady-state run each.
pub const MAX_ARMS: usize = 6;

/// One regimen in the comparison.
#[derive(Debug, Clone, Serialize, Deserialize)]
#[serde(rename_all = "camelCase")]
pub struct CompareArm {
    /// Shown to the user as-is; defaults to `ester route`.
    #[serde(default)]
    pub label: Option<String>,
    pub schedule: Schedule,
}

#[derive(Debug, Clone, Serialize)]
#[serde(rename_all = "camelCase")]
pub struct ArmReport {
    pub label: String,
    /// `e2`, `t`, `cpa`, `spiro`, or `None` when nothing is modelled.
    pub analyte: Option<&'static str>,
    pub ester: &'static str,
    pub route: &'static str,
    pub dose_mg: f64,
    pub interval_h: f64,
    /// `dose_mg × 24 / interval_h`.
    pub daily_mg: f64,
    pub weekly_mg: f64,
    /// Milligrams of active hormone per day, after the ester's weight is
    /// removed. The only figure that compares esters fairly.
    pub active_daily_mg: f64,
    pub modelled: bool,
    /// True when two consecutive cycles agreed to within 1%.
    pub stable: bool,
    /// Doses simulated before the reported cycle was read.
    pub cycles: usize,
    /// Steady-state peak over first-cycle peak.
    pub accumulation_ratio: f64,
    /// The settled cycle for this arm's own analyte.
    pub curve: Option<CurveStats>,
    /// `inRange`, `belowRange`, `aboveRange`, `volatile`, `notStable`,
    /// `notModelled` or `noCurve`.
    pub verdict: &'static str,
    pub note: &'static str,
}

#[derive(Debug, Clone, Serialize)]
#[serde(rename_all = "camelCase")]
pub struct CompareReport {
    pub arms: Vec<ArmReport>,
    /// Arm with the smallest peak-to-trough swing, among modelled arms.
    pub steadiest: Option<String>,
    /// Arm with the highest time-weighted mean, among modelled arms.
    pub highest_mean: Option<String>,
    /// Arm spending the fewest milligrams per week, among modelled arms.
    pub lowest_weekly_mg: Option<String>,
    pub target: Option<TargetRange>,
    pub note: &'static str,
}

pub struct CompareInput {
    pub arms: Vec<CompareArm>,
    pub weight: f64,
    pub birth_year: Option<f64>,
    pub params: PkParams,
    pub e2_target: Option<TargetRange>,
    pub t_target: Option<TargetRange>,
    pub max_cycles: usize,
}

fn curve_for(stats: &SimulationStats, analyte: &str) -> Option<CurveStats> {
    match analyte {
        "e2" => stats.e2.clone(),
        "t" => stats.t.clone(),
        "cpa" => stats.cpa.clone(),
        "spiro" => stats.spiro.clone(),
        _ => None,
    }
}

fn default_label(arm: &CompareArm) -> String {
    let ester = arm.schedule.ester.code();
    let route = arm.schedule.route.code();
    format!("{ester} {route}")
}

/// Verdict for a settled arm, given the range it is being judged against.
///
/// Order matters: an unstable schedule is called unstable before it is called
/// volatile, because "it has not settled yet" explains the swing rather than
/// the other way round.
fn verdict_for(curve: &CurveStats, stable: bool, target: Option<TargetRange>) -> &'static str {
    if !stable {
        return "notStable";
    }
    if let Some(range) = target.and_then(|r| r.normalized()) {
        if curve.time_in_range_pct >= 90.0 {
            return "inRange";
        }
        if curve.mean < range.low {
            return "belowRange";
        }
        if curve.mean > range.high {
            return "aboveRange";
        }
    }
    if curve.fluctuation_pct > 100.0 {
        "volatile"
    } else {
        "inRange"
    }
}

fn note_for(verdict: &'static str) -> &'static str {
    match verdict {
        "inRange" => "Settles inside the target range for most of the interval.",
        "belowRange" => "Settles below the target range; the dose is the place to change it.",
        "aboveRange" => "Settles above the target range; the dose is the place to change it.",
        "volatile" => {
            "Swings by more than the trough itself within one interval. A shorter interval \
             or a slower-release route flattens this; a larger dose does not."
        }
        "notStable" => {
            "Did not settle within the cycle budget, so the numbers describe a cycle that is \
             still climbing. Long esters can take months to plateau."
        }
        "notModelled" => "This compound has no curve in the model, so only the dose is compared.",
        _ => "No curve was produced for this arm.",
    }
}

pub fn compare(input: CompareInput) -> CompareReport {
    let mut arms = Vec::new();
    let mut target_used = None;

    for arm in input.arms.iter().take(MAX_ARMS) {
        let sched = &arm.schedule;
        let analyte = sched.ester.hormone();
        let target = match analyte {
            Some("e2") => input.e2_target,
            Some("t") => input.t_target,
            _ => None,
        };
        if target_used.is_none() {
            target_used = target.and_then(|r| r.normalized());
        }

        let daily_mg = if sched.interval_h > 0.0 {
            sched.dose_mg * 24.0 / sched.interval_h
        } else {
            0.0
        };

        let report = if analyte.is_some() {
            steady_state(
                sched,
                input.weight,
                input.birth_year,
                &input.params,
                input.max_cycles.clamp(2, 512),
                input.e2_target,
                input.t_target,
                false,
            )
        } else {
            None
        };

        let (stable, cycles, accumulation_ratio, curve) = match (&report, analyte) {
            (Some(r), Some(a)) => (r.stable, r.cycles, r.accumulation_ratio, curve_for(&r.cycle, a)),
            _ => (false, 0, 0.0, None),
        };

        let verdict = if analyte.is_none() {
            "notModelled"
        } else if curve.is_none() {
            "noCurve"
        } else {
            verdict_for(curve.as_ref().expect("checked above"), stable, target)
        };

        arms.push(ArmReport {
            label: arm.label.clone().unwrap_or_else(|| default_label(arm)),
            analyte,
            ester: sched.ester.code(),
            route: sched.route.code(),
            dose_mg: sched.dose_mg,
            interval_h: sched.interval_h,
            daily_mg,
            weekly_mg: daily_mg * 7.0,
            active_daily_mg: daily_mg * sched.ester.to_active_factor(),
            modelled: analyte.is_some(),
            stable,
            cycles,
            accumulation_ratio,
            curve,
            verdict,
            note: note_for(verdict),
        });
    }

    let measured: Vec<&ArmReport> = arms
        .iter()
        .filter(|a| a.curve.is_some() && a.modelled)
        .collect();

    let steadiest = measured
        .iter()
        .filter(|a| a.stable)
        .min_by(|a, b| {
            let fa = a.curve.as_ref().map(|c| c.fluctuation_pct).unwrap_or(f64::MAX);
            let fb = b.curve.as_ref().map(|c| c.fluctuation_pct).unwrap_or(f64::MAX);
            fa.partial_cmp(&fb).unwrap_or(std::cmp::Ordering::Equal)
        })
        .map(|a| a.label.clone());

    let highest_mean = measured
        .iter()
        .max_by(|a, b| {
            let ma = a.curve.as_ref().map(|c| c.mean).unwrap_or(f64::MIN);
            let mb = b.curve.as_ref().map(|c| c.mean).unwrap_or(f64::MIN);
            ma.partial_cmp(&mb).unwrap_or(std::cmp::Ordering::Equal)
        })
        .map(|a| a.label.clone());

    let lowest_weekly_mg = measured
        .iter()
        .min_by(|a, b| {
            a.weekly_mg
                .partial_cmp(&b.weekly_mg)
                .unwrap_or(std::cmp::Ordering::Equal)
        })
        .map(|a| a.label.clone());

    CompareReport {
        arms,
        steadiest,
        highest_mean,
        lowest_weekly_mg,
        target: target_used,
        note: "Every arm is read after it settles, in its own analyte's units. \
               Milligram totals are only comparable within an ester; the active \
               milligram figure removes the ester's weight for cross-ester comparisons.",
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    fn arm(dose_mg: f64, interval_h: f64, ester: Ester, route: Route) -> CompareArm {
        CompareArm {
            label: None,
            schedule: Schedule {
                route,
                ester,
                dose_mg,
                interval_h,
                extras: Default::default(),
                start_h: 0.0,
            },
        }
    }

    fn run(arms: Vec<CompareArm>) -> CompareReport {
        compare(CompareInput {
            arms,
            weight: 70.0,
            birth_year: None,
            params: PkParams::default(),
            e2_target: Some(TargetRange::new(100.0, 200.0)),
            t_target: None,
            max_cycles: 96,
        })
    }

    #[test]
    fn milligrams_per_week_follow_the_interval() {
        let report = run(vec![arm(2.0, 84.0, Ester::EV, Route::Injection)]);
        let a = &report.arms[0];
        assert!((a.weekly_mg - 4.0).abs() < 1e-9, "{}", a.weekly_mg);
        assert!((a.daily_mg - 4.0 / 7.0).abs() < 1e-9);
    }

    #[test]
    fn an_unmodelled_compound_is_compared_by_dose_only() {
        let report = run(vec![arm(50.0, 24.0, Ester::BICA, Route::Oral)]);
        let a = &report.arms[0];
        assert_eq!(a.verdict, "notModelled");
        assert!(a.curve.is_none());
        assert!(report.steadiest.is_none());
    }

    #[test]
    fn daily_dosing_is_steadier_than_a_weekly_bolus() {
        let report = run(vec![
            arm(4.0, 168.0, Ester::EV, Route::Injection),
            arm(0.5, 24.0, Ester::E2, Route::Oral),
        ]);
        assert_eq!(report.arms.len(), 2);
        let weekly = &report.arms[0].curve.as_ref().expect("weekly curve");
        let daily = &report.arms[1].curve.as_ref().expect("daily curve");
        assert!(
            daily.fluctuation_pct < weekly.fluctuation_pct,
            "daily {} vs weekly {}",
            daily.fluctuation_pct,
            weekly.fluctuation_pct
        );
        assert_eq!(report.steadiest.as_deref(), Some("E2 oral"));
    }

    #[test]
    fn more_than_six_arms_is_capped() {
        let arms = (0..9)
            .map(|i| arm(1.0 + i as f64, 168.0, Ester::EV, Route::Injection))
            .collect();
        assert_eq!(run(arms).arms.len(), MAX_ARMS);
    }
}
