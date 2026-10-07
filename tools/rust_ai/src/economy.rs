//! BARb's EconomyManager (CircuitAI barbarian: module/EconomyManager.cpp; BAR's script/hard/manager/economy.as;
//! see PORTING.md): the economy's flags, and the tasks it puts in the builders' pool (builders.rs):
//!
//! - `update_metal_tasks` (a builder asks for work): energy while energy stalls; else an extractor upgrade, or an
//!   extractor on the nearest open spot along the cluster graph (metal.rs), or a converter when energy is full and
//!   metal is not, or reclaim;
//! - `update_energy_tasks`: economy.json's generator table, highest score first, the first under its limit whose
//!   income conditions are met;
//! - `update_factory_tasks` (every second): a construction turret by a factory that wants one, or a new factory when
//!   income covers it and it is time (factory.rs chooses which);
//! - `update_storage_tasks` (every second from 30 s): metal storage when metal is full, energy storage when it holds
//!   under 5 seconds of income;
//! - build chains when a building is finished (build_chain.json), and porcupine by extractors (porc.rs).

use crate::brain::Brain;
use crate::builders::{Builders, Kind, Priority, Task, ELMO, MAX_BUILD_SEC, THREAT_MIN};
use crate::defs::DefId;
use crate::map::P;
use crate::world::{Unit, World};
use crate::HashMap;

#[derive(Default, Clone, Debug)]
pub struct EcoState {
    pub metal: f64,
    pub energy: f64,
    pub metal_income: f64,
    pub energy_income: f64,
    pub metal_capacity: f64,
    pub energy_capacity: f64,
    pub metal_pull: f64,
    pub energy_pull: f64,
    pub metal_empty: bool,
    pub metal_full: bool,
    pub energy_empty: bool,
    pub energy_stalling: bool,
    pub energy_full: bool,
    pub assist_required: bool,
    /// BARb's buildpower: its builders' build speed (workertime / 20)
    pub buildpower: f64,
    pub builders: usize,
}

/// A generator as economy.json has it, with BARb's defaults filled in (InitEconomyScores).
#[derive(Clone, Debug)]
pub struct EnergyInfo {
    pub def: DefId,
    pub limit: f64,
    pub metal_income: f64,
    pub energy_income: f64,
    pub score: f64,
    pub make: f64,
    pub wind: bool,
}

#[derive(Default, Clone)]
pub struct Economy {
    pub state: EcoState,
    pub energy: Vec<EnergyInfo>,
    /// the cumulative metal made (times BARb's metalMod) and spent, for IsExcessed
    metal_produced: f64,
    metal_used: f64,
    last: f64,
    /// each cluster's last request for tasks (MakeEconomyTasks does one a second a cluster)
    cluster_frame: HashMap<usize, f64>,
    /// "enough metal, request energy"
    pub energy_required: bool,
    next_factory: f64,
    next_storage: f64,
    pub line: Option<String>,
    wind_sum: f64,
    wind_n: f64,
    pub debug: serde_json::Value,
    /// since when its metal has been all but full (for another lab)
    overflow_since: Option<f64>,
    /// choose energy as if it were stalling (a proactive energy build, `energy_wanted`)
    pub force_energy: bool,
    initialized: bool,
    /// each generator's limit (economy.json's cond), drawn once
    energy_limits: HashMap<DefId, f64>,
    /// can a builder def upgrade extractors (SetCanUpMex), by def
    can_up_mex: HashMap<DefId, bool>,
}

impl Economy {
    pub fn new() -> Economy {
        Economy::default()
    }

    pub fn line_name(&self) -> String {
        match self.line.as_deref() {
            Some("vehicles") => "vehicle".to_string(),
            Some("bots") => "bot".to_string(),
            Some(other) => other.to_string(),
            None => "none".to_string(),
        }
    }

    /// The line it plays: the hello's, else bots unless only vehicles can walk to the enemy.
    pub fn resolve_line(&mut self, brain: &Brain) {
        if self.line.is_some() {
            return;
        }
        let wanted = match brain.line.as_deref() {
            Some("vehicle") | Some("vehicles") => "vehicles",
            Some("bot") | Some("bots") => "bots",
            _ => {
                let can = |cat: &str| -> bool {
                    brain.defs.labs.get(cat).and_then(|l| l.0).and_then(|lab| brain.defs.constructor_of(lab)).map_or(false, |c| {
                        brain.map.reachable(brain.defs.list[c].m.ground.as_deref(), brain.home, brain.enemy_home)
                    })
                };
                if can("bots") || !can("vehicles") {
                    "bots"
                } else {
                    "vehicles"
                }
            }
        };
        self.line = Some(wanted.to_string());
    }

    fn avg_wind(&self) -> f64 {
        if self.wind_n > 0.0 {
            self.wind_sum / self.wind_n
        } else {
            10.0
        }
    }

    /// The generators of economy.json that this game has, scored as BARb scores them (wind at the average wind so
    /// far), highest first.
    fn init_energy(&mut self, brain: &mut Brain) {
        let mut infos = Vec::new();
        let wind = self.avg_wind();
        for e in brain.barb.economy.energy_land.clone() {
            let Some(def) = brain.defs.get(&e.def) else { continue };
            let d = brain.defs.list[def].clone();
            let is_wind = d.m.wind > 0.0;
            let make = if is_wind { (d.m.wind * 25.0).min(wind) } else { d.energy_make };
            let c = &e.cond;
            let min = c.first().copied().unwrap_or(1.0);
            let max = c.get(1).copied().unwrap_or(min);
            let limit = *self.energy_limits.entry(def).or_insert_with(|| min + ((brain.rng.unit() * (max - min + 1.0)).floor()).min(max - min));
            let mi = c.get(2).copied().filter(|v| *v >= 0.0).unwrap_or_else(|| (d.m.metal * 16.0 / MAX_BUILD_SEC).sqrt());
            let ei = c.get(3).copied().filter(|v| *v >= 0.0).unwrap_or(d.m.energy * brain.barb.economy.cost_ratio);
            // BARb's size is in map squares (16 elmos)
            let squares = |half: f64| (2.0 * half / ELMO / 16.0).max(1.0);
            let score = c.get(4).copied().filter(|v| *v >= 0.0).unwrap_or_else(|| make * make / (d.m.metal.max(1.0) * squares(d.m.half_x) * squares(d.m.half_z)));
            infos.push(EnergyInfo { def, limit, metal_income: mi, energy_income: ei, score, make, wind: is_wind });
        }
        infos.sort_by(|a, b| b.score.total_cmp(&a.score));
        self.energy = infos;
    }

