//! Every number the Rust AI decides by, in one place, each with its default and the range a search may move it over
//! (`rust_ai --schema` prints them, for tools/rust_ai/search.py's CMA-ES). A match gives any of them in its side's
//! `params`; the rest keep their defaults. A switch is a number too: on at 0.5 and over.
//!
//! Where BARb (data/barb.json, from BAR's BARb hard config) has a number for something, the default is BARb's and the
//! doc says so; the rest are the Rust AI's own.

use serde_json::{json, Map, Value};

macro_rules! params {
    ($( $name:ident : $default:expr, $lo:expr, $hi:expr, $doc:literal; )*) => {
        #[derive(Clone, Debug)]
        pub struct Params { $( pub $name: f64, )* }

        impl Default for Params {
            fn default() -> Self { Params { $( $name: $default, )* } }
        }

        impl Params {
            /// The defaults with `given` over them; an error names any it does not know.
            pub fn from_map(given: &Map<String, Value>) -> Result<Params, String> {
                let mut params = Params::default();
                for (key, value) in given {
                    let number = value
                        .as_f64()
                        .or_else(|| value.as_bool().map(|b| if b { 1.0 } else { 0.0 }))
                        .ok_or_else(|| format!("param {key} is not a number"))?;
                    match key.as_str() {
                        $( stringify!($name) => params.$name = number, )*
                        _ => return Err(format!("unknown param {key}")),
                    }
                }
                Ok(params)
            }

            pub fn schema() -> Value {
                Value::Array(vec![ $( json!({
                    "name": stringify!($name),
                    "default": $default,
                    "min": $lo,
                    "max": $hi,
                    "doc": $doc,
                }), )* ])
            }

            pub fn to_json(&self) -> Value {
                let mut map = Map::new();
                $( map.insert(stringify!($name).to_string(), json!(self.$name)); )*
                Value::Object(map)
            }
        }
    };
}

