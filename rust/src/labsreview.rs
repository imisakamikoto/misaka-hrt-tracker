//! Reading a lab panel back, rather than fitting it.
//!
//! Calibration asks "what would have to be true for the model to match these
//! numbers". This module asks the smaller and more frequently useful question:
//! which of these numbers are inside the range they are being compared against,
//! which are not, which way are they moving, and how long has it been since the
//! last one.
//!
//! It does not fit anything, and it does not average across analytes. A single
//! estradiol result is compared against the estradiol range and a single
//! testosterone result against the testosterone range; if no range is supplied
//! the reading is reported with `noTarget` rather than being quietly judged
//! against a default nobody chose.

use serde::Serialize;

use crate::model::{LabResult, LabUnit, TargetRange};

/// A common follow-up interval in the first year of treatment. Returned as the
/// default, not as a rule — the caller can and should override it.
pub const DEFAULT_CADENCE_DAYS: f64 = 90.0;

/// Percentage change between consecutive readings that counts as movement
/// rather than assay noise.
const TREND_THRESHOLD_PCT: f64 = 10.0;

#[derive(Debug, Clone, Serialize)]
#[serde(rename_all = "camelCase")]
pub struct LabReading {
    pub id: String,
    pub time_h: f64,
    /// Days before `nowH`. Negative means the reading is dated in the future.
    pub days_ago: f64,
    /// `e2` or `t`, decided by the unit the value was reported in.
    pub analyte: &'static str,
    /// The value in the model's own unit: pg/mL for estradiol, ng/dL for
    /// testosterone.
    pub value: f64,
    /// The value exactly as reported, for showing back to the user.
    pub reported: f64,
    pub unit: &'static str,
    /// `below`, `inRange`, `above` or `noTarget`.
    pub status: &'static str,
    pub target: Option<TargetRange>,
}

#[derive(Debug, Clone, Serialize)]
#[serde(rename_all = "camelCase")]
pub struct LabsReview {
    pub readings: Vec<LabReading>,
    pub e2_count: usize,
    pub t_count: usize,
    pub e2_latest: Option<f64>,
    pub t_latest: Option<f64>,
    /// `rising`, `falling`, `stable` or `insufficient`.
    pub e2_trend: &'static str,
    pub t_trend: &'static str,
    pub e2_trend_pct: Option<f64>,
    pub t_trend_pct: Option<f64>,
    pub below: usize,
    pub above: usize,
    pub in_range: usize,
    /// Days between the most recent reading and `nowH`.
    pub days_since_last: Option<f64>,
    pub cadence_days: f64,
    /// `fresh`, `dueSoon`, `overdue` or `none`.
    pub cadence: &'static str,
    /// Days past the cadence, when overdue.
    pub overdue_by_days: Option<f64>,
    pub note: &'static str,
}

pub struct LabsInput<'a> {
    pub labs: &'a [LabResult],
    pub now_h: f64,
    pub e2_target: Option<TargetRange>,
    pub t_target: Option<TargetRange>,
    pub cadence_days: Option<f64>,
}

fn analyte_of(unit: LabUnit) -> &'static str {
    if unit.is_testosterone() {
        "t"
    } else {
        "e2"
    }
}

fn status_of(value: f64, target: Option<TargetRange>) -> &'static str {
    match target.and_then(|r| r.normalized()) {
        None => "noTarget",
        Some(range) => {
            if value < range.low {
                "below"
            } else if value > range.high {
                "above"
            } else {
                "inRange"
            }
        }
    }
}

/// Change between the last two values, as a percentage of the earlier one.
fn trend(values: &[f64]) -> (&'static str, Option<f64>) {
    if values.len() < 2 {
        return ("insufficient", None);
    }
    let v1 = values[values.len() - 2];
    let v2 = values[values.len() - 1];
    if v1.abs() < 1e-9 {
        return ("insufficient", None);
    }
    let pct = (v2 - v1) / v1 * 100.0;
    if pct.abs() < TREND_THRESHOLD_PCT {
        ("stable", Some(pct))
    } else if pct > 0.0 {
        ("rising", Some(pct))
    } else {
        ("falling", Some(pct))
    }
}