    /// BARb's economy script's flags, and what its manager keeps (UpdateEconomy).
    pub fn update_state(&mut self, brain: &Brain, world: &World) {
        let t = world.my_team();
        let now = brain.now;
        let dt = (now - self.last).max(0.0);
        let first = self.last == 0.0;
        self.last = now;
        self.wind_sum += world.wind;
        self.wind_n += 1.0;
        let mut s = EcoState {
            metal: t.metal,
            energy: t.energy,
            metal_income: t.metal_income,
            energy_income: t.energy_income,
            metal_capacity: t.metal_capacity.max(1.0),
            energy_capacity: t.energy_capacity.max(1.0),
            metal_pull: t.metal_expense,
            energy_pull: t.energy_expense,
            ..Default::default()
        };
        s.metal_empty = s.metal < s.metal_capacity * brain.params.metal_empty;
        s.metal_full = s.metal > s.metal_capacity * brain.params.metal_full;
        if now < 180.0 {
            s.energy_empty = false;
            s.energy_stalling = s.energy_income < s.energy_pull && s.energy < s.energy_capacity * 0.3;
        } else {
            s.energy_empty = s.energy < s.energy_capacity * brain.params.energy_empty;
            s.energy_stalling = s.energy_empty || (s.energy_income < s.energy_pull && s.energy < s.energy_capacity * 0.6);
        }
        s.energy_full = s.energy > s.energy_capacity * brain.params.energy_full;
        s.assist_required = s.metal > s.metal_capacity * brain.params.metal_empty && !s.energy_stalling;
        for &i in &world.own {
            let u = &world.units[i];
            let d = &brain.defs.list[u.def];
            if u.built && d.mobile && d.m.buildpower > 0.0 && d.m.assists && !d.air {
                s.buildpower += d.build_speed;
                s.builders += 1;
            }
        }
        // metalMod = 1 - excess (economy.json excess -1: metal made counts double)
        let metal_mod = 1.0 - brain.barb.economy.excess;
        if first {
            self.metal_produced = t.metal * metal_mod;
        }
        self.metal_produced += s.metal_income * metal_mod * dt;
        self.metal_used += s.metal_pull * dt;
        self.state = s;
    }

    /// sim_barb's energy_wanted (server/ai/economy_planner.luau): its metal income times an energy factor that grows
    /// from energy_ratio_start to energy_ratio_end over energy_ratio_seconds, and what its converters burn.
    pub fn energy_wanted(&self, brain: &Brain, world: &World) -> f64 {
        let p = &brain.params;
        let along = (brain.now / p.energy_ratio_seconds.max(1.0)).clamp(0.0, 1.0);
        let factor = p.energy_ratio_start + (p.energy_ratio_end - p.energy_ratio_start) * along;
        let burn: f64 = world
            .own
            .iter()
            .map(|&i| &world.units[i])
            .filter(|u| u.built)
            .map(|u| brain.defs.list[u.def].m.convert_energy)
            .sum();
        self.state.metal_income * factor + burn
    }

    pub fn is_excessed(&self) -> bool {
        self.metal_produced > self.metal_used
    }

    /// BARb's pullMtoS: how much of the factories' metal pull the builders may have before they yield, by how many
    /// spots are taken (economy.json ms_pull), times how the army stands against the enemy's (ClampMobileCostRatio).
    pub fn pull_m_to_s(&self, brain: &Brain, army_cost: f64, enemy_mobile_cost: f64) -> f64 {
        let spots = brain.metal.spots.len().max(1) as f64;
        let mex = brain.metal.mine.iter().filter(|m| **m).count() as f64;
        let points: Vec<(f64, f64)> = brain.barb.economy.ms_pull.iter().map(|p| (p[1] * spots, p[0])).collect();
        let pull = if points.is_empty() {
            1.0
        } else if mex <= points[0].0 {
            points[0].1
        } else if mex >= points[points.len() - 1].0 {
            points[points.len() - 1].1
        } else {
            let mut v = points[0].1;
            for w in points.windows(2) {
                if mex >= w[0].0 && mex <= w[1].0 {
                    v = w[0].1 + (w[1].1 - w[0].1) * (mex - w[0].0) / (w[1].0 - w[0].0).max(1e-6);
                }
            }
            v
        };
        let clamp = if enemy_mobile_cost > army_cost { army_cost / enemy_mobile_cost.max(1e-6) } else { 1.0 };
        pull * clamp
    }

    /// IsIgnorePull: extractors do not count toward the builders' pull while there is no extractor cap.
    pub fn ignores_pull(&self, t: &Task) -> bool {
        t.kind == Kind::Mex
    }

    /// IsIgnoreStallingPull: extractors, and energy while energy stalls, may be built while metal stalls.
    pub fn ignores_stalling_pull(&self, t: &Task) -> bool {
        t.kind == Kind::Mex || (t.kind == Kind::Energy && self.state.energy_stalling)
    }

