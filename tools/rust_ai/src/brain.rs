//! A brain: everything the AI keeps from one thought to the next, and a thought, in order:
//!
//! 1. what it sees (world.rs), and what was lost since the last thought, on either side;
//! 2. the fields (fields.rs: BARb's threat and influence maps) and the enemy's groups (groups.rs);
//! 3. where it is winning and losing, its standing, and how desperate it is (fronts.rs);
//! 4. BARb's managers, each giving orders: builders (builders.rs) with the tasks the economy (economy.rs) and the
//!    porcupine (porc.rs) put in their pool, its labs (factory.rs), and its army (military.rs).
//!
//! Orders are given through the helpers here, which route every walk round danger (path.rs) and do not give a unit
//! the same order it is already on.

use crate::barb::Barb;
use crate::builders::{Builders, ELMO};
use crate::defs::{DefId, Defs};
use crate::economy::Economy;
use crate::factory::Factory;
use crate::fields::Fields;
use crate::fronts::Fronts;
use crate::groups::Groups;
use crate::map::{Map, P};
use crate::metal::Metal;
use crate::military::Military;
use crate::params::Params;
use crate::path::Pathfinder;
use crate::porc::Porc;
use crate::protocol::{Command, Hello, Observe, ResultMsg};
use crate::world::{Unit, World};
use serde_json::json;
use crate::HashMap;
use std::io::Write;

pub struct Rng(u64);
impl Rng {
    pub fn new(seed: u64) -> Rng {
        Rng(seed.max(1))
    }
    pub fn next(&mut self) -> u64 {
        let mut x = self.0;
        x ^= x << 13;
        x ^= x >> 7;
        x ^= x << 17;
        self.0 = x;
        x
    }
    /// A number in [0, 1).
    pub fn unit(&mut self) -> f64 {
        (self.next() >> 11) as f64 / (1u64 << 53) as f64
    }
}

/// What it knew of something last thought, to tell what was lost.
#[derive(Clone)]
pub struct Seen {
    pub team: i64,
    pub def: DefId,
    pub p: P,
    pub built: bool,
}

#[derive(Default)]
pub struct Stats {
    pub sims: u64,
    pub sim_seconds: f64,
    pub attacks: u64,
    pub raids: u64,
    pub defences: u64,
    pub retreats: u64,
    pub home_defences: u64,
    pub all_ins: u64,
    pub desperate_seconds: f64,
    pub peak_desperation: f64,
    pub builds_failed: u64,
    pub made: HashMap<String, u64>,
    pub think_seconds: f64,
}

