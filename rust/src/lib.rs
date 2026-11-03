//! `hrt_core` — an offline pharmacokinetic engine for estradiol and
//! testosterone HRT.
//!
//! The library answers questions about a dosing history: what the modelled
//! concentration is at a given moment, when it will leave a target range, what
//! a repeated schedule settles to, which dose would land inside that range,
//! and how far a person's own lab results say the model is off.
//!
//! ```
//! use hrt_core::engine::run_simulation;
//! use hrt_core::model::{DoseEvent, Ester, PkParams, Route};
//!
//! let event = DoseEvent {
//!     id: "first".into(),
//!     route: Route::Injection,
//!     time_h: 0.0,
//!     dose_mg: 4.0,
//!     ester: Ester::EV,
//!     extras: Default::default(),
//!     updated_at: None,
//! };
//! let sim = run_simulation(&[event], 70.0, None, &PkParams::default(), 72.0, 1.0)
//!     .expect("a curve");
//! assert!(sim.time_h.len() > 100);
//! ```
//!
//! # Layers
//!
//! * [`model`] — the vocabulary: doses, routes, esters, labs, targets.
//! * [`engine`] — the curves, solved analytically from the rate constants.
//! * [`calibration`] — fitting those curves to measured blood levels.
//! * [`stats`] — peak, trough, exposure and time in range.
//! * [`planning`] — steady state, dose solving, adherence, supply.
//! * [`reminders`] — when the level will drop out of range.
//! * [`blockade`] — anti-androgen dose bands, coverage and the next dose due.
//! * [`compare`] — several regimens settled side by side.
//! * [`whatif`] — the same record with one dose changed.
//! * [`labsreview`] — reading a panel back: in range, moving, overdue.
//! * [`body`] — bust, underbust and the cup size they imply in each system.
//! * [`progress`] — suppression and effectiveness over a day, a month and a year.
//! * [`units`], [`catalog`], [`safety`], [`analysis`] — everything a client
//!   needs around the maths.
//! * [`api`] — the same functionality as a JSON-over-C ABI, which is how the
//!   Flutter, Python and C# bindings reach it.
//!
//! # Units
//!
//! Concentrations are pg/mL for estradiol, ng/dL for testosterone, and ng/mL
//! for cyproterone acetate and for canrenone — the active metabolite through
//! which spironolactone is modelled. Times are hours since the Unix epoch,
//! except for the intervals and half-lives, which are durations in hours. Doses
//! are milligrams of the logged ester, not of the active hormone —
//! [`units::active_mg`] converts between the two.

pub mod analysis;
pub mod api;
pub mod blockade;
pub mod body;
pub mod calibration;
pub mod catalog;
pub mod compare;
pub mod engine;
pub mod labsreview;
pub mod model;
pub mod planning;
pub mod progress;
pub mod reminders;
pub mod safety;
pub mod stats;
pub mod units;
pub mod whatif;

/// The wire format version. Bumped whenever a request or response field
/// changes meaning, so a caller can refuse a library it does not understand.
pub const ABI_VERSION: i32 = api::ABI_VERSION;

pub use engine::{run_simulation, run_simulation_grid, SimGrid};
pub use model::{
    DoseEvent, Ester, LabResult, LabUnit, PkParams, Route, SimulationResult, TargetRange,
};

#[cfg(test)]
mod integration_tests {
    use super::*;

    /// End to end: a weekly injection, statistics over one interval, and a
    /// reminder for the dip before the next dose.
    #[test]
    fn a_schedule_can_be_planned_and_explained() {
        let schedule = planning::Schedule {
            route: Route::Injection,
            ester: Ester::EV,
            dose_mg: 4.0,
            interval_h: 168.0,
            extras: Default::default(),
            start_h: 0.0,
        };
        let params = PkParams::default();
        let range = TargetRange::new(100.0, 200.0);

        let steady = planning::steady_state(
            &schedule,
            70.0,
            None,
            &params,
            128,
            Some(range),
            None,
            false,
        )
        .expect("steady state");
        assert!(steady.stable);

        let solution = planning::solve_dose(
            &schedule,
            70.0,
            None,
            &params,
            planning::Objective::Trough,
            range,
            128,
        )
        .expect("solution");
        assert!(solution.dose_mg > 0.0);
        assert!(!solution.note.is_empty() || solution.in_range);
    }
}