    /// IsEnoughEnergy: whether there is the energy for `u` to build `t` while metal lasts, and after.
    pub fn is_enough_energy(&self, t: &Task, u: &Unit, brain: &Brain, m: f64) -> bool {
        if t.kind == Kind::Energy {
            return true;
        }
        let Some(def) = t.def else { return true };
        let s = &self.state;
        let bd = &brain.defs.list[def];
        let worker = brain.defs.list[u.def].m.buildpower.max(1e-6);
        let build_time = bd.m.buildtime / worker;
        let deficit = s.metal - ((s.metal_pull - s.metal_income) * build_time + bd.m.metal);
        if deficit >= 0.0 {
            return s.energy > (s.energy_pull - s.energy_income) * build_time + bd.m.energy * m;
        }
        let mi_require = bd.m.metal / build_time.max(1e-6);
        let time_to_deficit = s.metal / (s.metal_pull + mi_require - s.metal_income).max(1e-6);
        let deficit_time = build_time - time_to_deficit;
        let inv_avail = (s.metal_pull + mi_require) / s.metal_income.max(1e-6);
        let ei_require = bd.m.energy / build_time.max(1e-6) * m;
        s.energy > (s.energy_pull + ei_require - s.energy_income) * time_to_deficit + (s.energy_pull + ei_require - s.energy_income * inv_avail) * deficit_time
    }

    /// IsEnoughEnergyIncome: the energy income covers building `def` over its build time (no less than 20 s).
    pub fn is_enough_energy_income(&self, def: DefId, u: &Unit, brain: &Brain) -> bool {
        let bd = &brain.defs.list[def];
        let build_time = bd.m.buildtime / brain.defs.list[u.def].m.buildpower.max(1e-6);
        self.state.energy_income > bd.m.energy / build_time.max(crate::builders::EARLY_BUILD_SEC)
    }

    // Tasks ---------------------------------------------------------------------------------------------------------

    /// MakeEconomyTasks: once a second for each cluster, the metal tasks from where a builder stands.
    pub fn make_economy_tasks(&mut self, b: &mut Builders, brain: &mut Brain, world: &World, u: &Unit) {
        if !b.can_enqueue(8) {
            return;
        }
        if let Some(c) = brain.metal.nearest_cluster(u.p) {
            if self.cluster_frame.get(&c).map_or(false, |&t| t + 1.0 > brain.now) {
                return;
            }
            self.cluster_frame.insert(c, brain.now);
        }
        self.update_metal_tasks(b, brain, world, u);
    }

    fn update_metal_tasks(&mut self, b: &mut Builders, brain: &mut Brain, world: &World, u: &Unit) -> Option<u64> {
        if !b.can_enqueue(16) {
            return None;
        }
        if self.state.energy_stalling {
            return self.update_energy_tasks(b, brain, world, u.p, Some(u));
        }
        let d = brain.defs.list[u.def].clone();
        let now = brain.now;
        // extractor upgrades
        let mex_up_max = brain.barb.economy.mex_up;
        if (b.count_of(Kind::MexUp) as f64) < mex_up_max && self.state.metal_income > 10.0 {
            if let (Some(adv), Some(plain)) = (brain.defs.advanced_extractor, brain.defs.plain_extractor) {
                if d.options.contains(&adv) {
                    let upgrading: Vec<P> = b.tasks_of(Kind::MexUp).map(|t| t.pos).collect();
                    let found = {
                        let safe = |c: usize| brain.fields.danger(brain.metal.clusters[c].p) <= THREAT_MIN;
                        let accept = |s: usize| {
                            let sp = brain.metal.spots[s].0;
                            !upgrading.iter().any(|p| p.dist(sp) < 4.0)
                                && world.own.iter().any(|&i| world.units[i].def == plain && world.units[i].built && world.units[i].p.dist(sp) < 4.0)
                                && brain.map.reachable(d.m.ground.as_deref(), u.p, sp)
                        };
                        spot_to_upgrade(brain, u.p, &safe, &accept)
                    };
                    self.can_up_mex.insert(u.def, found.is_some());
                    if let Some(s) = found {
                        let pos = brain.metal.spots[s].0;
                        let id = b.enqueue(now, Kind::MexUp, Priority::High, Some(adv), pos, 0.0, true, 0.0, brain);
                        b.tasks.get_mut(&id).unwrap().spot = Some(s);
                        return Some(id);
                    }
                }
            }
        }
        // an extractor on the nearest open spot
        let can_up = self.can_up_mex.get(&u.def).copied().unwrap_or(false);
        if let Some(mex) = brain.defs.plain_extractor.filter(|m| d.options.contains(m)) {
            if (self.state.metal_income < 100.0 || !self.state.metal_full) && !can_up {
                let found = {
                    let safe = |c: usize| brain.fields.danger(brain.metal.clusters[c].p) <= THREAT_MIN;
                    let accept = |s: usize| {
                        let sp = brain.metal.spots[s].0;
                        !brain.metal.taken[s]
                            && !b.blocked_site(mex, sp)
                            && brain.fields.influence_at(sp) >= -0.01
                            && brain.map.reachable(d.m.ground.as_deref(), u.p, sp)
                            && brain.fields.danger(sp) <= THREAT_MIN
                    };
                    brain.metal.spot_to_build(u.p, &safe, &accept)
                };
                if let Some(s) = found {
                    let pos = brain.metal.spots[s].0;
                    brain.metal.taken[s] = true;
                    let id = b.enqueue(now, Kind::Mex, Priority::High, Some(mex), pos, 0.0, true, 0.0, brain);
                    b.tasks.get_mut(&id).unwrap().spot = Some(s);
                    return Some(id);
                }
            }
        }
        // converters when energy is full and metal is not
        let guard_num = brain.barb.escort[0] as usize;
        if self.state.energy_full && !self.state.metal_full && b.count_of(Kind::Convert) < 2 && (b.count_of(Kind::Mex) == 0 || b.workers > guard_num + 1) {
            let best = d
                .options
                .iter()
                .copied()
                .filter(|&o| brain.defs.list[o].m.convert_energy > 0.0)
                .max_by(|&a, &c| brain.defs.list[a].m.convert_metal.total_cmp(&brain.defs.list[c].m.convert_metal));
            if let Some(c) = best {
                let pos = brain.metal_base();
                return Some(b.enqueue(now, Kind::Convert, Priority::Normal, Some(c), pos, 0.0, true, 0.0, brain));
            }
        }
        self.update_reclaim_tasks(b, brain, world, u, true)
    }

