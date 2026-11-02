//! C ABI used by the Flutter side.
//!
//! Every entry point takes and returns UTF-8 JSON and never unwinds across the
//! boundary: a panic becomes an error object, so a bad import cannot take the
//! app's isolate down with it. Strings returned here must be released with
//! `hrt_free`.

use std::ffi::{CStr, CString};
use std::os::raw::c_char;
use std::panic::{catch_unwind, AssertUnwindSafe};

use serde::Deserialize;
use serde_json::{json, Value};

use crate::calibration::{calibrate, CalibrationInput};
use crate::engine::run_simulation;
use crate::model::{DoseEvent, LabResult, PkParams};

#[derive(Deserialize)]
#[serde(rename_all = "camelCase")]
struct SimRequest {
    events: Vec<DoseEvent>,
    body_weight_kg: f64,
    #[serde(default)]
    birth_year: Option<f64>,
    #[serde(default)]
    params: Option<PkParams>,
    now_h: f64,
    #[serde(default)]
    clearance_mult: Option<f64>,
}

#[derive(Deserialize)]
#[serde(rename_all = "camelCase")]
struct CalibrateRequest {
    events: Vec<DoseEvent>,
    body_weight_kg: f64,
    #[serde(default)]
    birth_year: Option<f64>,
    #[serde(default)]
    params: Option<PkParams>,
    labs: Vec<LabResult>,
    #[serde(default = "default_method")]
    method: String,
    #[serde(default = "default_history")]
    history_mode: String,
    now_h: f64,
}

fn default_method() -> String {
    "mipd".to_string()
}

fn default_history() -> String {
    "retrospective".to_string()
}

fn into_c_string(value: Value) -> *mut c_char {
    let text = serde_json::to_string(&value).unwrap_or_else(|_| "{\"ok\":false,\"error\":\"encode\"}".into());
    match CString::new(text) {
        Ok(c) => c.into_raw(),
        Err(_) => CString::new("{\"ok\":false,\"error\":\"nul byte\"}")
            .expect("static string is valid")
            .into_raw(),
    }
}

unsafe fn read_input<'a>(ptr: *const c_char) -> Result<&'a str, Value> {
    if ptr.is_null() {
        return Err(json!({"ok": false, "error": "null input"}));
    }
    CStr::from_ptr(ptr)
        .to_str()
        .map_err(|_| json!({"ok": false, "error": "input is not UTF-8"}))
}

/// Simulate the hormone curves for a set of doses.
#[no_mangle]
pub extern "C" fn hrt_simulate(input: *const c_char) -> *mut c_char {
    let result = catch_unwind(AssertUnwindSafe(|| {
        let text = unsafe { read_input(input) }?;
        let req: SimRequest = serde_json::from_str(text)
            .map_err(|e| json!({"ok": false, "error": format!("bad request: {e}")}))?;
        let params = req.params.unwrap_or_default().sanitized();
        let mult = req.clearance_mult.unwrap_or(1.0).clamp(0.1, 10.0);
        match run_simulation(
            &req.events,
            req.body_weight_kg,
            req.birth_year,
            &params,
            req.now_h,
            mult,
        ) {
            Some(sim) => Ok(json!({"ok": true, "result": sim})),
            None => Ok(json!({"ok": true, "result": Value::Null})),
        }
    }));

    match result {
        Ok(Ok(value)) => into_c_string(value),
        Ok(Err(value)) => into_c_string(value),
        Err(_) => into_c_string(json!({"ok": false, "error": "engine panic"})),
    }
}

/// Fit the model to the person's own lab results.
#[no_mangle]
pub extern "C" fn hrt_calibrate(input: *const c_char) -> *mut c_char {
    let result = catch_unwind(AssertUnwindSafe(|| {
        let text = unsafe { read_input(input) }?;
        let req: CalibrateRequest = serde_json::from_str(text)
            .map_err(|e| json!({"ok": false, "error": format!("bad request: {e}")}))?;
        let params = req.params.unwrap_or_default().sanitized();
        let out = calibrate(CalibrationInput {
            events: &req.events,
            weight: req.body_weight_kg,
            birth_year: req.birth_year,
            params: &params,
            labs: &req.labs,
            method: &req.method,
            history_mode: &req.history_mode,
            now_h: req.now_h,
        });
        Ok(json!({"ok": true, "result": out}))
    }));

    match result {
        Ok(Ok(value)) => into_c_string(value),
        Ok(Err(value)) => into_c_string(value),
        Err(_) => into_c_string(json!({"ok": false, "error": "engine panic"})),
    }
}

/// Free a string previously returned by this library.
#[no_mangle]
pub extern "C" fn hrt_free(ptr: *mut c_char) {
    if ptr.is_null() {
        return;
    }
    unsafe {
        drop(CString::from_raw(ptr));
    }
}

/// ABI version, so the Dart side can refuse a stale shared library.
#[no_mangle]
pub extern "C" fn hrt_abi_version() -> i32 {
    1
}

/// Human-readable core version.
#[no_mangle]
pub extern "C" fn hrt_version() -> *mut c_char {
    into_c_string(json!({"ok": true, "result": env!("CARGO_PKG_VERSION")}))
}