pub struct Brain {
    pub defs: Defs,
    pub barb: Barb,
    pub map: Map,
    pub params: Params,
    pub me: i64,
    pub enemies: Vec<i64>,
    pub line: Option<String>,
    pub fields: Fields,
    pub groups: Groups,
    pub pf: Pathfinder,
    pub home: P,
    pub enemy_home: P,
    pub rng: Rng,
    pub now: f64,
    pub cmds: Vec<Command>,
    /// what it last sent each unit, and when: the goal and the kind of order
    pub sent: HashMap<i64, (P, &'static str, f64)>,
    pub seen: HashMap<i64, Seen>,
    pub economy: Economy,
    pub factory: Factory,
    pub military: Military,
    pub builders: Builders,
    pub metal: Metal,
    pub porc: Porc,
    /// what the bridge made of last thought's commands
    pub results: Vec<ResultMsg>,
    /// everything seen this thought, by id
    pub units_now: HashMap<i64, Unit>,
    pub fronts: Fronts,
    pub stats: Stats,
    pub log: Option<std::fs::File>,
    pub thoughts: u64,
}

impl Brain {
    pub fn new(hello: Hello) -> Result<Brain, String> {
        let params = Params::from_map(&hello.params)?;
        let barb = Barb::load();
        let defs = Defs::new(hello.defs, hello.constants, &barb);
        let map = Map::new(hello.map);
        let fields = Fields::new(&map);
        let cells = map.w * map.h;
        let home = map.starts.get(&hello.team).copied().unwrap_or(P::new(map.ox + map.width_studs() / 2.0, map.oz + map.depth_studs() / 2.0));
        let enemy_home = hello
            .enemies
            .iter()
            .filter_map(|t| map.starts.get(t).copied())
            .next()
            .unwrap_or(P::new(2.0 * (map.ox + map.width_studs() / 2.0) - home.x, 2.0 * (map.oz + map.depth_studs() / 2.0) - home.z));
        let log = hello.log.as_ref().and_then(|path| std::fs::File::create(path).ok());
        let seed = (home.x.to_bits() ^ home.z.to_bits().rotate_left(17) ^ (hello.team as u64).wrapping_mul(0x9E3779B97F4A7C15)) | 1;
        let fronts = Fronts::new(&map, params.front_region);
        let spots: Vec<(P, f64)> = map.metal.iter().map(|s| (s.p, s.mult)).collect();
        let metal = Metal::new(spots, barb.economy.cluster_range * ELMO, barb.porcupine.point_range * ELMO);
        Ok(Brain {
            defs,
            barb,
            map,
            params,
            me: hello.team,
            enemies: hello.enemies,
            line: hello.line,
            fields,
            groups: Groups::new(),
            pf: Pathfinder::new(cells),
            home,
            enemy_home,
            rng: Rng::new(seed),
            now: 0.0,
            cmds: Vec::new(),
            sent: HashMap::default(),
            seen: HashMap::default(),
            economy: Economy::new(),
            factory: Factory::new(),
            military: Military::new(),
            builders: Builders::new(),
            metal,
            porc: Porc::new(),
            results: Vec::new(),
            units_now: HashMap::default(),
            fronts,
            stats: Stats::default(),
            log,
            thoughts: 0,
        })
    }

    /// A thought: what it sees in, commands out.
    pub fn think(&mut self, obs: &Observe) -> (Vec<Command>, Option<serde_json::Value>) {
        let started = std::time::Instant::now();
        self.now = obs.time;
        self.cmds.clear();
        let world = World::new(obs, &self.defs, self.me, &self.enemies);

        // what the bridge made of last thought's commands
        self.results = obs.results.clone();
        self.stats.builds_failed += obs.results.iter().filter(|r| !r.ok && r.tag.is_some()).count() as u64;
        self.units_now = world.units.iter().map(|u| (u.id, u.clone())).collect();

        // what was lost since last thought
        let mut lost: Vec<Seen> = Vec::new();
        for (id, seen) in self.seen.iter() {
            if !world.by_id.contains_key(id) {
                lost.push(seen.clone());
            }
        }
        self.seen.clear();
        for u in &world.units {
            self.seen.insert(u.id, Seen { team: u.team, def: u.def, p: u.p, built: u.built });
        }
        self.sent.retain(|id, _| world.by_id.contains_key(id));

        // buildings stand in the way of routes
        self.map.clear_occupied();
        for u in &world.units {
            let d = &self.defs.list[u.def];
            if d.is_building {
                self.map.mark_building(u.p, d.m.half_x, d.m.half_z, u.team.max(1));
            }
        }
        // home follows the commander early on, and then its labs
        if let Some(c) = world.own.iter().map(|&i| &world.units[i]).find(|u| self.defs.list[u.def].commander) {
            if self.now < 30.0 {
                self.home = c.p;
            }
        }

        self.fields.refresh(&world, &self.defs);
        self.groups.update(&world, &self.defs, 1.0, 1.0);
        self.fronts.update(&world, &self.defs, &self.fields, &lost, &self.params, self.now, self.me);
        if self.fronts.desperation > 0.0 {
            self.stats.desperate_seconds += 1.0;
        }
        self.stats.peak_desperation = self.stats.peak_desperation.max(self.fronts.desperation);

        // the managers each take themselves out of the brain while they work; the economy leaves a copy of itself
        // behind for the others to read
        let mut economy = std::mem::take(&mut self.economy);
        economy.resolve_line(self);
        economy.update_state(self, &world);
        self.economy = economy.clone();
        let mut builders = std::mem::take(&mut self.builders);
        crate::builders::run(&mut builders, &mut economy, self, &world);
        self.economy = economy;
        self.builders = builders;
        let mut factory = std::mem::take(&mut self.factory);
        factory.run(self, &world);
        self.factory = factory;
        let mut military = std::mem::take(&mut self.military);
        let mut builders = std::mem::take(&mut self.builders);
        military.run(self, &world, &mut builders);
        self.military = military;
        self.builders = builders;

        self.thoughts += 1;
        self.stats.think_seconds += started.elapsed().as_secs_f64();
        let report = if self.thoughts % 5 == 0 { Some(self.report(&world)) } else { None };
        let census = if self.log.is_some() && self.thoughts % 60 == 0 { Some(self.census(&world)) } else { None };
        if let Some(log) = self.log.as_mut() {
            let line = json!({
                "t": self.now,
                "standing": self.fronts.standing,
                "desperation": self.fronts.desperation,
                "winning": self.fronts.winning.len(),
                "losing": self.fronts.losing.len(),
                "squads": self.military.describe(),
                "eco": self.economy.debug,
                "tasks": self.builders.tasks.len(),
                "census": census,
                "cmds": self.cmds.len(),
            });
            let _ = writeln!(log, "{}", line);
        }
        (std::mem::take(&mut self.cmds), report)
    }

