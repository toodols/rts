//! BARb's FactoryManager (CircuitAI barbarian: module/FactoryManager.cpp `CreateFactoryTask`, `UpdateBuildPower`,
//! `RequiredFireDef`, `NeedUpgrade`, `EnableFactory`; unit/FactoryData.cpp `GetFactoryToBuild`;
//! module/MilitaryManager.cpp `RoleProbability`; BAR's script/hard/misc/commander.as openers and
//! script/hard/manager/factory.as switch time; see PORTING.md), with the battle simulator on top:
//!
//! - a new lab first makes BARb's opener for the BAR lab it stands for (only the first lab of a kind);
//! - then, one unit at a time: a constructor while buildpower is under `metal_income * bp_ratio` (half the time only
//!   while the lab is "active"); else nothing while metal stalls and the labs' pull outweighs the builders'
//!   (`ms_pull`); else a fighter by BARb's roulette (`RoleProbability * (tier + _weight_)`, batches of `num_batch` for
//!   a response, the air table while the enemy's aircraft outweigh its anti-air);
//! - a lab of the first tier is not "active" once it has one of the second: it makes only constructors, half as often;
//! - an air lab makes nothing while the enemy's anti-air threat is over `aa_threat`;
//! - and on top of BARb, each fighter's weight is multiplied by how a budget of it fares against the enemy's army in
//!   the battle simulator (`counter_sim_weight`; 0 is BARb alone).
//!
//! It also answers the economy (economy.rs) about labs: which to build next, where, whether it is time, what they
//! pull, and which wants a construction turret.

use crate::brain::Brain;
use crate::builders::ELMO;
use crate::defs::DefId;
use crate::economy::EcoState;
use crate::map::P;
use crate::sim::{Fighter, Options};
use crate::world::{Unit, World};
use crate::{HashMap, HashSet};
use std::collections::VecDeque;