    /// sim_barb's extractor upgrades (server/ai/economy_planner.luau `extractor_upgrade`): an advanced constructor
    /// upgrades the nearest of its extractors it can safely get to, while fewer upgrades are under way than it has
    /// advanced constructors.
    pub fn upgrade_task(&mut self, b: &mut Builders, brain: &mut Brain, world: &World, u: &Unit) -> Option<u64> {
        let (adv, plain) = (brain.defs.advanced_extractor?, brain.defs.plain_extractor?);
        let d = brain.defs.list[u.def].clone();
        if !d.options.contains(&adv) {
            return None;
        }
        let advanced_builders = world.own.iter().filter(|&&i| brain.defs.list[world.units[i].def].options.contains(&adv) && brain.defs.list[world.units[i].def].mobile).count();
        if b.count_of(Kind::MexUp) >= advanced_builders.max(1) {
            return None;
        }
        let upgrading: Vec<P> = b.tasks_of(Kind::MexUp).map(|t| t.pos).collect();
        let found = {
            let safe = |c: usize| brain.fields.danger(brain.metal.clusters[c].p) <= THREAT_MIN;
            let accept = |s: usize| {
                let sp = brain.metal.spots[s].0;
                !upgrading.iter().any(|p| p.dist(sp) < 4.0)
                    && world.own.iter().any(|&i| world.units[i].def == plain && world.units[i].built && world.units[i].p.dist(sp) < 4.0)
                    && brain.map.reachable(d.m.ground.as_deref(), u.p, sp)
            };
            spot_to_upgrade(brain, u.p, &safe, &accept)
        }?;
        let pos = brain.metal.spots[found].0;
        let id = b.enqueue(brain.now, Kind::MexUp, Priority::High, Some(adv), pos, 0.0, true, 0.0, brain);
        b.tasks.get_mut(&id).unwrap().spot = Some(found);
        Some(id)
    }

    /// sim_barb's energy choice (server/ai/economy_planner.luau `energy_choice`), by tiers: fusion once its energy
    /// income is over advanced_energy_income (for a builder that can build it), advanced solar once it is over
    /// constructor_energy_income, else the first tier's generator that costs least metal for the energy it makes (a wind
    /// turbine at the wind seen so far; sim_barb takes the cheapest, wind whatever the wind). With a higher tier reached
    /// that this builder cannot build, nothing unless energy stalls, as sim_barb has it.
    pub fn scaled_energy(&self, brain: &Brain, u: &Unit) -> Option<DefId> {
        let ei = self.state.energy_income;
        let p = &brain.params;
        let d = &brain.defs.list[u.def];
        let can = |def: DefId| d.options.contains(&def) && brain.is_available(def);
        let named = |n: &str| brain.defs.get(n).filter(|&def| can(def));
        if ei >= p.advanced_energy_income {
            if let Some(f) = named("fusion_reactor") {
                return Some(f);
            }
        }
        if ei >= p.constructor_energy_income {
            if let Some(a) = named("advanced_solar_collector") {
                return Some(a);
            }
            if !self.state.energy_stalling && !d.commander {
                return None;
            }
        }
        let wind = self.avg_wind();
        // the first tier: what a commander builds (catalog.luau's ENERGY_TIERS, tier 0)
        let commander_builds = |o: DefId| brain.defs.list.iter().any(|c| c.commander && c.options.contains(&o));
        d.options
            .iter()
            .copied()
            .filter(|&o| can(o) && commander_builds(o))
            .filter(|&o| {
                let od = &brain.defs.list[o];
                od.is_building && od.tech < 2.0 && od.m.tidal <= 0.0 && od.m.spot.is_none() && od.m.convert_energy <= 0.0 && (od.energy_make > 0.0 || od.m.wind > 0.0)
            })
            .map(|o| {
                let od = &brain.defs.list[o];
                let make = if od.m.wind > 0.0 { (od.m.wind * wind).min(od.m.wind * 25.0) } else { od.energy_make };
                // sim_barb's tier is cheapest first: the energy it makes does not come into it
                if crate::params::Params::on(p.energy_cheapest) {
                    return (o, if make > 0.0 { od.m.metal } else { f64::INFINITY });
                }
                (o, od.m.metal.max(1.0) / make.max(1e-6))
            })
            .filter(|(_, per)| per.is_finite())
            .min_by(|a, b| a.1.total_cmp(&b.1))
            .map(|(o, _)| o)
    }

    /// sim_barb's conversion_task: an energy store or a converter while energy piles up (see builders.rs).
    pub fn conversion_task(&mut self, b: &mut Builders, brain: &mut Brain, world: &World, u: &Unit) -> Option<u64> {
        let s = self.state.clone();
        let p = brain.params.clone();
        let fill = s.energy / s.energy_capacity.max(1.0);
        // sim_barb's planner runs once its opening is done: not before its first lab (energy starts full)
        if brain.factory_count() == 0 || (fill < p.piling_fill && fill < p.energy_full) {
            return None;
        }
        let d = brain.defs.list[u.def].clone();
        let is_store = |o: DefId| {
            let od = &brain.defs.list[o];
            od.is_building && od.m.energy_storage > 0.0 && od.energy_make <= 0.0 && od.m.wind <= 0.0 && od.m.tidal <= 0.0 && od.m.convert_energy <= 0.0 && !od.factory && od.options.is_empty()
        };
        let store_wanted = p.converter_storage.max(s.energy_income * p.storage_seconds);
        let stores = world.own.iter().filter(|&&i| is_store(world.units[i].def)).count() as f64;
        if s.energy_capacity < store_wanted && stores < p.energy_stores_max {
            let store = d.options.iter().copied().filter(|&o| is_store(o) && brain.is_available(o)).min_by(|&a, &c| brain.defs.list[a].cost.total_cmp(&brain.defs.list[c].cost))?;
            if b.count_of(Kind::Store) > 0 {
                return None;
            }
            let (at, shake) = crate::builders::cluster_site(b, brain, world, store);
            return Some(b.enqueue(brain.now, Kind::Store, Priority::Normal, Some(store), at, shake, true, 0.0, brain));
        }
        if s.metal_full || b.count_of(Kind::Convert) as f64 >= p.converters_at_once {
            return None;
        }
        let burn = s.energy_income * p.converter_burn_share;
        let converter = d
            .options
            .iter()
            .copied()
            .filter(|&o| brain.defs.list[o].m.convert_energy > 0.0 && brain.defs.list[o].m.convert_energy <= burn && brain.is_available(o))
            .max_by(|&a, &c| brain.defs.list[a].m.convert_energy.total_cmp(&brain.defs.list[c].m.convert_energy))?;
        let at = brain.metal_base();
        Some(b.enqueue(brain.now, Kind::Convert, Priority::Normal, Some(converter), at, 8.0 * 8.0 * ELMO, true, 0.0, brain))
    }

