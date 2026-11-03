//! Domain types shared with the Flutter layer.
//!
//! Every field name is serialised in camelCase so the JSON produced by
//! `serde_json` reads the same as the TypeScript objects the model was
//! originally written against.

use serde::{Deserialize, Serialize};

/// How a dose enters the body.
#[derive(Debug, Clone, Copy, PartialEq, Eq, Serialize, Deserialize)]
#[serde(rename_all = "camelCase")]
pub enum Route {
    Sublingual,
    Injection,
    PatchApply,
    PatchRemove,
    Gel,
    Oral,
}

impl Route {
    pub fn is_injection(self) -> bool {
        matches!(self, Route::Injection)
    }
}

/// Drug codes. The names match the codes stored on disk.
#[derive(Debug, Clone, Copy, PartialEq, Eq, Serialize, Deserialize)]
pub enum Ester {
    E2,
    EB,
    EV,
    EC,
    EN,
    EU,
    CPA,
    SPIRO,
    BICA,
    MPA,
    LEUP,
    TRIP,
    RLX,
    T,
    TC,
    TE,
    TU,
}

impl Ester {
    pub fn is_testosterone(self) -> bool {
        matches!(self, Ester::T | Ester::TC | Ester::TE | Ester::TU)
    }

    pub fn is_unmodelled(self) -> bool {
        matches!(
            self,
            Ester::BICA | Ester::MPA | Ester::LEUP | Ester::TRIP | Ester::RLX
        )
    }

    pub fn is_estradiol(self) -> bool {
        !self.is_testosterone()
            && self != Ester::CPA
            && self != Ester::SPIRO
            && !self.is_unmodelled()
    }

    /// Molecular weight, g/mol.
    pub fn mw(self) -> f64 {
        match self {
            Ester::E2 => 272.38,
            Ester::EB => 376.5,
            Ester::EV => 356.5,
            Ester::EC => 396.58,
            Ester::EN => 384.56,
            Ester::EU => 440.66,
            Ester::CPA => 416.94,
            Ester::SPIRO => 416.57,
            Ester::BICA => 430.37,
            Ester::MPA => 386.52,
            Ester::LEUP => 1209.42,
            Ester::TRIP => 1311.45,
            Ester::RLX => 473.58,
            Ester::T => 288.42,
            Ester::TC => 412.6,
            Ester::TE => 400.59,
            Ester::TU => 456.7,
        }
    }

    /// mg of active hormone per mg of the logged ester.
    pub fn to_active_factor(self) -> f64 {
        if self.is_unmodelled() || self == Ester::CPA || self == Ester::E2 {
            return 1.0;
        }
        if self.is_testosterone() {
            return Ester::T.mw() / self.mw();
        }
        Ester::E2.mw() / self.mw()
    }
}

/// Keys allowed in `extras`.
pub const EXTRA_CONCENTRATION: &str = "concentrationMGmL";
pub const EXTRA_AREA: &str = "areaCM2";
pub const EXTRA_RELEASE_RATE: &str = "releaseRateUGPerDay";
pub const EXTRA_SL_THETA: &str = "sublingualTheta";
pub const EXTRA_SL_TIER: &str = "sublingualTier";
pub const EXTRA_GEL_SITE: &str = "gelSite";
pub const EXTRA_PATCH_WEAR: &str = "patchWearH";

pub const GEL_SITES: [&str; 3] = ["arm", "thigh", "scrotal"];

#[derive(Debug, Clone, Serialize, Deserialize)]
#[serde(rename_all = "camelCase")]
pub struct DoseEvent {
    pub id: String,
    pub route: Route,
    /// Hours since the Unix epoch.
    pub time_h: f64,
    /// Milligrams of the ester as logged.
    ///
    /// The stored/backup shape spells the unit in capitals (`doseMG`), and the
    /// Dart side sends events in exactly that shape, so both spellings are
    /// accepted. `camelCase` alone would reject the payloads the app actually
    /// produces.
    #[serde(rename = "doseMG", alias = "doseMg", alias = "dose_mg")]
    pub dose_mg: f64,
    pub ester: Ester,
    #[serde(default)]
    pub extras: std::collections::HashMap<String, f64>,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub updated_at: Option<i64>,
}

impl DoseEvent {
    pub fn extra(&self, key: &str) -> Option<f64> {
        self.extras.get(key).copied().filter(|v| v.is_finite())
    }

