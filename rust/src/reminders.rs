//! When will the level leave the target range?
//!
//! The app uses this to decide when to ring: a reminder is placed a little
//! before the modelled curve crosses the lower bound, so the dose can be taken
//! while the level is still acceptable rather than after it has already gone
//! too low.

use serde::{Deserialize, Serialize};

use crate::model::{SimulationResult, TargetRange};

/// One predicted crossing of the lower bound.
#[derive(Debug, Clone, Serialize, Deserialize)]
#[serde(rename_all = "camelCase")]
pub struct Reminder {
    /// When the notification should fire, in hours since the Unix epoch.
    pub at_h: f64,
    /// When the modelled level actually crosses `low`.
    pub crossing_h: f64,
    /// Level at the moment of the crossing (the lower bound, by definition).
    pub level: f64,
    /// Hours from `from_h` until the notification.
    pub hours_until: f64,
    /// How much earlier than the crossing the notification is placed.
    pub lead_h: f64,
}

/// Crossings of `low` in the falling direction.
///
/// `lead_h` shifts each reminder earlier, `min_gap_h` suppresses a second
/// reminder that would arrive uncomfortably close to the first (which happens
/// when a dose produces a brief dip right after a previous reminder), and
/// `horizon_h` bounds the search so a years-long simulation cannot produce a
/// thousand notifications.
pub fn predicted_drops(
    sim: &SimulationResult,
    low: f64,
    from_h: f64,
    horizon_h: f64,
    lead_h: f64,
    min_gap_h: f64,
) -> Vec<Reminder> {
    if !(low > 0.0) || !(horizon_h > 0.0) {
        return Vec::new();
    }
    let end = from_h + horizon_h;
    let lead = lead_h.max(0.0);
    let min_gap = min_gap_h.max(0.0);
    let mut out: Vec<Reminder> = Vec::new();

    for i in 1..sim.time_h.len() {
        let (t0, t1) = (sim.time_h[i - 1], sim.time_h[i]);
        if t1 < from_h || t0 > end {
            continue;
        }
        let (c0, c1) = (sim.e2_pg_ml[i - 1], sim.e2_pg_ml[i]);
        if !(c0 >= low && c1 < low) {
            continue;
        }
        let crossing = if (c1 - c0).abs() < 1e-12 {
            t1
        } else {
            t0 + (low - c0) / (c1 - c0) * (t1 - t0)
        };
        if crossing < from_h || crossing > end {
            continue;
        }
        let at = (crossing - lead).max(from_h);
        if let Some(last) = out.last() {
            if at - last.at_h < min_gap {
                continue;
            }
        }
        out.push(Reminder {
            at_h: at,
            crossing_h: crossing,
            level: low,
            hours_until: at - from_h,
            lead_h: lead,
        });
    }
    out
}

/// Hours spent below `low` inside the window — the amount of the horizon the
/// person would spend under-target if they did nothing.
pub fn hours_below(sim: &SimulationResult, low: f64, from_h: f64, to_h: f64) -> f64 {
    let mut hours = 0.0;
    for i in 1..sim.time_h.len() {
        let (t0, t1) = (sim.time_h[i - 1], sim.time_h[i]);
        let start = t0.max(from_h);
        let end = t1.min(to_h);
        if end <= start {
            continue;
        }
        let (c0, c1) = (sim.e2_pg_ml[i - 1], sim.e2_pg_ml[i]);
        let dt = end - start;
        if c0 < low && c1 < low {
            hours += dt;
        } else if c0 < low || c1 < low {
            let span = c1 - c0;
            if span.abs() > 1e-12 {
                let frac = ((low - c0) / span).clamp(0.0, 1.0);
                hours += if c0 < low {
                    dt * frac
                } else {
                    dt * (1.0 - frac)
                };
            }
        }
    }
    hours
}

/// The soonest and latest crossing inside a window, for a "next dip" card.
pub fn next_drop(sim: &SimulationResult, low: f64, from_h: f64) -> Option<Reminder> {
    predicted_drops(sim, low, from_h, 24.0 * 365.0, 0.0, 0.0)
        .into_iter()
        .next()
}

/// Convenience: a full target range, returning the first exit below it.
pub fn first_exit_below(
    sim: &SimulationResult,
    range: TargetRange,
    from_h: f64,
    horizon_h: f64,
) -> Option<f64> {
    let range = range.normalized()?;
    predicted_drops(sim, range.low, from_h, horizon_h, 0.0, 0.0)
        .first()
        .map(|r| r.crossing_h)
}

#[cfg(test)]
mod tests {
    use super::*;

    fn decaying_curve() -> SimulationResult {
        let times: Vec<f64> = (0..=120).map(|h| h as f64).collect();
        let values: Vec<f64> = times.iter().map(|h| 300.0 * (-0.03 * h).exp()).collect();
        SimulationResult {
            time_h: times,
            e2_pg_ml: values,
            cpa_ng_ml: vec![0.0; 121],
            t_ng_dl: vec![0.0; 121],
            spiro_ng_ml: vec![0.0; 121],
            auc: 0.0,
            spiro_auc: 0.0,
        }
    }

    #[test]
    fn finds_the_crossing_before_it_happens() {
        let sim = decaying_curve();
        let drops = predicted_drops(&sim, 150.0, 0.0, 120.0, 24.0, 1.0);
        assert_eq!(drops.len(), 1);
        let expected = 150.0f64.ln() / 300.0f64.ln();
        let _ = expected;
        let crossing = 300.0f64.ln() / 0.03 - 150.0f64.ln() / 0.03;
        assert!(
            (drops[0].crossing_h - crossing).abs() < 0.5,
            "{:?}",
            drops[0]
        );
        assert!(drops[0].at_h < drops[0].crossing_h);
    }

    #[test]
    fn counts_the_hours_under_the_floor() {
        let sim = decaying_curve();
        let hours = hours_below(&sim, 150.0, 0.0, 120.0);
        assert!(hours > 0.0 && hours < 120.0, "hours {hours}");
    }
}