pub fn review(input: LabsInput) -> LabsReview {
    let cadence = input
        .cadence_days
        .filter(|d| d.is_finite() && *d > 0.0)
        .unwrap_or(DEFAULT_CADENCE_DAYS);

    let mut sorted: Vec<&LabResult> = input
        .labs
        .iter()
        .filter(|l| l.conc_value.is_finite() && l.time_h.is_finite())
        .collect();
    sorted.sort_by(|a, b| {
        a.time_h
            .partial_cmp(&b.time_h)
            .unwrap_or(std::cmp::Ordering::Equal)
    });
    sorted.truncate(500);

    let mut readings = Vec::with_capacity(sorted.len());
    let mut e2_series: Vec<f64> = Vec::new();
    let mut t_series: Vec<f64> = Vec::new();
    let (mut below, mut above, mut in_range) = (0usize, 0usize, 0usize);

    for lab in &sorted {
        let analyte = analyte_of(lab.unit);
        let value = lab.unit.to_model_unit(lab.conc_value);
        let target = match analyte {
            "t" => input.t_target,
            _ => input.e2_target,
        };
        let status = status_of(value, target);
        match status {
            "below" => below += 1,
            "above" => above += 1,
            "inRange" => in_range += 1,
            _ => {}
        }
        if analyte == "t" {
            t_series.push(value);
        } else {
            e2_series.push(value);
        }
        readings.push(LabReading {
            id: lab.id.clone(),
            time_h: lab.time_h,
            days_ago: (input.now_h - lab.time_h) / 24.0,
            analyte,
            value,
            reported: lab.conc_value,
            unit: lab.unit.code(),
            status,
            target: target.and_then(|r| r.normalized()),
        });
    }

    let (e2_trend, e2_trend_pct) = trend(&e2_series);
    let (t_trend, t_trend_pct) = trend(&t_series);

    let newest = sorted.last().map(|l| l.time_h);
    let days_since_last = newest.map(|t| (input.now_h - t) / 24.0);
    let (cadence_state, overdue_by) = match days_since_last {
        None => ("none", None),
        Some(days) if days > cadence => ("overdue", Some(days - cadence)),
        Some(days) if days > cadence * 0.8 => ("dueSoon", None),
        Some(_) => ("fresh", None),
    };

    LabsReview {
        readings,
        e2_count: e2_series.len(),
        t_count: t_series.len(),
        e2_latest: e2_series.last().copied(),
        t_latest: t_series.last().copied(),
        e2_trend,
        t_trend,
        e2_trend_pct,
        t_trend_pct,
        below,
        above,
        in_range,
        days_since_last,
        cadence_days: cadence,
        cadence: cadence_state,
        overdue_by_days: overdue_by,
        note: "Readings are compared against the range supplied for their own analyte, in the \
               model's units. A trend needs two readings of the same analyte and only counts \
               as movement beyond 10%, which is roughly the between-assay spread of the \
               immunoassays these numbers usually come from.",
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    fn lab(id: &str, time_h: f64, value: f64, unit: LabUnit) -> LabResult {
        LabResult {
            id: id.into(),
            time_h,
            conc_value: value,
            unit,
            assay: None,
            updated_at: None,
        }
    }

    fn run(labs: &[LabResult]) -> LabsReview {
        review(LabsInput {
            labs,
            now_h: 24.0 * 200.0,
            e2_target: Some(TargetRange::new(100.0, 200.0)),
            t_target: Some(TargetRange::new(10.0, 50.0)),
            cadence_days: None,
        })
    }

    #[test]
    fn a_value_above_the_range_is_flagged() {
        let review = run(&[lab("a", 24.0 * 190.0, 320.0, LabUnit::PgMl)]);
        assert_eq!(review.readings[0].status, "above");
        assert_eq!(review.above, 1);
        assert_eq!(review.e2_latest, Some(320.0));
    }

    #[test]
    fn the_analyte_follows_the_unit() {
        let review = run(&[
            lab("e", 24.0 * 190.0, 180.0, LabUnit::PgMl),
            lab("t", 24.0 * 190.0, 30.0, LabUnit::NgDl),
        ]);
        assert_eq!(review.e2_count, 1);
        assert_eq!(review.t_count, 1);
        assert_eq!(review.readings[0].analyte, "e2");
        assert_eq!(review.readings[1].analyte, "t");
        assert_eq!(review.readings[1].status, "inRange");
    }

    #[test]
    fn molar_units_are_converted_before_comparing() {
        // 400 pmol/L is about 109 pg/mL, which is inside 100–200.
        let review = run(&[lab("a", 24.0 * 199.0, 400.0, LabUnit::PmolL)]);
        let r = &review.readings[0];
        assert!((r.value - 108.96).abs() < 0.5, "{}", r.value);
        assert_eq!(r.status, "inRange");
        assert!((r.reported - 400.0).abs() < 1e-9);
    }

    #[test]
    fn two_readings_of_one_analyte_give_a_trend() {
        let review = run(&[
            lab("a", 24.0 * 100.0, 120.0, LabUnit::PgMl),
            lab("b", 24.0 * 190.0, 250.0, LabUnit::PgMl),
        ]);
        assert_eq!(review.e2_trend, "rising");
        assert!(review.e2_trend_pct.expect("pct") > 100.0);
        assert_eq!(review.t_trend, "insufficient");
    }

    #[test]
    fn a_stale_panel_is_overdue_against_the_cadence() {
        let review = run(&[lab("a", 24.0 * 100.0, 150.0, LabUnit::PgMl)]);
        assert_eq!(review.cadence, "overdue");
        assert!((review.overdue_by_days.expect("overdue") - 10.0).abs() < 1e-6);
    }

    #[test]
    fn an_empty_panel_is_not_an_error() {
        let review = run(&[]);
        assert_eq!(review.cadence, "none");
        assert_eq!(review.readings.len(), 0);
        assert_eq!(review.in_range, 0);
    }
}