    pub fn gel_site(&self) -> &'static str {
        let idx = self
            .extra(EXTRA_GEL_SITE)
            .unwrap_or(0.0)
            .round()
            .clamp(0.0, (GEL_SITES.len() - 1) as f64) as usize;
        GEL_SITES[idx]
    }

    pub fn patch_rate_mg_per_day(&self) -> Option<f64> {
        self.extra(EXTRA_RELEASE_RATE)
            .filter(|v| *v > 0.0)
            .map(|ug| ug / 1000.0)
    }

    pub fn planned_wear_h(&self) -> Option<f64> {
        self.extra(EXTRA_PATCH_WEAR).filter(|v| *v > 0.0)
    }

    pub fn hormone(&self) -> Option<&'static str> {
        if self.ester.is_testosterone() {
            Some("t")
        } else if self.ester.is_estradiol() {
            Some("e2")
        } else {
            None
        }
    }
}

#[derive(Debug, Clone, Copy, PartialEq, Eq, Serialize, Deserialize)]
#[serde(rename_all = "camelCase")]
pub enum LabUnit {
    #[serde(rename = "pg/ml")]
    PgMl,
    #[serde(rename = "pmol/l")]
    PmolL,
    #[serde(rename = "ng/dl")]
    NgDl,
    #[serde(rename = "nmol/l")]
    NmolL,
}

impl LabUnit {
    pub fn is_testosterone(self) -> bool {
        matches!(self, LabUnit::NgDl | LabUnit::NmolL)
    }

    /// Value in the model's own unit: pg/mL for estradiol, ng/dL for testosterone.
    pub fn to_model_unit(self, value: f64) -> f64 {
        match self {
            LabUnit::PgMl | LabUnit::NgDl => value,
            LabUnit::PmolL => value / 3.671,
            LabUnit::NmolL => value * 28.842,
        }
    }
}

#[derive(Debug, Clone, Serialize, Deserialize)]
#[serde(rename_all = "camelCase")]
pub struct LabResult {
    pub id: String,
    pub time_h: f64,
    pub conc_value: f64,
    pub unit: LabUnit,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub assay: Option<String>,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub updated_at: Option<i64>,
}

/// Tunable PK parameters, all settable in the app's advanced screen.
///
/// A caller may send a subset: every missing field falls back to
/// [`PkParams::default`]. Without that, adding a parameter would break every
/// client that stored a settings object built against an older release.
#[derive(Debug, Clone, Copy, Serialize, Deserialize)]
#[serde(rename_all = "camelCase", default)]
pub struct PkParams {
    pub e2_k_clear: f64,
    pub e2_k_clear_inj: f64,
    pub e2_ff_eb: f64,
    pub e2_ff_ev: f64,
    pub e2_ff_ec: f64,
    pub e2_ff_en: f64,
    pub e2_ff_eu: f64,
    pub e2_oral_bio: f64,
    pub e2_sl_quick: f64,
    pub e2_sl_casual: f64,
    pub e2_sl_standard: f64,
    pub e2_sl_strict: f64,
    pub e2_gel_arm: f64,
    pub e2_gel_thigh: f64,
    pub e2_gel_scrotal: f64,
    pub t_k_clear: f64,
    pub t_k_clear_inj: f64,
    pub t_ff_tc: f64,
    pub t_ff_te: f64,
    pub t_ff_tu: f64,
    pub t_gel_arm: f64,
    pub t_gel_thigh: f64,
    pub t_gel_scrotal: f64,
    /// Fraction of an oral spironolactone dose that reaches canrenone:
    /// absorption (~0.65) × hepatic conversion (~0.80).
    pub spiro_f_canrenone: f64,
    /// Absorption rate of spironolactone itself, /h.
    pub spiro_k_abs: f64,
    /// Conversion of spironolactone to canrenone, /h.
    pub spiro_k_convert: f64,
    /// Canrenone elimination, /h. Default is a 19 h half-life.
    pub spiro_k_clear: f64,
}

impl Default for PkParams {
    fn default() -> Self {
        PkParams {
            e2_k_clear: 0.41,
            e2_k_clear_inj: 0.041,
            e2_ff_eb: 0.1092,
            e2_ff_ev: 0.0623,
            e2_ff_ec: 0.1173,
            e2_ff_en: 0.12,
            e2_ff_eu: 0.04,
            e2_oral_bio: 0.03,
            e2_sl_quick: 0.01,
            e2_sl_casual: 0.04,
            e2_sl_standard: 0.11,
            e2_sl_strict: 0.18,
            e2_gel_arm: 0.05,
            e2_gel_thigh: 0.05,
            e2_gel_scrotal: 0.25,
            t_k_clear: 0.5,
            t_k_clear_inj: 0.035,
            t_ff_tc: 0.043,
            t_ff_te: 0.043,
            t_ff_tu: 0.043,
            t_gel_arm: 0.1,
            t_gel_thigh: 0.1,
            t_gel_scrotal: 0.5,
            spiro_f_canrenone: 0.52,
            spiro_k_abs: 1.386,
            spiro_k_convert: 0.495,
            spiro_k_clear: 0.0365,
        }
    }
}

