//! What BARb (BAR's computer player: CircuitAI's "barbarian" branch, with its settings in Beyond-All-Reason's
//! luarules/configs/BARb/stable/config/hard) says about this game's units, from data/barb.json (barb_import.py builds
//! it): each unit's roles and retreat health and the modifiers on its threat and power (behaviour.json), how likely
//! each lab is to make it at each income tier (factory.json), and what each role is made in answer to
//! (response.json).

#![allow(dead_code)]

use serde::Deserialize;
use crate::HashMap;

const DATA: &str = include_str!("../data/barb.json");

#[derive(Deserialize, Debug, Clone, Default)]
pub struct Threat {
    pub air: Option<f64>,
    pub surf: Option<f64>,
    pub water: Option<f64>,
    pub default: Option<f64>,
    #[serde(default)]
    pub vs: HashMap<String, f64>,
}

#[derive(Deserialize, Debug, Clone, Default)]
pub struct UnitInfo {
    pub bar: String,
    #[serde(default)]
    pub role: Vec<String>,
    #[serde(default)]
    pub attribute: Vec<String>,
    pub retreat: Option<f64>,
    pub power: Option<f64>,
    pub threat: Option<Threat>,
    #[serde(default)]
    pub tiers: HashMap<String, Vec<f64>>,
    #[serde(default)]
    pub income_tier: Vec<f64>,
    pub native_lab: Option<String>,
    /// behaviour.json: seconds before which it is not built, the most of it, and its goal build time's modifier
    pub since: Option<f64>,
    pub limit: Option<f64>,
    pub build_mod: Option<f64>,
    pub build_speed: Option<f64>,
}

#[derive(Deserialize, Debug, Clone)]
pub struct Response {
    #[serde(default)]
    pub vs: Vec<String>,
    #[serde(default)]
    pub ratio: Vec<f64>,
    #[serde(default)]
    pub importance: Vec<f64>,
    #[serde(default = "one")]
    pub max_percent: f64,
    #[serde(default = "one")]
    pub eps_step: f64,
}

fn one() -> f64 {
    1.0
}

#[derive(Deserialize, Debug, Clone)]
pub struct EnergyEntry {
    pub def: String,
    /// [limit_min, limit_max, metal_income, energy_income, score]; what is missing is BARb's default
    pub cond: Vec<f64>,
}

#[derive(Deserialize, Debug, Clone)]
pub struct Economy {
    pub factor: Vec<[f64; 2]>,
    pub buildpower: f64,
    pub goal_exec: f64,
    pub mex_up: f64,
    pub build_mod: f64,
    pub cluster_range: f64,
    pub mex_max: serde_json::Value,
    pub ms_pull: Vec<[f64; 2]>,
    pub eps_step: f64,
    pub excess: f64,
    pub min_income: f64,
    pub cost_ratio: f64,
    pub em_ratio: f64,
    pub energy_land: Vec<EnergyEntry>,
    /// [newFacModM, newFacModE, facModM, facModE]
    pub production: Vec<f64>,
    pub assist: Vec<String>,
}

#[derive(Deserialize, Debug, Clone)]
pub struct Porcupine {
    /// BARb's defender list, each index as this game's unit(s)
    pub defenders: Vec<Vec<String>>,
    /// the indices of `defenders` a land cluster is given, in order
    pub land: Vec<usize>,
    pub prevent: f64,
    pub amount: serde_json::Value,
    pub point_range: f64,
    /// [index into defenders, seconds]
    pub base: Vec<[f64; 2]>,
}

#[derive(Deserialize, Debug, Clone)]
pub struct ChainStep {
    pub unit: String,
    #[serde(default)]
    pub priority: Option<String>,
    #[serde(default)]
    pub offset: Option<serde_json::Value>,
    #[serde(default)]
    pub condition: Option<serde_json::Value>,
}

#[derive(Deserialize, Debug, Clone)]
pub struct Chain {
    pub category: String,
    #[serde(default)]
    pub porc: bool,
    #[serde(default)]
    pub hub: Vec<Vec<ChainStep>>,
}

#[derive(Deserialize, Debug, Clone)]
pub struct FactoryInfo {
    pub bar: String,
    pub importance: Vec<f64>,
    pub caretaker: f64,
    #[serde(default)]
    pub require_energy: bool,
}

#[derive(Deserialize, Debug, Clone)]
pub struct Hide {
    pub time: f64,
    pub threat: f64,
    #[serde(default)]
    pub air: bool,
    pub task_rad: Vec<f64>,
}

#[derive(Deserialize, Debug, Clone)]
pub struct CommanderInfo {
    pub hide: Hide,
    pub assist_fac: f64,
}

#[derive(Deserialize, Debug, Clone)]
struct Raw {
    quota: serde_json::Value,
    retreat: serde_json::Value,
    units: HashMap<String, UnitInfo>,
    response: serde_json::Map<String, serde_json::Value>,
    economy: Economy,
    defence: serde_json::Value,
    porcupine: Porcupine,
    build_chain: HashMap<String, Chain>,
    factories: HashMap<String, FactoryInfo>,
    commanders: HashMap<String, CommanderInfo>,
    #[serde(default)]
    bar_names: HashMap<String, String>,
    #[serde(default)]
    select: serde_json::Value,
}

