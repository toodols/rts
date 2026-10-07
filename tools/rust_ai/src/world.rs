//! What the team sees in one thought: every team's bank, and everything on the map, sorted into its own, the enemy's
//! and what lies about to be reclaimed.

#![allow(dead_code)]

use crate::defs::{DefId, Defs};
use crate::map::P;
use crate::protocol::{Observe, TeamMsg};
use crate::HashMap;

#[derive(Clone, Debug)]
pub struct Unit {
    pub id: i64,
    pub team: i64,
    pub def: DefId,
    pub p: P,
    pub v: P,
    pub hp: f64,
    pub mhp: f64,
    /// finished; a blueprint is not
    pub built: bool,
    pub progress: f64,
    pub order: Option<String>,
    pub order_target: Option<i64>,
    pub order_pos: Option<P>,
    pub orders: usize,
    pub build_def: Option<DefId>,
    pub build_pos: Option<P>,
    pub queue: Vec<DefId>,
    pub emp: f64,
    pub dgun_reload: f64,
}

impl Unit {
    pub fn idle(&self) -> bool {
        self.orders == 0
    }
    pub fn health_share(&self) -> f64 {
        if self.mhp > 0.0 {
            self.hp / self.mhp
        } else {
            1.0
        }
    }
}

#[derive(Clone, Debug)]
pub struct Remains {
    pub id: i64,
    pub p: P,
    pub metal: f64,
    pub energy: f64,
    pub work: f64,
    pub source: Option<DefId>,
}

pub struct World {
    pub time: f64,
    pub wind: f64,
    pub me: i64,
    pub enemies: Vec<i64>,
    pub teams: HashMap<i64, TeamMsg>,
    pub units: Vec<Unit>,
    pub by_id: HashMap<i64, usize>,
    /// indices into `units`
    pub own: Vec<usize>,
    pub enemy: Vec<usize>,
    pub remains: Vec<Remains>,
}

impl World {
    pub fn new(obs: &Observe, defs: &Defs, me: i64, enemies: &[i64]) -> World {
        let mut units = Vec::with_capacity(obs.entities.len());
        let mut remains = Vec::new();
        for e in &obs.entities {
            if e.k == "unit" || e.k == "building" {
                let def = match defs.get(&e.d) {
                    Some(d) => d,
                    None => continue,
                };
                let order_pos = match (e.ox, e.oz) {
                    (Some(x), Some(z)) => Some(P::new(x, z)),
                    _ => None,
                };
                let build_pos = match (e.bx, e.bz) {
                    (Some(x), Some(z)) => Some(P::new(x, z)),
                    _ => None,
                };
                units.push(Unit {
                    id: e.id,
                    team: e.t,
                    def,
                    p: P::new(e.x, e.z),
                    v: P::new(e.vx, e.vz),
                    hp: e.hp,
                    mhp: if e.mhp > 0.0 { e.mhp } else { defs.list[def].health },
                    built: e.bp.is_none(),
                    progress: e.bp.unwrap_or(1.0),
                    order: e.o.clone(),
                    order_target: e.ot,
                    order_pos,
                    orders: e.on,
                    build_def: e.od.as_deref().and_then(|n| defs.get(n)),
                    build_pos,
                    queue: e.q.iter().filter_map(|n| defs.get(n)).collect(),
                    emp: e.emp,
                    dgun_reload: e.dr,
                });
            } else if e.ml > 0.0 || e.el > 0.0 {
                remains.push(Remains {
                    id: e.id,
                    p: P::new(e.x, e.z),
                    metal: e.ml,
                    energy: e.el,
                    work: e.bl,
                    source: e.src.as_deref().and_then(|n| defs.get(n)),
                });
            }
        }
        let mut by_id = HashMap::with_capacity_and_hasher(units.len(), Default::default());
        let mut own = Vec::new();
        let mut enemy = Vec::new();
        for (i, u) in units.iter().enumerate() {
            by_id.insert(u.id, i);
            if u.team == me {
                own.push(i);
            } else if enemies.contains(&u.team) {
                enemy.push(i);
            }
        }
        let teams = obs
            .teams
            .iter()
            .filter_map(|(k, v)| k.parse::<i64>().ok().map(|t| (t, v.clone())))
            .collect();
        World { time: obs.time, wind: obs.wind, me, enemies: enemies.to_vec(), teams, units, by_id, own, enemy, remains }
    }

    pub fn get(&self, id: i64) -> Option<&Unit> {
        self.by_id.get(&id).map(|&i| &self.units[i])
    }

    pub fn my_team(&self) -> TeamMsg {
        self.teams.get(&self.me).cloned().unwrap_or_default()
    }

    pub fn enemy_team(&self) -> TeamMsg {
        let mut sum = TeamMsg::default();
        for t in &self.enemies {
            if let Some(m) = self.teams.get(t) {
                sum.metal += m.metal;
                sum.energy += m.energy;
                sum.metal_income += m.metal_income;
                sum.energy_income += m.energy_income;
                sum.metal_capacity += m.metal_capacity;
                sum.energy_capacity += m.energy_capacity;
            }
        }
        sum
    }
}
