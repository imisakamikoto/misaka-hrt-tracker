//! Anti-androgen support: is the regimen taken, and is the dose in a range
//! that is actually used for androgen blockade?
//!
//! This module answers two questions a person on an anti-androgen actually
//! asks — "am I due?" and "is this dose doing anything?" — and refuses to
//! answer a third one: how much androgen is blocked. The engine has no
//! endogenous testosterone production and no receptor model, so any number
//! claiming to be "percent blocked" would be invented. What it can say is
//! whether the dose sits in a range that is commonly prescribed, whether the
//! record shows the drug being taken on schedule, and what the modelled
//! canrenone or cyproterone level is.
//!
//! The bands below are prescribing ranges, not measured thresholds. They come
//! from the doses used in the literature for androgen blockade and are meant to
//! start a conversation with a prescriber, not replace one.

use serde::Serialize;

use crate::engine::run_simulation_grid;
use crate::model::*;
use crate::planning::adherence;
use crate::stats::{curve_stats, CurveStats};

/// Default assessment window, in days. Four weeks covers a monthly review and
/// is long enough for a missed week to show up.
pub const DEFAULT_WINDOW_DAYS: f64 = 28.0;

/// A dose range commonly used for androgen blockade.
#[derive(Debug, Clone, Copy)]
struct Band {
    low_mg: f64,
    high_mg: f64,
    ceiling_mg: f64,
}

fn band_for(ester: Ester) -> Option<Band> {
    Some(match ester {
        // 50–200 mg/day is the usual range; 400 mg/day is the practical ceiling.
        Ester::SPIRO => Band {
            low_mg: 50.0,
            high_mg: 200.0,
            ceiling_mg: 400.0,
        },
        // Cyproterone is used at 12.5–50 mg/day; above that the liver and
        // prolactin risks climb steeply.
        Ester::CPA => Band {
            low_mg: 12.5,
            high_mg: 50.0,
            ceiling_mg: 100.0,
        },
        // Bicalutamide is almost always 50 mg/day; 150 mg is the oncology dose.
        Ester::BICA => Band {
            low_mg: 25.0,
            high_mg: 50.0,
            ceiling_mg: 150.0,
        },
        // Medroxyprogesterone is used at 5–10 mg/day for this purpose.
        Ester::MPA => Band {
            low_mg: 2.5,
            high_mg: 10.0,
            ceiling_mg: 20.0,
        },
        _ => return None,
    })
}

fn name_for(ester: Ester) -> &'static str {
    match ester {
        Ester::SPIRO => "Spironolactone",
        Ester::CPA => "Cyproterone acetate",
        Ester::BICA => "Bicalutamide",
        Ester::MPA => "Medroxyprogesterone acetate",
        _ => "Anti-androgen",
    }
}

/// How a compound is expected to act, which is not the same question as how
/// much of it is in the blood.
///
/// The distinction matters because the two are routinely conflated for
/// spironolactone: it blocks the receptor, and the evidence does not support it
/// lowering testosterone at clinical doses. A record that credits spiro with
/// suppression will read a rising testosterone as a dosing failure when the
/// dose was never the mechanism.
fn mechanism_for(ester: Ester) -> &'static str {
    match ester {
        // Receptor antagonist only. The androgen-synthesis inhibition seen in
        // animals needs doses far above the clinical range.
        Ester::SPIRO | Ester::BICA => "receptorBlockade",
        // Suppresses gonadotropins at clinical doses, so testosterone falls.
        Ester::CPA => "synthesisAndReceptor",
        Ester::MPA => "gonadotropinSuppression",
        _ => "unknown",
    }
}

/// Whether a fall in testosterone is expected from this compound alone.
fn expects_testosterone_fall(ester: Ester) -> bool {
    matches!(ester, Ester::CPA | Ester::MPA)
}

