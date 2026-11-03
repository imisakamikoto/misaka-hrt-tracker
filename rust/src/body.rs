//! Bust, underbust and cup size.
//!
//! Cup size is a two-number system that is written as one string: the band is
//! the underbust circumference and the cup is the difference between the bust
//! and the band. Only the second number is about breast volume, and the letter
//! that represents it is not the same letter in every country — the same body
//! is a 75C in one sizing system, a 34B in another, and a D in a third.
//!
//! So this module never reports a bare cup letter. It reports the difference in
//! centimetres, the band it pairs with, and the resulting label in each system
//! the caller asks for. The difference is the measurement; the letter is a
//! convention sitting on top of it.
//!
//! The arithmetic is deliberately conservative about what it claims. There is
//! no size that means "growing normally", no target, and no volume estimate:
//! turning a circumference into millilitres needs a shape assumption that
//! varies more between two people than between two cup sizes.

use serde::{Deserialize, Serialize};

/// Which national sizing convention to express a cup in.
#[derive(Debug, Clone, Copy, PartialEq, Eq, Serialize, Deserialize)]
#[serde(rename_all = "camelCase")]
pub enum CupSystem {
    /// Underbust in centimetres rounded to 5, 2 cm cup steps. Most of Europe.
    Eu,
    /// Underbust in centimetres rounded to 5, 2.5 cm cup steps. China and Japan
    /// share the band; Japan writes the cup the same way.
    Cn,
    /// Underbust in inches with the +4 rule, 1 inch cup steps.
    Uk,
    /// Same arithmetic as the UK, different labels above DD.
    Us,
}

impl CupSystem {
    pub const ALL: [CupSystem; 4] = [CupSystem::Eu, CupSystem::Cn, CupSystem::Uk, CupSystem::Us];

    pub fn code(self) -> &'static str {
        match self {
            CupSystem::Eu => "eu",
            CupSystem::Cn => "cn",
            CupSystem::Uk => "uk",
            CupSystem::Us => "us",
        }
    }

    pub fn parse(text: &str) -> Option<CupSystem> {
        match text.trim().to_ascii_lowercase().as_str() {
            "eu" | "europe" => Some(CupSystem::Eu),
            "cn" | "jp" | "asia" => Some(CupSystem::Cn),
            "uk" => Some(CupSystem::Uk),
            "us" => Some(CupSystem::Us),
            _ => None,
        }
    }

    fn band_unit(self) -> &'static str {
        match self {
            CupSystem::Eu | CupSystem::Cn => "cm",
            CupSystem::Uk | CupSystem::Us => "in",
        }
    }
}

/// One resolved size in one system.
#[derive(Debug, Clone, Serialize)]
#[serde(rename_all = "camelCase")]
pub struct CupSize {
    pub system: &'static str,
    /// Band as the system writes it: 75 or 80 for EU/CN, 34/36 for UK/US.
    pub band: f64,
    pub band_unit: &'static str,
    /// `AA`, `A` … `H`, or `H+` when the difference is past the table.
    pub cup: &'static str,
    /// `75B`, `34B`.
    pub label: String,
    /// Bust minus underbust, in centimetres, before any rounding.
    pub difference_cm: f64,
    pub difference_in: f64,
}

/// A single tape-measure session.
#[derive(Debug, Clone, Deserialize)]
#[serde(rename_all = "camelCase")]
pub struct Measurement {
    pub time_h: f64,
    /// Fullest part of the bust, tape level and not compressing.
    #[serde(alias = "bust")]
    pub bust_cm: f64,
    /// Snug underbust, tape exhaled.
    #[serde(default, alias = "underbust")]
    pub underbust_cm: Option<f64>,
}

#[derive(Debug, Clone, Serialize)]
#[serde(rename_all = "camelCase")]
pub struct GrowthPoint {
    pub time_h: f64,
    pub bust_cm: f64,
    pub underbust_cm: f64,
    pub difference_cm: f64,
    /// Cup in the system the caller asked for.
    pub cup: &'static str,
    pub label: String,
}

#[derive(Debug, Clone, Serialize)]
#[serde(rename_all = "camelCase")]
pub struct GrowthReport {
    pub points: usize,
    pub span_days: f64,
    pub first_difference_cm: f64,
    pub last_difference_cm: f64,
    /// Change in the difference, in centimetres. Negative means it shrank.
    pub change_cm: f64,
    /// Least-squares slope of the difference over time, in cm per 30.44 days.
    pub rate_cm_per_month: f64,
    /// The next cup boundary above the latest difference, in the requested
    /// system.
    pub next_cup: Option<&'static str>,
    /// Months until that boundary at the measured rate. `None` when the rate is
    /// flat or negative, because projecting a stop is not a projection.
    pub months_to_next_cup: Option<f64>,
}

