//! Planning: what a schedule settles to, what dose gets there, and whether a
//! person is actually following it.
//!
//! Everything here is deterministic and offline; nothing is a prescription.
//! The numbers describe what the model would do with a given input, which is
//! what makes them useful for "if I inject every 7 days instead of 5, where
//! does my trough end up?" and useless as medical advice.

use std::collections::HashMap;

use serde::{Deserialize, Serialize};

use crate::engine::{run_simulation, run_simulation_grid, SimGrid};
use crate::model::*;
use crate::stats::{simulation_stats, SimulationStats};

/// A repeating dose: route, ester, amount every `interval_h` hours.
#[derive(Debug, Clone, Serialize, Deserialize)]
#[serde(rename_all = "camelCase")]
pub struct Schedule {
    pub route: Route,
    pub ester: Ester,
    #[serde(rename = "doseMG", alias = "doseMg", alias = "dose_mg")]
    pub dose_mg: f64,
    pub interval_h: f64,
    #[serde(default)]
    pub extras: HashMap<String, f64>,
    #[serde(default)]
    pub start_h: f64,
}

impl Schedule {
    /// `cycles` doses, one every interval.
    pub fn events(&self, cycles: usize) -> Vec<DoseEvent> {
        (0..cycles)
            .map(|i| DoseEvent {
                id: format!("sched-{i}"),
                route: self.route,
                time_h: self.start_h + i as f64 * self.interval_h,
                dose_mg: self.dose_mg,
                ester: self.ester,
                extras: self.extras.clone(),
                updated_at: None,
            })
            .collect()
    }

    fn at_dose(&self, dose_mg: f64) -> Schedule {
        Schedule {
            dose_mg,
            ..self.clone()
        }
    }
}

/// Where a repeated schedule settles.
#[derive(Debug, Clone, Serialize, Deserialize)]
#[serde(rename_all = "camelCase")]
pub struct SteadyStateReport {
    /// Doses simulated before the last cycle was read.
    pub cycles: usize,
    /// True when two consecutive cycles agreed to within 1%.
    pub stable: bool,
    /// Steady-state peak divided by the first cycle's peak.
    pub accumulation_ratio: f64,
    pub interval_h: f64,
    pub cycle: SimulationStats,
    /// The last cycle's samples, when the caller asked for them.
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub series: Option<SimulationResult>,
}

fn relative_change(a: f64, b: f64) -> f64 {
    let scale = a.abs().max(b.abs()).max(1e-9);
    (a - b).abs() / scale
}