/// BARb's openers (commander.as, GetOpenInfo), for the BAR lab each of this game's labs stands for: weight, queue.
fn openers(bar_lab: &str) -> Vec<(f64, Vec<(&'static str, u32)>)> {
    match bar_lab {
        "armlab" => vec![
            (0.4, vec![("builder", 1), ("scout", 2), ("raider", 2), ("builder", 1), ("raider", 1), ("builder", 1), ("raider", 5), ("builder", 1), ("raider", 1)]),
            (0.3, vec![("builder", 1), ("scout", 1), ("raider", 1), ("builder", 1), ("raider", 1), ("builder", 3), ("raider", 3), ("support", 1), ("raider", 1)]),
            (0.3, vec![("scout", 1), ("builder", 1), ("raider", 3), ("builder", 1), ("raider", 2), ("builder", 1)]),
        ],
        "corlab" => vec![
            (0.3, vec![("builder", 1), ("raider", 1), ("builder", 1), ("raider", 4), ("builder", 1), ("raider", 2)]),
            (0.3, vec![("raider", 1), ("builder", 1), ("raider", 2), ("builder", 1), ("raider", 1), ("builder", 1), ("raider", 2), ("riot", 1), ("builder", 1), ("raider", 2)]),
            (0.4, vec![("raider", 1), ("builder", 1), ("raider", 1), ("builder", 1), ("raider", 1), ("builder", 1), ("raider", 1)]),
        ],
        "armvp" => vec![
            (0.4, vec![("scout", 1), ("builder", 1), ("raider", 1), ("builder", 1), ("raider", 1), ("builder", 1), ("raider", 3), ("builder", 1), ("raider", 1)]),
            (0.3, vec![("scout", 2), ("raider", 1), ("builder", 1), ("raider", 1), ("builder", 1), ("raider", 1)]),
            (0.3, vec![("builder", 1), ("raider", 1), ("builder", 1), ("raider", 1), ("builder", 1)]),
        ],
        "corvp" => vec![
            (0.4, vec![("scout", 1), ("raider", 1), ("builder", 1), ("raider", 2), ("builder", 1), ("raider", 2), ("builder", 1), ("raider", 2)]),
            (0.3, vec![("scout", 1), ("builder", 1), ("raider", 1), ("builder", 1), ("raider", 5), ("builder", 1)]),
            (0.3, vec![("builder", 1), ("raider", 1), ("builder", 1), ("raider", 1), ("builder", 1), ("raider", 1)]),
        ],
        "armalab" => vec![(1.0, vec![("builder", 1), ("riot", 1), ("assault", 2), ("builder", 1), ("assault", 1), ("skirmish", 1), ("builder", 1), ("anti_heavy_ass", 2), ("builder", 1), ("heavy", 1), ("builder", 1)])],
        "armavp" => vec![
            (0.4, vec![("builder", 1), ("skirmish", 2), ("builder", 1), ("skirmish", 1), ("builder", 1), ("anti_heavy_ass", 1), ("builder", 1), ("skirmish", 1), ("anti_heavy_ass", 1), ("builder", 1)]),
            (0.6, vec![("builder", 1), ("skirmish", 1), ("builder", 1), ("skirmish", 1), ("builder", 1), ("skirmish", 2)]),
        ],
        "coralab" => vec![(1.0, vec![("builder", 1), ("raider", 3), ("builder", 1), ("raider", 3), ("builder", 1), ("skirmish", 1), ("heavy", 1), ("builder", 1), ("assault", 2), ("builder", 1)])],
        "coravp" => vec![(1.0, vec![("builder", 1), ("skirmish", 2), ("builder", 1), ("assault", 1), ("builder", 1), ("heavy", 1), ("builder", 2)])],
        _ => vec![(1.0, vec![("builder", 1), ("raider", 3), ("builder", 1), ("raider", 1)])],
    }
}

#[derive(Default)]
pub struct Factory {
    opener: HashMap<i64, VecDeque<&'static str>>,
    /// the kinds of lab that have played their opener
    opened_kinds: HashSet<DefId>,
    batch: HashMap<i64, (DefId, u32)>,
    /// each def's simulated margin against the enemy's army, and when it was worked out
    counter: HashMap<DefId, (f64, f64)>,
    /// labs waiting (CreateFactoryTask's Wait tasks), until when
    wait: HashMap<i64, f64>,
    last_switch: f64,
    switch_limit: f64,
    /// the randomness of each factory's choice (GetFactoryToBuild's offset), by def, drawn once
    offsets: HashMap<DefId, f64>,
    /// the metal pull of what its labs are making now
    pub metal_pull: f64,
}

impl Factory {
    pub fn new() -> Factory {
        Factory::default()
    }

    // For the economy ------------------------------------------------------------------------------------------------

    /// AiIsSwitchTime: `(frames since the last switch)^0.9 * income + metal * 7` over a limit drawn from 8000 to
    /// 12000 seconds (in frames).
    pub fn is_switch_time(&mut self, now: f64, s: &EcoState) -> bool {
        if self.switch_limit == 0.0 {
            self.switch_limit = (8000.0 + 4000.0 * ((now * 7919.0).sin().abs())) * 30.0;
        }
        let frames = (now - self.last_switch).max(0.0) * 30.0;
        frames.powf(0.9) * s.metal_income + s.metal * 7.0 > self.switch_limit
    }

    pub fn apply_switch_frame(&mut self, now: f64) {
        self.last_switch = now;
        self.switch_limit = (8000.0 + 4000.0 * ((now * 104729.0).sin().abs())) * 30.0;
    }

    /// The labs this game's line may use: its line's labs, and aircraft.
    fn allowed_lab(&self, brain: &Brain, def: DefId) -> bool {
        let line = brain.economy.line.clone().unwrap_or_else(|| "bots".to_string());
        let labs = brain.defs.labs.get(&line).copied().unwrap_or((None, None));
        let air = brain.defs.labs.get("aircraft").copied().unwrap_or((None, None));
        Some(def) == labs.0 || Some(def) == labs.1 || Some(def) == air.0 || Some(def) == air.1
    }

    /// GetFactoryToBuild: of the labs its builders can build, the fewest built first, then by importance (factory.json
    /// `[start, switch]`) times the map's share it can go on, with a little randomness.
    pub fn factory_to_build(&mut self, brain: &mut Brain, world: &World, is_start: bool) -> Option<DefId> {
        let air_valid = self.is_air_valid(brain, world);
        let buildable: HashSet<DefId> = world.own.iter().flat_map(|&i| brain.defs.list[world.units[i].def].options.clone()).collect();
        let mut best: Option<(usize, f64, DefId)> = None;
        let select = brain.barb_select();
        for &def in &buildable {
            let d = &brain.defs.list[def];
            if !d.factory || !d.is_building || !self.allowed_lab(brain, def) || !brain.is_available(def) {
                continue;
            }
            let Some(info) = brain.barb.factories.get(&d.name) else { continue };
            let importance = if is_start {
                let has_builder = d.options.iter().any(|&o| brain.defs.list[o].builder);
                info.importance.first().copied().unwrap_or(1.0) * if has_builder { 1.0 } else { 0.1 }
            } else {
                info.importance.get(1).copied().unwrap_or(1.0)
            };
            if importance <= 0.0 {
                continue;
            }
            let is_air = brain.defs.list[def].options.iter().any(|&o| brain.defs.list[o].air);
            if is_air && (!air_valid || is_start) {
                continue;
            }
            let offset = *self.offsets.entry(def).or_insert_with(|| select.0 + brain.rng.unit() * (select.1 - select.0));
            let map_percent = if is_air { select.2 } else { 100.0 };
            let percent = offset + importance * (map_percent + select.3);
            let count = world.own.iter().filter(|&&i| world.units[i].def == def).count();
            if best.map_or(true, |(c, p, _)| count < c || (count == c && percent > p)) {
                best = Some((count, percent, def));
            }
        }
        best.map(|(_, _, d)| d)
    }

    /// Where a new lab goes (UpdateFactoryTasks): by the finished cluster nearest the middle between base and enemy,
    /// 200 elmos back from it toward home (forward if the cluster is behind home).
    pub fn factory_site(&self, brain: &Brain, world: &World, def: DefId) -> P {
        let _ = world;
        let base = brain.home;
        let mid = base.lerp(brain.enemy_home, 0.5);
        let m = &brain.metal;
        let near = m.nearest_cluster_where(mid, &|c| m.is_finished(c) && brain.fields.influence_at(m.clusters[c].p) >= -0.01);
        let is_air = brain.defs.list[def].options.iter().any(|&o| brain.defs.list[o].air);
        let pos = match near {
            Some(c) if !is_air => m.clusters[c].p,
            _ => base,
        };
        let toward = brain.enemy_home.sub(pos).norm();
        let offset = if is_air { -200.0 } else if brain.enemy_home.dist(base) > brain.enemy_home.dist(pos) { -200.0 } else { 200.0 };
        brain.map.clamp(pos.add(toward.scale(offset * ELMO)))
    }

    /// GetRepresenter: what a lab makes that stands for it in the resource sums (its cheapest armed unit).
    pub fn representative(&self, brain: &Brain, lab: DefId) -> Option<DefId> {
        brain.defs.list[lab]
            .options
            .iter()
            .copied()
            .filter(|&o| brain.defs.list[o].armed && brain.defs.list[o].mobile)
            .min_by(|&a, &b| brain.defs.list[a].cost.total_cmp(&brain.defs.list[b].cost))
    }

    /// The metal and energy a second its labs, and the turrets by them, use making their representatives
    /// (FactoryManager's metalRequire and energyRequire).
    pub fn require(&self, brain: &Brain, world: &World) -> (f64, f64) {
        let mut m = 0.0;
        let mut e = 0.0;
        for &i in &world.own {
            let u = &world.units[i];
            let d = &brain.defs.list[u.def];
            if !(u.built && d.factory && d.is_building) {
                continue;
            }
            let Some(r) = self.representative(brain, u.def) else { continue };
            let rd = &brain.defs.list[r];
            let fac_work = d.m.buildpower.max(1e-6);
            let t = rd.m.buildtime / fac_work;
            let (mi, ei) = (rd.m.metal / t, rd.m.energy / t);
            m += mi;
            e += ei;
            for &j in &world.own {
                let n = &world.units[j];
                let nd = &brain.defs.list[n.def];
                if n.built && nd.is_building && !nd.factory && nd.m.assists && n.p.dist(u.p) < nd.m.build_range.max(1.0) * 0.9 {
                    m += mi * nd.m.buildpower / fac_work;
                    e += ei * nd.m.buildpower / fac_work;
                }
            }
        }
        (m, e)
    }

    pub fn assist_speed(&self, brain: &Brain) -> f64 {
        brain.barb.economy.assist.iter().find_map(|n| brain.defs.get(n)).map(|d| brain.defs.list[d].build_speed).unwrap_or(0.0)
    }

    /// NeedUpgrade: the last lab with fewer turrets by it than `labs * caretaker` (factory.json).
    pub fn need_upgrade(&self, brain: &Brain, world: &World, labs: &[Unit], queued: usize) -> Option<Unit> {
        let n = labs.len() as f64;
        for lab in labs.iter().rev() {
            let d = &brain.defs.list[lab.def];
            let weight = brain.barb.factories.get(&d.name).map(|f| f.caretaker).unwrap_or(0.0);
            let nanos = world
                .own
                .iter()
                .map(|&j| &world.units[j])
                .filter(|x| {
                    let xd = &brain.defs.list[x.def];
                    xd.is_building && !xd.factory && xd.m.assists && xd.m.buildpower > 0.0 && x.p.dist(lab.p) < xd.m.build_range.max(1.0)
                })
                .count();
            if ((nanos + queued) as f64) < n * weight {
                return Some(lab.clone());
            }
            return None;
        }
        None
    }

    /// A lab making something now, and what.
    pub fn current_recruit(&self, world: &World) -> Option<(i64, DefId)> {
        world.own.iter().map(|&i| &world.units[i]).find(|u| u.built && !u.queue.is_empty()).map(|u| (u.id, u.queue[0]))
    }

    /// IsAirValid: the enemy's anti-air threat is under behaviour.json's `aa_threat`.
    fn is_air_valid(&self, brain: &Brain, world: &World) -> bool {
        let limit = brain.barb_aa_threat();
        let threat: f64 = world
            .enemy
            .iter()
            .map(|&i| &world.units[i])
            .filter(|u| brain.defs.has_role(u.def, "anti_air"))
            .map(|u| brain.defs.list[u.def].thr_air * u.hp.max(0.0).sqrt())
            .sum();
        threat <= limit
    }

    // Production -----------------------------------------------------------------------------------------------------

    pub fn run(&mut self, brain: &mut Brain, world: &World) {
        let labs: Vec<Unit> = world
            .own
            .iter()
            .map(|&i| world.units[i].clone())
            .filter(|u| u.built && brain.defs.list[u.def].factory && brain.defs.list[u.def].is_building)
            .collect();
        self.opener.retain(|id, _| labs.iter().any(|l| l.id == *id));
        self.batch.retain(|id, _| labs.iter().any(|l| l.id == *id));
        let t2 = labs.iter().any(|l| brain.defs.list[l.def].tech >= 2.0 || brain.defs.list[l.def].options.iter().any(|&o| brain.defs.list[o].tech >= 2.0 && brain.defs.list[o].builder));
        self.metal_pull = 0.0;
        for lab in &labs {
            if !self.opener.contains_key(&lab.id) {
                let mut q = VecDeque::new();
                if self.opened_kinds.insert(lab.def) {
                    let bar = brain.barb.bar_name(&brain.defs.list[lab.def].name);
                    let choices = openers(&bar);
                    let total: f64 = choices.iter().map(|(w, _)| w).sum();
                    let mut dice = brain.rng.unit() * total;
                    let mut picked = &choices[0].1;
                    for (w, queue) in &choices {
                        dice -= w;
                        if dice < 0.0 {
                            picked = queue;
                            break;
                        }
                    }
                    for (role, n) in picked {
                        for _ in 0..*n {
                            q.push_back(*role);
                        }
                    }
                }
                self.opener.insert(lab.id, q);
            }
            // what it is making pulls metal
            if let Some(&def) = lab.queue.first() {
                let rd = &brain.defs.list[def];
                let t = rd.m.buildtime / brain.defs.list[lab.def].m.buildpower.max(1e-6);
                self.metal_pull += rd.m.metal / t.max(1e-6);
            }
            // one at a time, as BARb's recruit tasks go (and one more behind it, so that it does not stand idle
            // between thoughts)
            let queue_len = brain.params.lab_queue.round().max(1.0) as usize;
            if lab.queue.len() >= queue_len || self.wait.get(&lab.id).map_or(false, |&t| t > brain.now) {
                continue;
            }
            let is_t1 = brain.defs.list[lab.def].tech <= 1.0 && !brain.defs.list[lab.def].options.iter().any(|&o| brain.defs.list[o].tech >= 2.0);
            let active = !t2 || !is_t1;
            match self.choose(brain, world, lab, active) {
                Some(def) => brain.produce(lab, def, 1),
                None => {
                    self.wait.insert(lab.id, brain.now + if active { 3.0 } else { 10.0 });
                }
            }
        }
    }

    /// CreateFactoryTask: the opener, else a constructor, else (unless metal stalls) a fighter.
    fn choose(&mut self, brain: &mut Brain, world: &World, lab: &Unit, active: bool) -> Option<DefId> {
        let options: Vec<DefId> = brain.defs.list[lab.def].options.clone();
        let is_air_lab = options.iter().any(|&o| brain.defs.list[o].air);
        if is_air_lab && !self.is_air_valid(brain, world) {
            return None;
        }
        let s = brain.economy.state.clone();
        let income = s.metal_income.min(s.energy_income.max(1.0));
        let enemy_air = enemy_role_cost(brain, world, "air");
        let own_aa = own_role_cost(brain, world, "anti_air");
        let air_tiers = enemy_air > own_aa;

        // the opener first
        if let Some(q) = self.opener.get_mut(&lab.id) {
            while let Some(role) = q.pop_front() {
                let picks: Vec<(DefId, f64)> = options
                    .iter()
                    .copied()
                    .filter(|&o| brain.defs.main_role(o) == role || (role == "builder" && brain.defs.list[o].builder))
                    .map(|o| (o, brain.defs.tier_weight(o, income, air_tiers).max(0.05)))
                    .collect();
                if let Some(d) = roulette(brain, &picks) {
                    return Some(d);
                }
            }
        }

        // sim_barb's constructors (server/ai/labs.luau), counted by tier: builders_min and one more for every
        // metal_per_builder of income up to builders_max of the first; one and one more for every
        // metal_per_advanced_builder up to advanced_builders_max of the second, from a lab that makes them
        let p = brain.params.clone();
        let cheapest = |advanced: bool| {
            options
                .iter()
                .copied()
                .filter(|&o| brain.defs.list[o].builder && brain.defs.list[o].mobile && (brain.defs.list[o].tech >= 2.0) == advanced)
                .min_by(|&a, &b| brain.defs.list[a].cost.total_cmp(&brain.defs.list[b].cost))
        };
        let have = |advanced: bool| {
            world
                .own
                .iter()
                .map(|&i| &brain.defs.list[world.units[i].def])
                .filter(|d| d.builder && d.mobile && !d.commander && !d.options.is_empty() && (d.tech >= 2.0) == advanced)
                .count() as f64
        };
        let income = s.metal_income;
        if let Some(c) = cheapest(true) {
            let wanted = (1.0 + (income / p.metal_per_advanced_builder.max(1.0)).floor()).clamp(1.0, p.advanced_builders_max);
            if have(true) < wanted {
                return Some(c);
            }
        }
        if let Some(c) = cheapest(false) {
            let wanted = (p.builders_min + (income / p.metal_per_builder.max(0.5)).floor()).clamp(p.builders_min, p.builders_max);
            if have(false) < wanted {
                return Some(c);
            }
        }
        // UpdateBuildPower: a constructor while buildpower is short (half the time while active), up to builders_max
        if (!crate::params::Params::on(p.constructor_cap) || have(false) < p.builders_max) && s.buildpower < s.metal_income.min(s.energy_income) * brain.params.buildpower_ratio && (!active || brain.rng.unit() >= 0.5) {
            if let Some(c) = options.iter().copied().filter(|&o| brain.defs.list[o].builder).min_by(|&a, &b| brain.defs.list[a].cost.total_cmp(&brain.defs.list[b].cost)) {
                return Some(c);
            }
        }

        // isNotReady: metal stalling with the labs' pull over the builders' (ms_pull), or not excessed
        let army_cost: f64 = world
            .own
            .iter()
            .map(|&i| &world.units[i])
            .filter(|u| brain.defs.list[u.def].armed && brain.defs.list[u.def].mobile && !brain.defs.list[u.def].commander)
            .map(|u| brain.defs.list[u.def].cost)
            .sum();
        let enemy_mobile: f64 = world
            .enemy
            .iter()
            .map(|&i| &world.units[i])
            .filter(|u| brain.defs.list[u.def].armed && brain.defs.list[u.def].mobile)
            .map(|u| brain.defs.list[u.def].cost)
            .sum();
        let pull_m_to_s = brain.economy.pull_m_to_s(brain, army_cost, enemy_mobile);
        let stalling = s.metal_empty && s.metal_income * 1.2 < s.metal_pull && self.metal_pull * pull_m_to_s > brain.builders.metal_pull;
        if !brain.economy.is_excessed() || stalling {
            return None;
        }

        // a batch under way
        if let Some((d, n)) = self.batch.get_mut(&lab.id) {
            if *n > 0 && options.contains(d) {
                *n -= 1;
                return Some(*d);
            }
        }

        // RequiredFireDef: BARb's roulette, weighed by the simulator
        let mut candidates: Vec<(DefId, f64, bool)> = Vec::new();
        for &o in &options {
            let d = &brain.defs.list[o];
            if !d.mobile || !d.armed || d.builder || d.commander {
                continue;
            }
            // an inactive lab makes only what BARb marks rare (none here)
            if !active {
                continue;
            }
            let tier = brain.defs.tier_weight(o, income, air_tiers);
            let tier = if tier > 0.0 { tier } else { brain.params.tier_weight_floor };
            if tier <= 0.0 {
                continue;
            }
            let resp = role_probability(brain, world, o, army_cost) * brain.params.response_weight;
            let is_resp = resp > 0.0 && d.cost <= army_cost.max(d.cost);
            let mut weight = if is_resp { resp * (tier + brain.barb.response_weight) } else { tier };
            if brain.params.counter_sim_weight > 0.0 {
                let margin = self.counter_margin(brain, world, o, income);
                weight *= (brain.params.counter_sim_weight * margin * 2.0).exp();
            }
            candidates.push((o, weight, is_resp));
        }
        let weighted: Vec<(DefId, f64)> = candidates.iter().map(|(d, w, _)| (*d, *w)).collect();
        let pick = roulette(brain, &weighted)?;
        if candidates.iter().any(|(d, _, r)| *d == pick && *r) {
            let n = (brain.params.num_batch.round() as u32).saturating_sub(1);
            if n > 0 {
                self.batch.insert(lab.id, (pick, n));
            }
        }
        Some(pick)
    }

    /// How a budget of `def` fares against the enemy's army in the simulator, -1 to 1, worked out again every 15
    /// seconds.
    fn counter_margin(&mut self, brain: &mut Brain, world: &World, def: DefId, income: f64) -> f64 {
        if let Some((t, m)) = self.counter.get(&def) {
            if brain.now - t < 15.0 {
                return *m;
            }
        }
        let budget = (income * brain.params.counter_budget_seconds).max(brain.defs.list[def].cost * 3.0).max(400.0);
        let mut enemy: Vec<(DefId, f64)> = world
            .enemy
            .iter()
            .map(|&i| &world.units[i])
            .filter(|u| {
                let d = &brain.defs.list[u.def];
                u.built && d.armed && d.mobile && !d.commander
            })
            .map(|u| (u.def, u.hp))
            .collect();
        if enemy.is_empty() {
            enemy = likely_enemy_army(brain, world, income);
        }
        if enemy.is_empty() {
            self.counter.insert(def, (brain.now, 0.0));
            return 0.0;
        }
        let enemy_worth: f64 = enemy.iter().map(|(d, _)| brain.defs.list[*d].cost).sum();
        // the enemy's mix at the budget's size: every k-th of them, or all of them over again
        let mut theirs: Vec<(DefId, f64)> = Vec::new();
        let scale = budget / enemy_worth.max(1.0);
        let mut acc = 0.0;
        for (d, hp) in enemy.iter().cycle().take(((enemy.len() as f64) * scale.max(1.0)).ceil() as usize) {
            acc += scale.min(1.0);
            if acc >= 1.0 {
                acc -= 1.0;
                theirs.push((*d, *hp));
            }
        }
        if theirs.is_empty() {
            theirs.push(enemy[0]);
        }
        let n = (budget / brain.defs.list[def].cost).round().clamp(1.0, 60.0) as usize;
        let ours: Vec<(DefId, f64)> = (0..n).map(|_| (def, brain.defs.list[def].health)).collect();
        let a = formation(&ours, P::new(0.0, 0.0), 1.0);
        let reach = theirs.iter().map(|(d, _)| brain.defs.list[*d].range_ground).fold(0.0, f64::max).max(brain.defs.list[def].range_ground);
        let b = formation(&theirs, P::new(reach + 40.0, 0.0), -1.0);
        let outcome = brain.simulate(&a, &b, Options { horizon: 40.0, ..Default::default() });
        // the margin, and what each side lost for its price
        let margin = outcome.margin;
        self.counter.insert(def, (brain.now, margin));
        margin
    }
}

/// `units` in a block facing +x (`facing` 1) or -x, centred on `at`.
fn formation(units: &[(DefId, f64)], at: P, facing: f64) -> Vec<Fighter> {
    let per_row = ((units.len() as f64).sqrt().ceil() as usize).max(1);
    units
        .iter()
        .enumerate()
        .map(|(i, (d, hp))| {
            let row = (i / per_row) as f64;
            let col = (i % per_row) as f64 - per_row as f64 / 2.0;
            Fighter { def: *d, p: P::new(at.x - facing * row * 4.0, at.z + col * 4.0), hp: *hp }
        })
        .collect()
}

/// What the enemy's labs are likeliest to make, by BARb's weights at the enemy's income, for when none of its army
/// has been seen.
fn likely_enemy_army(brain: &Brain, world: &World, income: f64) -> Vec<(DefId, f64)> {
    let mut out = Vec::new();
    let labs: Vec<DefId> = world
        .enemy
        .iter()
        .map(|&i| world.units[i].def)
        .filter(|&d| brain.defs.list[d].factory && brain.defs.list[d].is_building)
        .collect();
    let labs = if labs.is_empty() {
        brain.defs.labs.values().filter_map(|l| l.0).collect::<Vec<_>>()
    } else {
        labs
    };
    for lab in labs {
        for &o in &brain.defs.list[lab].options {
            let d = &brain.defs.list[o];
            if !d.mobile || !d.armed || d.builder {
                continue;
            }
            let w = brain.defs.tier_weight(o, income, false);
            let n = (w * 10.0).round() as usize;
            for _ in 0..n {
                out.push((o, d.health));
            }
        }
    }
    out
}

fn roulette(brain: &mut Brain, picks: &[(DefId, f64)]) -> Option<DefId> {
    let total: f64 = picks.iter().map(|(_, w)| w.max(0.0)).sum();
    if picks.is_empty() {
        return None;
    }
    if total <= 0.0 {
        let i = (brain.rng.next() as usize) % picks.len();
        return Some(picks[i].0);
    }
    let mut dice = brain.rng.unit() * total;
    for (d, w) in picks {
        dice -= w.max(0.0);
        if dice < 0.0 {
            return Some(*d);
        }
    }
    picks.last().map(|(d, _)| *d)
}

pub fn enemy_role_cost(brain: &Brain, world: &World, role: &str) -> f64 {
    world
        .enemy
        .iter()
        .map(|&i| &world.units[i])
        .filter(|u| brain.defs.has_role(u.def, role) || (role == "air" && brain.defs.list[u.def].air && brain.defs.list[u.def].armed))
        .map(|u| brain.defs.list[u.def].cost * if u.built { 1.0 } else { u.progress })
        .sum()
}

pub fn own_role_cost(brain: &Brain, world: &World, role: &str) -> f64 {
    world
        .own
        .iter()
        .map(|&i| &world.units[i])
        .filter(|u| brain.defs.has_role(u.def, role))
        .map(|u| brain.defs.list[u.def].cost)
        .sum()
}

/// BARb's RoleProbability: the most, over the roles its main role answers, of enemy metal in that role over its own
/// metal in its role, by importance, where the enemy has enough in it (enemy * ratio >= own) and its role is under its
/// share of the army (max_percent).
fn role_probability(brain: &Brain, world: &World, def: DefId, army_cost: f64) -> f64 {
    let role = brain.defs.main_role(def).to_string();
    let Some(resp) = brain.barb.responses.get(&role) else { return 0.0 };
    let own = own_role_cost(brain, world, &role);
    let cost = brain.defs.list[def].cost;
    let mut best = 0.0;
    for (k, vs) in resp.vs.iter().enumerate() {
        let enemy = enemy_role_cost(brain, world, vs);
        let ratio = resp.ratio.get(k).copied().unwrap_or(1.0);
        let importance = resp.importance.get(k).copied().unwrap_or(1.0) * brain.barb.importance_mod;
        let prob = enemy / (own + 1.0) * importance;
        if prob > best && enemy * ratio >= own && own + cost <= (army_cost + cost) * resp.max_percent {
            best = prob;
        }
    }
    best
}
