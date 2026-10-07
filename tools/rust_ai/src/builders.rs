//! BARb's builder task pool and BuilderManager (CircuitAI barbarian: module/BuilderManager.cpp,
//! task/builder/BuilderTask.cpp, task/builder/MexTask.cpp, task/RetreatTask.cpp; see PORTING.md).
//!
//! Builders are not given orders directly: tasks go into a pool (economy.rs, porc.rs, retreat's repairs), and a
//! builder that wants work takes the task with the least `path cost * 1 / (priority + 1)^2` among those it may be
//! assigned. A task keeps the builders on it until it is finished (its blueprint stands finished), aborted, or runs
//! out of time; its buildpower grows with each builder until it would be done in `build_mod / metal_income` seconds,
//! past which it takes no more.

use crate::brain::Brain;
use crate::defs::DefId;
use crate::map::P;
use crate::world::{Unit, World};
use crate::HashMap;

/// BARb's constants (util/Defines.h).
pub const THREAT_MIN: f64 = 1.0;
pub const MAX_TRAVEL_SEC: f64 = 60.0;
pub const EARLY_BUILD_SEC: f64 = 20.0;
pub const MAX_BUILD_SEC: f64 = 40.0;
const TASK_RETRIES: u32 = 20;
/// Elmos a stud.
pub const ELMO: f64 = 1.0 / 11.0;

#[derive(Clone, Copy, PartialEq, Eq, Hash, Debug)]
pub enum Kind {
    Factory,
    Nano,
    Store,
    Energy,
    Defence,
    Mex,
    MexUp,
    Convert,
    Reclaim,
    Resurrect,
    Repair,
    Guard,
}

#[derive(Clone, Copy, PartialEq, Eq, PartialOrd, Ord, Debug)]
pub enum Priority {
    Low = 0,
    Normal = 1,
    High = 2,
    Now = 3,
}

#[derive(Clone, Debug)]
pub struct Task {
    pub id: u64,
    pub kind: Kind,
    pub priority: Priority,
    pub def: Option<DefId>,
    pub pos: P,
    pub shake: f64,
    pub cost_metal: f64,
    pub cost_energy: f64,
    /// the blueprint it builds once started, the unit it repairs or guards, or the remains it reclaims
    pub target: Option<i64>,
    pub units: Vec<i64>,
    /// the metal and energy a second its builders would spend on it (ShowAssignee)
    pub bp_metal: f64,
    pub bp_energy: f64,
    pub created: f64,
    /// seconds after `created` it is given up if nothing stands yet; 0 for never
    pub timeout: f64,
    pub spot: Option<usize>,
    pub def_point: Option<usize>,
    /// a task that goes into the pool once this one is finished (a chain of defences)
    pub next: Option<u64>,
    pub active: bool,
    /// where the bridge put it
    pub site: Option<P>,
    pub fails: u32,
    /// for a guard task: until when
    pub until: f64,
    /// a defence under the enemy's influence (CBDefenceTask isUrgent)
    pub urgent: bool,
}

#[derive(Default)]
pub struct Builders {
    pub tasks: HashMap<u64, Task>,
    pub next_id: u64,
    pub unit_task: HashMap<i64, u64>,
    /// units retreating to be mended, and when they started
    pub retreating: HashMap<i64, f64>,
    /// builders with BARb's BASE attribute (script/hard/manager/builder.as's energizers)
    pub energizer1: Option<i64>,
    pub energizer2: Option<i64>,
    /// when each builder last saw danger (MakeCommTask's dangerTime)
    pub danger_time: HashMap<i64, f64>,
    /// sim_barb's opening (server/ai/errands.luau `open`), its steps still to come: None until it is planned
    pub opening: Option<Vec<(Kind, DefId, P)>>,
    /// the opening's step under way, and where its next step was queued behind it (if it was)
    pub opening_task: Option<u64>,
    pub opening_queued: Option<P>,
    /// builders fleeing danger (sim_barb's flee), since when
    pub fleeing: HashMap<i64, f64>,
    pub metal_pull: f64,
    pub workers: usize,
    /// sites that could not be built on, until when
    pub blocked: Vec<(DefId, P, f64)>,
    /// how its tasks ended, by kind and how, all game (for the log)
    pub outcomes: HashMap<String, u32>,
    /// its buildings that stood finished at the last thought
    pub prev_built: crate::HashSet<i64>,
    /// why extractor tasks were passed over this thought, for the log
    pub why: std::cell::RefCell<HashMap<&'static str, u32>>,
}

impl Builders {
    pub fn new() -> Builders {
        Builders::default()
    }

    pub fn tasks_of(&self, kind: Kind) -> impl Iterator<Item = &Task> {
        self.tasks.values().filter(move |t| t.active && t.kind == kind)
    }

    pub fn count_of(&self, kind: Kind) -> usize {
        self.tasks_of(kind).count()
    }

    /// CanEnqueueTask: fewer tasks than workers times `m`.
    pub fn can_enqueue(&self, m: usize) -> bool {
        self.tasks.values().filter(|t| t.active).count() < self.workers.max(1) * m
    }

    #[allow(clippy::too_many_arguments)]
    pub fn enqueue(&mut self, now: f64, kind: Kind, priority: Priority, def: Option<DefId>, pos: P, shake: f64, active: bool, timeout: f64, brain: &Brain) -> u64 {
        self.next_id += 1;
        let id = self.next_id;
        let (cost_metal, cost_energy) = def.map(|d| (brain.defs.list[d].m.metal, brain.defs.list[d].m.energy)).unwrap_or((0.0, 0.0));
        self.tasks.insert(
            id,
            Task {
                id,
                kind,
                priority,
                def,
                pos,
                shake,
                cost_metal,
                cost_energy,
                target: None,
                units: Vec::new(),
                bp_metal: 0.0,
                bp_energy: 0.0,
                created: now,
                timeout,
                spot: None,
                def_point: None,
                next: None,
                active,
                site: None,
                fails: 0,
                until: 0.0,
                urgent: false,
            },
        );
        id
    }

    /// Takes every builder off `id` and forgets it, and the chain after it; what it held (a spot, a defence
    /// point's cost) is given back by the caller (economy.rs `on_abort`).
    pub fn remove(&mut self, id: u64) -> Option<Task> {
        let t = self.tasks.remove(&id)?;
        for u in &t.units {
            self.unit_task.remove(u);
        }
        let mut next = t.next;
        while let Some(n) = next {
            next = self.tasks.remove(&n).and_then(|x| x.next);
        }
        Some(t)
    }

    pub fn release(&mut self, unit: i64, brain: &Brain) {
        if let Some(id) = self.unit_task.remove(&unit) {
            if let Some(t) = self.tasks.get_mut(&id) {
                t.units.retain(|&u| u != unit);
                recompute_power(t, brain);
            }
        }
    }