params! {
    // Economy -------------------------------------------------------------------------------------------------------
    energy_ratio_start: 6.0, 2.0, 20.0, "energy income wanted per metal income at the start (sim_barb: 6)";
    energy_ratio_end: 30.0, 6.0, 40.0, "energy income wanted per metal income once the game is on (sim_barb: 30; the Luau default: 15 throughout)";
    energy_ratio_seconds: 420.0, 120.0, 1500.0, "seconds over which the energy ratio grows from start to end";
    buildpower_ratio: 1.2, 0.5, 3.0, "BARb economy.json buildpower: constructors are made while its build speed is under this times the metal income";
    builders_min: 4.0, 1.0, 8.0, "sim_barb's constructors_min: first-tier constructors it keeps whatever its income";
    metal_per_builder: 5.0, 2.0, 15.0, "sim_barb's metal_per_constructor: one more first-tier constructor for every this much metal income";
    builders_max: 14.0, 4.0, 40.0, "sim_barb's constructors_max: most first-tier constructors it keeps";
    metal_per_advanced_builder: 25.0, 5.0, 100.0, "sim_barb's metal_per_advanced_constructor: one advanced constructor, and one more for every this much metal income";
    advanced_builders_max: 4.0, 1.0, 12.0, "sim_barb's advanced_constructors_max";
    piling_fill: 0.7, 0.3, 1.0, "sim_barb's piling_fill: share of energy storage full at which it turns to storing and converting energy";
    converter_storage: 6000.0, 1000.0, 20000.0, "sim_barb's converter_storage: the least energy storage before converters";
    storage_seconds: 12.0, 2.0, 60.0, "sim_barb's storage_seconds: seconds of energy income it wants to hold before converters";
    energy_stores_max: 6.0, 0.0, 12.0, "sim_barb's energy_stores_max";
    converters_at_once: 2.0, 1.0, 6.0, "sim_barb's converters_at_once";
    converter_burn_share: 0.5, 0.1, 1.0, "sim_barb's converter_burn_share: the most of its energy income one converter may burn";
    porc_scale: 0.3, 0.0, 2.0, "times BARb's porcupine amount: how many seconds of metal income a defence point may hold (BARb's 32 to 48 on this game's maps)";
    extractor_builders: 0.5, 0.0, 1.0, "share of its constructors kept on extractors while there are spots to take (sim_barb's extractor_builders)";
    hunt_groups: 2.0, 0.0, 4.0, "sim_barb's hunts: most groups at once of what waits at home, sent after the enemy's units in its territory";
    hunt_radius: 100.0, 20.0, 250.0, "sim_barb's hunt_radius: studs round its extractors (and home) that are its territory";
    hunt_home: 70.0, 20.0, 200.0, "sim_barb's base_radius: studs round home that are its territory besides";
    home_defence: 1.0, 0.0, 1.0, "switch: sim_barb's whole-army defence: an intruder near home that what waits at home cannot see off brings every group home to fight it";
    defend_radius: 110.0, 40.0, 250.0, "sim_barb's defend_radius: how near home an intruder brings the whole army back";
    sim_defend_margin: 0.3, -0.3, 1.0, "sim_barb's sim_defend_margin: the least simulated margin what waits at home must win by, else the whole army comes";
    hunt_margin: 0.3, -0.3, 1.0, "the least simulated margin a hunt goes with";
    repair_patience: 30.0, 5.0, 120.0, "sim_barb's repair_patience: seconds a hurt unit waits at home to be mended before it goes back to work";
    retreat_walk_seconds: 120.0, 30.0, 300.0, "sim_barb's retreat_walk_seconds: most seconds a hurt unit spends going home and waiting";
    turrets_max: 8.0, 0.0, 20.0, "sim_barb's turrets_max: most construction turrets, one for every turret_income of metal income";
    constructor_energy_income: 200.0, 50.0, 1000.0, "sim_barb: energy income over which constructors build advanced solar rather than BARb's table (wind)";
    advanced_energy_income: 1000.0, 300.0, 3000.0, "sim_barb: energy income over which advanced constructors build fusion";
    energizers: 0.0, 0.0, 1.0, "switch: BARb's energizers (its first two advanced constructors build energy first); sim_barb has its advanced constructors upgrade extractors first";
    builder_flee_danger: 20.0, 0.5, 20.0, "sim_barb's flee_danger: the enemy threat (BARb's threat map) where a constructor stands over which it runs home, where the enemy outweighs it";
    flee_seconds: 12.0, 3.0, 40.0, "sim_barb's flee_seconds: the least a fleeing constructor runs for";
    opening_mex: 3.0, 0.0, 6.0, "sim_barb's opening_extractors: extractors its commander puts up first, on the spots nearest it";
    opening_energy: 4.0, 0.0, 8.0, "sim_barb's opening_energy: generators its commander puts up next, before its first lab";
    opening: 1.0, 0.0, 1.0, "switch: sim_barb's commander opening (extractors, energy, then its first lab)";
    opening_queue: 1.0, 0.0, 1.0, "switch: the commander's next opening step is queued behind the one under way (sim_barb gives the whole opening as one queue), not ordered once it is done";
    energy_full_enough: 0.0, 0.0, 1.0, "switch: energy storage all but full is energy enough: labs and construction turrets do not wait on energy income then, no more energy is started, and energy tasks nobody has begun are dropped";
    energy_cluster: 1.0, 0.0, 1.0, "switch: energy and stores go beside another of their kind, nearest home first (sim_barb's siting.luau cluster_site), and not scattered about the energy base";
    energy_cheapest: 1.0, 0.0, 1.0, "switch: the first tier of energy is the cheapest the builder can build (sim_barb's ENERGY_TIERS order), not the least metal for what it makes at the map's wind";
    turrets_first: 0.0, 0.0, 1.0, "switch: construction turret tasks come first with labs (sim_barb's order)";
    commander_energy: 0.0, 0.0, 1.0, "switch: its commander builds energy to keep up with its metal too";
    energy_cap: 0.0, 0.0, 1.0, "switch: no more energy tasks at once than one for every three builders";
    t2_energy_skip: 0.0, 0.0, 1.0, "switch: the advanced lab goes up without waiting on the energy it would use (as sim_barb's)";
    builders_resurrect: 1.0, 0.0, 1.0, "switch: constructors that can resurrect do (this game's can); off, only what cannot build does";
    workers_all: 1.0, 0.0, 1.0, "switch: every mobile builder counts as a worker (resurrection bots too)";
    lab_overflow: 1.01, 0.5, 1.01, "share of metal storage full over which it is time for another lab (1.01: never)";
    constructor_cap: 0.0, 0.0, 1.0, "switch: BARb's buildpower rule adds no constructors past builders_max";
    commander_reach: 70.0, 20.0, 200.0, "sim_barb's base_radius for its commander: studs from home it takes work within, helping its lab otherwise (BARb's 2000 elmos is 182)";
    commander_reach_after: 480.0, 0.0, 1500.0, "seconds after which its commander keeps within commander_reach";
    reserve_defences: 1.0, 0.0, 1.0, "switch: the extractor reserve counts builders on extractor clusters' defences too";
    escort_gate: 0.0, 0.0, 1.0, "switch: BARb's rule that an unescorted constructor takes no extractor in an undefended cluster in the first minutes (sim_barb has none)";
    builder_threat: 0.4, 0.0, 10.0, "the most enemy threat a builder's site or way may have (BARb builders avoid any)";
    t2_income: 20.0, 8.0, 60.0, "metal income at which it puts up an advanced lab (BARb's advanced labs' first income tier is 30)";
    t2_seconds: 600.0, 300.0, 1800.0, "seconds after which it puts up an advanced lab whatever its income";
    turret_income: 12.0, 4.0, 50.0, "metal income a second for each construction turret";
    energy_full: 0.88, 0.5, 1.0, "BARb economy script: share of energy storage over which energy is full (converters)";
    metal_full: 0.99, 0.6, 1.0, "BARb economy script: share of metal storage over which metal is full (storage, no reclaim)";
    energy_empty: 0.2, 0.0, 0.5, "BARb economy script: share of energy storage under which energy is empty (after 3 minutes)";
    metal_empty: 0.2, 0.0, 0.5, "BARb economy script: share of metal storage under which metal is empty (and over which builders help labs)";
    defence_after: 300.0, 0.0, 900.0, "BAR military script: defences go up after this many seconds, or at defence_income";
    defence_income: 10.0, 0.0, 40.0, "BAR military script: metal income at which defences go up";

    // Production ----------------------------------------------------------------------------------------------------
    response_weight: 1.0, 0.0, 3.0, "how much BARb's response table counts in choosing what to make (1 is BARb)";
    counter_sim_weight: 1.0, 0.0, 4.0, "how much the battle simulator's verdict of a unit against the enemy's army counts (0 is BARb alone)";
    counter_budget_seconds: 60.0, 15.0, 240.0, "seconds of income each candidate is simulated with";
    tier_weight_floor: 0.02, 0.0, 0.3, "weight given what BARb's tier table leaves at nothing, so the simulator can still pick it";
    num_batch: 3.0, 1.0, 8.0, "BARb behaviour.json num_batch: a response is made this many times over";
    lab_queue: 2.0, 1.0, 5.0, "units kept queued in each lab";

    // The army ------------------------------------------------------------------------------------------------------
    attack_thr: 0.7, 0.2, 2.0, "BARb thr_mod attack (0.6 to 0.8, drawn within 0.1 of this): an attack's power modifier is 0.8 over it";
    defence_thr: 0.4, 0.1, 1.5, "BARb thr_mod defence (0.3 to 0.5, drawn within 0.1 of this): a defend group is promoted at its power over it";
    attack_min_power: 60.0, 5.0, 300.0, "BARb quota attack: the least power a defend group is promoted to an attack at (over defence_thr)";
    raid_min_power: 6.0, 1.0, 60.0, "BARb quota raid: the power a defend group of raiders is promoted to a raid at (over defence_thr)";
    raid_max_power: 150.0, 20.0, 400.0, "BARb quota raid: the most power raids merge into";
    sim_gate: 1.0, 0.0, 1.0, "switch: an attack BARb's rule allows must also be won in the battle simulator";
    attack_margin: 0.1, -0.4, 0.8, "the least simulated margin an attack goes in with";
    retreat_margin: -0.25, -0.8, 0.2, "the simulated margin below which a fighting group pulls back";
    raid_margin: 0.3, -0.3, 1.0, "the least simulated margin a raid attacks with";
    army_threat_weight: 0.05, 0.0, 2.0, "how much its army's routes go round enemy threat";
    builder_threat_weight: 3.0, 0.1, 20.0, "how much its builders' routes go round enemy threat";
    raid_threat_weight: 1.0, 0.0, 10.0, "how much its raids' routes go round enemy threat";
    retreat_scale: 0.6, 0.0, 1.6, "times BARb's retreat health (behaviour.json: 0.5 for fighters, 0.85 for builders, or the unit's own)";
    chase_check: 1.0, 0.0, 1.0, "switch: no running after what outpaces the group's slowest and is getting away; a hunt that cannot catch its prey holds at what it threatens, hunters that keep up go first, and squads aim where a mover is going";
    kite: 1.0, 0.0, 1.0, "switch: units that outrange what they fight keep out of its reach";
    commander_dgun: 1.0, 0.0, 1.0, "switch: its commander fires its manual weapon at what comes near";
    sim_horizon: 30.0, 10.0, 90.0, "seconds a simulated fight is played for";
    sim_reinforce: 12.0, 0.0, 45.0, "seconds within which enemies that could join a fight are counted in it";

    // Where it is winning and losing, and desperation ----------------------------------------------------------------
    front_region: 64.0, 32.0, 160.0, "the size of the regions it tracks winning and losing in, in studs";
    front_memory: 40.0, 10.0, 150.0, "seconds over which it remembers what was lost where";
    front_contest: 1.3, 1.0, 3.0, "strength ratio at which a region is won or lost rather than contested";
    standing_income_weight: 90.0, 0.0, 300.0, "seconds of income a side's standing counts, beside its army and buildings";
    desperation_threshold: 0.6, 0.3, 0.95, "its standing against the enemy's under which it starts to be desperate";
    desperation_full: 0.3, 0.05, 0.7, "its standing at which it is fully desperate";
    desperation_trend: 1.0, 0.0, 4.0, "how much a falling standing adds to desperation, per the share it fell in the last minute";
    desperation_margin_drop: 0.0, 0.0, 1.5, "how far its attack margins fall at full desperation";
    desperation_all_in: 1.01, 0.3, 1.01, "desperation at which everything goes for the enemy's commander";
    winning_push: 2.0, 1.1, 5.0, "standing at which it goes all out to finish the enemy";
}

impl Params {
    pub fn on(value: f64) -> bool {
        value >= 0.5
    }
}