fn mechanism_note(ester: Ester) -> &'static str {
    match ester {
        Ester::SPIRO => {
            "Blocks the androgen receptor. A review of 22 studies in men and 11 \
             in trans women found no consistent fall in testosterone; with \
             estradiol, the fall comes from the estradiol. Expect the level to \
             be present, not the testosterone to drop."
        }
        Ester::BICA => {
            "Blocks the androgen receptor and raises testosterone rather than \
             lowering it; the level here is not measured by this model."
        }
        Ester::CPA => {
            "Suppresses gonadotropins as well as blocking the receptor, so \
             testosterone usually falls by roughly half at clinical doses."
        }
        Ester::MPA => {
            "Suppresses gonadotropins; used as an alternative where cyproterone \
             is not available."
        }
        _ => "Mechanism not classified.",
    }
}

#[derive(Debug, Clone, Serialize)]
#[serde(rename_all = "camelCase")]
pub struct BlockadeCompound {
    /// Ester code, e.g. `SPIRO`.
    pub ester: &'static str,
    pub name: &'static str,
    /// Whether the engine produces a curve for this compound.
    pub modelled: bool,
    /// The most recent dose in the window, in mg.
    ///
    /// The app, the backups and this crate's own API document spell the unit
    /// in capitals, so that is what goes out on the wire; `doseMg` is still
    /// accepted on the way in for a client that read the old shape.
    #[serde(rename = "doseMG", alias = "doseMg")]
    pub dose_mg: f64,
    /// Median spacing between doses, in hours.
    pub interval_h: f64,
    /// Total dose in the window divided by the days it covers.
    #[serde(rename = "dailyMG", alias = "dailyMg")]
    pub daily_mg: f64,
    /// `low`, `typical`, `high` or `aboveCeiling`.
    pub band: &'static str,
    #[serde(rename = "bandLowMG", alias = "bandLowMg")]
    pub band_low_mg: f64,
    #[serde(rename = "bandHighMG", alias = "bandHighMg")]
    pub band_high_mg: f64,
    #[serde(rename = "bandCeilingMG", alias = "bandCeilingMg")]
    pub band_ceiling_mg: f64,
    /// Peak/trough/mean of the modelled curve, when there is one.
    pub level: Option<CurveStats>,
    pub coverage_pct: f64,
    pub expected: usize,
    pub taken: usize,
    /// Last dose plus one interval.
    pub next_due_h: Option<f64>,
    /// Positive when the next dose is already late, in hours.
    pub overdue_h: f64,
    /// `adequate`, `lowDose`, `highDose`, `aboveCeiling`, `coverage`,
    /// `nothingLogged` or `unknown`.
    pub verdict: &'static str,
    /// `receptorBlockade`, `synthesisAndReceptor`, `gonadotropinSuppression`
    /// or `unknown`.
    pub mechanism: &'static str,
    /// Whether this compound alone is expected to lower testosterone.
    pub expects_testosterone_fall: bool,
    /// One sentence on the mechanism and what the evidence supports.
    pub mechanism_note: &'static str,
    pub notes: Vec<String>,
}

#[derive(Debug, Clone, Serialize)]
#[serde(rename_all = "camelCase")]
pub struct BlockadeReport {
    pub compounds: Vec<BlockadeCompound>,
    pub window_days: f64,
    pub window_start_h: f64,
    pub window_end_h: f64,
    /// Always false. Kept explicit so no client mistakes the verdict for a
    /// measurement of androgen suppression.
    pub androgen_suppression_modelled: bool,
    pub note: &'static str,
}

fn median_interval(times: &[f64]) -> f64 {
    if times.len() < 2 {
        return 24.0;
    }
    let mut gaps: Vec<f64> = times
        .windows(2)
        .map(|w| w[1] - w[0])
        .filter(|g| g.is_finite() && *g > 0.0)
        .collect();
    if gaps.is_empty() {
        return 24.0;
    }
    gaps.sort_by(|a, b| a.partial_cmp(b).unwrap_or(std::cmp::Ordering::Equal));
    let mid = gaps.len() / 2;
    let median = if gaps.len() % 2 == 0 {
        (gaps[mid - 1] + gaps[mid]) / 2.0
    } else {
        gaps[mid]
    };
    median.clamp(4.0, 24.0 * 30.0)
}

