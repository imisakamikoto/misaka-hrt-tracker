//! Plausibility checks on what the caller recorded.
//!
//! None of this is diagnostic. The checks answer one question: "is there
//! something in this record that the model cannot represent, or that the
//! person probably mistyped?" A curve that silently ignores half the doses is
//! worse than a curve with a note attached.

use serde::Serialize;

use crate::engine::{bioavailability, patch_pairs};
use crate::model::*;
use crate::stats::SimulationStats;

#[derive(Debug, Clone, Serialize)]
#[serde(rename_all = "camelCase")]
pub struct Warning {
    /// Stable machine-readable identifier, e.g. `routeNotModelled`.
    pub code: &'static str,
    /// `info`, `warning` or `critical`.
    pub severity: &'static str,
    pub message: String,
    /// When the condition applies to a moment in time.
    pub at_h: Option<f64>,
    /// The offending value, when there is a single one.
    pub value: Option<f64>,
}

fn warn(code: &'static str, severity: &'static str, message: impl Into<String>) -> Warning {
    Warning {
        code,
        severity,
        message: message.into(),
        at_h: None,
        value: None,
    }
}

pub struct SafetyInput<'a> {
    pub events: &'a [DoseEvent],
    pub labs: &'a [LabResult],
    pub params: &'a PkParams,
    pub stats: Option<&'a SimulationStats>,
    pub e2_range: Option<TargetRange>,
    pub t_range: Option<TargetRange>,
    pub weight: f64,
    pub now_h: f64,
}