impl PkParams {
    /// Clamp every field into the range the settings screen allows, so an
    /// imported backup cannot divide by zero or turn decay into growth.
    pub fn sanitized(mut self) -> PkParams {
        for (value, (lo, hi)) in self.fields_mut() {
            if !value.is_finite() {
                *value = lo;
            } else {
                *value = value.clamp(lo, hi);
            }
        }
        self
    }

    fn fields_mut(&mut self) -> Vec<(&mut f64, (f64, f64))> {
        vec![
            (&mut self.e2_k_clear, (0.001, 5.0)),
            (&mut self.e2_k_clear_inj, (0.001, 1.0)),
            (&mut self.e2_ff_eb, (0.0, 1.0)),
            (&mut self.e2_ff_ev, (0.0, 1.0)),
            (&mut self.e2_ff_ec, (0.0, 1.0)),
            (&mut self.e2_ff_en, (0.0, 1.0)),
            (&mut self.e2_ff_eu, (0.0, 1.0)),
            (&mut self.e2_oral_bio, (0.0, 1.0)),
            (&mut self.e2_sl_quick, (0.0, 1.0)),
            (&mut self.e2_sl_casual, (0.0, 1.0)),
            (&mut self.e2_sl_standard, (0.0, 1.0)),
            (&mut self.e2_sl_strict, (0.0, 1.0)),
            (&mut self.e2_gel_arm, (0.0, 1.0)),
            (&mut self.e2_gel_thigh, (0.0, 1.0)),
            (&mut self.e2_gel_scrotal, (0.0, 1.0)),
            (&mut self.t_k_clear, (0.001, 5.0)),
            (&mut self.t_k_clear_inj, (0.001, 1.0)),
            (&mut self.t_ff_tc, (0.0, 1.0)),
            (&mut self.t_ff_te, (0.0, 1.0)),
            (&mut self.t_ff_tu, (0.0, 1.0)),
            (&mut self.t_gel_arm, (0.0, 1.0)),
            (&mut self.t_gel_thigh, (0.0, 1.0)),
            (&mut self.t_gel_scrotal, (0.0, 1.0)),
            (&mut self.spiro_f_canrenone, (0.05, 1.0)),
            (&mut self.spiro_k_abs, (0.05, 10.0)),
            (&mut self.spiro_k_convert, (0.02, 5.0)),
            (&mut self.spiro_k_clear, (0.005, 0.5)),
        ]
    }
}

/// The window a person is trying to stay inside, in the model's own unit
/// (pg/mL for estradiol, ng/dL for testosterone).
#[derive(Debug, Clone, Copy, PartialEq, Serialize, Deserialize)]
#[serde(rename_all = "camelCase")]
pub struct TargetRange {
    pub low: f64,
    pub high: f64,
}

impl TargetRange {
    pub fn new(low: f64, high: f64) -> Self {
        if low <= high {
            TargetRange { low, high }
        } else {
            TargetRange {
                low: high,
                high: low,
            }
        }
    }

    pub fn normalized(self) -> Option<Self> {
        if self.low.is_finite() && self.high.is_finite() && self.low > 0.0 && self.high > self.low {
            Some(TargetRange::new(self.low, self.high))
        } else {
            None
        }
    }

    pub fn contains(self, value: f64) -> bool {
        value >= self.low && value <= self.high
    }
}

/// The curve a simulation produced.
#[derive(Debug, Clone, Default, Serialize, Deserialize)]
#[serde(rename_all = "camelCase")]
pub struct SimulationResult {
    pub time_h: Vec<f64>,
    pub e2_pg_ml: Vec<f64>,
    pub cpa_ng_ml: Vec<f64>,
    pub t_ng_dl: Vec<f64>,
    /// Canrenone, the active metabolite of spironolactone, in ng/mL.
    #[serde(default)]
    pub spiro_ng_ml: Vec<f64>,
    pub auc: f64,
    /// Area under the canrenone curve over the same window, ng/mL·h.
    #[serde(default)]
    pub spiro_auc: f64,
}

