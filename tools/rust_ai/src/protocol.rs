//! The lines of JSON the bridge (tools/rust_ai/bridge.luau) and this process pass each other: `Hello` once, then an
//! `Observe` a thought, each answered with an `Answer` of commands.

#![allow(dead_code)]

use serde::{Deserialize, Serialize};
use crate::HashMap;

/// Lune writes an empty table as `{}`, so a list may come as an empty object.
fn seq<'de, D, T>(d: D) -> Result<Vec<T>, D::Error>
where
    D: serde::Deserializer<'de>,
    T: Deserialize<'de>,
{
    #[derive(Deserialize)]
    #[serde(untagged)]
    enum Either<T> {
        List(Vec<T>),
        Map(serde_json::Map<String, serde_json::Value>),
    }
    match Either::<T>::deserialize(d)? {
        Either::List(v) => Ok(v),
        Either::Map(m) if m.is_empty() => Ok(Vec::new()),
        Either::Map(_) => Err(serde::de::Error::custom("expected a list")),
    }
}

#[derive(Deserialize, Debug, Clone)]
pub struct WeaponMsg {
    pub dps: f64,
    pub shot: f64,
    pub reload: f64,
    pub range: f64,
    pub splash: f64,
    pub edge: f64,
    pub flight: f64,
    pub scatter: f64,
    pub ground: bool,
    pub water: bool,
    pub air: bool,
    pub under: bool,
    pub anti_air: bool,
    pub manual: bool,
    pub anti_nuke: bool,
    pub paralyze: bool,
    pub group: Option<String>,
    #[serde(default)]
    pub energy_per_shot: f64,
    #[serde(default)]
    pub stockpile: bool,
}

#[derive(Deserialize, Debug, Clone)]
pub struct DefMsg {
    pub name: String,
    pub kind: String,
    pub category: String,
    pub tech: f64,
    pub metal: f64,
    pub energy: f64,
    pub buildtime: f64,
    pub health: f64,
    pub speed: f64,
    pub air: bool,
    pub bomber: bool,
    pub radius: f64,
    pub half_x: f64,
    pub half_z: f64,
    pub ground: Option<String>,
    pub buildpower: f64,
    pub build_range: f64,
    #[serde(default, deserialize_with = "seq")]
    pub options: Vec<String>,
    pub assists: bool,
    pub repairs: bool,
    pub reclaims: bool,
    pub resurrects: bool,
    pub factory: bool,
    pub commander: bool,
    pub metal_income: f64,
    pub energy_income: f64,
    pub wind: f64,
    pub tidal: f64,
    pub metal_storage: f64,
    pub energy_storage: f64,
    pub convert_energy: f64,
    pub convert_metal: f64,
    pub spot: Option<String>,
    #[serde(default, deserialize_with = "seq")]
    pub upgrades: Vec<String>,
    pub stealth: bool,
    pub autoheal: f64,
    pub death_radius: f64,
    pub death_damage: f64,
    #[serde(default, deserialize_with = "seq")]
    pub weapons: Vec<WeaponMsg>,
    pub dgun_range: f64,
    pub dgun_reload: f64,
    pub dgun_energy: f64,
    pub carrier_range: f64,
    pub carrier_drone: Option<String>,
    pub carrier_count: f64,
    pub immune: bool,
    pub objectify: bool,
    pub power: f64,
}

#[derive(Deserialize, Debug, Clone)]
pub struct SpotMsg {
    pub x: f64,
    pub z: f64,
    #[serde(default = "one")]
    pub m: f64,
}

fn one() -> f64 {
    1.0
}

#[derive(Deserialize, Debug, Clone)]
pub struct PointMsg {
    pub x: f64,
    pub z: f64,
}

#[derive(Deserialize, Debug, Clone)]
pub struct MapMsg {
    pub cells_x: usize,
    pub cells_z: usize,
    pub cell: f64,
    pub origin_x: f64,
    pub origin_z: f64,
    pub grounds: HashMap<String, String>,
    #[serde(default, deserialize_with = "seq")]
    pub heights: Vec<f64>,
    #[serde(default, deserialize_with = "seq")]
    pub metal: Vec<SpotMsg>,
    #[serde(default, deserialize_with = "seq")]
    pub geo: Vec<PointMsg>,
    pub starts: HashMap<String, PointMsg>,
}

#[derive(Deserialize, Debug, Clone)]
pub struct Constants {
    pub non_aa_air_fraction: f64,
    pub aa_non_air_damage: f64,
    pub range_margin: f64,
}

