//! `hrt_core` — the pharmacokinetic engine behind the Flutter app.
//!
//! The UI never computes a concentration itself: doses and lab results go in as
//! JSON, curves come back as JSON. Keeping the maths here means it is written
//! in a memory-safe language with no GC pauses, runs off the UI isolate, and
//! has its own unit tests independent of the interface.

pub mod api;
pub mod calibration;
pub mod engine;
pub mod model;
