//! A computer player for the RTS, played headless in the AI arena: tools/rust_ai/bridge.luau starts this process for a
//! team and talks to it in lines of JSON on stdin and stdout (protocol.rs). See tools/rust_ai/README.md.
//!
//!     rust_ai            play: read `hello`, answer `ready`, then answer each `observe` with commands
//!     rust_ai --schema   print every tunable number with its default and range (params.rs), for a search

/// Maps and sets that go through their entries in the same order every run (std's are seeded at random per
/// process), so that a game played again is the same game.
pub type HashMap<K, V> = std::collections::HashMap<K, V, std::hash::BuildHasherDefault<std::collections::hash_map::DefaultHasher>>;
pub type HashSet<K> = std::collections::HashSet<K, std::hash::BuildHasherDefault<std::collections::hash_map::DefaultHasher>>;

mod barb;
mod brain;
mod builders;
mod defs;
mod economy;
mod factory;
mod fields;
mod fronts;
mod groups;
mod map;
mod metal;
mod military;
mod params;
mod path;
mod porc;
mod protocol;
mod sim;
mod world;

use std::io::{BufRead, BufWriter, Write};

/// The battle simulator held up against staged fights played in the real game (tools/ai_arena/fight_check.py's
/// results): how often it names the real winner, beside server/ai's predictor. `hello` is arena.luau's "rust_hello".
fn predict(hello_path: &str, fights_path: &str) {
    let text = std::fs::read_to_string(hello_path).expect("no hello file");
    let value: serde_json::Value = serde_json::from_str(text.lines().last().unwrap_or("")).expect("hello is not JSON");
    let hello: protocol::Hello = serde_json::from_value(value["hello"].clone()).expect("bad hello");
    let barb = barb::Barb::load();
    let defs = defs::Defs::new(hello.defs, hello.constants, &barb);
    let mut n = 0;
    let (mut ours, mut theirs, mut close_n, mut close_ours, mut close_theirs) = (0, 0, 0, 0, 0);
    let mut worth_error = 0.0;
    let started = std::time::Instant::now();
    for line in std::fs::read_to_string(fights_path).expect("no fights file").lines() {
        let Ok(f) = serde_json::from_str::<serde_json::Value>(line) else { continue };
        if !f["ok"].as_bool().unwrap_or(false) {
            continue;
        }
        let side = |key: &str| -> Vec<sim::Fighter> {
            f["start"][key]
                .as_array()
                .map(|list| {
                    list.iter()
                        .filter_map(|u| {
                            let d = defs.get(u["def"].as_str()?)?;
                            Some(sim::Fighter { def: d, p: map::P::new(u["x"].as_f64()?, u["z"].as_f64()?), hp: defs.list[d].health })
                        })
                        .collect()
                })
                .unwrap_or_default()
        };
        let (a, b) = (side("a"), side("b"));
        let trace = std::env::var("PREDICT_TRACE").ok().map_or(false, |want| {
            f["start"]["a"].as_array().map_or(false, |l| l.iter().any(|u| u["def"].as_str() == Some(want.as_str())))
        });
        let outcome = sim::simulate(&defs, &a, &b, sim::Options { horizon: 90.0, trace, ..Default::default() });
        let real = f["real"]["winner"].as_str().unwrap_or("");
        let luau = f["predicted"]["winner"].as_str().unwrap_or("");
        let mine = if outcome.margin > 0.0 { "a" } else if outcome.margin < 0.0 { "b" } else { "" };
        if mine != real && std::env::var("PREDICT_VERBOSE").is_ok() {
            let names = |list: &[sim::Fighter]| {
                let mut counts: std::collections::BTreeMap<&str, usize> = Default::default();
                for x in list {
                    *counts.entry(defs.list[x.def].name.as_str()).or_insert(0) += 1;
                }
                format!("{counts:?}")
            };
            eprintln!(
                "WRONG real={real} luau={luau} rust_margin={:.2} ({:.0}s, left {:.0}/{:.0} vs {:.0}/{:.0}; real {}s) real_margin={} | a {} | b {} | b_def {}",
                outcome.margin,
                outcome.seconds,
                outcome.end[0],
                outcome.start[0],
                outcome.end[1],
                outcome.start[1],
                f["real"]["seconds"],
                f["real"]["margin"],
                names(&a),
                names(&b),
                f["start"]["b_defences"].is_array()
            );
        }
        n += 1;
        ours += (mine == real) as i32;
        theirs += (luau == real) as i32;
        let (wa, wb) = (f["real"]["start_worth"]["a"].as_f64().unwrap_or(1.0), f["real"]["start_worth"]["b"].as_f64().unwrap_or(1.0));
        if wa.max(wb) / wa.min(wb).max(1.0) <= 1.5 {
            close_n += 1;
            close_ours += (mine == real) as i32;
            close_theirs += (luau == real) as i32;
        }
        let real_a = f["real"]["worth"]["a"].as_f64().unwrap_or(0.0) / wa.max(1.0);
        let real_b = f["real"]["worth"]["b"].as_f64().unwrap_or(0.0) / wb.max(1.0);
        let my_a = outcome.end[0] / outcome.start[0].max(1.0);
        let my_b = outcome.end[1] / outcome.start[1].max(1.0);
        worth_error += ((my_a - real_a).abs() + (my_b - real_b).abs()) / 2.0;
    }
    println!(
        "{}",
        serde_json::json!({
            "fights": n,
            "rust_right": ours, "luau_right": theirs,
            "close": close_n, "rust_close_right": close_ours, "luau_close_right": close_theirs,
            "rust_worth_error": worth_error / n.max(1) as f64,
            "ms_each": started.elapsed().as_secs_f64() * 1000.0 / n.max(1) as f64,
        })
    );
}