#[derive(Deserialize, Debug, Clone)]
pub struct Hello {
    pub team: i64,
    #[serde(default, deserialize_with = "seq")]
    pub enemies: Vec<i64>,
    pub line: Option<String>,
    pub constants: Constants,
    #[serde(default)]
    pub params: serde_json::Map<String, serde_json::Value>,
    pub log: Option<String>,
    pub map: MapMsg,
    #[serde(default, deserialize_with = "seq")]
    pub defs: Vec<DefMsg>,
}

#[derive(Deserialize, Debug, Clone, Default)]
pub struct TeamMsg {
    pub metal: f64,
    pub energy: f64,
    pub metal_income: f64,
    pub energy_income: f64,
    pub metal_capacity: f64,
    pub energy_capacity: f64,
    pub metal_revenue: f64,
    pub metal_expense: f64,
    pub energy_revenue: f64,
    pub energy_expense: f64,
}

#[derive(Deserialize, Debug, Clone)]
pub struct EntityMsg {
    pub id: i64,
    pub t: i64,
    pub d: String,
    pub k: String,
    pub x: f64,
    #[serde(default)]
    pub y: f64,
    pub z: f64,
    #[serde(default)]
    pub vx: f64,
    #[serde(default)]
    pub vz: f64,
    #[serde(default)]
    pub hp: f64,
    #[serde(default)]
    pub mhp: f64,
    pub bp: Option<f64>,
    pub o: Option<String>,
    pub ot: Option<i64>,
    pub ox: Option<f64>,
    pub oz: Option<f64>,
    #[serde(default)]
    pub on: usize,
    pub od: Option<String>,
    pub bx: Option<f64>,
    pub bz: Option<f64>,
    #[serde(default, deserialize_with = "seq")]
    pub q: Vec<String>,
    #[serde(default)]
    pub emp: f64,
    #[serde(default)]
    pub dr: f64,
    #[serde(default)]
    pub ml: f64,
    #[serde(default)]
    pub el: f64,
    #[serde(default)]
    pub bl: f64,
    pub src: Option<String>,
}

#[derive(Deserialize, Debug, Clone)]
pub struct ResultMsg {
    pub ok: bool,
    pub why: Option<String>,
    pub i: Option<usize>,
    pub tag: Option<String>,
    pub x: Option<f64>,
    pub z: Option<f64>,
}

#[derive(Deserialize, Debug, Clone)]
pub struct Observe {
    pub time: f64,
    pub wind: f64,
    pub teams: HashMap<String, TeamMsg>,
    #[serde(default, deserialize_with = "seq")]
    pub entities: Vec<EntityMsg>,
    #[serde(default, deserialize_with = "seq")]
    pub results: Vec<ResultMsg>,
}

/// A command for the bridge to carry out. Fields a command does not use are left out of the line.
#[derive(Serialize, Debug, Clone, Default)]
pub struct Command {
    pub c: &'static str,
    #[serde(skip_serializing_if = "Option::is_none")]
    pub u: Option<i64>,
    #[serde(skip_serializing_if = "Option::is_none")]
    pub path: Option<Vec<[f64; 2]>>,
    #[serde(skip_serializing_if = "Option::is_none")]
    pub def: Option<String>,
    #[serde(skip_serializing_if = "Option::is_none")]
    pub x: Option<f64>,
    #[serde(skip_serializing_if = "Option::is_none")]
    pub z: Option<f64>,
    #[serde(skip_serializing_if = "Option::is_none")]
    pub facing: Option<f64>,
    #[serde(skip_serializing_if = "Option::is_none")]
    pub search: Option<f64>,
    #[serde(skip_serializing_if = "Option::is_none")]
    pub target: Option<i64>,
    #[serde(skip_serializing_if = "Option::is_none")]
    pub radius: Option<f64>,
    #[serde(skip_serializing_if = "Option::is_none")]
    pub n: Option<u32>,
    #[serde(skip_serializing_if = "std::ops::Not::not")]
    pub queue: bool,
    #[serde(skip_serializing_if = "Option::is_none")]
    pub tag: Option<String>,
}

#[derive(Serialize, Debug)]
pub struct Answer {
    #[serde(rename = "type")]
    pub kind: &'static str,
    pub cmds: Vec<Command>,
    #[serde(skip_serializing_if = "Option::is_none")]
    pub report: Option<serde_json::Value>,
}