    /// Every def each side has, by name, for the log.
    fn census(&self, world: &World) -> serde_json::Value {
        let mut own: std::collections::BTreeMap<String, u32> = Default::default();
        let mut enemy: std::collections::BTreeMap<String, u32> = Default::default();
        for &i in &world.own {
            *own.entry(self.defs.list[world.units[i].def].name.clone()).or_insert(0) += 1;
        }
        for &i in &world.enemy {
            *enemy.entry(self.defs.list[world.units[i].def].name.clone()).or_insert(0) += 1;
        }
        let near: Vec<(String, f64, f64)> = world
            .own
            .iter()
            .map(|&i| &world.units[i])
            .find(|u| self.defs.list[u.def].commander)
            .map(|c| {
                world
                    .own
                    .iter()
                    .map(|&i| &world.units[i])
                    .filter(|u| self.defs.list[u.def].is_building && u.p.dist(c.p) < 25.0)
                    .map(|u| (self.defs.list[u.def].name.clone(), (u.p.x - c.p.x).round(), (u.p.z - c.p.z).round()))
                    .collect()
            })
            .unwrap_or_default();
        json!({"own": own, "enemy": enemy, "near_commander": near})
    }

    pub fn report(&self, _world: &World) -> serde_json::Value {
        json!({
            "engine": "rust",
            "line": self.economy.line_name(),
            "standing": (self.fronts.standing * 1000.0).round() / 1000.0,
            "desperation": (self.fronts.desperation * 1000.0).round() / 1000.0,
            "peak_desperation": (self.stats.peak_desperation * 1000.0).round() / 1000.0,
            "desperate_seconds": self.stats.desperate_seconds,
            "regions_winning": self.fronts.winning.len(),
            "regions_losing": self.fronts.losing.len(),
            "attacks": self.stats.attacks,
            "waves_sent": self.stats.attacks,
            "raids": self.stats.raids,
            "defences": self.stats.defences,
            "retreats": self.stats.retreats,
            "home_defences": self.stats.home_defences,
            "all_ins": self.stats.all_ins,
            "sims": self.stats.sims,
            "sim_ms": (self.stats.sim_seconds * 1000.0 * 10.0).round() / 10.0,
            "paths": self.pf.searches,
            "builds_failed": self.stats.builds_failed,
            "made": self.stats.made,
            "params": self.params.to_json(),
            "rust_ms_per_thought": (self.stats.think_seconds * 1000.0 / self.thoughts.max(1) as f64 * 100.0).round() / 100.0,
        })
    }

