//! BARb's MilitaryManager and fighter tasks (CircuitAI barbarian: module/MilitaryManager.cpp `DefaultMakeTask`,
//! `EnqueueTask`, `FillFrontPos`, `FillSafePos`; task/fighter/{FighterTask, SquadTask, DefendTask, AttackTask,
//! RaidTask, ScoutTask, AntiAirTask, ArtilleryTask, GuardTask}.cpp; task/RetreatTask.cpp; see PORTING.md).
//!
//! Each fighter is in one task. A new one's task comes from its main role (`make_task`); most start in a DEFEND task
//! that stands at the front and is promoted to a new ATTACK (or RAID) task once it has the power, or once a task of
//! that kind exists. Squads merge into stronger ones of their kind, regroup when strung out, and attack from arcs round
//! their target. A hurt unit goes home to be repaired as BARb's OnUnitDamaged has it.
//!
//! What the Rust AI adds, at BARb's own decision points: an ATTACK or RAID target BARb's rule accepts must also be won
//! in the battle simulator (`sim_gate`), an engaged attack the simulator says is losing falls back to defending, and
//! desperation (fronts.rs) raises the power modifiers and at last sends everything at the enemy's commander.

use crate::brain::Brain;
use crate::builders::{Builders, Kind as BKind, Priority, ELMO, MAX_TRAVEL_SEC, THREAT_MIN};
use crate::map::P;
use crate::params::Params;
use crate::sim::{Fighter, Options};
use crate::world::{Unit, World};
use serde_json::json;
use crate::{HashMap, HashSet};

const INFL_SAFE: f64 = 2.0;
const INFL_EPS: f64 = 0.01;
const RANGE_MOD: f64 = 0.8;

#[derive(Clone, Copy, PartialEq, Eq, Debug, Hash)]
pub enum Fight {
    Defend,
    Attack,
    Raid,
    Scout,
    AA,
    Arty,
    Bomb,
    Guard,
    AllIn,
    /// sim_barb's hunt: a few of what waits at home after an intruder
    Hunt,
}

#[derive(Clone, Copy, PartialEq, Eq, Debug)]
pub enum State {
    Roam,
    Engage,
    Regroup,
}

#[derive(Clone, Debug)]
pub struct Task {
    pub id: u64,
    pub kind: Fight,
    pub units: Vec<i64>,
    /// for a DEFEND task: what it becomes, the kind whose existence promotes it, and at what power
    pub promote: Fight,
    pub check: Fight,
    pub max_power: f64,
    pub power_mod: f64,
    pub position: P,
    pub target: Option<i64>,
    pub state: State,
    pub updates: u64,
    pub group_pos: P,
    /// for a GUARD task: the builder it escorts
    pub vip: Option<i64>,
    pub last_check: f64,
    /// for a HUNT: where it holds when its prey outruns it (its own nearest the prey)
    pub guard: Option<P>,
}

#[derive(Default)]
pub struct Military {
    pub tasks: HashMap<u64, Task>,
    pub unit_task: HashMap<i64, u64>,
    next_id: u64,
    /// units retreating to be mended, since when
    pub retreating: HashMap<i64, f64>,
    last_hp: HashMap<i64, f64>,
    /// retreating units that have got to the haven, since when
    arrived: HashMap<i64, f64>,
    all_in: bool,
    /// the intruder near home the whole army is seeing off (sim_barb's army.luau `defending`), and when it was judged
    home_intruder: Option<i64>,
    home_checked: f64,
}

impl Military {
    pub fn new() -> Military {
        Military::default()
    }

    pub fn is_escorted(&self, builder: i64) -> bool {
        self.tasks.values().any(|t| t.kind == Fight::Guard && t.vip == Some(builder) && !t.units.is_empty())
    }

    pub fn describe(&self) -> serde_json::Value {
        let mut counts: HashMap<String, (usize, usize)> = HashMap::default();
        for t in self.tasks.values() {
            let e = counts.entry(format!("{:?}", t.kind)).or_insert((0, 0));
            e.0 += 1;
            e.1 += t.units.len();
        }
        json!({"tasks": counts, "retreating": self.retreating.len(), "all_in": self.all_in})
    }

    /// EnqueueTask, with each kind's power modifier (AttackTask 0.8, RaidTask 0.75, AntiAirTask 1, BombTask 2, over a
    /// random thr_mod.attack), made bolder by desperation and by winning.
    fn enqueue(&mut self, kind: Fight, brain: &mut Brain) -> u64 {
        self.next_id += 1;
        let id = self.next_id;
        let (amin, amax) = (brain.params.attack_thr - 0.1, brain.params.attack_thr + 0.1);
        let modr = (amin + brain.rng.unit() * (amax - amin)).max(0.05);
        let bold = 1.0 + brain.fronts.desperation * brain.params.desperation_margin_drop * 2.0 + if brain.fronts.standing >= brain.params.winning_push { 0.5 } else { 0.0 };
        let power_mod = match kind {
            Fight::Attack | Fight::AllIn => 0.8 / modr * bold,
            Fight::Raid | Fight::Scout => 0.75 / modr * bold,
            Fight::AA => 1.0 / modr,
            Fight::Bomb => 2.0 / modr,
            _ => 1.0,
        };
        let pos = brain.home;
        self.tasks.insert(
            id,
            Task {
                id,
                kind,
                units: Vec::new(),
                promote: kind,
                check: kind,
                max_power: 0.0,
                power_mod,
                position: pos,
                target: None,
                state: State::Roam,
                updates: 0,
                group_pos: pos,
                vip: None,
                last_check: 0.0,
                guard: None,
            },
        );
        id
    }

    /// TaskF::Defend(promote, power): a DEFEND task promoted to `promote` at `power` over a random thr_mod.defence.
    fn enqueue_defend(&mut self, promote: Fight, power: f64, brain: &mut Brain) -> u64 {
        let id = self.enqueue(Fight::Defend, brain);
        let (dmin, dmax) = (brain.params.defence_thr - 0.1, brain.params.defence_thr + 0.1);
        let m = (dmin + brain.rng.unit() * (dmax - dmin)).max(0.05);
        let t = self.tasks.get_mut(&id).unwrap();
        t.promote = promote;
        t.check = promote;
        t.max_power = power / m;
        id
    }

    fn assign(&mut self, unit: i64, id: u64) {
        if let Some(old) = self.unit_task.insert(unit, id) {
            if old != id {
                if let Some(t) = self.tasks.get_mut(&old) {
                    t.units.retain(|&u| u != unit);
                }
            }
        }
        if let Some(t) = self.tasks.get_mut(&id) {
            if !t.units.contains(&unit) {
                t.units.push(unit);
            }
        }
    }

    fn release(&mut self, unit: i64) {
        if let Some(old) = self.unit_task.remove(&unit) {
            if let Some(t) = self.tasks.get_mut(&old) {
                t.units.retain(|&u| u != unit);
            }
        }
    }

    fn members(&self, world: &World, id: u64) -> Vec<Unit> {
        self.tasks.get(&id).map(|t| t.units.iter().filter_map(|u| world.get(*u).cloned()).collect()).unwrap_or_default()
    }

    /// IFighterTask::attackPower: the sum of its members' power.
    fn power(brain: &Brain, units: &[Unit]) -> f64 {
        units.iter().map(|u| brain.defs.list[u.def].barb_power).sum()
    }