#[derive(Debug, Clone, Serialize)]
#[serde(rename_all = "camelCase")]
pub struct BodyReport {
    pub system: &'static str,
    /// Most recent measurement with both circumferences.
    pub bust_cm: Option<f64>,
    pub underbust_cm: Option<f64>,
    pub difference_cm: Option<f64>,
    pub difference_in: Option<f64>,
    /// The requested system first, then the others.
    pub sizes: Vec<CupSize>,
    /// Bust ÷ underbust. A body with no breast tissue sits near 1.0; the
    /// figure does not depend on any sizing convention.
    pub ratio: Option<f64>,
    /// Only when a height was supplied alongside a weight.
    pub bmi: Option<f64>,
    /// Whether the two circumferences arrived in the same session.
    pub paired: bool,
    /// Where the difference sits between the two nearest cup boundaries,
    /// 0–1, for a bar. `None` when there is no difference to place.
    pub cup_progress: Option<f64>,
    pub growth: Option<GrowthReport>,
    pub note: &'static str,
}

pub struct BodyInput<'a> {
    pub measurements: &'a [Measurement],
    pub system: Option<CupSystem>,
    pub height_cm: Option<f64>,
    pub weight_kg: Option<f64>,
}

/// Letters below the first whole step, then in order.
///
/// The table stops at `H` because the differences past it are rare enough that
/// a caller showing `H+` is more honest than a caller extrapolating `I` and `J`
/// from a convention that has already stopped being standardised.
const LETTERS: [&str; 9] = ["AA", "A", "B", "C", "D", "DD", "E", "F", "G"];

fn letter(index: i32) -> &'static str {
    if index < 0 {
        return "AA";
    }
    LETTERS
        .get(index as usize)
        .copied()
        .unwrap_or("H+")
}

/// Round to the nearest multiple of `step`.
fn snap(value: f64, step: f64) -> f64 {
    if step <= 0.0 || !value.is_finite() {
        return value;
    }
    (value / step).round() * step
}

fn cm_to_in(cm: f64) -> f64 {
    cm / 2.54
}

fn in_to_cm(inches: f64) -> f64 {
    inches * 2.54
}

/// Resolve one difference into a size in one system.
pub fn size_for(difference_cm: f64, underbust_cm: f64, system: CupSystem) -> CupSize {
    let difference_in = cm_to_in(difference_cm);
    let (band, cup) = match system {
        CupSystem::Eu => {
            // Band snaps to 5 cm; each cup is 2 cm of difference, with A
            // starting at 10 cm.
            let band = snap(underbust_cm, 5.0);
            let index = ((difference_cm - 10.0) / 2.0).floor() as i32 + 1;
            (band, letter(index))
        }
        CupSystem::Cn => {
            let band = snap(underbust_cm, 5.0);
            let index = ((difference_cm - 10.0) / 2.5).floor() as i32 + 1;
            (band, letter(index))
        }
        CupSystem::Uk | CupSystem::Us => {
            // The +4 rule: measure snug in inches, add four when even, five
            // when odd, then snap up to the next even number.
            let snug = snap(cm_to_in(underbust_cm), 1.0);
            let plus = if (snug as i64) % 2 == 0 { snug + 4.0 } else { snug + 5.0 };
            let band = plus.max(28.0);
            let index = (difference_in - (band - snug)).floor() as i32;
            (band, letter(index))
        }
    };
    CupSize {
        system: system.code(),
        band,
        band_unit: system.band_unit(),
        cup,
        label: format!("{band:.0}{cup}"),
        difference_cm,
        difference_in,
    }
}

/// The lower edge of the next cup boundary above `difference_cm`.
fn next_boundary(difference_cm: f64, system: CupSystem) -> Option<(&'static str, f64)> {
    let (start, step) = match system {
        CupSystem::Eu => (10.0, 2.0),
        CupSystem::Cn => (10.0, 2.5),
        CupSystem::Uk | CupSystem::Us => (in_to_cm(1.0), in_to_cm(1.0)),
    };
    // Which step are we in, and what is the next one above it?
    let index = if difference_cm < start {
        0
    } else {
        ((difference_cm - start) / step).floor() as i32 + 1
    };
    let next_index = index + 1;
    let next_letter = LETTERS.get(next_index as usize).copied()?;
    let boundary = start + step * (next_index as f64 - 1.0);
    Some((next_letter, boundary))
}