impl SimulationResult {
    pub fn is_empty(&self) -> bool {
        self.time_h.is_empty()
    }

    fn index_at_or_before(&self, hour: f64) -> Option<usize> {
        if self.time_h.is_empty() {
            return None;
        }
        if hour <= self.time_h[0] {
            return Some(0);
        }
        let last = self.time_h.len() - 1;
        if hour >= self.time_h[last] {
            return Some(last);
        }
        let (mut lo, mut hi) = (0usize, last);
        while hi - lo > 1 {
            let mid = (lo + hi) / 2;
            if self.time_h[mid] <= hour {
                lo = mid;
            } else {
                hi = mid;
            }
        }
        Some(lo)
    }

    pub fn e2_at(&self, hour: f64) -> Option<f64> {
        let i = self.index_at_or_before(hour)?;
        if i + 1 >= self.time_h.len() {
            return self.e2_pg_ml.get(i).copied();
        }
        let (t0, t1) = (self.time_h[i], self.time_h[i + 1]);
        let (c0, c1) = (self.e2_pg_ml[i], self.e2_pg_ml[i + 1]);
        if t1 <= t0 {
            return Some(c0);
        }
        Some(c0 + (c1 - c0) * (hour - t0) / (t1 - t0))
    }

    pub fn t_at(&self, hour: f64) -> Option<f64> {
        let i = self.index_at_or_before(hour)?;
        if i + 1 >= self.time_h.len() {
            return self.t_ng_dl.get(i).copied();
        }
        let (t0, t1) = (self.time_h[i], self.time_h[i + 1]);
        let (c0, c1) = (self.t_ng_dl[i], self.t_ng_dl[i + 1]);
        if t1 <= t0 {
            return Some(c0);
        }
        Some(c0 + (c1 - c0) * (hour - t0) / (t1 - t0))
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    /// The Dart side sends events straight from its own `toJson`, which spells
    /// the dose with capital letters (`doseMG`) because that is the storage and
    /// backup shape. A stricter `camelCase` reading rejected every real payload,
    /// which made an imported history look empty.
    #[test]
    fn accepts_the_payload_the_app_actually_sends() {
        let json = r#"{
            "id": "6e9c58b7",
            "route": "sublingual",
            "timeH": 498220.8304513889,
            "doseMG": 1,
            "ester": "EV",
            "extras": {"sublingualTier": 3},
            "updatedAt": 1793594989627
        }"#;
        let event: DoseEvent = serde_json::from_str(json).expect("dart payload parses");
        assert_eq!(event.dose_mg, 1.0);
        assert_eq!(event.time_h, 498220.8304513889);
        assert_eq!(event.route, Route::Sublingual);
        assert_eq!(event.ester, Ester::EV);
        assert_eq!(event.extra(EXTRA_SL_TIER), Some(3.0));
    }

    /// Round-tripping must keep the app's spelling, so a snapshot written by
    /// the core can be read back by the Dart models unchanged.
    #[test]
    fn serialises_the_dose_with_the_same_spelling() {
        let event = DoseEvent {
            id: "x".into(),
            route: Route::Sublingual,
            time_h: 1.0,
            dose_mg: 2.0,
            ester: Ester::EV,
            extras: Default::default(),
            updated_at: None,
        };
        let json = serde_json::to_string(&event).unwrap();
        assert!(json.contains("\"doseMG\":2.0"), "{json}");
    }
}

// --- Stable codes, for the wire format and the catalogue -------------------

impl Ester {
    /// Every ester the engine knows, in a fixed order.
    pub const ALL: [Ester; 17] = [
        Ester::E2,
        Ester::EB,
        Ester::EV,
        Ester::EC,
        Ester::EN,
        Ester::EU,
        Ester::CPA,
        Ester::SPIRO,
        Ester::BICA,
        Ester::MPA,
        Ester::LEUP,
        Ester::TRIP,
        Ester::RLX,
        Ester::T,
        Ester::TC,
        Ester::TE,
        Ester::TU,
    ];

