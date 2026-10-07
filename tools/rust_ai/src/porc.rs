//! BARb's porcupine: defences by extractor clusters (CircuitAI barbarian: module/MilitaryManager.cpp
//! `DefaultMakeDefence`, `UpdateDefenceTasks`, `MakeBaseDefence`, `UpdateDefence`; BAR's
//! script/hard/manager/military.as `AiMakeDefence`; config/hard/build_chain.json `porcupine`; see PORTING.md).
//!
//! A defence point's cost (the metal of the defences at it) is worked out again each thought from what stands and
//! what is queued there, rather than kept by marking and unmarking each defence as BARb does; it comes to the same.

use crate::brain::Brain;
use crate::builders::{Builders, Kind, Priority, ELMO, THREAT_MIN};
use crate::defs::DefId;
use crate::map::P;
use crate::world::World;

#[derive(Default)]
pub struct Porc {
    /// UpdateDefenceTasks's round of the clusters
    next_cluster: usize,
    next_update: f64,
    /// base defences still to come: (def, second, where)
    base_queue: Vec<(DefId, f64, P)>,
    base_made: bool,
    amount_offset: Option<f64>,
}

impl Porc {
    pub fn new() -> Porc {
        Porc::default()
    }
}

/// The defenders a land cluster is given (porcupine.land), as this game's defs its builders can build, in order.
fn land_defenders(brain: &Brain, world: &World) -> Vec<DefId> {
    let porc = &brain.barb.porcupine;
    let buildable = |d: DefId| world.own.iter().any(|&i| brain.defs.list[world.units[i].def].options.contains(&d));
    let mut out = Vec::new();
    for &idx in &porc.land {
        if let Some(names) = porc.defenders.get(idx) {
            if let Some(d) = names.iter().filter_map(|n| brain.defs.get(n)).find(|&d| buildable(d) && brain.is_available(d)) {
                out.push(d);
            }
        }
    }
    out
}

/// BAR's script (military.as AiMakeDefence): after 5 minutes, or at 10 metal income, or once the enemy has an army.
fn allowed(brain: &Brain, world: &World) -> bool {
    brain.now > brain.params.defence_after
        || brain.economy.state.metal_income > brain.params.defence_income
        || world.enemy.iter().any(|&i| {
            let d = &brain.defs.list[world.units[i].def];
            d.armed && d.mobile && !d.commander
        })
}

/// Each defence point's cost from the defences of its own that stand, or are queued, there.
pub fn refresh_points(b: &Builders, brain: &mut Brain, world: &World) {
    let near = 30.0;
    let costs: Vec<f64> = brain
        .metal
        .points
        .iter()
        .enumerate()
        .map(|(pi, pt)| {
            let standing: f64 = world
                .own
                .iter()
                .map(|&i| &world.units[i])
                .filter(|u| {
                    let d = &brain.defs.list[u.def];
                    d.is_building && d.armed && u.p.dist(pt.p) < near
                })
                .map(|u| brain.defs.list[u.def].m.metal)
                .sum();
            let queued: f64 = b.tasks.values().filter(|t| t.kind == Kind::Defence && t.def_point == Some(pi) && t.target.is_none()).map(|t| t.cost_metal).sum();
            standing + queued
        })
        .collect();
    for (pt, c) in brain.metal.points.iter_mut().zip(costs) {
        pt.cost = c;
    }
}

/// MakeDefence(pos): the porcupine of the cluster nearest `pos`.
pub fn make_defence(b: &mut Builders, brain: &mut Brain, world: &World, pos: P) {
    if let Some(c) = brain.metal.nearest_cluster(pos) {
        default_make_defence(b, brain, world, c, pos);
    }
}

fn amount_factor(brain: &mut Brain) -> f64 {
    let amount = brain.barb.porcupine.amount.clone();
    let get = |k: &str, i: usize, d: f64| amount.get(k).and_then(|v| v.get(i)).and_then(|v| v.as_f64()).unwrap_or(d);
    let (min_off, max_off) = (get("offset", 0, -0.2), get("offset", 1, 0.2));
    let offset = match brain.porc.amount_offset {
        Some(o) => o,
        None => {
            let o = brain.rng.unit() * (max_off - min_off) + min_off;
            brain.porc.amount_offset = Some(o);
            o
        }
    };
    let (min_f, max_f) = (get("factor", 0, 2.0), get("factor", 1, 1.0));
    let (min_m, max_m) = (get("map", 0, 8.0), get("map", 1, 24.0));
    // the map's size in 512-elmo squares
    let size = (brain.map.width_studs() / ELMO / 512.0) * (brain.map.depth_studs() / ELMO / 512.0);
    (max_f - min_f) / (max_m * max_m - min_m * min_m) * (size - min_m * min_m) + min_f + offset
}