    /// UpdateReclaimTasks: the nearest remains worth anything, reachable safely.
    pub fn update_reclaim_tasks(&mut self, b: &mut Builders, brain: &mut Brain, world: &World, u: &Unit, near: bool) -> Option<u64> {
        let d = brain.defs.list[u.def].clone();
        if !d.m.reclaims {
            return None;
        }
        // resurrecting is for what cannot build (BAR's resurrection bots); this game's constructors can resurrect too
        let resurrect = d.m.resurrects && (d.options.is_empty() || crate::params::Params::on(brain.params.builders_resurrect));
        if (self.state.metal_full || b.count_of(Kind::Reclaim) >= b.workers / 2) && !resurrect {
            return None;
        }
        let distance = if near { d.speed * if self.state.metal_pull * 0.8 > self.state.metal_income { 60.0 } else { 20.0 } } else { f64::MAX };
        let mut best: Option<(f64, P)> = None;
        for r in &world.remains {
            if r.metal < 1.0 || u.p.dist(r.p) > distance {
                continue;
            }
            if resurrect && r.source.is_none() {
                continue;
            }
            if brain.fields.danger(r.p) > THREAT_MIN || !brain.map.reachable(d.m.ground.as_deref(), u.p, r.p) {
                continue;
            }
            let dd = u.p.dist2(r.p);
            if best.map_or(true, |(bd, _)| dd < bd) {
                best = Some((dd, r.p));
            }
        }
        let (_, p) = best?;
        let kind = if resurrect { Kind::Resurrect } else { Kind::Reclaim };
        if let Some(t) = b.tasks.values().find(|t| t.active && t.kind == kind && t.pos.dist(p) < 8.0) {
            return Some(t.id);
        }
        Some(b.enqueue(brain.now, kind, Priority::High, None, p, 0.0, true, 300.0, brain))
    }

    /// UpdateEnergyTasks.
    pub fn update_energy_tasks(&mut self, b: &mut Builders, brain: &mut Brain, world: &World, position: P, unit: Option<&Unit>) -> Option<u64> {
        if !b.can_enqueue(32) {
            return None;
        }
        // scored again each time: wind by the wind seen so far, as BARb scores it by the map's average
        self.init_energy(brain);
        self.initialized = true;
        let s = self.state.clone();
        let factor = brain.barb.energy_factor(brain.now);
        let metal_income = s.metal_income.min(s.energy_income) * factor;
        let buildpower = s.buildpower.min(metal_income);
        let energy_income = s.energy_income * if s.energy_stalling { 0.5 } else { 1.0 };
        let stalling = s.energy_stalling || self.energy_required || self.force_energy;
        let mut last_hope = stalling;
        let mut hope: Option<DefId> = None;
        let mut best: Option<DefId> = None;
        let mut best_dist = f64::MAX;
        let can_build = |def: DefId| -> bool {
            brain.is_available(def)
                && match unit {
                Some(u) => brain.defs.list[u.def].options.contains(&def),
                None => world.own.iter().any(|&i| brain.defs.list[world.units[i].def].options.contains(&def) && brain.defs.list[world.units[i].def].mobile),
            }
        };
        let count = |def: DefId| world.own.iter().filter(|&&i| world.units[i].def == def).count() as f64;
        let tasks_of = |def: DefId| b.tasks.values().filter(|t| t.active && t.kind == Kind::Energy && t.def == Some(def)).count() as f64;
        let wind = world.wind;
        let infos = self.energy.clone();
        for (i, e) in infos.iter().enumerate() {
            if !can_build(e.def) {
                continue;
            }
            let cost = brain.defs.list[e.def].m.metal.max(1.0);
            if count(e.def) < e.limit {
                last_hope = false;
                if tasks_of(e.def) < (buildpower / cost * 4.0 + 1.0).floor() {
                    if e.wind {
                        // checkWind: wind is worth it only against the next generator down
                        let lower = infos[i + 1..].iter().find(|l| l.metal_income < metal_income && l.energy_income < energy_income && can_build(l.def));
                        if let Some(l) = lower {
                            if wind * wind / (e.make * e.make).max(1e-6) * e.score <= l.score {
                                continue;
                            }
                        }
                    }
                    if e.metal_income < metal_income && e.energy_income < energy_income {
                        best = Some(e.def);
                        break;
                    }
                    let res_dist = (e.metal_income - metal_income).max(0.0) + brain.barb.economy.em_ratio * (e.energy_income - energy_income).max(0.0);
                    if res_dist < best_dist {
                        best_dist = res_dist;
                        best = Some(e.def);
                    }
                } else if e.metal_income < metal_income && e.energy_income < energy_income {
                    best = None;
                    break;
                }
            } else if !stalling {
                best = None;
                break;
            } else if hope.is_none() {
                hope = Some(e.def);
                last_hope = last_hope && tasks_of(e.def) < (buildpower / cost * 4.0 + 1.0).floor();
            }
        }
        if last_hope {
            best = hope;
        }
        // sim_barb's tiers for whoever builds it: this builder, or, asked for no builder in particular, its constructors
        // (else its commander); BARb's table only where the tiers name nothing
        let chooser = unit.cloned().or_else(|| {
            let mut own: Vec<&Unit> = world.own.iter().map(|&i| &world.units[i]).filter(|x| x.built && brain.defs.list[x.def].mobile && !brain.defs.list[x.def].options.is_empty()).collect();
            own.sort_by_key(|x| (brain.defs.list[x.def].commander, x.id));
            own.first().map(|x| (*x).clone())
        });
        let def = chooser.as_ref().and_then(|u| self.scaled_energy(brain, u)).or(best)?;
        // no more energy under way at once than sim_barb has (one build for every three builders): past that, the
        // open energy task with the fewest on it
        let at_once = ((b.workers + 1) as f64 / 3.0).ceil().max(1.0) as usize;
        if crate::params::Params::on(brain.params.energy_cap) && b.count_of(Kind::Energy) >= at_once {
            return b.tasks_of(Kind::Energy).min_by_key(|t| (t.units.len(), t.id)).map(|t| t.id);
        }
        // where: heavy energy at the base (main.as gives it the BASE attribute), the rest near base or the builder
        let d = brain.defs.list[def].clone();
        let base = brain.home;
        let pos = if d.m.metal >= 200.0 || position.dist(base) < 600.0 * ELMO || unit.map_or(false, |u| brain.defs.list[u.def].commander) {
            crate::builders::cluster_site(b, brain, world, def).0
        } else {
            let out = position.sub(brain.map_center()).norm();
            brain.map.clamp(position.add(out.scale(d.m.radius + 6.0 * 8.0 * ELMO)))
        };
        let priority = if stalling {
            if s.energy_empty {
                Priority::Now
            } else {
                Priority::High
            }
        } else {
            Priority::Normal
        };
        Some(b.enqueue(brain.now, Kind::Energy, priority, Some(def), pos, 0.0, true, 0.0, brain))
    }