    fn note(&self, t: &Task, why: &'static str) {
        if t.kind == Kind::Mex {
            *self.why.borrow_mut().entry(why).or_insert(0) += 1;
        } else if t.kind == Kind::Factory {
            *self.why.borrow_mut().entry(match why {
                "assign" => "lab_assign",
                "threat" => "lab_threat",
                "reach" => "lab_reach",
                "cost_blocked" => "lab_cost_blocked",
                "not_ready" => "lab_not_ready",
                "comm_radius" => "lab_comm_radius",
                _ => "lab_other",
            }).or_insert(0) += 1;
        }
    }

    fn is_blocked(&self, def: DefId, p: P) -> bool {
        self.blocked.iter().any(|(d, bp, _)| *d == def && bp.dist(p) < 6.0)
    }
}

/// The metal and energy a second the builders on `t` would spend on it (ShowAssignee): each one's
/// `cost / (buildtime / workertime)`; for what has no def, its build speed.
fn recompute_power(t: &mut Task, brain: &Brain) {
    t.bp_metal = 0.0;
    t.bp_energy = 0.0;
    for &u in &t.units {
        let Some(unit) = brain.seen_unit(u).map(|x| x.def) else { continue };
        let worker = brain.defs.list[unit].m.buildpower.max(1e-6);
        match t.def {
            Some(d) => {
                let dd = &brain.defs.list[d];
                let build_time = dd.m.buildtime / worker;
                t.bp_metal += dd.m.metal / build_time.max(1e-6);
                t.bp_energy += dd.m.energy / build_time.max(1e-6);
            }
            None => {
                let speed = brain.defs.list[unit].build_speed;
                t.bp_metal += speed;
                t.bp_energy += speed * 10.0;
            }
        }
    }
}

/// The threat-weighted walking cost from a builder to every field cell (CPathFinder's cost map query over the threat
/// map): cells in COST_BASE per cell walked, and a cell whose threat is over the builder's power is closed.
pub struct CostMap {
    pub cost: Vec<f64>,
    pub w: usize,
}

impl CostMap {
    pub fn build(brain: &Brain, u: &Unit) -> CostMap {
        let f = &brain.fields;
        let (w, h) = (f.w, f.h);
        let mut cost = vec![f64::MAX; w * h];
        let d = &brain.defs.list[u.def];
        let key = d.m.ground.clone();
        let power = (d.thr_surf.max(d.thr_air) * u.hp.max(0.0).sqrt()).max(THREAT_MIN);
        let Some(start) = f.index_of(u.p) else { return CostMap { cost, w } };
        let open = |i: usize| -> bool {
            let c = f.center(i);
            (key.is_none() || brain.map.open(key.as_deref(), c)) && f.e_surf[i] <= power
        };
        let mut heap = std::collections::BinaryHeap::new();
        cost[start] = 0.0;
        heap.push(std::cmp::Reverse((ordered(0.0), start)));
        while let Some(std::cmp::Reverse((c, i))) = heap.pop() {
            let c = c.0;
            if c > cost[i] {
                continue;
            }
            let (x, z) = ((i % w) as i64, (i / w) as i64);
            for (dx, dz) in [(1i64, 0i64), (-1, 0), (0, 1), (0, -1), (1, 1), (1, -1), (-1, 1), (-1, -1)] {
                let (nx, nz) = (x + dx, z + dz);
                if nx < 0 || nz < 0 || nx >= w as i64 || nz >= h as i64 {
                    continue;
                }
                let j = nz as usize * w + nx as usize;
                if !open(j) {
                    continue;
                }
                let step = if dx != 0 && dz != 0 { std::f64::consts::SQRT_2 } else { 1.0 };
                let nc = c + step * (1.0 + f.e_surf[j]);
                if nc < cost[j] {
                    cost[j] = nc;
                    heap.push(std::cmp::Reverse((ordered(nc), j)));
                }
            }
        }
        CostMap { cost, w }
    }

    /// GetCostAt: the cost of getting to within `range` of `p`, or None if there is no way.
    pub fn at(&self, brain: &Brain, p: P, range: f64) -> Option<f64> {
        let f = &brain.fields;
        let cells = (range / crate::fields::FIELD).ceil() as i64;
        let i = f.index_of(p)?;
        let (x, z) = ((i % self.w) as i64, (i / self.w) as i64);
        let mut best = f64::MAX;
        for dz in -cells..=cells {
            for dx in -cells..=cells {
                let (nx, nz) = (x + dx, z + dz);
                if nx < 0 || nz < 0 || nx as usize >= self.w || nz as usize >= f.h {
                    continue;
                }
                best = best.min(self.cost[nz as usize * self.w + nx as usize]);
            }
        }
        if best == f64::MAX {
            None
        } else {
            Some(best)
        }
    }
}

#[derive(PartialEq, PartialOrd, Clone, Copy)]
struct Ordered(f64);
impl Eq for Ordered {}
impl Ord for Ordered {
    fn cmp(&self, o: &Self) -> std::cmp::Ordering {
        self.0.total_cmp(&o.0)
    }
}
fn ordered(v: f64) -> Ordered {
    Ordered(v)
}

/// How the builder picks among tasks (MakeBuilderTask, MakeCommTask, MakeEnergizerTask).
pub enum Mode {
    Builder,
    /// within `radius` of base, with the commander's weights
    Commander { radius: f64 },
    Energizer,
}

impl Builders {
    /// CanAssignTo, as each of BARb's task kinds has it (task/builder/*Task.cpp).
    pub fn can_assign(&self, t: &Task, u: &Unit, brain: &Brain) -> bool {
        let d = &brain.defs.list[u.def];
        let eco = &brain.economy;
        match t.kind {
            // CBGuardTask
            Kind::Guard => return true,
            // CBRepairTask: not the commander
            Kind::Repair => return !d.commander && (d.m.assists || d.m.repairs),
            // CBReclaimTask: not metal while metal is full, and the extractors' escort rule
            Kind::Reclaim | Kind::Resurrect => {
                if !d.m.reclaims || (t.kind == Kind::Reclaim && eco.state.metal_full) {
                    return false;
                }
                return d.armed || self.escort_allows(t, u, brain);
            }
            _ => {}
        }
        let Some(def) = t.def else { return true };
        let assists = t.target.is_some() && d.m.assists;
        if !assists && !d.options.contains(&def) {
            self.note(t, "cannot_build");
            return false;
        }
        // enough buildpower on it already: cost < buildpower * build_mod / metal income
        let income = eco.state.metal_income.max(1e-6);
        let over = t.cost_metal < t.bp_metal * brain.defs.list[def].build_mod / income;
        match t.kind {
            // CBEnergyTask: no cap while energy stalls; the commander does not walk back for a small one
            Kind::Energy => {
                if !eco.state.energy_stalling && over {
                    return false;
                }
                let near = t.pos.dist(u.p) < d.m.build_range + 128.0 * ELMO;
                t.cost_metal > 200.0 || !d.commander || near || (t.site.is_none() && t.target.is_none())
            }
            // CBMexTask: the energy income check instead of the stall check, and the escort rule
            Kind::Mex => {
                if over {
                    self.note(t, "bp_cap");
                    return false;
                }
                if t.target.is_none() && !eco.is_enough_energy_income(def, u, brain) && !eco.is_enough_energy(t, u, brain, 0.8) {
                    self.note(t, "energy");
                    return false;
                }
                if d.armed {
                    return true;
                }
                let ok = self.escort_allows(t, u, brain);
                if !ok {
                    self.note(t, "escort");
                }
                ok
            }
            _ => {
                if over {
                    return false;
                }
                if t.target.is_none() && eco.state.energy_stalling && !eco.is_enough_energy(t, u, brain, 0.8) {
                    return false;
                }
                // CBDefenceTask: not before its first factory
                !(t.kind == Kind::Defence && brain.factory_count() == 0)
            }
        }
    }