    /// ISquadTask::FindLeader: the slowest member leads.
    fn leader<'a>(brain: &Brain, units: &'a [Unit]) -> Option<&'a Unit> {
        units.iter().min_by(|a, b| brain.defs.list[a.def].speed.total_cmp(&brain.defs.list[b.def].speed))
    }

    /// The pace of `units` together: their slowest's top speed.
    fn pace(brain: &Brain, units: &[Unit]) -> f64 {
        let p = units.iter().map(|u| brain.defs.list[u.def].speed).fold(f64::MAX, f64::min);
        if p == f64::MAX { 0.0 } else { p }
    }

    /// Whether `units` (led from `from`) can get at `e`: it stands still for good (a building), is no faster than
    /// their pace, is in their reach already, or is not getting away from them (holding still, or coming on).
    fn catchable(brain: &Brain, units: &[Unit], from: P, e: &Unit) -> bool {
        let ed = &brain.defs.list[e.def];
        if !Params::on(brain.params.chase_check) || !ed.mobile || ed.air {
            return true;
        }
        let pace = Self::pace(brain, units);
        if ed.speed <= pace * 1.05 {
            return true;
        }
        let gap = e.p.sub(from);
        let dist = gap.len();
        if dist <= Self::highest_range(brain, units) + 5.0 {
            return true;
        }
        // how fast it is opening the gap
        let opening = (e.v.x * gap.x + e.v.z * gap.z) / dist.max(1e-6);
        opening < pace * 0.25
    }

    /// Where `units` meet `e`: where it will be by the time they get there (but never more than a few seconds on).
    fn lead_point(brain: &Brain, units: &[Unit], from: P, e: &Unit) -> P {
        if !Params::on(brain.params.chase_check) || e.v.len() < 0.5 {
            return e.p;
        }
        let pace = Self::pace(brain, units).max(1.0);
        let t = (e.p.dist(from) / pace).min(4.0);
        brain.map.clamp(e.p.add(e.v.scale(t)))
    }

    fn highest_range(brain: &Brain, units: &[Unit]) -> f64 {
        units.iter().map(|u| brain.defs.list[u.def].range_ground.max(brain.defs.list[u.def].range_air)).fold(0.0, f64::max)
    }

    // Task by role ------------------------------------------------------------------------------------------------

    /// DefaultMakeTask.
    fn make_task(&mut self, u: &Unit, brain: &mut Brain, world: &World) {
        let role = brain.defs.main_role(u.def).to_string();
        let attack_power = brain.params.attack_min_power.max(brain.groups.pre_max_influence());
        let escort_until = brain.barb.escort[2];
        let escort_each = brain.barb.escort[1];
        let guard = if brain.now <= escort_until {
            self.tasks.values().find(|t| t.kind == Fight::Guard && (t.units.len() as f64) < escort_each).map(|t| t.id)
        } else {
            None
        };
        let scouts = self.tasks.values().filter(|t| t.kind == Fight::Scout).count() as f64;
        let existing = |this: &Self, k: Fight| this.tasks.values().find(|t| t.kind == k).map(|t| t.id);
        let id = match role.as_str() {
            "scout" if scouts < brain.barb.quota_scout => self.enqueue(Fight::Scout, brain),
            "raider" => match guard {
                Some(g) => g,
                None => self.enqueue_defend(Fight::Raid, brain.params.raid_min_power, brain),
            },
            "riot" => match guard {
                Some(g) => g,
                None => self.enqueue_defend(Fight::Attack, attack_power, brain),
            },
            "artillery" => match existing(self, Fight::Arty) {
                Some(t) => t,
                None => self.enqueue(Fight::Arty, brain),
            },
            "anti_air" => self.enqueue(Fight::AA, brain),
            "bomber" => self.enqueue(Fight::Bomb, brain),
            "anti_heavy" if crate::factory::enemy_role_cost(brain, world, "heavy") >= 1.0 => self.enqueue(Fight::Attack, brain),
            _ => self.enqueue_defend(Fight::Attack, attack_power, brain),
        };
        self.assign(u.id, id);
    }

    pub fn run(&mut self, brain: &mut Brain, world: &World, builders: &mut Builders) {
        let now = brain.now;
        let alive: HashSet<i64> = world.own.iter().map(|&i| world.units[i].id).collect();
        for t in self.tasks.values_mut() {
            t.units.retain(|u| alive.contains(u));
        }
        self.unit_task.retain(|u, _| alive.contains(u));
        self.retreating.retain(|u, _| alive.contains(u));
        self.last_hp.retain(|u, _| alive.contains(u));

        // escort guard tasks for the first constructors (BuilderManager's worker-created handler)
        let [escorted, _, until] = brain.barb.escort;
        if now <= until {
            let list: Vec<i64> = world
                .own
                .iter()
                .map(|&i| &world.units[i])
                .filter(|u| {
                    let d = &brain.defs.list[u.def];
                    u.built && d.builder && d.mobile && !d.commander && !d.armed
                })
                .map(|u| u.id)
                .collect();
            for b in list {
                let guards = self.tasks.values().filter(|t| t.kind == Fight::Guard).count();
                if (guards as f64) < escorted && !self.tasks.values().any(|t| t.vip == Some(b)) {
                    let id = self.enqueue(Fight::Guard, brain);
                    self.tasks.get_mut(&id).unwrap().vip = Some(b);
                }
            }
        }
        // a guard task ends with its builder, or its time
        let ended: Vec<u64> = self
            .tasks
            .values()
            .filter(|t| t.kind == Fight::Guard && (now > until || !t.vip.map_or(false, |v| alive.contains(&v))))
            .map(|t| t.id)
            .collect();
        for id in ended {
            let units = self.tasks.remove(&id).map(|t| t.units).unwrap_or_default();
            for u in units {
                self.unit_task.remove(&u);
            }
        }

        let fighters: Vec<Unit> = world
            .own
            .iter()
            .map(|&i| world.units[i].clone())
            .filter(|u| {
                let d = &brain.defs.list[u.def];
                u.built && d.mobile && d.armed && !d.commander && !d.builder
            })
            .collect();

        // hurt: OnUnitDamaged, as the health it lost since the last thought tells
        for u in &fighters {
            let before = self.last_hp.insert(u.id, u.hp).unwrap_or(u.hp);
            if !self.retreating.contains_key(&u.id) && u.hp < before - 1e-6 {
                self.on_damaged(u, brain, world, builders);
            }
        }
        // retreating: to the haven, and back to work when mended (RetreatTask); and, as sim_barb has it
        // (server/ai/retreats.luau), back to work anyway after repair_patience seconds there waiting to be mended, or
        // retreat_walk_seconds all told
        let haven = self.haven(brain, world);
        self.arrived.retain(|u, _| alive.contains(u));
        for u in &fighters {
            let Some(since) = self.retreating.get(&u.id).copied() else { continue };
            let at_haven = u.p.dist(haven) <= 30.0;
            if at_haven {
                self.arrived.entry(u.id).or_insert(now);
            }
            let waited = self.arrived.get(&u.id).map_or(0.0, |t| now - t);
            if u.health_share() > 0.98 || waited >= brain.params.repair_patience || now - since >= brain.params.retreat_walk_seconds {
                self.retreating.remove(&u.id);
                self.arrived.remove(&u.id);
                continue;
            }
            if at_haven {
                if !brain.defs.list[u.def].air && !builders.tasks.values().any(|t| t.kind == BKind::Repair && t.target == Some(u.id)) {
                    let id = builders.enqueue(now, BKind::Repair, Priority::High, None, u.p, 0.0, true, 0.0, brain);
                    builders.tasks.get_mut(&id).unwrap().target = Some(u.id);
                }
            } else if !brain.recently_sent(u.id, haven, "move", 20.0, 8.0) {
                brain.go(u, haven, "move", brain.params.builder_threat_weight);
            }
        }

        // all in, when desperate enough
        let was = self.all_in;
        self.all_in = brain.fronts.desperation >= brain.params.desperation_all_in || (was && brain.fronts.desperation >= brain.params.desperation_all_in - 0.15);
        if self.all_in && !was {
            brain.stats.all_ins += 1;
            let id = self.enqueue(Fight::AllIn, brain);
            for u in fighters.iter().filter(|u| !self.retreating.contains_key(&u.id)).map(|u| u.id).collect::<Vec<_>>() {
                self.assign(u, id);
            }
        }

        // new fighters get a task
        for u in &fighters {
            if self.unit_task.contains_key(&u.id) || self.retreating.contains_key(&u.id) {
                continue;
            }
            if self.all_in {
                if let Some(id) = self.tasks.values().find(|t| t.kind == Fight::AllIn).map(|t| t.id) {
                    self.assign(u.id, id);
                    continue;
                }
            }
            self.make_task(u, brain, world);
        }

        self.start_hunts(brain, world);
        self.judge_home(brain, world);
        let defending = self.home_intruder.and_then(|e| world.get(e)).cloned();
        let mut ids: Vec<u64> = self.tasks.keys().copied().collect();
        ids.sort_unstable();
        for id in ids {
            let Some(t) = self.tasks.get_mut(&id) else { continue };
            t.updates += 1;
            if t.units.is_empty() {
                if t.kind != Fight::Guard {
                    self.tasks.remove(&id);
                }
                continue;
            }
            if let Some(e) = defending.as_ref().filter(|_| matches!(t.kind, Fight::Attack | Fight::Raid | Fight::Scout | Fight::Defend | Fight::Hunt)) {
                self.defend_home(id, e, brain, world);
                continue;
            }
            match t.kind {
                Fight::Defend => self.update_defend(id, brain, world),
                Fight::Attack | Fight::AllIn => self.update_attack(id, brain, world),
                Fight::Raid | Fight::Scout | Fight::Bomb => self.update_raid(id, brain, world),
                Fight::AA => self.update_aa(id, brain, world),
                Fight::Arty => self.update_arty(id, brain, world),
                Fight::Guard => self.update_guard(id, brain, world),
                Fight::Hunt => self.update_hunt(id, brain, world),
            }
        }
        self.dgun(brain, world);
    }

    /// sim_barb's whole-army defence (server/ai/army.luau, defence.luau), judged every 3 seconds: the enemy's armed
    /// ground unit nearest home within defend_radius of it; if what waits at home (its DEFEND and HUNT tasks) would not
    /// beat it and what is round it by sim_defend_margin, every group comes to fight it, until it is dead or gone.
    fn judge_home(&mut self, brain: &mut Brain, world: &World) {
        if !Params::on(brain.params.home_defence) {
            self.home_intruder = None;
            return;
        }
        let radius = brain.params.defend_radius;
        // one being seen off is seen off until it is dead or well away
        if let Some(e) = self.home_intruder.and_then(|e| world.get(e)) {
            if e.p.dist(brain.home) <= radius * 1.3 {
                return;
            }
        }
        self.home_intruder = None;
        if brain.now - self.home_checked < 3.0 {
            return;
        }
        self.home_checked = brain.now;
        let intruder = world
            .enemy
            .iter()
            .map(|&i| &world.units[i])
            .filter(|e| {
                let d = &brain.defs.list[e.def];
                e.built && d.mobile && d.armed && d.dps_ground > 0.0 && !d.air && e.p.dist(brain.home) <= radius
            })
            .min_by(|a, b| a.p.dist(brain.home).total_cmp(&b.p.dist(brain.home)).then(a.id.cmp(&b.id)))
            .cloned();
        let Some(e) = intruder else { return };
        let mut ids: Vec<u64> = self.tasks.values().filter(|t| matches!(t.kind, Fight::Defend | Fight::Hunt)).map(|t| t.id).collect();
        ids.sort_unstable();
        let home: Vec<Unit> = ids.iter().flat_map(|&id| self.members(world, id)).filter(|u| !brain.defs.list[u.def].air).collect();
        let theirs = brain.enemy_fighters_near(world, e.p, 30.0);
        let margin = if home.is_empty() {
            -1.0
        } else {
            let ours: Vec<Fighter> = home.iter().map(|u| Fighter { def: u.def, p: e.p.add(u.p.sub(e.p).norm().scale(30.0)), hp: u.hp }).collect();
            brain.simulate(&ours, &theirs, Options { a_kites: Params::on(brain.params.kite), ..Default::default() }).margin
        };
        if margin < brain.params.sim_defend_margin {
            self.home_intruder = Some(e.id);
            brain.stats.home_defences += 1;
        }
    }

    /// A group brought home to see off `e` with the whole army: at it, as an attack is, or on the way there.
    fn defend_home(&mut self, id: u64, e: &Unit, brain: &mut Brain, world: &World) {
        let members: Vec<Unit> = self.members(world, id).into_iter().filter(|u| !brain.defs.list[u.def].air).collect();
        if members.is_empty() {
            return;
        }
        let Some(lead) = Self::leader(brain, &members).cloned() else { return };
        let tm = self.tasks.get_mut(&id).unwrap();
        tm.target = Some(e.id);
        tm.position = e.p;
        if e.p.dist(lead.p) < Self::highest_range(brain, &members) + 60.0 {
            tm.state = State::Engage;
            Self::arc_attack(brain, &members, e);
        } else {
            tm.state = State::Roam;
            let movers: Vec<&Unit> = members.iter().filter(|u| !brain.recently_sent(u.id, e.p, "fight", 20.0, 6.0)).collect();
            brain.go_group(&movers, e.p, "fight", brain.params.army_threat_weight);
        }
    }

    /// IFighterTask::OnUnitDamaged: home to be repaired under its retreat health, or with no target, or out of reach
    /// of it with threat twice its power; a heavy unit gets a repair task while it keeps fighting.
    fn on_damaged(&mut self, u: &Unit, brain: &mut Brain, world: &World, builders: &mut Builders) {
        let d = brain.defs.list[u.def].clone();
        let retreat = d.retreat * brain.params.retreat_scale;
        let hp = u.health_share();
        if hp > retreat {
            if brain.defs.has_role(u.def, "heavy") && hp < 0.9 && !builders.tasks.values().any(|t| t.kind == BKind::Repair && t.target == Some(u.id)) {
                let id = builders.enqueue(brain.now, BKind::Repair, Priority::Now, None, u.p, 0.0, true, 0.0, brain);
                builders.tasks.get_mut(&id).unwrap().target = Some(u.id);
            }
            return;
        }
        let out_of_reach = hp < 0.2 || {
            let target = self.unit_task.get(&u.id).and_then(|id| self.tasks.get(id)).and_then(|t| t.target).and_then(|id| world.get(id));
            match target {
                None => true,
                Some(t) => t.p.dist(u.p) > d.range_ground.max(d.range_air) || brain.fields.threat_at(d.air, u.p) * 2.0 > d.barb_power,
            }
        };
        if !out_of_reach {
            return;
        }
        self.release(u.id);
        self.retreating.insert(u.id, brain.now);
        brain.stats.retreats += 1;
        if !d.air && !builders.tasks.values().any(|t| t.kind == BKind::Repair && t.target == Some(u.id)) {
            let id = builders.enqueue(brain.now, BKind::Repair, Priority::High, None, u.p, 0.0, true, 0.0, brain);
            builders.tasks.get_mut(&id).unwrap().target = Some(u.id);
        }
    }

    /// GetClosestHaven: where the hurt go, its lab nearest home.
    fn haven(&self, brain: &Brain, world: &World) -> P {
        world
            .own
            .iter()
            .map(|&i| &world.units[i])
            .filter(|u| u.built && brain.defs.list[u.def].factory && brain.defs.list[u.def].is_building)
            .min_by(|a, b| a.p.dist(brain.home).total_cmp(&b.p.dist(brain.home)))
            .map(|u| brain.map.clamp(u.p.add(brain.toward_enemy().scale(-12.0))))
            .unwrap_or(brain.home)
    }

    /// FillFrontPos: the defence point of its own cluster nearest the lane to the enemy where its influence is not
    /// the enemy's; else base.
    fn front_pos(brain: &Brain) -> P {
        let m = &brain.metal;
        let lane = brain.home.lerp(brain.enemy_home, 0.35);
        let c = m.nearest_cluster_where(lane, &|c| brain.fields.influence_at(m.clusters[c].p) > -INFL_EPS && m.clusters[c].spots.iter().any(|&s| m.mine[s]));
        match c {
            Some(c) => m.closest_point(c, brain.enemy_home, &|_| true).map(|pi| m.points[pi].p).unwrap_or(m.clusters[c].p),
            None => brain.home,
        }
    }

    /// FillSafePos: its attack and defend squads' leaders, else base.
    fn safe_pos(&self, brain: &Brain, world: &World) -> P {
        for kind in [Fight::Attack, Fight::Defend] {
            let mut ids: Vec<u64> = self.tasks.values().filter(|t| t.kind == kind).map(|t| t.id).collect();
            ids.sort_unstable();
            for id in ids {
                let m = self.members(world, id);
                if let Some(l) = Self::leader(brain, &m) {
                    return l.p;
                }
            }
        }
        brain.home
    }

    // Squads ------------------------------------------------------------------------------------------------------

    /// ISquadTask::GetMergeTask, every 8 thoughts: into a stronger task of its kind it can reach safely nearby (a raid
    /// only into one of the same def, under the raid quota's power).
    fn try_merge(&mut self, id: u64, brain: &Brain, world: &World) -> bool {
        let t = &self.tasks[&id];
        if t.updates % 8 != 1 {
            return false;
        }
        let members = self.members(world, id);
        let Some(lead) = Self::leader(brain, &members) else { return false };
        if brain.fields.influence_at(lead.p) <= -INFL_EPS {
            return false;
        }
        let power = Self::power(brain, &members);
        let speed = members.iter().map(|u| brain.defs.list[u.def].speed).fold(f64::MAX, f64::min);
        let max_dist = MAX_TRAVEL_SEC * speed;
        let (kind, promote) = (t.kind, t.promote);
        let key = brain.defs.list[lead.def].m.ground.clone();
        let mut best: Option<(f64, u64)> = None;
        for (oid, o) in &self.tasks {
            if *oid == id || o.kind != kind || o.promote != promote || o.units.is_empty() {
                continue;
            }
            let om = self.members(world, *oid);
            let other_power = Self::power(brain, &om);
            if other_power < power {
                continue;
            }
            let Some(ol) = Self::leader(brain, &om) else { continue };
            if kind == Fight::Raid && (ol.def != lead.def || other_power + power > brain.params.raid_max_power) {
                continue;
            }
            let d = ol.p.dist(lead.p);
            if d > max_dist || brain.fields.peak_danger(lead.p, ol.p, false) > THREAT_MIN || !brain.map.reachable(key.as_deref(), lead.p, ol.p) {
                continue;
            }
            if best.map_or(true, |(bd, _)| d < bd) {
                best = Some((d, *oid));
            }
        }
        let Some((_, into)) = best else { return false };
        let units = self.tasks[&id].units.clone();
        for u in units {
            self.assign(u, into);
        }
        self.tasks.remove(&id);
        true
    }

    /// ISquadTask::IsMustRegroup, every 4 thoughts: members further than max(64 elmos a member, its highest range)
    /// from where they gather, somewhere safe.
    fn regroup(&mut self, id: u64, brain: &mut Brain, world: &World) -> bool {
        let members = self.members(world, id);
        let t = self.tasks.get_mut(&id).unwrap();
        if t.kind == Fight::AllIn || t.state == State::Engage || members.len() < 2 {
            return false;
        }
        if t.updates % 4 != 3 {
            return t.state == State::Regroup;
        }
        let Some(lead) = Self::leader(brain, &members) else { return false };
        if brain.fields.influence_at(lead.p) <= -INFL_EPS {
            t.state = State::Roam;
            return false;
        }
        if t.state != State::Regroup {
            t.group_pos = lead.p;
        }
        let max_dist = (64.0 * ELMO * members.len() as f64).max(Self::highest_range(brain, &members));
        let strung = members.iter().any(|u| !brain.defs.list[u.def].air && u.p.dist(t.group_pos) > max_dist);
        t.state = if strung && brain.fields.danger(t.group_pos) < THREAT_MIN { State::Regroup } else { State::Roam };
        if t.state != State::Regroup {
            return false;
        }
        let at = t.group_pos;
        let movers: Vec<&Unit> = members.iter().filter(|u| u.p.dist(at) > max_dist * 0.5 && !brain.recently_sent(u.id, at, "move", 10.0, 8.0)).collect();
        brain.go_group(&movers, at, "move", brain.params.army_threat_weight);
        true
    }

    /// ISquadTask::Attack: members on arcs round the target, a row for each range, at RANGE_MOD of it.
    fn arc_attack(brain: &mut Brain, members: &[Unit], target: &Unit) {
        let center = members.iter().fold(P::new(0.0, 0.0), |a, u| a.add(u.p)).scale(1.0 / members.len().max(1) as f64);
        let tp = Self::lead_point(brain, members, center, target);
        let dir = center.sub(tp);
        let alpha = dir.z.atan2(dir.x);
        let target_air = brain.defs.list[target.def].air;
        let mut rows: Vec<(f64, Vec<&Unit>)> = Vec::new();
        for u in members {
            let d = &brain.defs.list[u.def];
            let r = if target_air { d.range_air } else { d.range_ground };
            match rows.iter_mut().find(|(rr, _)| (*rr - r).abs() < 1.0) {
                Some((_, v)) => v.push(u),
                None => rows.push((r, vec![u])),
            }
        }
        let aoe = brain.defs.list[target.def].splash.max(1.0);
        for (range, units) in rows {
            let range = (range * RANGE_MOD).max(2.0);
            let n = units.len() as f64;
            let max_delta = std::f64::consts::PI * 0.9 / n;
            let radius = brain.defs.list[units[0].def].m.radius;
            let delta = ((3.0 * (radius + aoe)) / range).min(max_delta);
            let mut beta = -delta * (units.len() / 2) as f64;
            for u in units {
                if brain.defs.list[u.def].air {
                    if !brain.recently_sent(u.id, tp, "attack", 4.0, 3.0) {
                        brain.order_target(u, "attack", target.id, tp);
                    }
                    continue;
                }
                let a = alpha + beta;
                beta += delta;
                let spot = brain.map.clamp(P::new(tp.x + range * a.cos(), tp.z + range * a.sin()));
                if !brain.recently_sent(u.id, spot, "fight", 4.0, 3.0) {
                    brain.go(u, spot, "fight", brain.params.army_threat_weight);
                }
            }
        }
    }

    /// The simulated fight of `members` against the enemy round `at`.
    fn simulated_margin(brain: &mut Brain, world: &World, members: &[Unit], at: P, radius: f64) -> Option<f64> {
        let enemies = brain.enemy_fighters_near(world, at, radius);
        if enemies.is_empty() {
            return None;
        }
        let ours: Vec<Fighter> = members.iter().map(|u| Fighter { def: u.def, p: u.p, hp: u.hp }).collect();
        Some(brain.simulate(&ours, &enemies, Options { a_kites: Params::on(brain.params.kite), ..Default::default() }).margin)
    }

    fn margin_drop(brain: &Brain) -> f64 {
        brain.fronts.desperation * brain.params.desperation_margin_drop
    }

    // DEFEND ------------------------------------------------------------------------------------------------------

    /// CDefendTask: promoted every 8 thoughts once it has the power or a task of its kind exists; else it takes on
    /// what comes into ground its static defences cover (up to 4 times its power near base), or stands at the front.
    fn update_defend(&mut self, id: u64, brain: &mut Brain, world: &World) {
        let members = self.members(world, id);
        let power = Self::power(brain, &members);
        let t = self.tasks[&id].clone();
        if t.updates % 8 == 1 && (power >= t.max_power || self.tasks.values().any(|o| o.kind == t.check)) {
            match t.promote {
                Fight::Attack => brain.stats.attacks += 1,
                Fight::Raid => brain.stats.raids += 1,
                _ => {}
            }
            let into = self.enqueue(t.promote, brain);
            for u in t.units {
                self.assign(u, into);
            }
            self.tasks.remove(&id);
            return;
        }
        if self.try_merge(id, brain, world) {
            return;
        }
        let Some(lead) = Self::leader(brain, &members).cloned() else { return };
        let max_power = power * t.power_mod;
        let base_range = brain.base_range();
        let hits_air = members.iter().any(|u| brain.defs.list[u.def].dps_air > 0.0);
        let mut best: Option<(f64, Unit)> = None;
        for &i in &world.enemy {
            let e = &world.units[i];
            let ed = &brain.defs.list[e.def];
            if ed.m.objectify || brain.fields.defend_at(e.p) < INFL_EPS || (ed.air && !hits_air) {
                continue;
            }
            if !Self::catchable(brain, &members, lead.p, e) {
                continue;
            }
            let d_base = e.p.dist(brain.home);
            let mut check = max_power;
            if d_base < base_range {
                check *= 4.0 - 3.0 / base_range * d_base;
            }
            if check <= brain.fields.threat_at(ed.air, e.p) {
                continue;
            }
            let dist = lead.p.dist2(e.p);
            if best.as_ref().map_or(true, |(bd, _)| dist < *bd) {
                best = Some((dist, e.clone()));
            }
        }
        let tm = self.tasks.get_mut(&id).unwrap();
        tm.state = State::Roam;
        if let Some((_, e)) = best {
            tm.target = Some(e.id);
            tm.position = e.p;
            if e.p.dist(lead.p) < Self::highest_range(brain, &members) + 300.0 * ELMO {
                tm.state = State::Engage;
                Self::arc_attack(brain, &members, &e);
            } else {
                let movers: Vec<&Unit> = members.iter().filter(|u| !brain.recently_sent(u.id, e.p, "fight", 20.0, 8.0)).collect();
                brain.go_group(&movers, e.p, "fight", brain.params.army_threat_weight);
            }
            return;
        }
        tm.target = None;
        let front = Self::front_pos(brain);
        tm.position = front;
        let movers: Vec<&Unit> = members.iter().filter(|u| u.p.dist(front) > 20.0 && !brain.recently_sent(u.id, front, "fight", 15.0, 20.0)).collect();
        brain.go_group(&movers, front, "fight", brain.params.army_threat_weight);
    }

    // ATTACK ------------------------------------------------------------------------------------------------------

    /// CAttackTask::Update: the target FindTarget gives, engaged within its highest range and slack, else walked to;
    /// with no target, back to the front.
    fn update_attack(&mut self, id: u64, brain: &mut Brain, world: &World) {
        let kind = self.tasks[&id].kind;
        if kind == Fight::Attack && self.try_merge(id, brain, world) {
            return;
        }
        if self.regroup(id, brain, world) {
            return;
        }
        let members = self.members(world, id);
        let Some(lead) = Self::leader(brain, &members).cloned() else { return };
        let max_power = Self::power(brain, &members) * self.tasks[&id].power_mod;
        let target = if kind == Fight::AllIn {
            world.enemy.iter().map(|&i| world.units[i].clone()).find(|e| brain.defs.list[e.def].commander).or_else(|| self.find_attack_target(brain, world, &members, &lead, f64::MAX))
        } else {
            self.find_attack_target(brain, world, &members, &lead, max_power)
        };
        let highest = Self::highest_range(brain, &members);
        let Some(e) = target else {
            let tm = self.tasks.get_mut(&id).unwrap();
            tm.state = State::Roam;
            tm.target = None;
            let front = Self::front_pos(brain);
            let movers: Vec<&Unit> = members.iter().filter(|u| u.p.dist(front) > 25.0 && !brain.recently_sent(u.id, front, "fight", 15.0, 20.0)).collect();
            brain.go_group(&movers, front, "fight", brain.params.army_threat_weight);
            return;
        };
        // the simulator's say on a fight under way: a losing attack goes back to defending
        let last_check = self.tasks[&id].last_check;
        if kind == Fight::Attack && Params::on(brain.params.sim_gate) && brain.now - last_check >= 3.0 && e.p.dist(lead.p) < highest + 60.0 {
            self.tasks.get_mut(&id).unwrap().last_check = brain.now;
            if let Some(m) = Self::simulated_margin(brain, world, &members, lead.p, highest + 40.0) {
                if m < brain.params.retreat_margin - Self::margin_drop(brain) {
                    brain.stats.retreats += 1;
                    let front = Self::front_pos(brain);
                    let refs: Vec<&Unit> = members.iter().collect();
                    brain.go_group(&refs, front, "move", brain.params.army_threat_weight.max(1.0));
                    let units = self.tasks[&id].units.clone();
                    let d = self.enqueue_defend(Fight::Attack, max_power.max(brain.params.attack_min_power), brain);
                    for u in units {
                        self.assign(u, d);
                    }
                    self.tasks.remove(&id);
                    return;
                }
            }
        }
        let tm = self.tasks.get_mut(&id).unwrap();
        tm.target = Some(e.id);
        tm.position = e.p;
        let slack = if brain.fields.defend_at(e.p) > INFL_EPS { 300.0 } else { 100.0 } * ELMO;
        if e.p.dist(lead.p) < highest + slack {
            tm.state = State::Engage;
            Self::arc_attack(brain, &members, &e);
        } else {
            tm.state = State::Roam;
            let movers: Vec<&Unit> = members.iter().filter(|u| !brain.recently_sent(u.id, e.p, "fight", 25.0, 10.0)).collect();
            brain.go_group(&movers, e.p, "fight", brain.params.army_threat_weight);
        }
    }

    /// CAttackTask::FindTarget over the enemy groups (groups.rs): groups it can take on, good ones (not overpowering
    /// it eightfold) first, by `vague_metric * distance^2 * scale`; then the simulator's say on the best three.
    fn find_attack_target(&self, brain: &mut Brain, world: &World, members: &[Unit], lead: &Unit, max_power: f64) -> Option<Unit> {
        let base = brain.home;
        let sq_ob = lead.p.dist2(base).max(1.0);
        let fastest = members.iter().map(|u| brain.defs.list[u.def].speed).fold(0.0, f64::max);
        let hits_air = members.iter().any(|u| brain.defs.list[u.def].dps_air > 0.0);
        let key = brain.defs.list[lead.def].m.ground.clone();
        let mut ranked: Vec<(f64, bool, Unit)> = Vec::new();
        for g in &brain.groups.list {
            let scale = (g.p.dist(base) / sq_ob).min(1.0);
            // a group it outpowers eightfold is a lesser target than one worth its power
            let good = max_power * 0.125 <= g.influence;
            if (max_power <= g.influence * scale && brain.fields.influence_at(g.p) < INFL_SAFE) || !brain.map.reachable(key.as_deref(), lead.p, g.p) {
                continue;
            }
            for &i in &g.units {
                let e = &world.units[i];
                let ed = &brain.defs.list[e.def];
                let outpaces = if Params::on(brain.params.chase_check) { !Self::catchable(brain, members, lead.p, e) } else { ed.mobile && ed.speed > fastest * 1.01 && e.v.len() > fastest };
                if ed.m.objectify || outpaces || (ed.air && !hits_air) {
                    continue;
                }
                ranked.push((g.vague_metric * lead.p.dist2(e.p) * scale, good, e.clone()));
            }
        }
        ranked.sort_by(|a, b| b.1.cmp(&a.1).then(a.0.total_cmp(&b.0)));
        if !Params::on(brain.params.sim_gate) || max_power == f64::MAX {
            return ranked.into_iter().next().map(|(_, _, e)| e);
        }
        let margin = brain.params.attack_margin - Self::margin_drop(brain);
        let mut checked = 0;
        let mut seen_at: Vec<P> = Vec::new();
        for (_, _, e) in ranked {
            if checked >= 3 {
                break;
            }
            if seen_at.iter().any(|p| p.dist(e.p) < 20.0) {
                continue;
            }
            match Self::simulated_margin(brain, world, members, e.p, 20.0) {
                None => return Some(e),
                Some(m) => {
                    checked += 1;
                    seen_at.push(e.p);
                    if m >= margin {
                        return Some(e);
                    }
                }
            }
        }
        None
    }

    // RAID, SCOUT, BOMB ---------------------------------------------------------------------------------------------

    /// CRaidTask::Update and FindTarget: the best target within reach (builders first, then the most threatening it
    /// outpowers), else toward the nearest of the enemies it outpowers (those inside its defended ground near base
    /// first), else the enemy's extractors.
    fn update_raid(&mut self, id: u64, brain: &mut Brain, world: &World) {
        if self.try_merge(id, brain, world) {
            return;
        }
        if self.regroup(id, brain, world) {
            return;
        }
        let members = self.members(world, id);
        let Some(lead) = Self::leader(brain, &members).cloned() else { return };
        let t = self.tasks[&id].clone();
        let max_power = Self::power(brain, &members) * t.power_mod * if t.target.is_some() { 1.0 / 0.75 } else { 1.0 };
        let ld = brain.defs.list[lead.def].clone();
        let range = ld.range_ground.max(ld.range_air) + 200.0 * ELMO;
        let base_range = brain.base_range();
        let defender = lead.p.dist(brain.home) < base_range;
        let key = ld.m.ground.clone();
        let hits_air = members.iter().any(|u| brain.defs.list[u.def].dps_air > 0.0);
        let mut best: Option<(bool, f64, Unit)> = None;
        let mut positions: Vec<(bool, P)> = Vec::new();
        for &i in &world.enemy {
            let e = &world.units[i];
            let ed = &brain.defs.list[e.def];
            if ed.m.objectify || ed.m.immune || (ed.air && !hits_air) {
                continue;
            }
            if !ld.air && !brain.map.reachable(key.as_deref(), lead.p, e.p) {
                continue;
            }
            let d_base = e.p.dist(brain.home);
            let mut check = max_power;
            if d_base < base_range {
                check *= 2.0 - d_base / base_range;
            }
            if check <= brain.fields.threat_at(ld.air, e.p) {
                continue;
            }
            // something as fast as it, running away, is not caught
            if ed.mobile && e.v.len() >= ld.speed * 0.8 && e.v.x * (lead.p.x - e.p.x) + e.v.z * (lead.p.z - e.p.z) < 0.0 {
                continue;
            }
            if lead.p.dist(e.p) < range {
                let is_builder = ed.builder && ed.mobile;
                let threat = ed.thr_surf.max(ed.thr_air) * e.hp.max(0.0).sqrt();
                let better = match &best {
                    None => true,
                    Some((bb, bt, _)) => (is_builder && !bb) || (is_builder == *bb && threat > *bt),
                };
                if better {
                    best = Some((is_builder, threat, e.clone()));
                }
                continue;
            }
            positions.push((defender && brain.fields.defend_at(e.p) > INFL_EPS, e.p));
        }
        if let Some((_, _, e)) = best {
            // the simulator's say before it goes in
            if Params::on(brain.params.sim_gate) && t.target != Some(e.id) {
                if let Some(m) = Self::simulated_margin(brain, world, &members, e.p, 20.0) {
                    if m < brain.params.raid_margin - Self::margin_drop(brain) {
                        let back = Self::front_pos(brain);
                        let movers: Vec<&Unit> = members.iter().filter(|u| !brain.recently_sent(u.id, back, "move", 20.0, 8.0)).collect();
                        brain.go_group(&movers, back, "move", brain.params.raid_threat_weight);
                        let tm = self.tasks.get_mut(&id).unwrap();
                        tm.state = State::Roam;
                        tm.target = None;
                        return;
                    }
                }
            }
            let tm = self.tasks.get_mut(&id).unwrap();
            tm.state = State::Engage;
            tm.target = Some(e.id);
            tm.position = e.p;
            Self::arc_attack(brain, &members, &e);
            return;
        }
        let urgent: Vec<P> = positions.iter().filter(|(u, _)| *u).map(|(_, p)| *p).collect();
        let pool: Vec<P> = if urgent.is_empty() { positions.iter().map(|(_, p)| *p).collect() } else { urgent };
        let goal = pool.into_iter().min_by(|a, b| a.dist2(lead.p).total_cmp(&b.dist2(lead.p))).unwrap_or_else(|| {
            // FallbackRaid: the enemy's extractors, else its start
            world
                .enemy
                .iter()
                .map(|&i| &world.units[i])
                .filter(|e| brain.defs.list[e.def].m.spot.is_some())
                .map(|e| e.p)
                .min_by(|a, b| a.dist2(lead.p).total_cmp(&b.dist2(lead.p)))
                .unwrap_or(brain.enemy_home)
        });
        let tm = self.tasks.get_mut(&id).unwrap();
        tm.state = State::Roam;
        tm.target = None;
        tm.position = goal;
        let movers: Vec<&Unit> = members.iter().filter(|u| !brain.recently_sent(u.id, goal, "move", 25.0, 8.0)).collect();
        brain.go_group(&movers, goal, "move", brain.params.raid_threat_weight);
    }

    // AA, ARTY, GUARD ---------------------------------------------------------------------------------------------

    /// CAntiAirTask: aircraft near it, else with the army (FillSafePos).
    fn update_aa(&mut self, id: u64, brain: &mut Brain, world: &World) {
        if self.try_merge(id, brain, world) {
            return;
        }
        let members = self.members(world, id);
        let Some(lead) = Self::leader(brain, &members).cloned() else { return };
        let reach = members.iter().map(|u| brain.defs.list[u.def].range_air).fold(f64::MAX, f64::min).max(20.0);
        let target = world
            .enemy
            .iter()
            .map(|&i| world.units[i].clone())
            .filter(|e| brain.defs.list[e.def].air)
            .min_by(|a, b| a.p.dist2(lead.p).total_cmp(&b.p.dist2(lead.p)));
        if let Some(e) = target {
            if e.p.dist(lead.p) < reach * 2.0 {
                Self::arc_attack(brain, &members, &e);
                return;
            }
        }
        let safe = self.safe_pos(brain, world);
        let movers: Vec<&Unit> = members.iter().filter(|u| u.p.dist(safe) > 20.0 && !brain.recently_sent(u.id, safe, "fight", 15.0, 10.0)).collect();
        brain.go_group(&movers, safe, "fight", brain.params.army_threat_weight);
    }

    /// CArtilleryTask: each unit on its own at the enemy's buildings in reach while it stands safe, else toward the
    /// nearest, else with the army.
    fn update_arty(&mut self, id: u64, brain: &mut Brain, world: &World) {
        let members = self.members(world, id);
        let safe_p = self.safe_pos(brain, world);
        for u in &members {
            let d = brain.defs.list[u.def].clone();
            let safe = brain.fields.danger(u.p) <= THREAT_MIN;
            let target = world
                .enemy
                .iter()
                .map(|&i| &world.units[i])
                .filter(|e| !brain.defs.list[e.def].mobile && !brain.defs.list[e.def].m.objectify)
                .min_by(|a, b| a.p.dist2(u.p).total_cmp(&b.p.dist2(u.p)))
                .cloned();
            match target {
                Some(e) if safe && e.p.dist(u.p) <= d.range_ground => {
                    if !brain.recently_sent(u.id, e.p, "attack", 5.0, 10.0) {
                        brain.order_target(u, "attack", e.id, e.p);
                    }
                }
                Some(e) if e.p.dist(u.p) < d.range_ground + MAX_TRAVEL_SEC * d.speed * 0.25 => {
                    let stand = brain.map.clamp(e.p.add(u.p.sub(e.p).norm().scale(d.range_ground * 0.9)));
                    if !brain.recently_sent(u.id, stand, "fight", 15.0, 10.0) {
                        brain.go(u, stand, "fight", brain.params.army_threat_weight.max(1.0));
                    }
                }
                _ => {
                    if u.p.dist(safe_p) > 30.0 && !brain.recently_sent(u.id, safe_p, "fight", 20.0, 15.0) {
                        brain.go(u, safe_p, "fight", brain.params.army_threat_weight);
                    }
                }
            }
        }
    }

    // HUNT (sim_barb, server/ai/groups.luau) ---------------------------------------------------------------------

    /// targets.luau's `intruders`: the enemy's armed ground units, but its commander, within hunt_radius of one of its
    /// extractors or of home.
    fn intruders(brain: &Brain, world: &World) -> Vec<Unit> {
        let r = brain.params.hunt_radius;
        let extractors: Vec<P> = world
            .own
            .iter()
            .map(|&i| &world.units[i])
            .filter(|u| brain.defs.list[u.def].m.spot.as_deref() == Some("metal"))
            .map(|u| u.p)
            .collect();
        let mut found: Vec<Unit> = world
            .enemy
            .iter()
            .map(|&i| &world.units[i])
            .filter(|e| {
                let d = &brain.defs.list[e.def];
                e.built && d.mobile && d.armed && d.dps_ground > 0.0 && !d.commander && !d.air
            })
            .filter(|e| e.p.dist(brain.home) <= brain.params.hunt_home + r || extractors.iter().any(|x| x.dist(e.p) <= r))
            .cloned()
            .collect();
        found.sort_by(|a, b| a.p.dist(brain.home).total_cmp(&b.p.dist(brain.home)).then(a.id.cmp(&b.id)));
        found
    }

    /// `start_hunts`: while fewer than hunt_groups are out, for each intruder nothing hunts, the nearest home first,
    /// the fewest of what waits at home (its DEFEND tasks), the quickest to get there first, that the simulator says
    /// beat it and what is round it by hunt_margin.
    fn start_hunts(&mut self, brain: &mut Brain, world: &World) {
        let most = brain.params.hunt_groups.round().max(0.0) as usize;
        let mut out = self.tasks.values().filter(|t| t.kind == Fight::Hunt).count();
        if out >= most {
            return;
        }
        let intruders = Self::intruders(brain, world);
        if intruders.is_empty() {
            return;
        }
        let hunted: Vec<P> = self
            .tasks
            .values()
            .filter(|t| t.kind == Fight::Hunt)
            .filter_map(|t| t.target.and_then(|id| world.get(id)).map(|e| e.p))
            .collect();
        let mut defend_ids: Vec<u64> = self.tasks.values().filter(|t| t.kind == Fight::Defend).map(|t| t.id).collect();
        defend_ids.sort_unstable();
        let mut pool: Vec<Unit> = defend_ids.iter().flat_map(|&id| self.members(world, id)).filter(|u| !brain.defs.list[u.def].air).collect();
        for prey in intruders {
            if out >= most || pool.is_empty() {
                break;
            }
            if hunted.iter().any(|p| p.dist(prey.p) < 20.0) {
                continue;
            }
            // those that keep up with it first (chase_check), the quickest there first
            let chase = Params::on(brain.params.chase_check);
            let prey_speed = brain.defs.list[prey.def].speed;
            pool.sort_by(|a, b| {
                let la = chase && brain.defs.list[a.def].speed < prey_speed * 0.95;
                let lb = chase && brain.defs.list[b.def].speed < prey_speed * 0.95;
                let ta = a.p.dist(prey.p) / brain.defs.list[a.def].speed.max(0.1);
                let tb = b.p.dist(prey.p) / brain.defs.list[b.def].speed.max(0.1);
                la.cmp(&lb).then(ta.total_cmp(&tb)).then(a.id.cmp(&b.id))
            });
            let theirs = brain.enemy_fighters_near(world, prey.p, 20.0);
            let margin = brain.params.hunt_margin;
            let mut count = None;
            let mut n = 1;
            let mut tries = 0;
            while n <= pool.len() && tries < 6 {
                let ours: Vec<Fighter> = pool[..n].iter().map(|u| Fighter { def: u.def, p: prey.p.add(u.p.sub(prey.p).norm().scale(30.0)), hp: u.hp }).collect();
                let m = brain.simulate(&ours, &theirs, Options { a_kites: Params::on(brain.params.kite), ..Default::default() }).margin;
                tries += 1;
                if m >= margin {
                    count = Some(n);
                    break;
                }
                if n == pool.len() {
                    break;
                }
                n = (n * 2).min(pool.len());
            }
            let Some(count) = count else { continue };
            let members: Vec<i64> = pool.drain(..count).map(|u| u.id).collect();
            let id = self.enqueue(Fight::Hunt, brain);
            // what it threatens: its own extractor nearest the prey, or home
            let guard = world
                .own
                .iter()
                .map(|&i| &world.units[i])
                .filter(|u| brain.defs.list[u.def].m.spot.as_deref() == Some("metal") && u.p.dist(prey.p) <= brain.params.hunt_radius)
                .map(|u| u.p)
                .min_by(|a, c| a.dist(prey.p).total_cmp(&c.dist(prey.p)))
                .unwrap_or(brain.home);
            let tm = self.tasks.get_mut(&id).unwrap();
            tm.target = Some(prey.id);
            tm.guard = Some(guard);
            for u in members {
                self.assign(u, id);
            }
            out += 1;
        }
    }

    /// A hunt after its target, then the nearest intruder nothing else hunts; home (back into the army) once there is
    /// none, or once the simulator says it would lose where it stands.
    fn update_hunt(&mut self, id: u64, brain: &mut Brain, world: &World) {
        let members = self.members(world, id);
        let Some(lead) = Self::leader(brain, &members).cloned() else { return };
        let t = self.tasks[&id].clone();
        let chase = Params::on(brain.params.chase_check);
        let intruders = Self::intruders(brain, world);
        let mut target = t.target.and_then(|tid| world.get(tid)).cloned();
        // prey that has left (sim_barb's hunts end there) or outruns it is let go
        if chase {
            target = target.filter(|e| intruders.iter().any(|x| x.id == e.id) && Self::catchable(brain, &members, lead.p, e));
        }
        if target.is_none() {
            let others: Vec<i64> = self.tasks.values().filter(|o| o.kind == Fight::Hunt && o.id != id).filter_map(|o| o.target).collect();
            target = intruders
                .iter()
                .filter(|e| !others.contains(&e.id) && (!chase || Self::catchable(brain, &members, lead.p, e)))
                .min_by(|a, b| a.p.dist2(lead.p).total_cmp(&b.p.dist2(lead.p)))
                .cloned();
        }
        // none it can catch, while the enemy is still about what it guards: it holds there, and fights what comes
        if target.is_none() && chase {
            if let Some(g) = t.guard.filter(|g| intruders.iter().any(|x| x.p.dist(*g) <= brain.params.hunt_radius)) {
                let tm = self.tasks.get_mut(&id).unwrap();
                tm.target = None;
                tm.state = State::Roam;
                tm.position = g;
                let movers: Vec<&Unit> = members.iter().filter(|u| u.p.dist(g) > 12.0 && !brain.recently_sent(u.id, g, "fight", 10.0, 8.0)).collect();
                brain.go_group(&movers, g, "fight", brain.params.army_threat_weight);
                return;
            }
        }
        let dissolve = |this: &mut Self| {
            for u in this.tasks[&id].units.clone() {
                this.unit_task.remove(&u);
            }
            this.tasks.remove(&id);
        };
        let Some(e) = target else {
            dissolve(self);
            return;
        };
        if brain.now - t.last_check >= 3.0 {
            self.tasks.get_mut(&id).unwrap().last_check = brain.now;
            if let Some(m) = Self::simulated_margin(brain, world, &members, lead.p, 40.0) {
                if m < 0.0 {
                    brain.stats.retreats += 1;
                    let front = Self::front_pos(brain);
                    let refs: Vec<&Unit> = members.iter().collect();
                    brain.go_group(&refs, front, "move", brain.params.army_threat_weight.max(1.0));
                    dissolve(self);
                    return;
                }
            }
        }
        let tm = self.tasks.get_mut(&id).unwrap();
        tm.target = Some(e.id);
        tm.position = e.p;
        if e.p.dist(lead.p) < Self::highest_range(brain, &members) + 100.0 * ELMO {
            tm.state = State::Engage;
            Self::arc_attack(brain, &members, &e);
        } else {
            tm.state = State::Roam;
            let movers: Vec<&Unit> = members.iter().filter(|u| !brain.recently_sent(u.id, e.p, "fight", 15.0, 5.0)).collect();
            brain.go_group(&movers, e.p, "fight", brain.params.army_threat_weight);
        }
    }

    /// CFGuardTask: its fighters guard the builder it escorts.
    fn update_guard(&mut self, id: u64, brain: &mut Brain, world: &World) {
        let Some(vip) = self.tasks[&id].vip.and_then(|v| world.get(v)).cloned() else { return };
        for u in self.members(world, id) {
            if !brain.recently_sent(u.id, vip.p, "guard", 1.0e6, 30.0) {
                brain.order_target(&u, "guard", vip.id, vip.p);
            }
        }
    }

    /// The commander's manual weapon at what comes near, when none of its own are in the way (BARb's CDGunAction).
    fn dgun(&mut self, brain: &mut Brain, world: &World) {
        let Some(c) = world.own.iter().map(|&i| world.units[i].clone()).find(|u| brain.defs.list[u.def].commander) else { return };
        let d = brain.defs.list[c.def].clone();
        if !Params::on(brain.params.commander_dgun) || d.m.dgun_range <= 0.0 || c.dgun_reload > 0.0 || world.my_team().energy < d.m.dgun_energy {
            return;
        }
        let mut best: Option<(f64, P)> = None;
        for &i in &world.enemy {
            let e = &world.units[i];
            let ed = &brain.defs.list[e.def];
            if ed.air || ed.m.immune || !e.built || c.p.dist(e.p) > d.m.dgun_range * 0.95 {
                continue;
            }
            let dir = e.p.sub(c.p).norm();
            let blocked = world.own.iter().map(|&j| &world.units[j]).any(|o| {
                if o.id == c.id {
                    return false;
                }
                let rel = o.p.sub(c.p);
                let along = rel.x * dir.x + rel.z * dir.z;
                along > 0.0 && along < d.m.dgun_range && (rel.x * dir.z - rel.z * dir.x).abs() < 8.0
            });
            if blocked {
                continue;
            }
            let value = ed.power * if ed.armed { 1.5 } else { 1.0 };
            if best.map_or(true, |(b, _)| value > b) {
                best = Some((value, e.p));
            }
        }
        if let Some((value, at)) = best {
            if value > 60.0 {
                brain.dgun(&c, at);
            }
        }
    }
}