    /// UpdateStorageTasks (every second after 30 s).
    pub fn update_storage_tasks(&mut self, b: &mut Builders, brain: &mut Brain, world: &World) {
        if brain.now < self.next_storage {
            return;
        }
        self.next_storage = brain.now + 1.0;
        if brain.now < 30.0 || !b.can_enqueue(32) || b.count_of(Kind::Store) > 0 {
            return;
        }
        let s = self.state.clone();
        let buildable = |f: &dyn Fn(&crate::defs::Def) -> bool| -> Option<DefId> {
            world
                .own
                .iter()
                .flat_map(|&i| brain.defs.list[world.units[i].def].options.iter().copied())
                .filter(|&o| f(&brain.defs.list[o]) && brain.is_available(o))
                .max_by(|&a, &c| {
                    let sa = brain.defs.list[a].m.metal_storage.max(brain.defs.list[a].m.energy_storage) / brain.defs.list[a].m.metal.max(1.0);
                    let sc = brain.defs.list[c].m.metal_storage.max(brain.defs.list[c].m.energy_storage) / brain.defs.list[c].m.metal.max(1.0);
                    sa.total_cmp(&sc)
                })
        };
        let mut store = None;
        if s.metal_full {
            store = buildable(&|d| d.is_building && d.m.metal_storage > 0.0 && d.m.metal_income == 0.0 && !d.factory && d.m.buildpower == 0.0);
        }
        if store.is_none() && !(s.energy_capacity > 5.0 * s.energy_income || s.energy_empty) {
            store = buildable(&|d| d.is_building && d.m.energy_storage > 0.0 && d.energy_make == 0.0 && d.m.wind == 0.0 && d.m.convert_energy == 0.0 && !d.factory);
        }
        if let Some(def) = store {
            let pos = brain.home;
            b.enqueue(brain.now, Kind::Store, Priority::High, Some(def), pos, 0.0, true, 0.0, brain);
        }
    }