    /// The code used in storage, backups and this ABI (`EV`, `TC`, …).
    pub fn code(self) -> &'static str {
        match self {
            Ester::E2 => "E2",
            Ester::EB => "EB",
            Ester::EV => "EV",
            Ester::EC => "EC",
            Ester::EN => "EN",
            Ester::EU => "EU",
            Ester::CPA => "CPA",
            Ester::SPIRO => "SPIRO",
            Ester::BICA => "BICA",
            Ester::MPA => "MPA",
            Ester::LEUP => "LEUP",
            Ester::TRIP => "TRIP",
            Ester::RLX => "RLX",
            Ester::T => "T",
            Ester::TC => "TC",
            Ester::TE => "TE",
            Ester::TU => "TU",
        }
    }

    /// Reverse of [`Ester::code`], case-insensitive. Treatment names
    /// (`estradiol_valerate`, `testosterone-enanthate`) are also accepted so a
    /// caller does not have to know the storage spelling.
    pub fn from_code(text: &str) -> Option<Ester> {
        let key: String = text
            .chars()
            .filter(|c| c.is_ascii_alphanumeric())
            .map(|c| c.to_ascii_lowercase())
            .collect();
        Some(match key.as_str() {
            "e2" | "estradiol" => Ester::E2,
            "eb" | "estradiolbenzoate" => Ester::EB,
            "ev" | "estradiolvalerate" => Ester::EV,
            "ec" | "estradiolcypionate" => Ester::EC,
            "en" | "estradiolenanthate" => Ester::EN,
            "eu" | "estradiolundecylate" => Ester::EU,
            "cpa" | "cyproterone" | "cyproteroneacetate" => Ester::CPA,
            "spiro" | "spironolactone" => Ester::SPIRO,
            "bica" | "bicalutamide" => Ester::BICA,
            "mpa" | "medroxyprogesterone" => Ester::MPA,
            "leup" | "leuprolide" => Ester::LEUP,
            "trip" | "triptorelin" => Ester::TRIP,
            "rlx" | "relugolix" => Ester::RLX,
            "t" | "testosterone" => Ester::T,
            "tc" | "testosteronecypionate" => Ester::TC,
            "te" | "testosteroneenanthate" => Ester::TE,
            "tu" | "testosteroneundecanoate" => Ester::TU,
            _ => return None,
        })
    }

    /// `"e2"`, `"t"`, `"cpa"`, `"spiro"` — or `None` when the compound is not
    /// modelled at all.
    ///
    /// Spironolactone reports its active metabolite, canrenone: the parent drug
    /// is gone within hours while canrenone carries the effect.
    pub fn hormone(self) -> Option<&'static str> {
        if self.is_testosterone() {
            Some("t")
        } else if self == Ester::CPA {
            Some("cpa")
        } else if self == Ester::SPIRO {
            Some("spiro")
        } else if self.is_estradiol() {
            Some("e2")
        } else {
            None
        }
    }
}

impl Route {
    pub const ALL: [Route; 6] = [
        Route::Sublingual,
        Route::Injection,
        Route::PatchApply,
        Route::PatchRemove,
        Route::Gel,
        Route::Oral,
    ];

    pub fn code(self) -> &'static str {
        match self {
            Route::Sublingual => "sublingual",
            Route::Injection => "injection",
            Route::PatchApply => "patchApply",
            Route::PatchRemove => "patchRemove",
            Route::Gel => "gel",
            Route::Oral => "oral",
        }
    }
}

impl LabUnit {
    pub const ALL: [LabUnit; 4] = [LabUnit::PgMl, LabUnit::PmolL, LabUnit::NgDl, LabUnit::NmolL];

    pub fn code(self) -> &'static str {
        match self {
            LabUnit::PgMl => "pg/ml",
            LabUnit::PmolL => "pmol/l",
            LabUnit::NgDl => "ng/dl",
            LabUnit::NmolL => "nmol/l",
        }
    }

    pub fn from_code(text: &str) -> Option<LabUnit> {
        let key: String = text
            .chars()
            .filter(|c| c.is_ascii_alphanumeric())
            .map(|c| c.to_ascii_lowercase())
            .collect();
        Some(match key.as_str() {
            "pgml" | "pg" => LabUnit::PgMl,
            "pmoll" | "pmol" => LabUnit::PmolL,
            "ngdl" | "ng" => LabUnit::NgDl,
            "nmoll" | "nmol" => LabUnit::NmolL,
            _ => return None,
        })
    }

    /// Convert a value from this unit into `to`.
    ///
    /// Mass and molar units are tied together by the analyte's molecular
    /// weight, so estradiol and testosterone need different constants; the
    /// unit chosen decides which one is applied.
    pub fn convert(self, value: f64, to: LabUnit) -> f64 {
        if self == to {
            return value;
        }
        // Everything goes through the model's own mass unit first.
        let model = self.to_model_unit(value);
        match to {
            LabUnit::PgMl | LabUnit::NgDl => model,
            LabUnit::PmolL => model * 3.671,
            LabUnit::NmolL => model / 28.842,
        }
    }
}