/// Simulate a schedule for one cycle, after enough doses for it to settle.
///
/// Clearance is slow for the long esters, so a weekly injection can take two
/// months of doses to plateau. Cycles are tried in increasing order and the
/// loop stops as soon as peak and trough stop moving; `max_cycles` only caps
/// the search, it does not force it.
pub fn steady_state(
    sched: &Schedule,
    weight: f64,
    birth_year: Option<f64>,
    params: &PkParams,
    max_cycles: usize,
    e2_range: Option<TargetRange>,
    t_range: Option<TargetRange>,
    include_series: bool,
) -> Option<SteadyStateReport> {
    if !(sched.interval_h > 0.0) || !sched.dose_mg.is_finite() {
        return None;
    }
    let max_cycles = max_cycles.clamp(2, 512);
    let step = (sched.interval_h / 96.0).clamp(0.05, 0.5);

    let first_peak = {
        let events = sched.events(1);
        let grid = SimGrid::uniform(sched.start_h, sched.start_h + sched.interval_h, step);
        run_simulation_grid(
            &events,
            weight,
            birth_year,
            params,
            sched.start_h,
            1.0,
            &grid,
        )
        .and_then(|sim| {
            let stats = simulation_stats(&sim, None, e2_range, t_range);
            stats.e2.map(|s| s.peak).or_else(|| stats.t.map(|s| s.peak))
        })
    };

    let mut previous: Option<(f64, f64)> = None;
    let mut stable = false;

    let mut n = 2usize;
    while n <= max_cycles {
        let events = sched.events(n);
        let window_start = sched.start_h + (n as f64 - 1.0) * sched.interval_h;
        let window_end = window_start + sched.interval_h;
        let grid = SimGrid::uniform(window_start, window_end, step).with_max_points(4000);

        let Some(sim) =
            run_simulation_grid(&events, weight, birth_year, params, window_end, 1.0, &grid)
        else {
            return None;
        };
        let stats = simulation_stats(&sim, None, e2_range, t_range);
        let (peak, trough) = match (&stats.e2, &stats.t) {
            (Some(e2), _) => (e2.peak, e2.trough),
            (None, Some(t)) => (t.peak, t.trough),
            _ => return None,
        };

        if let Some((prev_peak, prev_trough)) = previous {
            if relative_change(peak, prev_peak) < 0.01
                && relative_change(trough, prev_trough) < 0.01
            {
                stable = true;
            }
        }

        let next = if n < 8 { n + 2 } else { (n * 3).div_ceil(2) };
        if stable {
            let series = if include_series { Some(sim) } else { None };
            return Some(SteadyStateReport {
                cycles: n,
                stable,
                accumulation_ratio: match (first_peak, stats.e2.as_ref().or(stats.t.as_ref())) {
                    (Some(first), Some(steady)) if first > 1e-9 => steady.peak / first,
                    _ => 1.0,
                },
                interval_h: sched.interval_h,
                cycle: stats,
                series,
            });
        }
        previous = Some((peak, trough));
        n = next;
    }

    // Not converged inside the cap: report the last cycle and say so, rather
    // than pretending it is steady.
    let events = sched.events(max_cycles);
    let window_start = sched.start_h + (max_cycles as f64 - 1.0) * sched.interval_h;
    let grid =
        SimGrid::uniform(window_start, window_start + sched.interval_h, step).with_max_points(4000);
    let sim = run_simulation_grid(
        &events,
        weight,
        birth_year,
        params,
        window_start + sched.interval_h,
        1.0,
        &grid,
    )?;
    let stats = simulation_stats(&sim, None, e2_range, t_range);
    Some(SteadyStateReport {
        cycles: max_cycles,
        stable: false,
        accumulation_ratio: match (first_peak, stats.e2.as_ref().or(stats.t.as_ref())) {
            (Some(first), Some(steady)) if first > 1e-9 => steady.peak / first,
            _ => 1.0,
        },
        interval_h: sched.interval_h,
        cycle: stats,
        series: if include_series { Some(sim) } else { None },
    })
}

/// Which number the solver should place in the target range.
#[derive(Debug, Clone, Copy, PartialEq, Eq, Serialize, Deserialize)]
#[serde(rename_all = "camelCase")]
pub enum Objective {
    /// Keep the lowest point above the lower bound — the usual goal for
    /// injections, where the trough is what causes symptoms.
    Trough,
    /// Keep the highest point below the upper bound.
    Peak,
    /// Put the time-weighted mean in the middle of the range.
    Mean,
}

impl Objective {
    pub fn parse(text: &str) -> Objective {
        match text.trim().to_ascii_lowercase().as_str() {
            "peak" | "cmax" => Objective::Peak,
            "mean" | "average" | "cavg" => Objective::Mean,
            _ => Objective::Trough,
        }
    }

    pub fn code(self) -> &'static str {
        match self {
            Objective::Trough => "trough",
            Objective::Peak => "peak",
            Objective::Mean => "mean",
        }
    }
}

/// A dose the solver suggests, with the curve it would produce.
#[derive(Debug, Clone, Serialize, Deserialize)]
#[serde(rename_all = "camelCase")]
pub struct DoseSolution {
    pub dose_mg: f64,
    pub objective: String,
    pub achieved_peak: f64,
    pub achieved_trough: f64,
    pub achieved_mean: f64,
    /// Both bounds respected at the suggested dose.
    pub in_range: bool,
    /// False when the interval cannot satisfy both bounds at any dose.
    pub feasible: bool,
    pub cycles: usize,
    pub note: String,
}