    // Orders -------------------------------------------------------------------------------------------------------

    fn push(&mut self, c: Command) {
        self.cmds.push(c);
    }

    /// Whether `unit` was sent to about `goal` with an order of `kind` in the last `fresh` seconds.
    pub fn recently_sent(&self, unit: i64, goal: P, kind: &str, slack: f64, fresh: f64) -> bool {
        match self.sent.get(&unit) {
            Some((g, k, t)) => *k == kind && g.dist(goal) <= slack && self.now - t < fresh,
            None => false,
        }
    }

    /// Sends `u` to `goal`, walking (`move`) or fighting its way (`fight`), round threat by `weight`.
    pub fn go(&mut self, u: &crate::world::Unit, goal: P, kind: &'static str, weight: f64) {
        let d = &self.defs.list[u.def];
        let key = d.m.ground.clone();
        let path = if d.air {
            self.pf.route(&self.map, &self.fields, None, u.p, goal, weight)
        } else {
            self.pf.route(&self.map, &self.fields, key.as_deref(), u.p, goal, weight)
        };
        let path: Vec<[f64; 2]> = path.iter().map(|p| [round(p.x), round(p.z)]).collect();
        self.sent.insert(u.id, (goal, kind, self.now));
        self.push(Command { c: kind, u: Some(u.id), path: Some(path), ..Default::default() });
    }

    /// Sends a group of units to `goal` along one route, worked out for the first (its slowest).
    pub fn go_group(&mut self, units: &[&crate::world::Unit], goal: P, kind: &'static str, weight: f64) {
        if units.is_empty() {
            return;
        }
        // the ground ones share the slowest's route; each keeps its place in the group off the route's end
        let lead = units
            .iter()
            .filter(|u| !self.defs.list[u.def].air)
            .min_by(|a, b| self.defs.list[a.def].speed.total_cmp(&self.defs.list[b.def].speed))
            .copied();
        let shared: Option<Vec<P>> = lead.map(|l| {
            let key = self.defs.list[l.def].m.ground.clone();
            self.pf.route(&self.map, &self.fields, key.as_deref(), l.p, goal, weight)
        });
        let center = units.iter().fold(P::new(0.0, 0.0), |s, u| s.add(u.p)).scale(1.0 / units.len() as f64);
        for u in units {
            let d = &self.defs.list[u.def];
            let offset = u.p.sub(center);
            let offset = if offset.len() > 12.0 { offset.norm().scale(12.0) } else { offset };
            let own_goal = self.map.clamp(goal.add(offset.scale(0.5)));
            let path: Vec<P> = if d.air {
                self.pf.route(&self.map, &self.fields, None, u.p, own_goal, weight)
            } else {
                match &shared {
                    Some(route) if self.map.reachable(d.m.ground.as_deref(), u.p, goal) => {
                        let mut r = route.clone();
                        if let Some(last) = r.last_mut() {
                            if self.map.open(d.m.ground.as_deref(), own_goal) {
                                *last = own_goal;
                            }
                        }
                        r
                    }
                    _ => {
                        let key = d.m.ground.clone();
                        self.pf.route(&self.map, &self.fields, key.as_deref(), u.p, own_goal, weight)
                    }
                }
            };
            let path: Vec<[f64; 2]> = path.iter().map(|p| [round(p.x), round(p.z)]).collect();
            self.sent.insert(u.id, (goal, kind, self.now));
            self.push(Command { c: kind, u: Some(u.id), path: Some(path), ..Default::default() });
        }
    }