    /// The escort rule (CBMexTask, CBReclaimTask): in the first minutes an unescorted builder does not go to a
    /// cluster without defences.
    fn escort_allows(&self, t: &Task, u: &Unit, brain: &Brain) -> bool {
        let [escorted, _, until] = brain.barb.escort;
        if !crate::params::Params::on(brain.params.escort_gate) || escorted <= 0.0 || brain.now > until {
            return true;
        }
        match brain.metal.nearest_cluster(t.pos) {
            Some(c) => brain.metal.has_defence(c) || brain.military.is_escorted(u.id),
            None => true,
        }
    }

    /// HasFreeAssists: few enough builders already guard builders (two while a factory or turret is being put up,
    /// else half of those that can assist); the commander only while there are few that can assist.
    pub fn has_free_assists(&self, u: &Unit, brain: &Brain, world: &World) -> bool {
        let d = &brain.defs.list[u.def];
        if !d.m.assists {
            return false;
        }
        let guard_count: usize = self
            .tasks
            .values()
            .filter(|t| t.kind == Kind::Guard && t.target.and_then(|id| world.get(id)).map_or(false, |x| !brain.defs.list[x.def].options.is_empty()))
            .map(|t| t.units.len())
            .sum();
        let assist_count = world.own.iter().filter(|&&i| world.units[i].built && brain.defs.list[world.units[i].def].mobile && brain.defs.list[world.units[i].def].m.assists && brain.defs.list[world.units[i].def].m.buildpower > 0.0).count();
        let con_tasks = self.count_of(Kind::Factory) + self.count_of(Kind::Nano);
        let limit = if con_tasks == 0 { assist_count / 2 } else { 2 };
        let assist_fac = brain.barb.commanders.values().next().map(|c| c.assist_fac).unwrap_or(3.0);
        guard_count <= limit && (!d.commander || (assist_count as f64) <= assist_fac)
    }

    /// The task for builder `u` (DefaultMakeTask's MakeBuilderTask / MakeCommTask / MakeEnergizerTask), from the pool.
    pub fn pick(&self, u: &Unit, brain: &Brain, mode: &Mode, not_ready: bool) -> Option<u64> {
        self.pick_of(u, brain, mode, not_ready, None)
    }

    /// `pick`, over the tasks of one kind only if `only` says so.
    pub fn pick_of(&self, u: &Unit, brain: &Brain, mode: &Mode, not_ready: bool, only: Option<&dyn Fn(&Task) -> bool>) -> Option<u64> {
        let d = &brain.defs.list[u.def];
        let cm = CostMap::build(brain, u);
        let speed = (d.speed / crate::fields::FIELD).max(1e-3);
        let build_distance = d.m.build_range.max(crate::fields::FIELD);
        let power = (d.thr_surf.max(d.thr_air) * u.hp.max(0.0).sqrt()).max(0.0);
        let base = brain.home;
        let mut best: Option<(f64, u64)> = None;

        // MakeCommTask's weights, by where the commander stands and the economy's balance
        let mut weights: HashMap<Kind, f64> = HashMap::default();
        if matches!(mode, Mode::Commander { .. }) {
            let center = brain.map_center();
            let to_base = u.p.dist(base).max(1.0);
            let to_center = u.p.dist(center).max(1.0);
            let base_div_enemy = to_base / to_center;
            let e = &brain.economy.state;
            let energy_div_metal = (e.energy_income * brain.barb.economy.em_ratio / e.metal_income.max(1e-3)).max(1e-3);
            weights.insert(Kind::Energy, base_div_enemy * energy_div_metal * 8.0);
            weights.insert(Kind::Defence, if brain.fields.danger(u.p) < 0.01 { 1.0 / base_div_enemy } else { base_div_enemy * 2.0 });
            weights.insert(Kind::Mex, base_div_enemy / energy_div_metal);
        }
        let energizer_order = [
            (Kind::Energy, 10000.0),
            (Kind::Store, 10000.0),
            (Kind::Factory, 10000.0),
            (Kind::Nano, 10000.0),
            (Kind::MexUp, 2000.0),
            (Kind::Mex, 2000.0),
            (Kind::Convert, 2000.0),
            (Kind::Defence, 2000.0),
            (Kind::Repair, 2000.0),
            (Kind::Reclaim, 2000.0),
            (Kind::Resurrect, 2000.0),
        ];
        let groups: Vec<Vec<&Task>> = match mode {
            Mode::Energizer => energizer_order.iter().map(|(k, _)| self.tasks_of(*k).collect()).collect(),
            _ => vec![self.tasks.values().filter(|t| t.active && t.kind != Kind::Guard && only.map_or(true, |f| f(t))).collect()],
        };
        let max_base_dist = u.p.dist(base);
        for (gi, group) in groups.iter().enumerate() {
            for t in group {
                if !self.can_assign(t, u, brain) {
                    self.note(t, "assign");
                    continue;
                }
                if not_ready && t.priority != Priority::Now && t.def.is_some() && !brain.economy.ignores_stalling_pull(t) {
                    self.note(t, "not_ready");
                    continue;
                }
                let at = t.site.unwrap_or(t.pos);
                if t.priority != Priority::Now {
                    match mode {
                        Mode::Energizer => {
                            let limit = energizer_order[gi].1 * ELMO;
                            let test = brain.metal.nearest_cluster(at).map(|c| brain.metal.clusters[c].p).unwrap_or(at);
                            if u.p.dist(test) > limit || base.dist(test) > max_base_dist.max(limit) || brain.fields.influence_at(test) < -0.01 {
                                continue;
                            }
                        }
                        Mode::Commander { radius } => {
                            let test = brain.metal.nearest_cluster(at).map(|c| brain.metal.clusters[c].p).unwrap_or(at);
                            if base.dist(test) > *radius || brain.fields.influence_at(test) < -0.01 {
                                self.note(t, "comm_radius");
                                continue;
                            }
                        }
                        Mode::Builder => {
                            let build_threat = t.def.map(|dd| brain.defs.list[dd].barb_power).unwrap_or(0.0);
                            let threatened = brain.fields.danger(at) > power.max(THREAT_MIN);
                            if build_threat < THREAT_MIN && threatened && brain.fields.influence_at(at) < -0.01 {
                                self.note(t, "threat");
                                continue;
                            }
                        }
                    }
                }
                if !brain.map.reachable(d.m.ground.as_deref(), u.p, at) {
                    self.note(t, "reach");
                    continue;
                }
                let raw = u.p.dist(at);
                let close = raw < build_distance;
                let dist_cost = if close {
                    raw / crate::fields::FIELD * 0.5
                } else {
                    match cm.at(brain, at, build_distance) {
                        Some(c) => c,
                        None => {
                            self.note(t, "cost_blocked");
                            continue;
                        }
                    }
                }
                .max(1.0);
                let weight = 1.0 / ((t.priority as u8 as f64 + 1.0).powi(2)) * weights.get(&t.kind).copied().unwrap_or(1.0);
                let metric = dist_cost * weight;
                if best.map_or(false, |(m, _)| metric >= m) {
                    continue;
                }
                if !close {
                    if let Some(target) = t.target.and_then(|id| brain.seen_unit(id)) {
                        // worth walking to only if there is enough of it left to build
                        let left = 1.0 - target.progress;
                        let health_speed = t.bp_metal / t.cost_metal.max(1e-6);
                        if left * 0.6 * speed <= health_speed * dist_cost {
                            continue;
                        }
                    } else if !matches!(mode, Mode::Builder) && dist_cost >= MAX_TRAVEL_SEC * speed {
                        continue;
                    }
                }
                best = Some((metric, t.id));
            }
            if best.is_some() && matches!(mode, Mode::Energizer) {
                break;
            }
        }
        best.map(|(_, id)| id)
    }