/// Solve for the dose that places `objective` in `range` at steady state.
///
/// Concentrations are linear in dose for every route here, so the solution is
/// a division, not a search: simulate one milligram, read the peak/trough it
/// produces, scale. The result is then simulated again at the rounded dose, so
/// the numbers returned are the ones the person would actually get.
pub fn solve_dose(
    sched: &Schedule,
    weight: f64,
    birth_year: Option<f64>,
    params: &PkParams,
    objective: Objective,
    range: TargetRange,
    max_cycles: usize,
) -> Option<DoseSolution> {
    let range = range.normalized()?;
    if sched.route == Route::PatchRemove {
        return None;
    }

    let unit = steady_state(
        &sched.at_dose(1.0),
        weight,
        birth_year,
        params,
        max_cycles,
        None,
        None,
        false,
    )?;
    let hormone = unit.cycle.e2.as_ref().or(unit.cycle.t.as_ref())?;
    let (per_mg_peak, per_mg_trough, per_mg_mean) = (hormone.peak, hormone.trough, hormone.mean);

    let span = range.high - range.low;
    let aim = match objective {
        Objective::Trough => range.low + span * 0.05,
        Objective::Peak => range.high - span * 0.10,
        Objective::Mean => (range.low + range.high) / 2.0,
    };
    let per_mg = match objective {
        Objective::Trough => per_mg_trough,
        Objective::Peak => per_mg_peak,
        Objective::Mean => per_mg_mean,
    };

    if !(per_mg > 1e-12) {
        return Some(DoseSolution {
            dose_mg: sched.dose_mg,
            objective: objective.code().to_string(),
            achieved_peak: hormone.peak,
            achieved_trough: hormone.trough,
            achieved_mean: hormone.mean,
            in_range: range.contains(hormone.trough) && range.contains(hormone.peak),
            feasible: false,
            cycles: unit.cycles,
            note: "This route does not respond to the logged amount — a patch \
                   with a labelled release rate delivers a fixed flux, so the \
                   dose has to be changed on the patch, not in milligrams."
                .to_string(),
        });
    }

    let raw = aim / per_mg;
    let dose = (raw * 10.0).round().max(1.0) / 10.0;

    let check = steady_state(
        &sched.at_dose(dose),
        weight,
        birth_year,
        params,
        max_cycles,
        None,
        None,
        false,
    )?;
    let achieved = check.cycle.e2.as_ref().or(check.cycle.t.as_ref())?;

    let in_range = range.contains(achieved.trough) && range.contains(achieved.peak);
    let note = if in_range {
        String::new()
    } else if achieved.peak > range.high && achieved.trough < range.low {
        "The swing across one interval is wider than the target range: no dose \
         keeps both the peak under the ceiling and the trough above the floor. \
         Shorten the interval or use a slower ester."
            .to_string()
    } else if achieved.peak > range.high {
        "Placing the trough in range pushes the peak over the ceiling; the \
         interval is long relative to the absorption."
            .to_string()
    } else {
        "Even this dose leaves the trough below the floor; the interval is long \
         enough that the curve decays past it."
            .to_string()
    };

    Some(DoseSolution {
        dose_mg: dose,
        objective: objective.code().to_string(),
        achieved_peak: achieved.peak,
        achieved_trough: achieved.trough,
        achieved_mean: achieved.mean,
        in_range,
        feasible: in_range,
        cycles: check.cycles,
        note,
    })
}