/// Least-squares slope in cm per day, over points given as (day, value).
fn slope_per_day(points: &[(f64, f64)]) -> f64 {
    if points.len() < 2 {
        return 0.0;
    }
    let n = points.len() as f64;
    let mean_x = points.iter().map(|(x, _)| x).sum::<f64>() / n;
    let mean_y = points.iter().map(|(_, y)| y).sum::<f64>() / n;
    let mut num = 0.0;
    let mut den = 0.0;
    for (x, y) in points {
        num += (x - mean_x) * (y - mean_y);
        den += (x - mean_x) * (x - mean_x);
    }
    if den.abs() < 1e-9 {
        0.0
    } else {
        num / den
    }
}

const MONTH_DAYS: f64 = 30.4375;

pub fn assess(input: BodyInput) -> BodyReport {
    let system = input.system.unwrap_or(CupSystem::Eu);

    let mut usable: Vec<&Measurement> = input
        .measurements
        .iter()
        .filter(|m| m.bust_cm.is_finite() && m.time_h.is_finite() && m.bust_cm > 0.0)
        .collect();
    usable.sort_by(|a, b| {
        a.time_h
            .partial_cmp(&b.time_h)
            .unwrap_or(std::cmp::Ordering::Equal)
    });
    usable.truncate(500);

    let paired: Vec<&Measurement> = usable
        .iter()
        .copied()
        .filter(|m| {
            m.underbust_cm
                .map(|u| u.is_finite() && u > 0.0 && m.bust_cm > u)
                .unwrap_or(false)
        })
        .collect();

    let latest = paired.last().copied();
    let (bust_cm, underbust_cm, difference_cm) = match latest {
        Some(m) => (
            Some(m.bust_cm),
            m.underbust_cm,
            m.underbust_cm.map(|u| m.bust_cm - u),
        ),
        None => (None, None, None),
    };

    let mut sizes = Vec::new();
    if let (Some(diff), Some(under)) = (difference_cm, underbust_cm) {
        sizes.push(size_for(diff, under, system));
        for other in CupSystem::ALL {
            if other != system {
                sizes.push(size_for(diff, under, other));
            }
        }
    }

    let growth = if paired.len() >= 2 {
        let first = paired.first().expect("checked length");
        let last = paired.last().expect("checked length");
        let series: Vec<(f64, f64)> = paired
            .iter()
            .map(|m| {
                (
                    m.time_h / 24.0,
                    m.bust_cm - m.underbust_cm.unwrap_or(m.bust_cm),
                )
            })
            .collect();
        let per_day = slope_per_day(&series);
        let last_diff = last.bust_cm - last.underbust_cm.unwrap_or(last.bust_cm);
        let next = next_boundary(last_diff, system);
        let months = next.and_then(|(_, boundary)| {
            let remaining = boundary - last_diff;
            if per_day > 1e-6 && remaining > 0.0 {
                Some(remaining / (per_day * MONTH_DAYS))
            } else {
                None
            }
        });
        Some(GrowthReport {
            points: paired.len(),
            span_days: (last.time_h - first.time_h) / 24.0,
            first_difference_cm: first.bust_cm - first.underbust_cm.unwrap_or(first.bust_cm),
            last_difference_cm: last_diff,
            change_cm: last_diff - (first.bust_cm - first.underbust_cm.unwrap_or(first.bust_cm)),
            rate_cm_per_month: per_day * MONTH_DAYS,
            next_cup: next.map(|(l, _)| l),
            months_to_next_cup: months,
        })
    } else {
        None
    };

    let bmi = match (input.height_cm, input.weight_kg) {
        (Some(h), Some(w)) if h.is_finite() && h > 30.0 && w.is_finite() && w > 0.0 => {
            Some(w / (h / 100.0).powi(2))
        }
        _ => None,
    };

    BodyReport {
        system: system.code(),
        bust_cm,
        underbust_cm,
        difference_cm,
        difference_in: difference_cm.map(cm_to_in),
        sizes,
        ratio: match (bust_cm, underbust_cm) {
            (Some(b), Some(u)) if u > 0.0 => Some(b / u),
            _ => None,
        },
        bmi,
        paired: latest.is_some(),
        cup_progress: difference_cm.and_then(|d| cup_progress(d, system)),
        growth,
        note: "The difference between bust and underbust is the measurement; the letter is a \
               convention. Band and cup arithmetic differs between countries, and between \
               manufacturers within a country, so the same body is not one size. Nothing here \
               is a target: cup size is reported, never judged.",
    }
}