    /// Puts `u` on task `id` and gives it the order that does it.
    pub fn assign(&mut self, u: &Unit, id: u64, brain: &mut Brain) {
        self.release(u.id, brain);
        let Some(t) = self.tasks.get_mut(&id) else { return };
        t.units.push(u.id);
        recompute_power(t, brain);
        self.unit_task.insert(u.id, id);
        let t = t.clone();
        self.execute(u, &t, brain);
    }

    /// IBuilderTask::Execute: help what it has started, or start it.
    pub fn execute(&mut self, u: &Unit, t: &Task, brain: &mut Brain) {
        match t.kind {
            Kind::Guard => {
                if let Some(target) = t.target {
                    let p = brain.seen_unit(target).map(|x| x.p).unwrap_or(t.pos);
                    brain.order_target(u, "guard", target, p);
                }
                return;
            }
            Kind::Repair => {
                if let Some(target) = t.target {
                    let p = brain.seen_unit(target).map(|x| x.p).unwrap_or(t.pos);
                    brain.order_target(u, "repair", target, p);
                }
                return;
            }
            Kind::Reclaim | Kind::Resurrect => {
                let kind = if t.kind == Kind::Reclaim { "area_reclaim" } else { "area_resurrect" };
                brain.order_area(u, kind, t.pos, 30.0);
                return;
            }
            _ => {}
        }
        if let Some(target) = t.target {
            let p = brain.seen_unit(target).map(|x| x.p).unwrap_or(t.pos);
            brain.order_target(u, "assist", target, p);
            return;
        }
        let Some(def) = t.def else { return };
        // a started one of the others on it: help that
        let at = t.site.unwrap_or(t.pos);
        let jitter = if t.shake > 0.0 && t.site.is_none() {
            let a = brain.rng.unit() * std::f64::consts::TAU;
            let r = brain.rng.unit() * t.shake;
            P::new(a.cos() * r, a.sin() * r)
        } else {
            P::new(0.0, 0.0)
        };
        let search = if t.kind == Kind::Mex || t.kind == Kind::MexUp { 0.0 } else { 200.0 * 8.0 * ELMO };
        brain.build(u, def, at.add(jitter), search.min(60.0), format!("t{}", t.id));
    }

    /// BuilderManager's upkeep of the pool each thought: what each task has built, what is finished, what failed.
    /// Returns the tasks finished (for their chains) and those aborted (to give back what they held).
    pub fn upkeep(&mut self, world: &World, brain: &mut Brain) -> (Vec<Task>, Vec<Task>) {
        let now = brain.now;
        self.blocked.retain(|(_, _, t)| *t > now);
        // what the bridge made of last thought's build orders
        for r in brain.results.clone() {
            let Some(tag) = r.tag.as_deref() else { continue };
            let Some(id) = tag.strip_prefix('t').and_then(|x| x.parse::<u64>().ok()) else { continue };
            if let Some(t) = self.tasks.get_mut(&id) {
                if r.ok {
                    if let (Some(x), Some(z)) = (r.x, r.z) {
                        t.site = Some(P::new(x, z));
                    }
                } else {
                    t.fails += 1;
                    if let Some(def) = t.def {
                        self.blocked.push((def, t.pos, now + 60.0));
                    }
                }
            }
        }
        let alive: crate::HashSet<i64> = world.own.iter().map(|&i| world.units[i].id).collect();
        let mut finished = Vec::new();
        let mut aborted = Vec::new();
        let ids: Vec<u64> = self.tasks.keys().copied().collect();
        // the blueprints tasks already hold, which no other task takes as its own
        let mut held: crate::HashSet<i64> = self.tasks.values().filter_map(|t| t.target).collect();
        for id in ids {
            let Some(t) = self.tasks.get_mut(&id) else { continue };
            if !t.active {
                continue;
            }
            t.units.retain(|u| alive.contains(u));
            // the blueprint it put down
            if t.target.is_none() && t.def.is_some() && !matches!(t.kind, Kind::Repair | Kind::Guard | Kind::Reclaim | Kind::Resurrect) {
                // an unfinished one of its def where the bridge put it (or near where it was asked for, before that),
                // that no other task holds: a finished building standing there already is not this task's work
                let def = t.def.unwrap();
                let (at, reach) = match t.site {
                    Some(site) => (site, 3.0),
                    None => (t.pos, 8.0 + t.shake),
                };
                let found = world
                    .own
                    .iter()
                    .map(|&i| &world.units[i])
                    .filter(|x| x.def == def && (!x.built || !self.prev_built.contains(&x.id)) && !held.contains(&x.id) && x.p.dist(at) < reach)
                    .min_by(|a, b| a.p.dist(at).total_cmp(&b.p.dist(at)));
                if let Some(bp) = found {
                    t.target = Some(bp.id);
                    held.insert(bp.id);
                }
            }
            if t.kind == Kind::Defence && t.target.is_some() && !t.units.is_empty() {
                let under = brain.fields.danger(t.site.unwrap_or(t.pos)) > 0.01;
                if under != t.urgent {
                    t.urgent = under;
                    if under {
                        t.priority = Priority::High;
                        t.cost_metal *= 8.0;
                    } else {
                        t.priority = Priority::Normal;
                        t.cost_metal /= 8.0;
                    }
                }
            }
            let target = t.target.and_then(|tid| world.get(tid));
            let done = match t.kind {
                Kind::Guard => now > t.until || target.is_none(),
                Kind::Repair => target.map_or(true, |x| x.health_share() > 0.98),
                Kind::Reclaim | Kind::Resurrect => {
                    !world.remains.iter().any(|r| r.p.dist(t.pos) < 30.0) || (t.timeout > 0.0 && now > t.created + t.timeout)
                }
                _ => match target {
                    Some(x) => x.built,
                    None => false,
                },
            };
            let lost = t.target.is_some() && target.is_none() && !matches!(t.kind, Kind::Guard | Kind::Repair | Kind::Reclaim | Kind::Resurrect);
            let timed_out = t.target.is_none() && t.timeout > 0.0 && now > t.created + t.timeout;
            let failed = t.fails > 2 && t.target.is_none();
            let how = if done {
                "done"
            } else if lost {
                "lost"
            } else if timed_out {
                "timeout"
            } else if failed || t.fails > TASK_RETRIES {
                "failed"
            } else {
                ""
            };
            if !how.is_empty() {
                *self.outcomes.entry(format!("{:?}:{how}", t.kind)).or_insert(0) += 1;
            }
            if done {
                let t = self.remove_keep_chain(id);
                if let Some(t) = t {
                    finished.push(t);
                }
            } else if !how.is_empty() {
                if let Some(t) = self.remove(id) {
                    aborted.push(t);
                }
            }
        }
        self.prev_built = world.own.iter().map(|&i| &world.units[i]).filter(|x| x.built).map(|x| x.id).collect();
        (finished, aborted)
    }