    /// Has `builder` build `def` at (or, if it cannot, within `search` studs of) `at`, walking there round threat.
    pub fn build(&mut self, builder: &crate::world::Unit, def: DefId, at: P, search: f64, tag: String) {
        let d = &self.defs.list[builder.def];
        let key = d.m.ground.clone();
        let reach = (d.m.build_range * 0.8).max(4.0);
        let mut path = self.pf.route(&self.map, &self.fields, key.as_deref(), builder.p, at, self.params.builder_threat_weight);
        // stop short of the site: the build order walks the rest
        while path.len() > 1 && path[path.len() - 1].dist(at) < reach {
            path.pop();
        }
        if path.len() == 1 && path[0].dist(at) < reach + 20.0 {
            path.clear();
        }
        let path: Vec<[f64; 2]> = path.iter().map(|p| [round(p.x), round(p.z)]).collect();
        self.sent.insert(builder.id, (at, "build", self.now));
        self.push(Command {
            c: "build",
            u: Some(builder.id),
            def: Some(self.defs.list[def].name.clone()),
            x: Some(round(at.x)),
            z: Some(round(at.z)),
            search: Some(search),
            path: if path.is_empty() { None } else { Some(path) },
            tag: Some(tag),
            ..Default::default()
        });
    }

    /// Has `builder` build `def` near `at` once it is done with what it is on.
    pub fn build_queued(&mut self, builder: &crate::world::Unit, def: DefId, at: P, search: f64, tag: Option<String>) {
        self.push(Command {
            c: "build",
            u: Some(builder.id),
            def: Some(self.defs.list[def].name.clone()),
            x: Some(round(at.x)),
            z: Some(round(at.z)),
            search: Some(search),
            queue: true,
            tag,
            ..Default::default()
        });
    }

    pub fn order_target(&mut self, u: &crate::world::Unit, kind: &'static str, target: i64, target_p: P) {
        self.sent.insert(u.id, (target_p, kind, self.now));
        self.push(Command { c: kind, u: Some(u.id), target: Some(target), ..Default::default() });
    }

    pub fn order_area(&mut self, u: &crate::world::Unit, kind: &'static str, at: P, radius: f64) {
        self.sent.insert(u.id, (at, kind, self.now));
        self.push(Command { c: kind, u: Some(u.id), x: Some(round(at.x)), z: Some(round(at.z)), radius: Some(radius), ..Default::default() });
    }

    pub fn dgun(&mut self, u: &crate::world::Unit, at: P) {
        self.push(Command { c: "dgun", u: Some(u.id), x: Some(round(at.x)), z: Some(round(at.z)), ..Default::default() });
    }

    pub fn stop(&mut self, u: &crate::world::Unit) {
        self.sent.remove(&u.id);
        self.push(Command { c: "stop", u: Some(u.id), ..Default::default() });
    }

    pub fn produce(&mut self, lab: &crate::world::Unit, def: DefId, n: u32) {
        *self.stats.made.entry(self.defs.list[def].name.clone()).or_insert(0) += n as u64;
        self.push(Command { c: "produce", u: Some(lab.id), def: Some(self.defs.list[def].name.clone()), n: Some(n), ..Default::default() });
    }

    // Reading the world ------------------------------------------------------------------------------------------

    /// The simulator, counted.
    pub fn simulate(&mut self, a: &[crate::sim::Fighter], b: &[crate::sim::Fighter], mut options: crate::sim::Options) -> crate::sim::Outcome {
        let started = std::time::Instant::now();
        options.horizon = options.horizon.min(self.params.sim_horizon.max(5.0));
        let outcome = crate::sim::simulate(&self.defs, a, b, options);
        self.stats.sims += 1;
        self.stats.sim_seconds += started.elapsed().as_secs_f64();
        outcome
    }