fn band_of(band: Band, daily_mg: f64) -> &'static str {
    if daily_mg < band.low_mg {
        "low"
    } else if daily_mg <= band.high_mg {
        "typical"
    } else if daily_mg <= band.ceiling_mg {
        "high"
    } else {
        "aboveCeiling"
    }
}

pub struct BlockadeInput<'a> {
    pub events: &'a [DoseEvent],
    pub params: &'a PkParams,
    pub weight: f64,
    pub birth_year: Option<f64>,
    pub now_h: f64,
    pub clearance_mult: f64,
    pub window_days: f64,
}

pub fn assess(input: BlockadeInput<'_>) -> BlockadeReport {
    let window_days = if input.window_days.is_finite() && input.window_days >= 7.0 {
        input.window_days.min(365.0)
    } else {
        DEFAULT_WINDOW_DAYS
    };
    let window_start = input.now_h - window_days * 24.0;
    let window_end = input.now_h;

    let mut report = BlockadeReport {
        compounds: Vec::new(),
        window_days,
        window_start_h: window_start,
        window_end_h: window_end,
        androgen_suppression_modelled: false,
        note: "These are doses commonly used for androgen blockade, not measured \
               thresholds. Two compounds that are routinely described as \
               lowering testosterone — spironolactone and bicalutamide — do not \
               do so at clinical doses in the published evidence; they block the \
               receptor. Cyproterone and medroxyprogesterone suppress \
               gonadotropins and do lower it. The model has no endogenous \
               testosterone production, so it reports the dose band, the \
               coverage and the modelled drug level, and leaves the question of \
               how much androgen is actually blocked open rather than inventing \
               a number for it.",
    };

    // Which anti-androgens appear at all, in a stable order.
    let mut seen: Vec<Ester> = Vec::new();
    for e in input.events {
        if band_for(e.ester).is_some() && !seen.contains(&e.ester) {
            seen.push(e.ester);
        }
    }
    if seen.is_empty() {
        return report;
    }

    // One simulation covers every compound that has a curve.
    let sim = run_simulation_grid(
        input.events,
        if input.weight > 0.0 {
            input.weight
        } else {
            70.0
        },
        input.birth_year,
        input.params,
        input.now_h,
        input.clearance_mult,
        &crate::engine::SimGrid {
            start_h: Some(window_start),
            end_h: Some(window_end + 1.0),
            step_h: Some(1.0),
            max_points: 20_000,
        },
    );

    for ester in seen {
        let band = band_for(ester).expect("filtered above");
        let mut times: Vec<f64> = input
            .events
            .iter()
            .filter(|e| e.ester == ester && e.dose_mg > 0.0)
            .map(|e| e.time_h)
            .collect();
        times.sort_by(|a, b| a.partial_cmp(b).unwrap_or(std::cmp::Ordering::Equal));
        if times.is_empty() {
            continue;
        }

        let interval = median_interval(&times);
        let in_window: Vec<&DoseEvent> = input
            .events
            .iter()
            .filter(|e| e.ester == ester && e.dose_mg > 0.0 && e.time_h >= window_start)
            .collect();
        let window_mg: f64 = in_window.iter().map(|e| e.dose_mg).sum();
        // Divide by the part of the window the record actually covers, not by
        // the whole window. A single 120 mg dose logged today is 120 mg a day;
        // averaging it over 28 days reads as 4 mg a day and calls a normal dose
        // sub-threshold. How fully the window is filled is what coverage
        // reports, and it already says so separately.
        let first_h = in_window
            .iter()
            .map(|e| e.time_h)
            .fold(f64::INFINITY, f64::min);
        let covered_days = if first_h.is_finite() {
            ((input.now_h - first_h) / 24.0).clamp(1.0, window_days)
        } else {
            window_days
        };
        let daily_mg = window_mg / covered_days;

        let last = *times.last().unwrap_or(&input.now_h);
        let next_due = last + interval;
        let overdue = (input.now_h - next_due).max(0.0);

        let cover = adherence(input.events, interval, window_start, window_end);
        let (coverage_pct, expected, taken) = match cover {
            Some(r) => (r.coverage_pct, r.expected, r.taken),
            None => (0.0, 0, in_window.len()),
        };

        let modelled = ester != Ester::BICA && ester != Ester::MPA;
        let level = if modelled {
            sim.as_ref().and_then(|s| {
                let values = if ester == Ester::SPIRO {
                    &s.spiro_ng_ml
                } else {
                    &s.cpa_ng_ml
                };
                curve_stats(&s.time_h, values, None).filter(|c| c.peak > 1e-9)
            })
        } else {
            None
        };

        let band_name = band_of(band, daily_mg);
        let verdict = if taken == 0 {
            "nothingLogged"
        } else if coverage_pct < 80.0 {
            "coverage"
        } else {
            match band_name {
                "low" => "lowDose",
                "high" => "highDose",
                "aboveCeiling" => "aboveCeiling",
                _ => "adequate",
            }
        };

        let mut notes: Vec<String> = Vec::new();
        match band_name {
            "low" => notes.push(format!(
                "Below the {:.0}–{:.0} mg/day usually used for androgen blockade.",
                band.low_mg, band.high_mg
            )),
            "high" => notes.push(format!(
                "Above the {:.0}–{:.0} mg/day usually needed; effects that scale \
                 with dose grow faster than the benefit.",
                band.low_mg, band.high_mg
            )),
            "aboveCeiling" => notes.push(format!(
                "Above the {:.0} mg/day that is usually the ceiling.",
                band.ceiling_mg
            )),
            _ => {}
        }
        if coverage_pct < 80.0 && taken > 0 {
            notes.push(format!(
                "{:.0}% of the expected doses in the last {:.0} days are logged.",
                coverage_pct, window_days
            ));
        }
        if overdue > 0.0 {
            notes.push(format!("The next dose was due {:.0} h ago.", overdue));
        }
        if ester == Ester::SPIRO {
            notes.push(
                "Reported as canrenone. Spironolactone blocks the receptor \
                 without lowering testosterone, so the level being present says \
                 nothing about how much is blocked."
                    .to_string(),
            );
            notes.push(
                "If testosterone is still high on oestradiol plus \
                 spironolactone, the dose is usually not the reason: the \
                 evidence points at the oestradiol, and a different \
                 anti-androgen class is the lever that moves it."
                    .to_string(),
            );
        }
        if !modelled {
            notes.push(
                "Stored but not modelled, so there is no level for this \
                 compound; the dose band and coverage still apply."
                    .to_string(),
            );
        }

        report.compounds.push(BlockadeCompound {
            ester: ester.code(),
            name: name_for(ester),
            modelled,
            dose_mg: input
                .events
                .iter()
                .filter(|e| e.ester == ester)
                .last()
                .map(|e| e.dose_mg)
                .unwrap_or(0.0),
            interval_h: interval,
            daily_mg,
            band: band_name,
            band_low_mg: band.low_mg,
            band_high_mg: band.high_mg,
            band_ceiling_mg: band.ceiling_mg,
            level,
            coverage_pct,
            expected,
            taken,
            next_due_h: Some(next_due),
            overdue_h: overdue,
            verdict,
            mechanism: mechanism_for(ester),
            expects_testosterone_fall: expects_testosterone_fall(ester),
            mechanism_note: mechanism_note(ester),
            notes,
        });
    }

    report
}