    /// UpdateFactoryTasks (every second; every thought until the first factory): a construction turret, or a new
    /// factory.
    pub fn update_factory_tasks(&mut self, b: &mut Builders, brain: &mut Brain, world: &World) {
        let factories: Vec<Unit> = world
            .own
            .iter()
            .map(|&i| world.units[i].clone())
            .filter(|u| u.built && brain.defs.list[u.def].factory && brain.defs.list[u.def].is_building)
            .collect();
        let is_start = factories.is_empty();
        // the first lab is the commander's opening's, while that is to come (builders.rs `plan_opening`)
        if is_start && b.opening.as_ref().map_or(true, |s| s.iter().any(|(k, _, _)| *k == Kind::Factory)) {
            return;
        }
        if !is_start && brain.now < self.next_factory {
            return;
        }
        self.next_factory = brain.now + 1.0;
        if !b.can_enqueue(64) || self.energy_required {
            return;
        }
        // sim_barb's advanced lab: its line's, once it makes t2_income metal or has played t2_seconds, whenever it is
        // time for a lab or not
        let line = self.line.clone().unwrap_or_else(|| "bots".to_string());
        let advanced = brain.defs.labs.get(&line).and_then(|l| l.1);
        let t2_due = advanced.map_or(false, |adv| {
            let has = world.own.iter().any(|&i| world.units[i].def == adv);
            let can = world.own.iter().any(|&i| brain.defs.list[world.units[i].def].options.contains(&adv));
            !is_start && !has && can && (self.state.metal_income >= brain.params.t2_income || brain.now >= brain.params.t2_seconds)
        });
        // metal it cannot spend (storage all but full) wants another lab too
        if self.state.metal > self.state.metal_capacity * brain.params.lab_overflow {
            self.overflow_since.get_or_insert(brain.now);
        } else {
            self.overflow_since = None;
        }
        let overflowing = brain.now > 600.0 && self.overflow_since.map_or(false, |t| brain.now - t >= 30.0);
        let switch_time = brain.factory.is_switch_time(brain.now, &self.state) || t2_due || overflowing;
        // sim_barb's construction turrets (server/ai/economy_planner.luau): one for every turret_income of metal income,
        // up to turrets_max, by the lab that has fewest
        if !is_start && b.count_of(Kind::Nano) == 0 {
            if let Some(assist) = brain.barb.economy.assist.iter().find_map(|n| brain.defs.get(n)) {
                let turrets: Vec<P> = world.own.iter().map(|&i| &world.units[i]).filter(|u| u.def == assist).map(|u| u.p).collect();
                let wanted = (self.state.metal_income / brain.params.turret_income.max(1.0)).floor().min(brain.params.turrets_max);
                let can = world.own.iter().any(|&i| brain.defs.list[world.units[i].def].options.contains(&assist));
                if can && (turrets.len() as f64) < wanted {
                    let range = brain.defs.list[assist].m.build_range.max(8.0);
                    if let Some(lab) = factories.iter().min_by_key(|f| turrets.iter().filter(|t| t.dist(f.p) < range).count()) {
                        let back = brain.toward_enemy().scale(-64.0 * ELMO);
                        b.enqueue(brain.now, Kind::Nano, Priority::High, Some(assist), lab.p.add(back), 8.0 * 8.0 * ELMO, true, 0.0, brain);
                        return;
                    }
                }
            }
        }
        // a construction turret by a factory that wants one (CheckAssistRequired)
        if !switch_time && !is_start && self.check_assist_required(b, brain, world, &factories) {
            return;
        }
        if b.count_of(Kind::Factory) > 0 {
            return;
        }
        let mut factory = std::mem::take(&mut brain.factory);
        let fac = factory.factory_to_build(brain, world, is_start);
        brain.factory = factory;
        let Some(mut fac) = fac else { return };
        if let Some(adv) = advanced.filter(|_| t2_due) {
            fac = adv;
        }
        let commander = world.own.iter().map(|&i| world.units[i].clone()).find(|u| brain.defs.list[u.def].commander);
        let fd = brain.defs.list[fac].clone();
        let repr = brain.factory.representative(brain, fac);
        let s = self.state.clone();
        let p = brain.barb.economy.production.clone();
        let (mi_require, ei_require) = match (is_start, &commander) {
            (true, Some(c)) => {
                let t = fd.m.buildtime / brain.defs.list[c.def].m.buildpower.max(1e-6);
                (fd.m.metal / t * 0.25, fd.m.energy / t)
            }
            _ => match repr {
                Some(r) => {
                    let rd = &brain.defs.list[r];
                    let t = rd.m.buildtime / fd.m.buildpower.max(1e-6);
                    (rd.m.metal / t * p.first().copied().unwrap_or(0.8), rd.m.energy / t * p.get(1).copied().unwrap_or(0.8))
                }
                None => (0.0, 0.0),
            },
        };
        let metal_factor = s.metal_income - mi_require;
        let energy_factor = (s.energy_income - ei_require) * brain.barb.economy.em_ratio;
        let nanos = b.count_of(Kind::Nano) as f64;
        let (fac_metal, fac_energy) = brain.factory.require(brain, world);
        let assist_speed = brain.factory.assist_speed(brain);
        let factory_power = fac_metal * p.get(2).copied().unwrap_or(0.8) + nanos * assist_speed;
        let energy_power = fac_energy * p.get(3).copied().unwrap_or(0.8) * brain.barb.economy.em_ratio + nanos * assist_speed;
        if metal_factor < factory_power && !switch_time && !t2_due && (is_start || fd.m.metal > s.metal) {
            return;
        }
        // sim_barb's advanced lab does not wait on the energy it would use, only on a stall
        let banked = crate::params::Params::on(brain.params.energy_full_enough) && s.energy_full;
        if (energy_factor < energy_power && !(t2_due && crate::params::Params::on(brain.params.t2_energy_skip)) && !banked) || s.energy_stalling {
            self.energy_required = true;
            let at = commander.as_ref().map(|c| c.p).unwrap_or(brain.home);
            self.update_energy_tasks(b, brain, world, at, commander.as_ref());
            return;
        }
        let pos = if is_start { commander.as_ref().map(|c| c.p).unwrap_or(brain.home) } else { brain.factory.factory_site(brain, world, fac) };
        let priority = if b.workers <= 2 { Priority::Now } else { Priority::High };
        b.enqueue(brain.now, Kind::Factory, priority, Some(fac), pos, 8.0 * 8.0 * ELMO, true, 120.0, brain);
        brain.factory.apply_switch_frame(brain.now);
    }

    /// CheckAssistRequired: a construction turret by a factory that has fewer than it wants, if income covers it.
    fn check_assist_required(&mut self, b: &mut Builders, brain: &mut Brain, world: &World, factories: &[Unit]) -> bool {
        let nanos = b.count_of(Kind::Nano);
        let Some(fac) = brain.factory.need_upgrade(brain, world, factories, nanos) else { return false };
        let assist = brain.barb.economy.assist.iter().find_map(|n| brain.defs.get(n));
        let Some(assist) = assist else { return true };
        let ad = brain.defs.list[assist].clone();
        let repr = brain.factory.representative(brain, fac.def);
        let (mut mi, mut ei) = match repr {
            Some(r) => {
                let rd = &brain.defs.list[r];
                let t = rd.m.buildtime / ad.m.buildpower.max(1e-6);
                (rd.m.metal / t, rd.m.energy / t)
            }
            None => (ad.build_speed, ad.build_speed / brain.barb.economy.em_ratio.max(1e-6)),
        };
        let p = brain.barb.economy.production.clone();
        mi *= p.first().copied().unwrap_or(0.8);
        ei *= p.get(1).copied().unwrap_or(0.8);
        let (fac_metal, fac_energy) = brain.factory.require(brain, world);
        let s = self.state.clone();
        if s.metal_income < fac_metal * p.get(2).copied().unwrap_or(0.8) + (nanos as f64 + 1.0) * mi {
            return true;
        }
        let banked = crate::params::Params::on(brain.params.energy_full_enough) && s.energy_full;
        if (s.energy_income < fac_energy * p.get(3).copied().unwrap_or(0.8) + (nanos as f64 + 1.0) * ei && !banked) || s.energy_stalling {
            self.energy_required = true;
            self.update_energy_tasks(b, brain, world, fac.p, None);
            return true;
        }
        // 64 elmos behind the factory's door
        let back = brain.toward_enemy().scale(-64.0 * ELMO);
        let pos = fac.p.add(back);
        b.enqueue(brain.now, Kind::Nano, Priority::High, Some(assist), pos, 8.0 * 8.0 * ELMO, true, 0.0, brain);
        true
    }

