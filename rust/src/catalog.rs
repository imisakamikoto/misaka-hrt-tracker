//! What the engine knows, as data.
//!
//! A client that wants a picker, a help screen or a unit menu should not have
//! to hard-code the same table a third time. Everything the model can accept
//! is described here, including the routes that are deliberately *not* modelled
//! — the difference between "this produces nothing" and "this is unknown" is
//! exactly what a user needs to be told.

use serde::Serialize;

use crate::model::{Ester, LabUnit, Route, TargetRange};

#[derive(Debug, Clone, Serialize)]
#[serde(rename_all = "camelCase")]
pub struct EsterInfo {
    pub code: &'static str,
    pub name: &'static str,
    pub molecular_weight: f64,
    /// Milligrams of active hormone per milligram of ester.
    pub active_factor: f64,
    /// `"e2"`, `"t"`, `"cpa"`, or `null` when the compound is not modelled.
    pub hormone: Option<&'static str>,
    pub modelled: bool,
    /// Routes that produce a curve for this ester.
    pub routes: Vec<&'static str>,
    /// Approximate terminal half-life in hours, for display only. The model
    /// does not read this value; it comes from the rate constants.
    pub half_life_hours: Option<f64>,
    pub note: Option<&'static str>,
}

#[derive(Debug, Clone, Serialize)]
#[serde(rename_all = "camelCase")]
pub struct RouteInfo {
    pub code: &'static str,
    pub name: &'static str,
    pub description: &'static str,
    /// Keys that may appear in `extras` for this route.
    pub extras: Vec<&'static str>,
    /// A patch removal is an event, not a dose.
    pub is_dose: bool,
}

#[derive(Debug, Clone, Serialize)]
#[serde(rename_all = "camelCase")]
pub struct UnitInfo {
    pub code: &'static str,
    pub analyte: &'static str,
    pub kind: &'static str,
}

#[derive(Debug, Clone, Serialize)]
#[serde(rename_all = "camelCase")]
pub struct Catalog {
    pub version: String,
    pub abi: i32,
    pub esters: Vec<EsterInfo>,
    pub routes: Vec<RouteInfo>,
    pub units: Vec<UnitInfo>,
    pub target_defaults: TargetDefaults,
    pub disclaimer: &'static str,
}

#[derive(Debug, Clone, Serialize)]
#[serde(rename_all = "camelCase")]
pub struct TargetDefaults {
    pub e2_pg_ml: TargetRange,
    pub t_ng_dl: TargetRange,
    pub note: &'static str,
}

fn routes_for(ester: Ester) -> Vec<&'static str> {
    match ester {
        Ester::E2 => vec!["injection", "oral", "sublingual", "gel", "patchApply"],
        Ester::EB | Ester::EC | Ester::EN | Ester::EU => vec!["injection"],
        Ester::EV => vec!["injection", "oral", "sublingual"],
        Ester::CPA => vec!["oral"],
        Ester::SPIRO => vec!["oral"],
        Ester::T => vec!["gel", "patchApply"],
        Ester::TC | Ester::TE | Ester::TU => vec!["injection"],
        Ester::BICA | Ester::MPA | Ester::LEUP | Ester::TRIP | Ester::RLX => Vec::new(),
    }
}

fn half_life_for(ester: Ester) -> Option<f64> {
    Some(match ester {
        Ester::E2 => 12.0,
        Ester::EB => 96.0,
        Ester::EV => 120.0,
        Ester::EC => 168.0,
        Ester::EN => 168.0,
        Ester::EU => 720.0,
        Ester::CPA => 43.9,
        Ester::SPIRO => 19.0,
        Ester::T => 2.0,
        Ester::TC => 192.0,
        Ester::TE => 120.0,
        Ester::TU => 792.0,
        _ => return None,
    })
}

fn note_for(ester: Ester) -> Option<&'static str> {
    match ester {
        Ester::E2 => Some(
            "Unesterified estradiol. Injection of this form is not modelled; the \
             oral, sublingual, gel and patch routes are.",
        ),
        Ester::T => Some(
            "Unesterified testosterone. Only the gel and patch routes are \
             modelled; injectable testosterone needs an ester.",
        ),
        Ester::SPIRO => Some(
            "Reported as canrenone, the active metabolite: the parent drug is \
             gone within hours while canrenone accumulates. Blocks the androgen \
             receptor without lowering testosterone, so the curve shows that \
             the drug is present, not how much androgen it is blocking.",
        ),
        Ester::BICA | Ester::MPA | Ester::LEUP | Ester::TRIP | Ester::RLX => Some(
            "Not modelled. The dose is still stored and shown, but no curve is \
             produced for it.",
        ),
        _ => None,
    }
}