    /// Removes a finished task, activating the next one in its chain.
    fn remove_keep_chain(&mut self, id: u64) -> Option<Task> {
        let t = self.tasks.remove(&id)?;
        for u in &t.units {
            self.unit_task.remove(u);
        }
        if let Some(n) = t.next {
            if let Some(nt) = self.tasks.get_mut(&n) {
                nt.active = true;
            }
        }
        Some(t)
    }

    pub fn metal_pull(&self, brain: &Brain) -> f64 {
        self.tasks
            .values()
            .filter(|t| t.active && t.def.is_some() && !brain.economy.ignores_pull(t))
            .map(|t| t.bp_metal)
            .sum()
    }

    pub fn blocked_site(&self, def: DefId, p: P) -> bool {
        self.is_blocked(def, p)
    }
}

/// Which spots are taken (an extractor of anyone's on it, or a task of its own for it) and which are its own.
fn refresh_spots(b: &Builders, brain: &mut Brain, world: &World) {
    let n = brain.metal.spots.len();
    let mut taken = vec![false; n];
    let mut mine = vec![false; n];
    for u in &world.units {
        if brain.defs.list[u.def].m.spot.as_deref() != Some("metal") {
            continue;
        }
        if let Some(s) = brain.metal.nearest_spot(u.p) {
            if brain.metal.spots[s].0.dist(u.p) < 6.0 {
                taken[s] = true;
                if u.team == brain.me && u.built {
                    mine[s] = true;
                }
            }
        }
    }
    for t in b.tasks.values() {
        if t.kind == Kind::Mex {
            if let Some(s) = t.spot {
                taken[s] = true;
            }
        }
    }
    brain.metal.taken = taken;
    brain.metal.mine = mine;
}

fn nearest_lab(brain: &Brain, world: &World, p: P) -> Option<Unit> {
    world
        .own
        .iter()
        .map(|&i| &world.units[i])
        .filter(|x| x.built && brain.defs.list[x.def].factory && brain.defs.list[x.def].is_building)
        .min_by(|x, y| x.p.dist(p).total_cmp(&y.p.dist(p)))
        .cloned()
}

/// sim_barb's opening: its commander's first orders, planned at the start: opening_mex extractors on the spots nearest
/// it within hunt_home of home, opening_energy of the commander's cheapest energy (by what it makes, `scaled_energy`)
/// at its energy site, and then its line's first lab, facing the enemy from home.
/// sim_barb's cluster_site (server/ai/siting.luau): where `def` goes and how far to scatter it. Beside the one of its
/// kind nearest home (built, under way, or planned by a task), which the bridge's search then finds room next to; or,
/// with none yet, where a block of its kind starts: ECONOMY_OFFSET back from home, stores as far again to one side.
pub fn cluster_site(b: &Builders, brain: &Brain, world: &World, def: DefId) -> (P, f64) {
    if !crate::params::Params::on(brain.params.energy_cluster) {
        return (brain.energy_base(), 8.0 * 8.0 * ELMO);
    }
    let home = brain.home;
    let anchor = world
        .own
        .iter()
        .map(|&i| &world.units[i])
        .filter(|u| u.def == def)
        .map(|u| u.p)
        .chain(b.tasks.values().filter(|t| t.active && t.def == Some(def)).map(|t| t.site.unwrap_or(t.pos)))
        .min_by(|a, c| a.dist(home).total_cmp(&c.dist(home)));
    if let Some(at) = anchor {
        // a footprint over toward home, so the block grows homeward (sim_barb's anchors go nearest home first)
        let step = brain.defs.list[def].m.radius.max(2.0) * 2.0;
        let toward = if at.dist(home) > step { home.sub(at).norm().scale(step) } else { P::new(0.0, 0.0) };
        return (brain.map.clamp(at.add(toward)), 0.0);
    }
    const ECONOMY_OFFSET: f64 = 22.0;
    let forward = brain.toward_enemy();
    let mut seed = home.sub(forward.scale(ECONOMY_OFFSET));
    let od = &brain.defs.list[def];
    if od.m.energy_storage > 0.0 && od.energy_make <= 0.0 && od.m.wind <= 0.0 {
        seed = seed.add(P::new(-forward.z, forward.x).scale(ECONOMY_OFFSET));
    }
    (brain.map.clamp(seed), 0.0)
}

fn plan_opening(eco: &crate::economy::Economy, brain: &Brain, world: &World, c: &Unit) -> Vec<(Kind, DefId, P)> {
    let d = &brain.defs.list[c.def];
    let mut steps = Vec::new();
    if let Some(mex) = brain.defs.plain_extractor.filter(|m| d.options.contains(m)) {
        let mut spots: Vec<usize> = (0..brain.metal.spots.len())
            .filter(|&s| !brain.metal.taken[s] && brain.metal.spots[s].0.dist(brain.home) <= brain.params.hunt_home)
            .filter(|&s| brain.map.reachable(d.m.ground.as_deref(), c.p, brain.metal.spots[s].0))
            .collect();
        spots.sort_by(|&a, &b| brain.metal.spots[a].0.dist2(c.p).total_cmp(&brain.metal.spots[b].0.dist2(c.p)));
        for s in spots.into_iter().take(brain.params.opening_mex.round().max(0.0) as usize) {
            steps.push((Kind::Mex, mex, brain.metal.spots[s].0));
        }
    }
    if let Some(energy) = eco.scaled_energy(brain, c) {
        for _ in 0..brain.params.opening_energy.round().max(0.0) as usize {
            steps.push((Kind::Energy, energy, brain.energy_base()));
        }
    }
    let line = eco.line.clone().unwrap_or_else(|| "bots".to_string());
    if let Some(lab) = brain.defs.labs.get(&line).and_then(|l| l.0).filter(|l| d.options.contains(l)) {
        let at = brain.map.clamp(brain.home.add(brain.toward_enemy().scale(12.0)));
        steps.push((Kind::Factory, lab, at));
    }
    let _ = world;
    steps
}