/// Where a difference sits between two cup boundaries, for a bar.
pub fn cup_progress(difference_cm: f64, system: CupSystem) -> Option<f64> {
    let (start, step) = match system {
        CupSystem::Eu => (10.0, 2.0),
        CupSystem::Cn => (10.0, 2.5),
        CupSystem::Uk | CupSystem::Us => (in_to_cm(1.0), in_to_cm(1.0)),
    };
    let t = (difference_cm - (start - step)) / step;
    if t.is_finite() {
        Some(t.clamp(0.0, 1.0))
    } else {
        None
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    fn m(time_h: f64, bust: f64, under: f64) -> Measurement {
        Measurement {
            time_h,
            bust_cm: bust,
            underbust_cm: Some(under),
        }
    }

    fn run(ms: &[Measurement], system: CupSystem) -> BodyReport {
        assess(BodyInput {
            measurements: ms,
            system: Some(system),
            height_cm: None,
            weight_kg: None,
        })
    }

    #[test]
    fn a_ten_centimetre_difference_is_an_a_cup() {
        let report = run(&[m(0.0, 85.0, 75.0)], CupSystem::Cn);
        let size = &report.sizes[0];
        assert_eq!(size.cup, "A");
        assert_eq!(size.label, "75A");
        assert!((report.difference_cm.unwrap() - 10.0).abs() < 1e-9);
    }

    #[test]
    fn the_same_body_is_not_one_size_in_every_country() {
        let report = run(&[m(0.0, 91.0, 76.0)], CupSystem::Eu);
        let by_system = |code: &str| {
            report
                .sizes
                .iter()
                .find(|s| s.system == code)
                .expect("every system")
                .label
                .clone()
        };
        // 15 cm is three 2 cm steps of Europe and three 2.5 cm steps of China,
        // so both land on C from different arithmetic.
        assert_eq!(by_system("eu"), "75C");
        assert_eq!(by_system("cn"), "75C");
        // 15 cm is 5.9 in. The +4 rule turns a 30 in snug band into 34, which
        // eats four inches of the difference and leaves 1.9 in: an A.
        assert_eq!(by_system("uk"), "34A");
        assert_ne!(by_system("uk"), by_system("eu"));
    }

    #[test]
    fn a_flat_difference_does_not_round_up_to_a_cup() {
        let size = size_for(3.0, 80.0, CupSystem::Cn);
        assert_eq!(size.cup, "AA");
    }

    #[test]
    fn the_band_snaps_to_the_convention() {
        assert!((size_for(12.0, 77.0, CupSystem::Eu).band - 75.0).abs() < 1e-9);
        assert!((size_for(12.0, 78.0, CupSystem::Eu).band - 80.0).abs() < 1e-9);
    }

    #[test]
    fn growth_is_the_slope_of_the_difference_not_of_the_bust() {
        // Bust and underbust both grow, so the cup barely changes: 10, 11, 12 cm.
        let report = run(
            &[
                m(0.0, 85.0, 75.0),
                m(24.0 * 30.0, 87.0, 76.0),
                m(24.0 * 60.0, 89.0, 77.0),
            ],
            CupSystem::Cn,
        );
        let growth = report.growth.as_ref().expect("growth");
        assert!((growth.change_cm - 2.0).abs() < 1e-9);
        assert!((growth.rate_cm_per_month - 1.0).abs() < 0.05, "{}", growth.rate_cm_per_month);
        assert_eq!(growth.next_cup, Some("B"));
        assert!(growth.months_to_next_cup.expect("months") > 0.0);
    }

    #[test]
    fn a_measurement_without_an_underbust_is_not_a_size() {
        let report = assess(BodyInput {
            measurements: &[Measurement {
                time_h: 0.0,
                bust_cm: 90.0,
                underbust_cm: None,
            }],
            system: Some(CupSystem::Eu),
            height_cm: None,
            weight_kg: None,
        });
        assert!(report.sizes.is_empty());
        assert!(!report.paired);
        assert!(report.difference_cm.is_none());
    }

    #[test]
    fn a_flat_rate_does_not_project_a_date() {
        let report = run(&[m(0.0, 85.0, 75.0), m(24.0 * 60.0, 85.0, 75.0)], CupSystem::Cn);
        let growth = report.growth.as_ref().expect("growth");
        assert!(growth.months_to_next_cup.is_none());
        assert!((growth.change_cm).abs() < 1e-9);
    }

    #[test]
    fn bmi_needs_both_numbers() {
        let report = assess(BodyInput {
            measurements: &[m(0.0, 85.0, 75.0)],
            system: None,
            height_cm: Some(170.0),
            weight_kg: Some(63.0),
        });
        assert!((report.bmi.expect("bmi") - 21.8).abs() < 0.1);
    }
}