/// Everything questionable about a record, most severe first.
pub fn check(input: SafetyInput<'_>) -> Vec<Warning> {
    let mut out: Vec<Warning> = Vec::new();
    let doses: Vec<&DoseEvent> = input
        .events
        .iter()
        .filter(|e| e.route != Route::PatchRemove && e.dose_mg > 0.0)
        .collect();

    if doses.is_empty() {
        out.push(warn(
            "noDoses",
            "critical",
            "No doses are recorded, so there is no curve to draw.",
        ));
        return out;
    }

    if input.labs.is_empty() {
        out.push(warn(
            "noLabs",
            "info",
            "No lab results are recorded. The curve shows what the population \
             model predicts, not what this person actually measured; adding one \
             result lets it be calibrated.",
        ));
    } else {
        let latest = input
            .labs
            .iter()
            .map(|l| l.time_h)
            .fold(f64::NEG_INFINITY, f64::max);
        let age_days = (input.now_h - latest) / 24.0;
        if age_days > 180.0 {
            out.push(
                warn(
                    "staleLabs",
                    "info",
                    format!(
                        "The newest lab is {:.0} days old. Clearance changes, so a \
                         calibration from half a year ago may no longer describe \
                         the present.",
                        age_days
                    ),
                )
                .with_value(age_days),
            );
        }
    }

    if !(30.0..=250.0).contains(&input.weight) {
        out.push(
            warn(
                "implausibleWeight",
                "warning",
                format!(
                    "Body weight is {:.1} kg. Volume of distribution is scaled \
                     from it, so a value outside 30–250 kg makes every \
                     concentration suspect.",
                    input.weight
                ),
            )
            .with_value(input.weight),
        );
    }

    // A dose that the engine will accept but multiply by zero.
    let mut silent: usize = 0;
    let mut first_silent: Option<f64> = None;
    for e in &doses {
        let modelled = e.ester.hormone().is_some() && bioavailability(input.params, e) > 0.0;
        if modelled {
            continue;
        }
        silent += 1;
        if first_silent.is_none() {
            first_silent = Some(e.time_h);
        }
        if e.ester == Ester::T && e.route == Route::Injection {
            out.push(
                warn(
                    "tInjectionNeedsEster",
                    "warning",
                    "Unesterified testosterone cannot be injected as a depot in \
                     this model. Log the ester instead (cypionate, enanthate or \
                     undecanoate); this dose produces no curve.",
                )
                .at(e.time_h),
            );
        } else if e.ester.is_unmodelled() {
            out.push(
                warn(
                    "compoundNotModelled",
                    "info",
                    format!(
                        "{} is stored but not modelled; it produces no curve. \
                         That is expected for this compound, not a data error.",
                        e.ester.code()
                    ),
                )
                .at(e.time_h),
            );
        } else {
            out.push(
                warn(
                    "routeNotModelled",
                    "warning",
                    format!(
                        "{} by {} is not modelled, so this dose contributes \
                         nothing to the curve. It is recorded, but the numbers \
                         beside it do not include it.",
                        e.ester.code(),
                        e.route.code()
                    ),
                )
                .at(e.time_h),
            );
        }
    }
    if silent > 0 && silent == doses.len() {
        out.push(warn(
            "nothingModelled",
            "critical",
            "Every recorded dose is of a form this model does not simulate, so \
             the curve is empty by construction.",
        ));
    }

    // Patches worn far past their plan.
    let pairs = patch_pairs(input.events);
    for (idx, e) in input.events.iter().enumerate() {
        if e.route != Route::PatchApply {
            continue;
        }
        let Some(removed_at) = pairs.get(&idx) else {
            continue;
        };
        let Some(planned) = e.planned_wear_h() else {
            continue;
        };
        let wear = removed_at - e.time_h;
        if wear > planned + 24.0 {
            out.push(
                warn(
                    "patchOverwear",
                    "warning",
                    format!(
                        "A patch planned for {:.0} h was worn for {:.0} h. The \
                         model lets it keep releasing until it comes off, which \
                         may overstate exposure near the end.",
                        planned, wear
                    ),
                )
                .at(e.time_h)
                .with_value(wear),
            );
        }
    }

    // Cyproterone acetate is the one anti-androgen with a dose ceiling worth
    // flagging, and only as a prompt to check the prescription.
    let cpa_total: f64 = doses
        .iter()
        .filter(|e| e.ester == Ester::CPA)
        .map(|e| e.dose_mg)
        .sum();
    if cpa_total > 0.0 {
        let span_days = {
            let first = doses.iter().map(|e| e.time_h).fold(f64::INFINITY, f64::min);
            let last = doses
                .iter()
                .map(|e| e.time_h)
                .fold(f64::NEG_INFINITY, f64::max);
            ((last - first) / 24.0).max(1.0)
        };
        let per_day = cpa_total / span_days;
        if per_day > 50.0 {
            out.push(
                warn(
                    "cpaHighDose",
                    "warning",
                    format!(
                        "Cyproterone acetate averages {:.0} mg/day over the \
                         record. Doses above 50 mg/day are outside the usual \
                         range and carry a higher risk of liver effects and \
                         prolactin elevation.",
                        per_day
                    ),
                )
                .with_value(per_day),
            );
        }
    }

    // Spironolactone sits on its own axis: it blocks the androgen receptor
    // rather than lowering testosterone, so nothing in the T curve reflects
    // whether it is working, and the model reports canrenone instead.
    let spiro_total: f64 = doses
        .iter()
        .filter(|e| e.ester == Ester::SPIRO)
        .map(|e| e.dose_mg)
        .sum();
    if spiro_total > 0.0 {
        let span_days = {
            let first = doses.iter().map(|e| e.time_h).fold(f64::INFINITY, f64::min);
            let last = doses
                .iter()
                .map(|e| e.time_h)
                .fold(f64::NEG_INFINITY, f64::max);
            ((last - first) / 24.0).max(1.0)
        };
        let per_day = spiro_total / span_days;

        out.push(warn(
            "spiroBlocksReceptors",
            "info",
            "Spironolactone is modelled as canrenone. It blocks the androgen \
             receptor rather than lowering testosterone, so this curve says \
             whether the drug is present, not how completely it is working — \
             and nothing here estimates receptor-level blockade.",
        ));

        if per_day < 50.0 {
            out.push(
                warn(
                    "spiroLowDose",
                    "info",
                    format!(
                        "Spironolactone averages {:.0} mg/day over the record. \
                         Androgen blockade usually needs 50–200 mg/day, and \
                         sometimes more; below that the level is mostly a \
                         diuretic effect.",
                        per_day
                    ),
                )
                .with_value(per_day),
            );
        } else if per_day > 400.0 {
            out.push(
                warn(
                    "spiroHighDose",
                    "warning",
                    format!(
                        "Spironolactone averages {:.0} mg/day over the record, \
                         above the 400 mg/day that is usually the ceiling. \
                         Potassium retention, low blood pressure, urinary \
                         frequency and gastrointestinal effects all become more \
                         likely, and the extra blockade is small.",
                        per_day
                    ),
                )
                .with_value(per_day),
            );
        } else if per_day > 200.0 {
            out.push(
                warn(
                    "spiroHighDose",
                    "warning",
                    format!(
                        "Spironolactone averages {:.0} mg/day, above the 200 \
                         mg/day usually needed with a non-oral oestrogen. Above \
                         that, potassium and blood-pressure effects grow faster \
                         than the benefit.",
                        per_day
                    ),
                )
                .with_value(per_day),
            );
        }
    }

    // Two nearly identical doses are usually a double tap, not a plan.
    let mut sorted: Vec<&&DoseEvent> = doses.iter().collect();
    sorted.sort_by(|a, b| {
        a.time_h
            .partial_cmp(&b.time_h)
            .unwrap_or(std::cmp::Ordering::Equal)
    });
    for pair in sorted.windows(2) {
        let (a, b) = (pair[0], pair[1]);
        if a.ester == b.ester && a.route == b.route && (b.time_h - a.time_h).abs() < 2.0 {
            out.push(
                warn(
                    "doseCluster",
                    "info",
                    format!(
                        "Two {} doses by {} are less than two hours apart. If one \
                         of them is a mis-tap, removing it will change the curve.",
                        a.ester.code(),
                        a.route.code()
                    ),
                )
                .at(b.time_h),
            );
        }
    }

    for e in &doses {
        // Spironolactone is routinely taken at 100–200 mg, so the generic
        // "large dose" prompt would fire on an ordinary prescription.
        if e.dose_mg > 100.0 && !e.ester.is_unmodelled() && e.ester != Ester::SPIRO {
            out.push(
                warn(
                    "largeDose",
                    "info",
                    format!(
                        "A single {} dose of {:.0} mg was recorded.",
                        e.ester.code(),
                        e.dose_mg
                    ),
                )
                .at(e.time_h)
                .with_value(e.dose_mg),
            );
        }
    }

    // What the curve itself says about the range.
    if let Some(stats) = input.stats {
        if let (Some(e2), Some(range)) = (
            stats.e2.as_ref(),
            input.e2_range.and_then(|r| r.normalized()),
        ) {
            range_warnings(
                &mut out,
                "e2",
                e2.peak,
                e2.trough,
                e2.time_in_range_pct,
                range,
            );
        }
        if let (Some(t), Some(range)) =
            (stats.t.as_ref(), input.t_range.and_then(|r| r.normalized()))
        {
            range_warnings(&mut out, "t", t.peak, t.trough, t.time_in_range_pct, range);
        }
    }

    out.sort_by_key(|w| match w.severity {
        "critical" => 0,
        "warning" => 1,
        _ => 2,
    });
    out
}