#[cfg(test)]
mod tests {
    use super::*;
    use std::collections::HashMap;

    fn dose(ester: Ester, mg: f64, time_h: f64) -> DoseEvent {
        DoseEvent {
            id: format!("{ester:?}-{time_h}"),
            route: Route::Oral,
            time_h,
            dose_mg: mg,
            ester,
            extras: HashMap::new(),
            updated_at: None,
        }
    }

    #[test]
    fn a_hundred_milligrams_a_day_is_a_typical_spiro_regimen() {
        let now = 1000.0 * 24.0;
        let events: Vec<DoseEvent> = (0..28)
            .map(|d| dose(Ester::SPIRO, 100.0, now - (28 - d) as f64 * 24.0))
            .collect();
        let report = assess(BlockadeInput {
            events: &events,
            params: &PkParams::default(),
            weight: 70.0,
            birth_year: None,
            now_h: now,
            clearance_mult: 1.0,
            window_days: 28.0,
        });
        let spiro = report.compounds.first().expect("a compound");
        assert_eq!(spiro.ester, "SPIRO");
        assert_eq!(spiro.band, "typical");
        assert_eq!(spiro.verdict, "adequate");
        assert!((spiro.interval_h - 24.0).abs() < 0.01);
        assert!(spiro.level.is_some(), "canrenone curve exists");
        assert!(!spiro.expects_testosterone_fall);
        assert_eq!(spiro.mechanism, "receptorBlockade");
        assert!(!report.androgen_suppression_modelled);
    }