    /// The enemy's armed things that could join a fight at `at` within `radius` of it now or within `sim_reinforce`
    /// seconds' walk, as fighters.
    pub fn enemy_fighters_near(&self, world: &World, at: P, radius: f64) -> Vec<crate::sim::Fighter> {
        let mut out = Vec::new();
        for &i in &world.enemy {
            let u = &world.units[i];
            let d = &self.defs.list[u.def];
            if !u.built || !d.armed {
                continue;
            }
            let reach = radius + d.range_ground.max(d.range_air) + if d.mobile { d.speed * self.params.sim_reinforce } else { 0.0 };
            if u.p.dist(at) <= reach {
                out.push(crate::sim::Fighter { def: u.def, p: u.p, hp: u.hp });
            }
        }
        out
    }

    /// CircuitDef::IsAvailable: past its `since`, and fewer of its own than its `limit`.
    pub fn is_available(&self, def: DefId) -> bool {
        let d = &self.defs.list[def];
        if self.now < d.since {
            return false;
        }
        if d.limit < f64::MAX {
            let n = self.units_now.values().filter(|u| u.team == self.me && u.def == def).count() as f64;
            if n >= d.limit {
                return false;
            }
        }
        true
    }

    pub fn factory_count(&self) -> usize {
        self.units_now.values().filter(|u| u.team == self.me && u.built && self.defs.list[u.def].factory && self.defs.list[u.def].is_building).count()
    }

    pub fn seen_unit(&self, id: i64) -> Option<&Unit> {
        self.units_now.get(&id)
    }

    pub fn map_center(&self) -> P {
        P::new(self.map.ox + self.map.width_studs() / 2.0, self.map.oz + self.map.depth_studs() / 2.0)
    }

    /// Where converters go (BARb's metal base): a little behind home.
    pub fn metal_base(&self) -> P {
        self.map.clamp(self.home.add(self.toward_enemy().scale(-15.0)))
    }

    /// Where heavy energy goes (BARb's energy base, the BASE attribute's site): further behind home, to one side.
    pub fn energy_base(&self) -> P {
        let back = self.toward_enemy();
        let side = P::new(-back.z, back.x);
        self.map.clamp(self.home.add(back.scale(-30.0)).add(side.scale(15.0)))
    }

    /// The map's size in BARb's 512-elmo squares a side, the larger side.
    fn map_squares(&self) -> f64 {
        self.map.width_studs().max(self.map.depth_studs()) / ELMO / 512.0
    }

    /// factory.json select: offset range, the air map percent, and the speed percent.
    pub fn barb_select(&self) -> (f64, f64, f64, f64) {
        let s = self.barb.select;
        (s[0], s[1], s[2], s[3])
    }

    /// behaviour.json quota aa_threat at this map's size.
    pub fn barb_aa_threat(&self) -> f64 {
        let pts = &self.barb.aa_threat;
        let size = self.map_squares();
        match pts.len() {
            0 => 500.0,
            1 => pts[0][1],
            _ => {
                let (a, b) = (pts[0], pts[pts.len() - 1]);
                let t = ((size - a[0]) / (b[0] - a[0]).max(1e-6)).clamp(0.0, 1.0);
                a[1] + (b[1] - a[1]) * t
            }
        }
    }

    /// The base's defended radius (defence base_rad: a quarter of the map's larger side, within its range).
    pub fn base_range(&self) -> f64 {
        let [lo, hi] = self.barb.base_rad;
        (self.map.width_studs().max(self.map.depth_studs()) / ELMO / 4.0).clamp(lo, hi) * ELMO
    }

    pub fn toward_enemy(&self) -> P {
        self.enemy_home.sub(self.home).norm()
    }

    /// Where its army gathers: out from home toward the enemy, on its own ground.
    pub fn rally_point(&self) -> P {
        let dir = self.toward_enemy();
        let d = self.home.dist(self.enemy_home);
        self.map.clamp(self.home.add(dir.scale((d * 0.22).min(90.0))))
    }
}

pub fn round(v: f64) -> f64 {
    (v * 100.0).round() / 100.0
}