/// BuilderManager each thought: the pool's upkeep, the economy's timed tasks, porcupine, and a task for every builder
/// without one (DefaultMakeTask: MakeEnergizerTask, MakeCommTask or MakeBuilderTask, else CreateBuilderTask).
pub fn run(b: &mut Builders, eco: &mut crate::economy::Economy, brain: &mut Brain, world: &World) {
    let now = brain.now;
    let builders: Vec<Unit> = world
        .own
        .iter()
        .map(|&i| world.units[i].clone())
        .filter(|u| {
            let d = &brain.defs.list[u.def];
            u.built && d.mobile && d.m.buildpower > 0.0 && !d.factory
        })
        .collect();
    // workers: its constructors (a resurrection bot builds nothing)
    let all_workers = crate::params::Params::on(brain.params.workers_all);
    b.workers = builders.iter().filter(|u| !brain.defs.list[u.def].commander && (all_workers || !brain.defs.list[u.def].options.is_empty())).count();
    let alive: crate::HashSet<i64> = world.own.iter().map(|&i| world.units[i].id).collect();
    b.unit_task.retain(|u, _| alive.contains(u));
    b.retreating.retain(|u, _| alive.contains(u));
    b.danger_time.retain(|u, _| alive.contains(u));
    b.fleeing.retain(|u, _| alive.contains(u));

    let (finished, aborted) = b.upkeep(world, brain);
    refresh_spots(b, brain, world);
    // energy all but full: energy tasks nobody has begun are dropped
    let banked = crate::params::Params::on(brain.params.energy_full_enough) && eco.state.energy_full && !eco.state.energy_stalling;
    if banked {
        let idle: Vec<u64> = b.tasks.values().filter(|t| t.kind == Kind::Energy && t.units.is_empty() && t.target.is_none()).map(|t| t.id).collect();
        for id in idle {
            b.remove(id);
        }
    }
    // CBEnergyTask Finish / Cancel: energy is no longer required; still stalling, more of it
    for t in finished.iter().chain(aborted.iter()).filter(|t| t.kind == Kind::Energy) {
        eco.energy_required = false;
        if eco.state.energy_stalling {
            eco.update_energy_tasks(b, brain, world, t.site.unwrap_or(t.pos), None);
        }
    }
    for t in finished {
        if let Some(def) = t.def {
            if brain.defs.list[def].is_building {
                eco.execute_chain(b, brain, world, def, t.site.unwrap_or(t.pos));
            }
        }
    }
    eco.update_factory_tasks(b, brain, world);
    eco.update_storage_tasks(b, brain, world);
    crate::porc::update(b, brain, world);

    // energizers (builder.as): its first two builders of the second tier, if it has them (a switch)
    for u in builders.iter().filter(|_| crate::params::Params::on(brain.params.energizers)) {
        let d = &brain.defs.list[u.def];
        if d.commander || d.tech < 2.0 || b.energizer1 == Some(u.id) || b.energizer2 == Some(u.id) {
            continue;
        }
        if b.energizer1.map_or(true, |e| !alive.contains(&e)) {
            b.energizer1 = Some(u.id);
        } else if b.energizer2.map_or(true, |e| !alive.contains(&e)) {
            b.energizer2 = Some(u.id);
        }
    }

    // isNotReady: metal not in excess, or stalling with the builders pulling more than their share
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
    let s = eco.state.clone();
    let stalling = s.metal_empty && s.metal_income * 1.2 < s.metal_pull && b.metal_pull > eco.pull_m_to_s(brain, army_cost, enemy_mobile) * brain.factory.metal_pull;
    let not_ready = !eco.is_excessed() || stalling;

    let haven = nearest_lab(brain, world, brain.home).map(|u| u.p).unwrap_or(brain.home);
    let enemy_air = world.enemy.iter().any(|&i| brain.defs.list[world.units[i].def].air && brain.defs.list[world.units[i].def].armed);

    for u in &builders {
        let d = brain.defs.list[u.def].clone();
        let danger = brain.fields.danger(u.p);
        let power = d.thr_surf.max(d.thr_air) * u.hp.max(0.0).sqrt();

        // sim_barb's flee (server/ai/errands.luau): a constructor where the enemy's threat is over builder_flee_danger
        // and the enemy's influence outweighs its own drops what it is doing and makes for home, for flee_seconds at
        // least, whether or not it has been hit
        if !d.commander {
            let threatened = danger > brain.params.builder_flee_danger && brain.fields.influence_at(u.p) < -0.01;
            if threatened {
                if !b.fleeing.contains_key(&u.id) {
                    b.release(u.id, brain);
                }
                b.fleeing.insert(u.id, now);
            }
            if let Some(&since) = b.fleeing.get(&u.id) {
                if now - since < brain.params.flee_seconds && u.p.dist(haven) > 20.0 {
                    if !brain.recently_sent(u.id, haven, "move", 20.0, 5.0) {
                        brain.go(u, haven, "move", brain.params.builder_threat_weight * 2.0);
                    }
                    continue;
                }
                b.fleeing.remove(&u.id);
            }
        }
        // retreat (OnUnitDamaged / RetreatTask): hurt under its retreat health where there is danger
        if b.retreating.contains_key(&u.id) {
            if u.health_share() > 0.98 || (danger < THREAT_MIN && u.p.dist(haven) < 30.0) {
                b.retreating.remove(&u.id);
            } else {
                if u.p.dist(haven) > 20.0 && !brain.recently_sent(u.id, haven, "move", 20.0, 8.0) {
                    brain.go(u, haven, "move", brain.params.builder_threat_weight);
                }
                continue;
            }
        }
        let retreat = d.retreat * brain.params.retreat_scale;
        if u.health_share() < retreat && danger > THREAT_MIN.max(power) {
            b.release(u.id, brain);
            b.retreating.insert(u.id, now);
            brain.stats.retreats += 1;
            if !b.tasks.values().any(|t| t.kind == Kind::Repair && t.target == Some(u.id)) {
                let id = b.enqueue(now, Kind::Repair, Priority::High, None, haven, 0.0, true, 0.0, brain);
                b.tasks.get_mut(&id).unwrap().target = Some(u.id);
            }
            brain.go(u, haven, "move", brain.params.builder_threat_weight);
            continue;
        }

        // sim_barb's opening: the commander's first orders, one step at a time, before anything else it would do
        if d.commander {
            if b.opening.is_none() {
                b.opening = Some(if crate::params::Params::on(brain.params.opening) { plan_opening(eco, brain, world, u) } else { Vec::new() });
            }
            // where the bridge put the step queued last thought
            for r in brain.results.iter().filter(|r| r.tag.as_deref() == Some("open") && r.ok) {
                if let (Some(x), Some(z)) = (r.x, r.z) {
                    b.opening_queued = Some(P::new(x, z));
                }
            }
            let free = !b.unit_task.contains_key(&u.id);
            if free {
                if let Some((kind, def, at)) = b.opening.as_mut().filter(|s| !s.is_empty()).map(|s| s.remove(0)) {
                    let queued = b.opening_queued.take();
                    let (at, shake) = match kind {
                        _ if queued.is_some() => (queued.unwrap(), 0.0),
                        Kind::Mex | Kind::Factory => (at, 0.0),
                        _ if crate::params::Params::on(brain.params.energy_cluster) => cluster_site(b, brain, world, def),
                        _ => (at, 8.0 * 8.0 * ELMO),
                    };
                    let id = b.enqueue(now, kind, Priority::Now, Some(def), at, shake, true, 120.0, brain);
                    if kind == Kind::Mex {
                        b.tasks.get_mut(&id).unwrap().spot = brain.metal.nearest_spot(at);
                    }
                    // the blueprint its queued order has put down already: carry on with that
                    if queued.is_some() {
                        let held: crate::HashSet<i64> = b.tasks.values().filter_map(|t| t.target).collect();
                        if let Some(bp) = world
                            .own
                            .iter()
                            .map(|&i| &world.units[i])
                            .filter(|x| x.def == def && !x.built && !held.contains(&x.id) && x.p.dist(at) < 30.0)
                            .min_by(|a, c| a.p.dist(at).total_cmp(&c.p.dist(at)))
                        {
                            b.tasks.get_mut(&id).unwrap().target = Some(bp.id);
                        }
                    }
                    b.opening_task = Some(id);
                    // at work on its queued order still: taken on without a new order, which would replace it (the
                    // blueprint is picked up by the pool's upkeep once it is seen)
                    if queued.is_some() && b.tasks[&id].target.is_none() && !u.idle() {
                        let t = b.tasks.get_mut(&id).unwrap();
                        t.units.push(u.id);
                        recompute_power(t, brain);
                        b.unit_task.insert(u.id, id);
                        brain.sent.insert(u.id, (at, "build", now));
                        continue;
                    }
                    b.assign(u, id, brain);
                    continue;
                }
            } else if crate::params::Params::on(brain.params.opening_queue) && b.opening_queued.is_none() {
                // the next step queued behind the one under way, as sim_barb gives its opening as one queue: once the
                // one under way is on the ground where it is to be built beside it (a site is found when it is asked
                // for, and would be the same one)
                let current = b.unit_task.get(&u.id).copied().filter(|&t| Some(t) == b.opening_task).and_then(|t| b.tasks.get(&t));
                let next = b.opening.as_ref().and_then(|s| s.first()).copied();
                if let (Some(t), Some((kind, def, at))) = (current, next) {
                    let near = t.kind == Kind::Energy || t.kind == Kind::Store;
                    if t.target.is_some() || (!near && kind != Kind::Energy) {
                        let at = if kind == Kind::Energy && crate::params::Params::on(brain.params.energy_cluster) { cluster_site(b, brain, world, def).0 } else { at };
                        let search = if kind == Kind::Mex { 0.0 } else { 60.0 };
                        brain.build_queued(u, def, at, search, Some("open".to_string()));
                        b.opening_queued = Some(at);
                    }
                }
            }
        }
        // the commander keeps from threat it cannot face (MakeCommTask's danger check), and near base once hidden
        let mut mode = Mode::Builder;
        if d.commander {
            let info = brain.barb.commanders.values().next().cloned();
            let (hide_time, hide_threat, hide_air, rads) = info
                .map(|c| (c.hide.time, c.hide.threat, c.hide.air, c.hide.task_rad.clone()))
                .unwrap_or((420.0, 8.0, true, vec![2000.0, 800.0]));
            if danger > hide_threat.max(power) {
                b.danger_time.insert(u.id, now);
            }
            if b.danger_time.get(&u.id).map_or(false, |&t| now - t < 5.0) {
                b.release(u.id, brain);
                if u.p.dist(haven) > 20.0 && !brain.recently_sent(u.id, haven, "move", 20.0, 4.0) {
                    brain.go(u, haven, "move", brain.params.builder_threat_weight * 2.0);
                }
                continue;
            }
            let hidden = now > hide_time && (brain.groups.pre_max_influence() > hide_threat || (hide_air && enemy_air));
            let radius = if hidden { rads.get(1).copied().unwrap_or(800.0) } else { rads.first().copied().unwrap_or(2000.0) } * ELMO;
            // sim_barb's commander keeps within its base radius (ai/census.luau duty_for: reach = base_radius)
            // (after commander_reach_after seconds: before, BARb's reach, as it takes the spots round it)
            let radius = if now >= brain.params.commander_reach_after { radius.min(brain.params.commander_reach) } else { radius };
            mode = Mode::Commander { radius };
        } else if b.energizer1 == Some(u.id) || b.energizer2 == Some(u.id) {
            mode = Mode::Energizer;
        }

        // on a task: keep at it, and give the order again if it stands idle
        if let Some(&tid) = b.unit_task.get(&u.id) {
            if let Some(t) = b.tasks.get(&tid).cloned() {
                if u.idle() && !brain.sent.get(&u.id).map_or(false, |(_, _, at)| now - at < 3.0) {
                    b.execute(u, &t, brain);
                }
                continue;
            }
            b.unit_task.remove(&u.id);
        }
        if !u.idle() && brain.sent.get(&u.id).map_or(false, |(_, _, at)| now - at < 2.0) {
            continue;
        }

        // MakeBuilderTask: help a lab that wants it, else the economy's tasks from where it stands, then the pool
        let builds = !d.options.is_empty();
        // an advanced constructor upgrades extractors before anything else (sim_barb's extractor_upgrade)
        if builds && !d.commander {
            let upgrading = |t: &Task| t.kind == Kind::MexUp;
            // each its own extractor, as sim_barb's are: a new upgrade first, joining one under way only if there is none
            let id = eco.upgrade_task(b, brain, world, u).or_else(|| b.pick_of(u, brain, &mode, false, Some(&upgrading)));
            if let Some(id) = id.filter(|id| b.tasks.get(id).map_or(false, |t| b.can_assign(t, u, brain))) {
                b.assign(u, id, brain);
                continue;
            }
        }
        // sim_barb's order (server/ai/economy_planner.luau's WANTS): a lab waiting to go up comes first
        // and its construction turrets right after (sim_barb's WANTS: labs, then turrets)
        let turrets_first = crate::params::Params::on(brain.params.turrets_first);
        let is_lab = |t: &Task| t.kind == Kind::Factory || (turrets_first && t.kind == Kind::Nano);
        if let Some(id) = b.pick_of(u, brain, &mode, false, Some(&is_lab)) {
            b.assign(u, id, brain);
            continue;
        }
        // sim_barb's extractor_builders (server/ai/economy_planner.luau): while fewer than that share of its workers are
        // out taking and guarding spots, a free one takes the best extractor task, or a defence of an extractor cluster,
        // before anything nearer home
        let with_guards = crate::params::Params::on(brain.params.reserve_defences);
        let expanding = |t: &Task| t.kind == Kind::Mex || (with_guards && t.kind == Kind::Defence && t.def_point.is_some());
        if builds && !d.commander && matches!(mode, Mode::Builder) {
            let out: usize = b.tasks.values().filter(|t| t.active && expanding(t)).map(|t| t.units.len()).sum();
            let want = (b.workers as f64 * brain.params.extractor_builders).ceil() as usize;
            if out < want {
                eco.make_economy_tasks(b, brain, world, u);
                if let Some(id) = b.pick_of(u, brain, &mode, false, Some(&expanding)) {
                    b.assign(u, id, brain);
                    continue;
                }
            }
        }
        // sim_barb's energy (server/ai/economy_planner.luau): while its energy income is under what its metal wants
        // (`energy_wanted`), one builder in three on energy, its commander too (a waiting lab comes first, above)
        let energy_at_once = (((b.workers + 1) as f64) / 3.0).ceil() as usize;
        if builds && !banked && (!d.commander || crate::params::Params::on(brain.params.commander_energy)) && eco.state.energy_income < eco.energy_wanted(brain, world) && b.count_of(Kind::Energy) < energy_at_once {
            let id = match eco.scaled_energy(brain, u) {
                Some(def) => {
                    let (at, shake) = cluster_site(b, brain, world, def);
                    Some(b.enqueue(now, Kind::Energy, Priority::Normal, Some(def), at, shake, true, 0.0, brain))
                }
                None => {
                    eco.force_energy = true;
                    let id = eco.update_energy_tasks(b, brain, world, u.p, Some(u));
                    eco.force_energy = false;
                    id
                }
            };
            if let Some(id) = id.filter(|id| b.tasks.get(id).map_or(false, |t| b.can_assign(t, u, brain))) {
                b.assign(u, id, brain);
                continue;
            }
        }
        // sim_barb's conversion (server/ai/economy_planner.luau `conversion_task`): while energy piles up, energy
        // stores until it holds storage_seconds of income and converter_storage, then converters burning no more than
        // converter_burn_share of the income, converters_at_once at a time
        if builds {
            if let Some(id) = eco.conversion_task(b, brain, world, u) {
                b.assign(u, id, brain);
                continue;
            }
        }
        let mut picked = eco.check_mobile_assist(b, brain, world, u);
        if picked.is_none() {
            eco.make_economy_tasks(b, brain, world, u);
            picked = b.pick(u, brain, &mode, not_ready);
            // nothing, and not ready: it keeps to what it was doing
            if picked.is_none() && not_ready && !d.commander {
                continue;
            }
        }
        // CreateBuilderTask: energy; else a reclaim task goes in the pool and it guards the nearest lab for a minute
        if picked.is_none() && !banked {
            picked = eco.update_energy_tasks(b, brain, world, u.p, Some(u));
        }
        if picked.is_none() {
            eco.update_reclaim_tasks(b, brain, world, u, false);
        }
        if picked.is_none() && d.m.assists {
            if let Some(lab) = nearest_lab(brain, world, u.p) {
                let id = b.enqueue(now, Kind::Guard, Priority::Normal, None, lab.p, 0.0, true, 0.0, brain);
                let t = b.tasks.get_mut(&id).unwrap();
                t.target = Some(lab.id);
                t.until = now + 60.0;
                picked = Some(id);
            }
        }
        if let Some(id) = picked {
            b.assign(u, id, brain);
        }
    }

    // construction turrets: guard the lab they stand by
    for &i in &world.own {
        let u = &world.units[i];
        let d = &brain.defs.list[u.def];
        if !(u.built && !d.mobile && !d.factory && d.m.assists && d.m.buildpower > 0.0 && u.idle()) {
            continue;
        }
        if brain.sent.get(&u.id).map_or(false, |(_, _, at)| now - at < 10.0) {
            continue;
        }
        let range = d.m.build_range.max(1.0);
        if let Some(lab) = nearest_lab(brain, world, u.p).filter(|l| l.p.dist(u.p) < range) {
            let u = u.clone();
            brain.order_target(&u, "guard", lab.id, lab.p);
        }
    }
    b.metal_pull = b.metal_pull(brain);

    let mut kinds: HashMap<String, (usize, usize)> = HashMap::default();
    for t in b.tasks.values().filter(|t| t.active) {
        let e = kinds.entry(format!("{:?}", t.kind)).or_insert((0, 0));
        e.0 += 1;
        e.1 += t.units.len();
    }
    let idle = builders.iter().filter(|u| !b.unit_task.contains_key(&u.id)).count();
    let spots_debug = {
            let m = &brain.metal;
            let free: Vec<usize> = (0..m.spots.len()).filter(|&i| !m.taken[i]).collect();
            let danger = free.iter().filter(|&&i| brain.fields.danger(m.spots[i].0) > THREAT_MIN).count();
            let influence = free.iter().filter(|&&i| brain.fields.influence_at(m.spots[i].0) < -0.01).count();
            let cluster = free.iter().filter(|&&i| brain.fields.danger(m.clusters[m.spot_cluster[i]].p) > THREAT_MIN).count();
            serde_json::json!({"all": m.spots.len(), "free": free.len(), "danger": danger, "enemy_influence": influence, "cluster_danger": cluster})
    };
    eco.debug = serde_json::json!({
        "mi": (s.metal_income * 10.0).round() / 10.0,
        "ei": (s.energy_income * 10.0).round() / 10.0,
        "m": s.metal.round(),
        "e": s.energy.round(),
        "estall": s.energy_stalling,
        "mex": brain.metal.mine.iter().filter(|m| **m).count(),
        "workers": b.workers,
        "free": idle,
        "not_ready": not_ready,
        "excessed": eco.is_excessed(),
        "tasks": kinds,
        "mex_why": b.why.borrow().clone(),
        "outcomes": b.outcomes.clone(),
        "spots": spots_debug,
        "energy_tasks": b.tasks.values().filter(|t| t.kind == Kind::Energy).map(|t| format!("#{} {} pos {:.0},{:.0} site {:?} target {:?} units {:?} age {:.0} fails {}", t.id, t.def.map(|d| brain.defs.list[d].name.clone()).unwrap_or_default(), t.pos.x, t.pos.z, t.site.map(|p| (p.x.round(), p.z.round())), t.target, t.units, now - t.created, t.fails)).collect::<Vec<_>>(),
        "builders_at": builders.iter().map(|u| (u.id, (u.p.x.round(), u.p.z.round()), b.unit_task.get(&u.id).and_then(|id| b.tasks.get(id)).map(|t| format!("{:?}@{:.0},{:.0}", t.kind, t.pos.x, t.pos.z)), format!("{}{}:{}", if brain.defs.list[u.def].commander { "C " } else if brain.defs.list[u.def].tech >= 2.0 { "A " } else { "" }, u.order.clone().unwrap_or_default(), u.orders))).collect::<Vec<_>>(),
    });
    b.why.borrow_mut().clear();
}
