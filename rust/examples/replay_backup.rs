//! Replays a complete-backup file through the engine to check what the app
//! would draw. Usage:
//!
//! ```text
//! cargo run --example replay_backup -- /path/to/hrt-complete-backup.json [nowH]
//! ```

use hrt_core::engine::run_simulation;
use hrt_core::model::{DoseEvent, PkParams};
use serde_json::Value;

fn main() {
    let mut args = std::env::args().skip(1);
    let path = args.next().expect("backup path");
    let raw = std::fs::read_to_string(&path).expect("read backup");
    let json: Value = serde_json::from_str(&raw).expect("parse backup");

    let mode = json
        .get("mode")
        .and_then(Value::as_str)
        .unwrap_or("transfem")
        .to_string();
    let weight = json
        .get("weight")
        .and_then(Value::as_f64)
        .unwrap_or(70.0)
        .clamp(20.0, 400.0);
    let block = json
        .get("modes")
        .and_then(|m| m.get(&mode))
        .cloned()
        .unwrap_or(Value::Null);
    let events: Vec<DoseEvent> =
        serde_json::from_value(block.get("events").cloned().unwrap_or(Value::Array(vec![])))
            .expect("parse events");

    println!("mode={mode} weight={weight} events={}", events.len());
    if let (Some(first), Some(last)) = (events.first(), events.last()) {
        println!(
            "first={:.1}h last={:.1}h dose={}mg route={:?} extras={:?}",
            first.time_h, last.time_h, last.dose_mg, last.route, last.extras
        );
    }

    let now_h = args
        .next()
        .and_then(|v| v.parse::<f64>().ok())
        .unwrap_or_else(|| {
            let last = events.last().map(|e| e.time_h).unwrap_or(0.0);
            last + 6.0
        });
    println!("now_h={now_h:.1}");

    let params = PkParams::default().sanitized();
    match run_simulation(&events, weight, None, &params, now_h, 1.0) {
        Some(sim) => {
            println!("points={} auc={:.3}", sim.time_h.len(), sim.auc);
            let at = sim.e2_at(now_h);
            println!("E2 @now = {:?} pg/mL", at);
            let max = sim.e2_pg_ml.iter().cloned().fold(f64::MIN, f64::max);
            println!("E2 peak = {:.3} pg/mL", max);
            let nonzero = sim.e2_pg_ml.iter().filter(|v| **v > 0.01).count();
            println!("nonzero points = {nonzero}");
        }
        None => println!("SIMULATION RETURNED NONE"),
    }
}