    /// CheckMobileAssistRequired: help the factory building now, if there are the resources for 8 seconds of it.
    pub fn check_mobile_assist(&mut self, b: &mut Builders, brain: &mut Brain, world: &World, u: &Unit) -> Option<u64> {
        if !self.state.assist_required || !b.has_free_assists(u, brain, world) {
            return None;
        }
        let (lab, def) = brain.factory.current_recruit(world)?;
        let lab_unit = world.get(lab)?.clone();
        if lab_unit.p.dist(u.p) > 600.0 * ELMO {
            return None;
        }
        let rd = &brain.defs.list[def];
        let t = rd.m.buildtime / brain.defs.list[u.def].m.buildpower.max(1e-6);
        let (mi, ei) = (rd.m.metal / t, rd.m.energy / t);
        let s = &self.state;
        if s.metal > (s.metal_pull + mi - s.metal_income) * 8.0 && s.energy > (s.energy_pull + ei - s.energy_income) * 8.0 {
            let id = b.enqueue(brain.now, Kind::Guard, Priority::High, None, lab_unit.p, 0.0, true, 0.0, brain);
            let tk = b.tasks.get_mut(&id).unwrap();
            tk.target = Some(lab);
            tk.until = brain.now + 10.0;
            return Some(id);
        }
        None
    }

    /// Build chains (IBuilderTask::ExecuteChain): what goes up after a building of `def` at `pos` is finished.
    pub fn execute_chain(&mut self, b: &mut Builders, brain: &mut Brain, world: &World, def: DefId, pos: P) {
        let name = brain.defs.list[def].name.clone();
        let Some(chain) = brain.barb.build_chain.get(&name).cloned() else { return };
        if chain.porc {
            crate::porc::make_defence(b, brain, world, pos);
        }
        let enemy_air = world.enemy.iter().any(|&i| brain.defs.list[world.units[i].def].air && brain.defs.list[world.units[i].def].armed);
        let fwd = brain.enemy_home.sub(pos).norm();
        let side = P::new(-fwd.z, fwd.x);
        for queue in &chain.hub {
            let mut parent: Option<u64> = None;
            for step in queue {
                let Some(unit) = brain.defs.get(&step.unit).filter(|&d| brain.is_available(d)) else { continue };
                if let Some(cond) = &step.condition {
                    if cond.get("air").and_then(|v| v.as_bool()) == Some(true) && !enemy_air {
                        continue;
                    }
                    if let Some(chance) = cond.get("chance").and_then(|v| v.as_f64()) {
                        if brain.rng.unit() >= chance {
                            continue;
                        }
                    }
                }
                let offset = match &step.offset {
                    Some(serde_json::Value::Object(o)) => {
                        if let Some(f) = o.get("front").and_then(|v| v.as_f64()) {
                            fwd.scale(f * ELMO)
                        } else if let Some(bk) = o.get("back").and_then(|v| v.as_f64()) {
                            fwd.scale(-bk * ELMO)
                        } else {
                            P::new(0.0, 0.0)
                        }
                    }
                    Some(serde_json::Value::Array(a)) => {
                        let x = a.first().and_then(|v| v.as_f64()).unwrap_or(0.0) * ELMO;
                        let z = a.get(1).and_then(|v| v.as_f64()).unwrap_or(0.0) * ELMO;
                        side.scale(x).add(fwd.scale(z))
                    }
                    _ => P::new(0.0, 0.0),
                };
                let priority = match step.priority.as_deref() {
                    Some("now") => Priority::Now,
                    Some("high") => Priority::High,
                    Some("low") => Priority::Low,
                    _ => Priority::Normal,
                };
                let kind = if brain.defs.list[unit].factory { Kind::Factory } else { Kind::Defence };
                let at = brain.map.clamp(pos.add(offset));
                let id = b.enqueue(brain.now, kind, priority, Some(unit), at, 0.0, parent.is_none(), 0.0, brain);
                if let Some(pid) = parent {
                    if let Some(pt) = b.tasks.get_mut(&pid) {
                        pt.next = Some(id);
                    }
                }
                parent = Some(id);
            }
        }
    }
}

/// GetSpotToUpgrade: like GetSpotToBuild, but over clusters that have something to upgrade.
fn spot_to_upgrade(brain: &Brain, from: P, safe: &dyn Fn(usize) -> bool, accept: &dyn Fn(usize) -> bool) -> Option<usize> {
    let m = &brain.metal;
    let start = m.nearest_cluster(from)?;
    if !safe(start) {
        return None;
    }
    let mut order: Vec<usize> = (0..m.clusters.len()).filter(|&c| safe(c)).collect();
    order.sort_by(|&a, &b| m.clusters[a].p.dist2(from).total_cmp(&m.clusters[b].p.dist2(from)));
    for c in order {
        let found: Vec<usize> = m.clusters[c].spots.iter().copied().filter(|&s| accept(s)).collect();
        if let Some(s) = found.into_iter().min_by(|&a, &b| m.spots[a].0.dist2(from).total_cmp(&m.spots[b].0.dist2(from))) {
            return Some(s);
        }
    }
    None
}
