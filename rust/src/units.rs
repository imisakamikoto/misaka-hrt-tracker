//! Unit conversion and dose equivalence.
//!
//! Labs are reported in four different units depending on the country and the
//! laboratory, and esters carry different amounts of hormone per milligram.
//! Both conversions are pure arithmetic, but getting them wrong is the kind of
//! mistake that makes a chart look plausible and be wrong by a factor of three,
//! so they live here with tests instead of being scattered through callers.

use serde::{Deserialize, Serialize};

use crate::model::{Ester, LabUnit};

/// Which molecule a concentration refers to.
#[derive(Debug, Clone, Copy, PartialEq, Eq, Serialize, Deserialize)]
#[serde(rename_all = "camelCase")]
pub enum Analyte {
    Estradiol,
    Testosterone,
}

impl Analyte {
    pub fn molecular_weight(self) -> f64 {
        match self {
            Analyte::Estradiol => Ester::E2.mw(),
            Analyte::Testosterone => Ester::T.mw(),
        }
    }

    pub fn code(self) -> &'static str {
        match self {
            Analyte::Estradiol => "e2",
            Analyte::Testosterone => "t",
        }
    }

    pub fn parse(text: &str) -> Option<Analyte> {
        match text.trim().to_ascii_lowercase().as_str() {
            "e2" | "estradiol" | "oestradiol" => Some(Analyte::Estradiol),
            "t" | "testosterone" => Some(Analyte::Testosterone),
            _ => None,
        }
    }

    /// pmol/L per pg/mL.
    pub fn picomolar_per_pg_ml(self) -> f64 {
        1000.0 / self.molecular_weight()
    }
}

/// Convert a concentration between any two of the four lab units.
///
/// `pg/ml` and `ng/dl` are mass units; `pmol/l` and `nmol/l` are molar. The
/// mass unit implies the analyte, so converting `ng/dl → nmol/l` with
/// `Analyte::Testosterone` is the only sensible pairing; passing estradiol
/// with testosterone units is the caller's mistake, and the arithmetic is
/// still done with the estradiol molecular weight.
pub fn convert_concentration(value: f64, from: LabUnit, to: LabUnit, analyte: Analyte) -> f64 {
    if from == to || !value.is_finite() {
        return value;
    }
    // Everything through pg/mL (estradiol) / ng/dL (testosterone), which the
    // model itself uses.
    let pg_per_ml = match from {
        LabUnit::PgMl | LabUnit::NgDl => {
            if from == LabUnit::NgDl {
                value * 10.0
            } else {
                value
            }
        }
        LabUnit::PmolL => value / analyte.picomolar_per_pg_ml(),
        LabUnit::NmolL => value * 1000.0 / analyte.picomolar_per_pg_ml(),
    };

    match to {
        LabUnit::PgMl => pg_per_ml,
        LabUnit::NgDl => pg_per_ml / 10.0,
        LabUnit::PmolL => pg_per_ml * analyte.picomolar_per_pg_ml(),
        LabUnit::NmolL => pg_per_ml * analyte.picomolar_per_pg_ml() / 1000.0,
    }
}

/// Milligrams of active hormone in a logged amount of ester.
pub fn active_mg(dose_mg: f64, ester: Ester) -> f64 {
    dose_mg * ester.to_active_factor()
}

/// The dose of `to` that carries the same amount of active hormone as
/// `dose_mg` of `from`.
///
/// This is the "2 mg of estradiol valerate is not 2 mg of estradiol" sum:
/// valerate is heavier, so 2 mg of EV contains 1.53 mg of estradiol.
pub fn dose_equivalent(dose_mg: f64, from: Ester, to: Ester) -> f64 {
    let active = active_mg(dose_mg, from);
    let factor = to.to_active_factor();
    if factor <= 0.0 {
        return 0.0;
    }
    active / factor
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn molar_and_mass_units_agree_for_estradiol() {
        // 100 pg/mL is 367.1 pmol/L.
        let pmol = convert_concentration(100.0, LabUnit::PgMl, LabUnit::PmolL, Analyte::Estradiol);
        assert!((pmol - 367.1).abs() < 0.2, "{pmol}");
        let back = convert_concentration(pmol, LabUnit::PmolL, LabUnit::PgMl, Analyte::Estradiol);
        assert!((back - 100.0).abs() < 1e-6, "{back}");
    }

    #[test]
    fn testosterone_uses_its_own_molecular_weight() {
        // 500 ng/dL = 17.34 nmol/L.
        let nmol =
            convert_concentration(500.0, LabUnit::NgDl, LabUnit::NmolL, Analyte::Testosterone);
        assert!((nmol - 17.34).abs() < 0.05, "{nmol}");
    }

    #[test]
    fn valerate_is_heavier_than_estradiol() {
        let e2 = dose_equivalent(2.0, Ester::EV, Ester::E2);
        assert!((e2 - 1.53).abs() < 0.02, "{e2}");
    }
}