fn main() {
    let args: Vec<String> = std::env::args().collect();
    if args.iter().any(|a| a == "--schema") {
        println!("{}", serde_json::to_string_pretty(&params::Params::schema()).unwrap());
        return;
    }
    if args.len() >= 4 && args[1] == "--predict" {
        predict(&args[2], &args[3]);
        return;
    }
    let stdin = std::io::stdin();
    let stdout = std::io::stdout();
    let mut out = BufWriter::new(stdout.lock());
    let mut brain: Option<brain::Brain> = None;
    for line in stdin.lock().lines() {
        let Ok(line) = line else { break };
        if line.trim().is_empty() {
            continue;
        }
        let value: serde_json::Value = match serde_json::from_str(&line) {
            Ok(v) => v,
            Err(e) => {
                eprintln!("rust_ai: bad line: {e}");
                std::process::exit(2);
            }
        };
        match value["type"].as_str() {
            Some("hello") => {
                let hello: protocol::Hello = match serde_json::from_value(value) {
                    Ok(h) => h,
                    Err(e) => {
                        eprintln!("rust_ai: bad hello: {e}");
                        std::process::exit(2);
                    }
                };
                match brain::Brain::new(hello) {
                    Ok(b) => brain = Some(b),
                    Err(e) => {
                        eprintln!("rust_ai: {e}");
                        std::process::exit(2);
                    }
                }
                writeln!(out, "{}", serde_json::json!({"type": "ready"})).unwrap();
                out.flush().unwrap();
            }
            Some("observe") => {
                let obs: protocol::Observe = match serde_json::from_value(value) {
                    Ok(o) => o,
                    Err(e) => {
                        eprintln!("rust_ai: bad observe: {e}");
                        std::process::exit(2);
                    }
                };
                let Some(b) = brain.as_mut() else {
                    eprintln!("rust_ai: observe before hello");
                    std::process::exit(2);
                };
                let (cmds, report) = b.think(&obs);
                let answer = protocol::Answer { kind: "cmds", cmds, report };
                serde_json::to_writer(&mut out, &answer).unwrap();
                writeln!(out).unwrap();
                out.flush().unwrap();
            }
            Some("bye") => break,
            other => {
                eprintln!("rust_ai: unknown message {other:?}");
            }
        }
    }
}