fn range_warnings(
    out: &mut Vec<Warning>,
    hormone: &str,
    peak: f64,
    trough: f64,
    time_in_range_pct: f64,
    range: TargetRange,
) {
    let label = if hormone == "t" {
        "Testosterone"
    } else {
        "Estradiol"
    };
    if peak > range.high * 1.25 {
        out.push(
            warn(
                if hormone == "t" {
                    "tPeakHigh"
                } else {
                    "e2PeakHigh"
                },
                "warning",
                format!(
                    "The modelled peak ({:.0}) is more than a quarter above the \
                     top of the target range ({:.0}).",
                    peak, range.high
                ),
            )
            .with_value(peak),
        );
    }
    if trough < range.low * 0.7 {
        out.push(
            warn(
                if hormone == "t" {
                    "tTroughLow"
                } else {
                    "e2TroughLow"
                },
                "warning",
                format!(
                    "{} troughs at {:.0}, well under the bottom of the target \
                     range ({:.0}) — the level is out of range for part of every \
                     interval.",
                    label, trough, range.low
                ),
            )
            .with_value(trough),
        );
    }
    if time_in_range_pct < 50.0 {
        out.push(
            warn(
                if hormone == "t" {
                    "tTimeInRangeLow"
                } else {
                    "e2TimeInRangeLow"
                },
                "info",
                format!(
                    "{} stays inside the target range only {:.0}% of the time.",
                    label, time_in_range_pct
                ),
            )
            .with_value(time_in_range_pct),
        );
    }
}

impl Warning {
    fn at(mut self, at_h: f64) -> Self {
        self.at_h = Some(at_h);
        self
    }

    fn with_value(mut self, value: f64) -> Self {
        self.value = Some(value);
        self
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    use std::collections::HashMap;

    fn dose(route: Route, ester: Ester, mg: f64, h: f64) -> DoseEvent {
        DoseEvent {
            id: format!("d{h}"),
            route,
            time_h: h,
            dose_mg: mg,
            ester,
            extras: HashMap::new(),
            updated_at: None,
        }
    }

    #[test]
    fn flags_a_dose_the_model_will_ignore() {
        let events = vec![dose(Route::Oral, Ester::T, 40.0, 0.0)];
        let params = PkParams::default();
        let warnings = check(SafetyInput {
            events: &events,
            labs: &[],
            params: &params,
            stats: None,
            e2_range: None,
            t_range: None,
            weight: 70.0,
            now_h: 24.0,
        });
        assert!(warnings.iter().any(|w| w.code == "routeNotModelled"));
        assert!(warnings.iter().any(|w| w.code == "nothingModelled"));
    }

    #[test]
    fn a_clean_record_only_mentions_missing_labs() {
        let events = vec![dose(Route::Injection, Ester::EV, 4.0, 0.0)];
        let params = PkParams::default();
        let warnings = check(SafetyInput {
            events: &events,
            labs: &[],
            params: &params,
            stats: None,
            e2_range: None,
            t_range: None,
            weight: 70.0,
            now_h: 24.0,
        });
        assert_eq!(warnings.len(), 1, "{warnings:?}");
        assert_eq!(warnings[0].code, "noLabs");
    }
}