/// How well a log matches a planned interval.
#[derive(Debug, Clone, Default, Serialize, Deserialize)]
#[serde(rename_all = "camelCase")]
pub struct AdherenceReport {
    pub expected: usize,
    pub taken: usize,
    /// `taken / expected`, capped at 100 — a surplus is reported separately.
    pub coverage_pct: f64,
    /// Doses that landed within a quarter of an interval of their slot.
    pub on_time_pct: f64,
    pub extra_doses: usize,
    pub longest_gap_h: f64,
    pub longest_gap_start_h: Option<f64>,
    /// Every stretch longer than 1.5 intervals, as (start, hours).
    pub gaps: Vec<(f64, f64)>,
}

/// Compare the logged doses with a fixed interval.
///
/// "Expected" is counted from the window, not derived from the log, so a
/// person who stopped logging is visible as missing doses rather than as a
/// perfect record of the ones they did log.
pub fn adherence(
    events: &[DoseEvent],
    interval_h: f64,
    from_h: f64,
    to_h: f64,
) -> Option<AdherenceReport> {
    if !(interval_h > 0.0) || !(to_h > from_h) {
        return None;
    }
    let mut times: Vec<f64> = events
        .iter()
        .filter(|e| e.route != Route::PatchRemove && e.dose_mg > 0.0)
        .map(|e| e.time_h)
        .filter(|t| *t >= from_h && *t <= to_h && t.is_finite())
        .collect();
    times.sort_by(|a, b| a.partial_cmp(b).unwrap_or(std::cmp::Ordering::Equal));
    times.dedup();

    let expected = (((to_h - from_h) / interval_h).floor() as i64 + 1).max(0) as usize;
    if expected == 0 {
        return None;
    }
    let taken = times.len();

    let mut on_time = 0usize;
    for t in &times {
        let slot = ((t - from_h) / interval_h).round() * interval_h + from_h;
        if (t - slot).abs() <= interval_h * 0.25 {
            on_time += 1;
        }
    }

    let mut gaps: Vec<(f64, f64)> = Vec::new();
    for pair in times.windows(2) {
        let gap = pair[1] - pair[0];
        if gap > interval_h * 1.5 {
            gaps.push((pair[0], gap));
        }
    }
    // A gap from the window start, or up to its end, counts too.
    if let Some(first) = times.first() {
        if *first - from_h > interval_h * 1.5 {
            gaps.push((from_h, *first - from_h));
        }
    }
    if let Some(last) = times.last() {
        if to_h - *last > interval_h * 1.5 {
            gaps.push((*last, to_h - *last));
        }
    }
    gaps.sort_by(|a, b| b.1.partial_cmp(&a.1).unwrap_or(std::cmp::Ordering::Equal));
    let (longest_gap_h, longest_gap_start_h) = match gaps.first() {
        Some((start, hours)) => (*hours, Some(*start)),
        None => (0.0, None),
    };
    gaps.truncate(12);

    let taken_in_slots = taken.min(expected);
    Some(AdherenceReport {
        expected,
        taken,
        coverage_pct: taken_in_slots as f64 / expected as f64 * 100.0,
        on_time_pct: if taken > 0 {
            on_time as f64 / taken as f64 * 100.0
        } else {
            0.0
        },
        extra_doses: taken.saturating_sub(expected),
        longest_gap_h,
        longest_gap_start_h,
        gaps,
    })
}

/// How long the supply lasts at the planned rate.
#[derive(Debug, Clone, Serialize, Deserialize)]
#[serde(rename_all = "camelCase")]
pub struct SupplyReport {
    pub on_hand_mg: f64,
    pub daily_mg: f64,
    pub weekly_mg: f64,
    pub doses_remaining: usize,
    pub days_remaining: f64,
    pub run_out_h: f64,
}

/// Forecast a supply against a schedule.
pub fn supply(on_hand_mg: f64, sched: &Schedule, as_of_h: f64) -> Option<SupplyReport> {
    if !(sched.interval_h > 0.0) || !(sched.dose_mg > 0.0) || !on_hand_mg.is_finite() {
        return None;
    }
    let daily_mg = sched.dose_mg / sched.interval_h * 24.0;
    if !(daily_mg > 0.0) {
        return None;
    }
    let days_remaining = (on_hand_mg / daily_mg).max(0.0);
    Some(SupplyReport {
        on_hand_mg,
        daily_mg,
        weekly_mg: daily_mg * 7.0,
        doses_remaining: (on_hand_mg / sched.dose_mg).floor().max(0.0) as usize,
        days_remaining,
        run_out_h: as_of_h + days_remaining * 24.0,
    })
}