    #[test]
    fn a_forgotten_week_shows_up_as_coverage() {
        let now = 1000.0 * 24.0;
        // Ten days of daily doses, then nothing for eighteen days.
        let events: Vec<DoseEvent> = (0..10)
            .map(|d| dose(Ester::SPIRO, 100.0, now - (28 - d) as f64 * 24.0))
            .collect();
        let report = assess(BlockadeInput {
            events: &events,
            params: &PkParams::default(),
            weight: 70.0,
            birth_year: None,
            now_h: now,
            clearance_mult: 1.0,
            window_days: 28.0,
        });
        let spiro = report.compounds.first().expect("a compound");
        assert!(spiro.coverage_pct < 100.0);
        assert!(spiro.overdue_h > 0.0);
    }

    #[test]
    fn a_low_dose_is_called_low() {
        let now = 1000.0 * 24.0;
        let events: Vec<DoseEvent> = (0..28)
            .map(|d| dose(Ester::SPIRO, 25.0, now - (28 - d) as f64 * 24.0))
            .collect();
        let report = assess(BlockadeInput {
            events: &events,
            params: &PkParams::default(),
            weight: 70.0,
            birth_year: None,
            now_h: now,
            clearance_mult: 1.0,
            window_days: 28.0,
        });
        let spiro = report.compounds.first().expect("a compound");
        assert_eq!(spiro.band, "low");
        assert_eq!(spiro.verdict, "lowDose");
    }

    #[test]
    fn one_dose_today_reads_as_that_dose_per_day() {
        let now = 1000.0 * 24.0;
        // Logged two hours ago: the record covers one day, not twenty-eight.
        // 120 mg a day is a normal spironolactone regimen, and the average must
        // not turn it into 4 mg a day just because the window is long.
        let events = vec![dose(Ester::SPIRO, 120.0, now - 2.0)];
        let report = assess(BlockadeInput {
            events: &events,
            params: &PkParams::default(),
            weight: 70.0,
            birth_year: None,
            now_h: now,
            clearance_mult: 1.0,
            window_days: 28.0,
        });
        let spiro = report.compounds.first().expect("a compound");
        assert!(
            (spiro.daily_mg - 120.0).abs() < 1e-9,
            "daily {}",
            spiro.daily_mg
        );
        assert_eq!(spiro.band, "typical");
        // A single dose is not a covered window, and the verdict says so.
        assert_eq!(spiro.verdict, "coverage");
        assert!(spiro.coverage_pct < 10.0);
    }

    #[test]
    fn the_payload_spells_milligrams_the_way_the_docs_do() {
        let now = 1000.0 * 24.0;
        let events = vec![dose(Ester::SPIRO, 100.0, now - 2.0)];
        let report = assess(BlockadeInput {
            events: &events,
            params: &PkParams::default(),
            weight: 70.0,
            birth_year: None,
            now_h: now,
            clearance_mult: 1.0,
            window_days: 28.0,
        });
        let json = serde_json::to_value(&report.compounds[0]).expect("json");
        for key in [
            "doseMG",
            "dailyMG",
            "bandLowMG",
            "bandHighMG",
            "bandCeilingMG",
        ] {
            assert!(json.get(key).and_then(|v| v.as_f64()).is_some(), "{key}");
        }
        assert!(json.get("dailyMg").is_none(), "one spelling, not two");
    }
}