pub struct Barb {
    pub units: HashMap<String, UnitInfo>,
    /// BAR's name for each of this game's defs that has one
    pub bar_names: HashMap<String, String>,
    /// our role -> what it answers
    pub responses: HashMap<String, Response>,
    pub response_weight: f64,
    pub importance_mod: f64,
    pub economy: Economy,
    pub thr_attack: [f64; 2],
    pub thr_defence: [f64; 2],
    pub thr_comm: f64,
    pub quota_attack: f64,
    pub quota_raid: [f64; 2],
    pub num_batch: f64,
    pub retreat_builder: f64,
    pub retreat_fighter: f64,
    pub quota_scout: f64,
    pub porcupine: Porcupine,
    pub build_chain: HashMap<String, Chain>,
    pub factories: HashMap<String, FactoryInfo>,
    pub commanders: HashMap<String, CommanderInfo>,
    /// behaviour.json defence: base_rad, comm_rad (elmos), escort [builders, guards each, seconds]
    pub base_rad: [f64; 2],
    pub comm_rad: [f64; 2],
    pub escort: [f64; 3],
    /// factory.json select: [offset min, offset max, air map percent, speed percent]
    pub select: [f64; 4],
    /// behaviour.json quota aa_threat: [map size, threat] points
    pub aa_threat: Vec<[f64; 2]>,
}

fn pair(v: &serde_json::Value, a: f64, b: f64) -> [f64; 2] {
    [v.get(0).and_then(|x| x.as_f64()).unwrap_or(a), v.get(1).and_then(|x| x.as_f64()).unwrap_or(b)]
}

impl Barb {
    pub fn load() -> Barb {
        let raw: Raw = serde_json::from_str(DATA).expect("data/barb.json is not what barb_import.py writes");
        let mut responses = HashMap::default();
        let mut response_weight = 0.5;
        let mut importance_mod = 1.0;
        for (key, value) in &raw.response {
            match key.as_str() {
                "_weight_" => response_weight = value.as_f64().unwrap_or(0.5),
                "_importance_mod_" => importance_mod = value.as_f64().unwrap_or(1.0),
                _ => {
                    if let Ok(r) = serde_json::from_value::<Response>(value.clone()) {
                        responses.insert(key.clone(), r);
                    }
                }
            }
        }
        let q = &raw.quota;
        let aa_threat: Vec<[f64; 2]> = q["aa_threat"].as_array().map(|a| a.iter().map(|p| pair(p, 8.0, 500.0)).collect()).unwrap_or_default();
        let sel = &raw.select;
        let select = [
            sel["offset"][0].as_f64().unwrap_or(-20.0),
            sel["offset"][1].as_f64().unwrap_or(20.0),
            sel["air_map"].as_f64().unwrap_or(100.0),
            0.0,
        ];
        let thr = &q["thr_mod"];
        Barb {
            units: raw.units,
            bar_names: raw.bar_names,
            responses,
            response_weight,
            importance_mod,
            economy: raw.economy,
            thr_attack: pair(&thr["attack"], 1.0, 1.0),
            thr_defence: pair(&thr["defence"], 1.0, 1.0),
            thr_comm: thr["comm"].as_f64().unwrap_or(1.0),
            quota_attack: q["attack"].as_f64().unwrap_or(8.0),
            quota_raid: pair(&q["raid"], 3.0, 5.0),
            num_batch: q["num_batch"].as_f64().unwrap_or(1.0),
            retreat_builder: raw.retreat["builder"][0].as_f64().unwrap_or(0.85),
            retreat_fighter: raw.retreat["fighter"][0].as_f64().unwrap_or(0.5),
            quota_scout: q["scout"].as_f64().unwrap_or(3.0),
            porcupine: raw.porcupine,
            build_chain: raw.build_chain,
            factories: raw.factories,
            commanders: raw.commanders,
            base_rad: pair(&raw.defence["base_rad"], 1000.0, 3000.0),
            comm_rad: pair(&raw.defence["comm_rad"], 1000.0, 300.0),
            escort: [
                raw.defence["escort"][0].as_f64().unwrap_or(2.0),
                raw.defence["escort"][1].as_f64().unwrap_or(1.0),
                raw.defence["escort"][2].as_f64().unwrap_or(600.0),
            ],
            select,
            aa_threat,
        }
    }

    pub fn bar_name(&self, ours: &str) -> String {
        self.bar_names.get(ours).cloned().unwrap_or_default()
    }

    /// BARb's energy factor at `seconds` (EconomyManager ReadConfig and UpdateEconomy): only the first two points of
    /// economy.json's "factor" count, [start_factor, start_second] and [end_factor, end_second], linear between.
    pub fn energy_factor(&self, seconds: f64) -> f64 {
        let points = &self.economy.factor;
        let (f0, t0) = points.first().map(|p| (p[0], p[1])).unwrap_or((0.5, 300.0));
        let (f1, t1) = points.get(1).map(|p| (p[0], p[1])).unwrap_or((2.0, 3600.0));
        if seconds <= t0 {
            f0
        } else if seconds >= t1 {
            f1
        } else {
            f0 + (f1 - f0) * (seconds - t0) / (t1 - t0).max(1e-6)
        }
    }
}