/// The whole table.
pub fn catalog() -> Catalog {
    Catalog {
        version: env!("CARGO_PKG_VERSION").to_string(),
        abi: crate::ABI_VERSION,
        esters: Ester::ALL
            .iter()
            .map(|e| EsterInfo {
                code: e.code(),
                name: match e {
                    Ester::E2 => "Estradiol",
                    Ester::EB => "Estradiol benzoate",
                    Ester::EV => "Estradiol valerate",
                    Ester::EC => "Estradiol cypionate",
                    Ester::EN => "Estradiol enanthate",
                    Ester::EU => "Estradiol undecylate",
                    Ester::CPA => "Cyproterone acetate",
                    Ester::SPIRO => "Spironolactone",
                    Ester::BICA => "Bicalutamide",
                    Ester::MPA => "Medroxyprogesterone acetate",
                    Ester::LEUP => "Leuprolide",
                    Ester::TRIP => "Triptorelin",
                    Ester::RLX => "Relugolix",
                    Ester::T => "Testosterone",
                    Ester::TC => "Testosterone cypionate",
                    Ester::TE => "Testosterone enanthate",
                    Ester::TU => "Testosterone undecanoate",
                },
                molecular_weight: e.mw(),
                active_factor: e.to_active_factor(),
                hormone: e.hormone(),
                modelled: !e.is_unmodelled(),
                routes: routes_for(*e),
                half_life_hours: half_life_for(*e),
                note: note_for(*e),
            })
            .collect(),
        routes: Route::ALL
            .iter()
            .map(|r| RouteInfo {
                code: r.code(),
                name: match r {
                    Route::Sublingual => "Sublingual",
                    Route::Injection => "Injection",
                    Route::PatchApply => "Patch applied",
                    Route::PatchRemove => "Patch removed",
                    Route::Gel => "Gel",
                    Route::Oral => "Oral",
                },
                description: match r {
                    Route::Sublingual => {
                        "Held under the tongue. The fraction absorbed through the \
                         mucosa is read from `sublingualTier` or `sublingualTheta`."
                    }
                    Route::Injection => {
                        "Intramuscular or subcutaneous. The ester decides the \
                         release; the log records the amount injected."
                    }
                    Route::PatchApply => {
                        "A patch going on. With `releaseRateUGPerDay` it is a \
                         zero-order input; without it, first-order from the \
                         amount on the patch. Pair with a removal to end it."
                    }
                    Route::PatchRemove => {
                        "A patch coming off. This event produces no dose of its \
                         own: it ends the application it is paired with."
                    }
                    Route::Gel => {
                        "Transdermal gel. `gelSite` (0 arm, 1 thigh, 2 scrotal) \
                         picks the bioavailability."
                    }
                    Route::Oral => {
                        "Swallowed. Subject to first-pass metabolism, so the \
                         bioavailability is much lower than the other routes."
                    }
                },
                extras: match r {
                    Route::Sublingual => vec!["sublingualTier", "sublingualTheta"],
                    Route::Gel => vec!["gelSite", "concentrationMGmL", "areaCM2"],
                    Route::PatchApply => vec!["releaseRateUGPerDay", "patchWearH", "areaCM2"],
                    _ => Vec::new(),
                },
                is_dose: *r != Route::PatchRemove,
            })
            .collect(),
        units: LabUnit::ALL
            .iter()
            .map(|u| UnitInfo {
                code: u.code(),
                analyte: if u.is_testosterone() { "t" } else { "e2" },
                kind: if matches!(u, LabUnit::PmolL | LabUnit::NmolL) {
                    "molar"
                } else {
                    "mass"
                },
            })
            .collect(),
        target_defaults: TargetDefaults {
            e2_pg_ml: TargetRange::new(100.0, 200.0),
            t_ng_dl: TargetRange::new(400.0, 700.0),
            note: "Ranges commonly used for monotherapy, offered as a starting \
                   point for the target fields — not a recommendation. Targets \
                   differ by regimen, by whether an anti-androgen is used, and \
                   by clinician; the app lets them be changed for that reason.",
        },
        disclaimer: "This library is a pharmacokinetic model, not medical advice. \
                     It estimates concentrations from what it is told and cannot \
                     know anything the caller did not record.",
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn every_ester_is_listed_once() {
        let cat = catalog();
        assert_eq!(cat.esters.len(), Ester::ALL.len());
        let mut codes: Vec<&str> = cat.esters.iter().map(|e| e.code).collect();
        codes.sort();
        codes.dedup();
        assert_eq!(codes.len(), Ester::ALL.len());
    }

    #[test]
    fn unmodelled_compounds_have_no_routes() {
        let cat = catalog();
        for e in &cat.esters {
            if !e.modelled {
                assert!(e.routes.is_empty(), "{} claims routes", e.code);
            }
        }
    }
}