/// `now_h` is only used to place the window; helpful for callers that would
/// otherwise hand-roll it.
pub fn window_ending_at(now_h: f64, days: f64) -> (f64, f64) {
    (now_h - days * 24.0, now_h)
}

/// A convenience wrapper for callers that want one simulation and its stats.
pub fn simulate_with_stats(
    events: &[DoseEvent],
    weight: f64,
    birth_year: Option<f64>,
    params: &PkParams,
    now_h: f64,
    clearance_mult: f64,
    window: Option<(f64, f64)>,
    e2_range: Option<TargetRange>,
    t_range: Option<TargetRange>,
) -> Option<(SimulationResult, SimulationStats)> {
    let sim = match window {
        Some((from, to)) if to > from => {
            let steps = ((to - from) / 1.0).ceil().clamp(48.0, 20_000.0) as usize;
            let step = (to - from) / steps as f64;
            run_simulation_grid(
                events,
                weight,
                birth_year,
                params,
                now_h,
                clearance_mult,
                &SimGrid::uniform(from, to, step),
            )?
        }
        _ => run_simulation(events, weight, birth_year, params, now_h, clearance_mult)?,
    };
    let stats = simulation_stats(&sim, None, e2_range, t_range);
    Some((sim, stats))
}

#[cfg(test)]
mod tests {
    use super::*;

    fn weekly_ev() -> Schedule {
        Schedule {
            route: Route::Injection,
            ester: Ester::EV,
            dose_mg: 4.0,
            interval_h: 168.0,
            extras: HashMap::new(),
            start_h: 0.0,
        }
    }

    #[test]
    fn weekly_valerate_settles_and_accumulates() {
        let params = PkParams::default();
        let report = steady_state(&weekly_ev(), 70.0, None, &params, 128, None, None, false)
            .expect("steady state");
        assert!(
            report.stable,
            "did not converge in {} cycles",
            report.cycles
        );
        let e2 = report.cycle.e2.expect("e2 curve");
        assert!(e2.peak > e2.trough);
        assert!(e2.peak > 50.0 && e2.peak < 900.0, "peak {}", e2.peak);
        assert!(report.accumulation_ratio >= 1.0);
    }

    #[test]
    fn solving_for_a_trough_lands_inside_the_range() {
        let params = PkParams::default();
        let range = TargetRange::new(100.0, 200.0);
        let sol = solve_dose(
            &weekly_ev(),
            70.0,
            None,
            &params,
            Objective::Trough,
            range,
            128,
        )
        .expect("solution");
        assert!(
            sol.dose_mg > 0.5 && sol.dose_mg < 30.0,
            "dose {}",
            sol.dose_mg
        );
        assert!(
            sol.achieved_trough >= 95.0,
            "trough {} below range",
            sol.achieved_trough
        );
    }

    #[test]
    fn coverage_counts_from_the_window_not_the_log() {
        let events: Vec<DoseEvent> = (0..3)
            .map(|i| DoseEvent {
                id: format!("d{i}"),
                route: Route::Injection,
                time_h: i as f64 * 168.0,
                dose_mg: 4.0,
                ester: Ester::EV,
                extras: HashMap::new(),
                updated_at: None,
            })
            .collect();
        let report = adherence(&events, 168.0, 0.0, 4.0 * 168.0).expect("report");
        assert_eq!(report.expected, 5);
        assert_eq!(report.taken, 3);
        assert!((report.coverage_pct - 60.0).abs() < 1e-6);
        assert!(report.longest_gap_h >= 168.0);
    }
}