/// DefaultMakeDefence.
pub fn default_make_defence(b: &mut Builders, brain: &mut Brain, world: &World, cluster: usize, pos: P) {
    if !allowed(brain, world) {
        return;
    }
    let s = brain.economy.state.clone();
    let metal_income = s.metal_income.min(s.energy_income);
    let max_cost = amount_factor(brain) * brain.params.porc_scale * metal_income;
    let Some(point) = brain.metal.closest_point(cluster, pos, &|p| p.cost < max_cost) else { return };
    let point_cost = brain.metal.points[point].cost;
    let point_p = brain.metal.points[point].p;

    // front-line porcupine: a rich cluster far from base, or next to two threatened clusters, or on ground not its own
    let m = &brain.metal;
    let mut is_porc = false;
    if m.cluster_std > 0.3 * m.cluster_avg_income {
        let income = (m.cluster_avg_income + m.cluster_max_income) * 0.5;
        is_porc = m.clusters[cluster].p.dist(brain.home) > 1000.0 * ELMO && m.clusters[cluster].income > income;
    }
    if !is_porc {
        let mut threatened = 0;
        for &(o, _) in &m.edges[cluster] {
            if m.is_finished(o) {
                continue;
            }
            if m.clusters[o].spots.iter().any(|&s| brain.fields.danger(m.spots[s].0) > THREAT_MIN * 4.0) {
                threatened += 1;
                if threatened >= 2 {
                    is_porc = true;
                    break;
                }
            }
        }
    }
    is_porc |= brain.fields.influence_at(pos) < 0.01;

    let defenders = land_defenders(brain, world);
    let prevent = brain.barb.porcupine.prevent as usize;
    let num = if is_porc { defenders.len() } else { prevent.min(defenders.len()) };
    let enemy_air = world.enemy.iter().any(|&i| brain.defs.list[world.units[i].def].air && brain.defs.list[world.units[i].def].armed);

    let front = brain.enemy_home.sub(pos).norm().scale(8.0 * 10.0 * ELMO);
    let side = P::new(-front.z, front.x);
    let back = point_p.sub(front);
    let mut poses: [([P; 2], usize); 3] = [
        ([point_p.add(front), point_p.add(front).sub(side)], 0),
        ([point_p, point_p.sub(side)], 0),
        ([back, back.sub(side)], 0),
    ];
    let mut total = 0.0;
    let mut parent: Option<u64> = None;
    for &def in defenders.iter().take(num) {
        let d = brain.defs.list[def].clone();
        if d.anti_air && d.dps_ground <= 0.0 && !enemy_air {
            continue;
        }
        total += d.m.metal;
        if total <= point_cost {
            continue;
        }
        if total >= max_cost {
            break;
        }
        let row = if d.armed { if d.range_ground.max(d.range_air) < 500.0 * ELMO { 0 } else { 1 } } else { 2 };
        let ind = poses[row].1 % 2;
        poses[row].1 += 1;
        let at = brain.map.clamp(poses[row].0[ind]);
        poses[row].0[ind] = if ind == 0 { poses[row].0[ind].add(side) } else { poses[row].0[ind].sub(side) };
        let id = b.enqueue(brain.now, Kind::Defence, Priority::Normal, Some(def), at, 2.0 * 8.0 * ELMO, parent.is_none(), 0.0, brain);
        b.tasks.get_mut(&id).unwrap().def_point = Some(point);
        brain.metal.points[point].cost += d.m.metal;
        if let Some(pid) = parent {
            if let Some(pt) = b.tasks.get_mut(&pid) {
                pt.next = Some(id);
            }
        }
        parent = Some(id);
    }
}

/// Every 5 seconds, the next cluster that is being or has been built on (UpdateDefenceTasks); and the base defences
/// as their time comes (UpdateDefence).
pub fn update(b: &mut Builders, brain: &mut Brain, world: &World) {
    refresh_points(b, brain, world);
    // the base's defences, from the first factory on
    if !brain.porc.base_made {
        if let Some(f) = world.own.iter().map(|&i| &world.units[i]).find(|u| u.built && brain.defs.list[u.def].factory && brain.defs.list[u.def].is_building) {
            brain.porc.base_made = true;
            let at = f.p;
            let porc = brain.barb.porcupine.clone();
            for entry in &porc.base {
                let idx = entry[0] as usize;
                if let Some(d) = porc.defenders.get(idx).and_then(|names| names.iter().find_map(|n| brain.defs.get(n))) {
                    brain.porc.base_queue.push((d, entry[1], at));
                }
            }
        }
    }
    let now = brain.now;
    let due: Vec<(DefId, f64, P)> = brain.porc.base_queue.iter().copied().filter(|(_, t, _)| now >= *t).collect();
    brain.porc.base_queue.retain(|(_, t, _)| now < *t);
    for (d, _, at) in due {
        b.enqueue(now, Kind::Defence, Priority::Normal, Some(d), at, 0.0, true, 0.0, brain);
    }
    if now < brain.porc.next_update {
        return;
    }
    brain.porc.next_update = now + 5.0;
    let n = brain.metal.clusters.len();
    for k in 0..n {
        let c = (brain.porc.next_cluster + k) % n;
        let m = &brain.metal;
        let working = m.clusters[c].spots.iter().any(|&s| m.mine[s]) && (m.is_queued(c) || m.is_finished(c));
        if working {
            brain.porc.next_cluster = c + 1;
            let p = brain.metal.clusters[c].p;
            default_make_defence(b, brain, world, c, p);
            return;
        }
    }
}
