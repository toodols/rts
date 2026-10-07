//! Routes round danger. The game's own pathfinder finds the shortest way; this one finds the cheapest, where a cell
//! costs more the more enemy fire reaches it (fields.rs), as BARb's threat-aware pathing does: a builder weighs danger
//! heavily and goes the long way round an enemy's guns, an army lightly. Buildings cost extra to go through, as the
//! game's units have to walk round them. A route comes back as a few waypoints: the cells of the search pulled tight
//! wherever a straight line costs no more than the cells it cuts out.

use crate::fields::Fields;
use crate::map::{Map, P};
use std::cmp::Ordering;
use std::collections::BinaryHeap;

/// What a cell of threat (fields.rs, BARb's units) adds to the cost of crossing it, before the route's own weight.
const DANGER_UNIT: f64 = 1.0;
/// The cost of walking through a building's cell, over open ground.
const BUILDING_COST: f64 = 6.0;
const MAX_EXPANSIONS: usize = 60_000;

#[derive(Copy, Clone, PartialEq)]
struct Node {
    f: f64,
    i: u32,
}
impl Eq for Node {}
impl Ord for Node {
    fn cmp(&self, o: &Self) -> Ordering {
        o.f.total_cmp(&self.f).then_with(|| self.i.cmp(&o.i))
    }
}
impl PartialOrd for Node {
    fn partial_cmp(&self, o: &Self) -> Option<Ordering> {
        Some(self.cmp(o))
    }
}

pub struct Pathfinder {
    g: Vec<f64>,
    from: Vec<u32>,
    stamp: Vec<u32>,
    generation: u32,
    pub searches: u64,
    pub expansions: u64,
}

impl Pathfinder {
    pub fn new(cells: usize) -> Pathfinder {
        Pathfinder { g: vec![0.0; cells], from: vec![0; cells], stamp: vec![0; cells], generation: 0, searches: 0, expansions: 0 }
    }

    fn ensure(&mut self, cells: usize) {
        if self.g.len() < cells {
            self.g.resize(cells, 0.0);
            self.from.resize(cells, 0);
            self.stamp.resize(cells, 0);
        }
    }

    /// A* on a w by h grid, 8 ways, from `start` to `goal` (cell indices): `open` says which cells may be entered and
    /// `cost` what entering one costs, at least 1 (per cell of distance). The cells of the way, start first.
    fn search(
        &mut self,
        w: usize,
        h: usize,
        start: usize,
        goal: usize,
        open: &dyn Fn(usize) -> bool,
        cost: &dyn Fn(usize) -> f64,
    ) -> Option<Vec<usize>> {
        self.ensure(w * h);
        self.searches += 1;
        self.generation = self.generation.wrapping_add(1);
        if self.generation == 0 {
            for s in self.stamp.iter_mut() {
                *s = 0;
            }
            self.generation = 1;
        }
        let gen = self.generation;
        let (gx, gz) = ((goal % w) as f64, (goal / w) as f64);
        let heuristic = |i: usize| -> f64 {
            let dx = ((i % w) as f64 - gx).abs();
            let dz = ((i / w) as f64 - gz).abs();
            dx.max(dz) + (std::f64::consts::SQRT_2 - 1.0) * dx.min(dz)
        };
        let mut heap = BinaryHeap::new();
        self.g[start] = 0.0;
        self.stamp[start] = gen;
        self.from[start] = start as u32;
        heap.push(Node { f: heuristic(start), i: start as u32 });
        let mut expansions = 0;
        // the settled cell nearest the goal, for a way that gets as near as it can
        let mut nearest = (heuristic(start), start);
        while let Some(Node { f, i }) = heap.pop() {
            let i = i as usize;
            let gi = self.g[i];
            if f - heuristic(i) > gi + 1e-9 {
                continue;
            }
            if i == goal {
                nearest = (0.0, goal);
                break;
            }
            let hi = heuristic(i);
            if hi < nearest.0 {
                nearest = (hi, i);
            }
            expansions += 1;
            if expansions > MAX_EXPANSIONS {
                break;
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
                let diagonal = dx != 0 && dz != 0;
                if diagonal {
                    // no cutting a corner past a closed cell
                    if !open(z as usize * w + nx as usize) || !open(nz as usize * w + x as usize) {
                        continue;
                    }
                }
                let step = if diagonal { std::f64::consts::SQRT_2 } else { 1.0 };
                let ng = gi + step * cost(j);
                if self.stamp[j] != gen || ng < self.g[j] {
                    self.stamp[j] = gen;
                    self.g[j] = ng;
                    self.from[j] = i as u32;
                    heap.push(Node { f: ng + heuristic(j), i: j as u32 });
                }
            }
        }
        self.expansions += expansions as u64;
        let end = nearest.1;
        if end == start && start != goal {
            return None;
        }
        let mut cells = vec![end];
        let mut at = end;
        while at != start {
            at = self.from[at] as usize;
            cells.push(at);
        }
        cells.reverse();
        Some(cells)
    }

    /// The way for something on ground `key` from `from` to `to`, round danger by `weight`, as waypoints (the last
    /// being `to`, or as near it as there is a way); straight there for what flies (`key` None) unless `weight` asks
    /// it round anti-air.
    pub fn route(&mut self, map: &Map, fields: &Fields, key: Option<&str>, from: P, to: P, weight: f64) -> Vec<P> {
        let ground = match key.and_then(|k| map.grounds.get(k)) {
            Some(g) => g,
            None => return self.air_route(fields, from, to, weight),
        };
        let start_p = match map.nearest_open(key, from, 6) {
            Some(p) => p,
            None => return vec![to],
        };
        let goal_p = match map.nearest_open(key, to, 8) {
            Some(p) => p,
            None => return vec![to],
        };
        let (sx, sz) = map.cell_of(start_p);
        let (gx, gz) = map.cell_of(goal_p);
        if !map.in_grid(sx, sz) || !map.in_grid(gx, gz) {
            return vec![to];
        }
        let w = map.w;
        let start = map.index(sx, sz);
        let goal = map.index(gx, gz);
        if ground.component[start] != ground.component[goal] {
            // it cannot get there: as near as it can, the search will find
        }
        let danger_cost = weight * DANGER_UNIT;
        let cell_danger = |i: usize| -> f64 {
            let p = P::new(map.ox + ((i % w) as f64 + 0.5) * map.cell, map.oz + ((i / w) as f64 + 0.5) * map.cell);
            fields.danger(p)
        };
        let open = |i: usize| ground.open[i];
        let cost = |i: usize| -> f64 {
            let mut c = 1.0 + danger_cost * cell_danger(i);
            if map.occupied[i] != 0 {
                c += BUILDING_COST;
            }
            c
        };
        let cells = match self.search(w, map.h, start, goal, &open, &cost) {
            Some(c) => c,
            None => return vec![to],
        };
        let points = self.pull_tight(&cells, w, &|i| open(i), &|i| cost(i), &|i| map.center((i % w) as i64, (i / w) as i64));
        let mut out = points;
        // the last point is where it was sent, if it got there
        if let Some(last) = out.last_mut() {
            if *cells.last().unwrap() == goal {
                *last = if map.open(key, to) { to } else { goal_p };
            }
        }
        if out.len() > 1 {
            out.remove(0);
        }
        out
    }

    /// For what flies: on the field's grid, round anti-air by `weight`.
    fn air_route(&mut self, fields: &Fields, from: P, to: P, weight: f64) -> Vec<P> {
        if weight <= 0.0 || fields.peak_danger(from, to, true) <= 0.0 {
            return vec![to];
        }
        let (w, h) = (fields.w, fields.h);
        let (Some(start), Some(goal)) = (fields.index_of(from), fields.index_of(to)) else {
            return vec![to];
        };
        let danger_cost = weight * DANGER_UNIT;
        let open = |_i: usize| true;
        let cost = |i: usize| 1.0 + danger_cost * fields.e_air[i];
        let cells = match self.search(w, h, start, goal, &open, &cost) {
            Some(c) => c,
            None => return vec![to],
        };
        let mut points = self.pull_tight(&cells, w, &open, &cost, &|i| fields.center(i));
        if points.len() > 1 {
            points.remove(0);
        }
        if let Some(last) = points.last_mut() {
            *last = to;
        }
        points
    }

    /// The cells of a way as the fewest points that keep its cost: from each point on, the furthest cell of the way a
    /// straight line reaches through open cells for no more than the way itself costs there.
    fn pull_tight(
        &self,
        cells: &[usize],
        w: usize,
        open: &dyn Fn(usize) -> bool,
        cost: &dyn Fn(usize) -> f64,
        center: &dyn Fn(usize) -> P,
    ) -> Vec<P> {
        if cells.len() <= 2 {
            return cells.iter().map(|&c| center(c)).collect();
        }
        // the cost along the way up to each cell
        let mut along = vec![0.0; cells.len()];
        for k in 1..cells.len() {
            let (a, b) = (cells[k - 1], cells[k]);
            let diagonal = a % w != b % w && a / w != b / w;
            along[k] = along[k - 1] + if diagonal { std::f64::consts::SQRT_2 } else { 1.0 } * cost(b);
        }
        let mut out = vec![center(cells[0])];
        let mut anchor = 0;
        while anchor < cells.len() - 1 {
            let mut best = anchor + 1;
            // look ahead in strides, then settle on the furthest that holds
            let mut k = cells.len() - 1;
            while k > anchor + 1 {
                if let Some(line_cost) = line_cost(cells[anchor], cells[k], w, open, cost) {
                    if line_cost <= (along[k] - along[anchor]) * 1.02 + 0.5 {
                        best = k;
                        break;
                    }
                }
                k = if k - anchor > 16 { anchor + (k - anchor) / 2 } else { k - 1 };
            }
            out.push(center(cells[best]));
            anchor = best;
        }
        out
    }
}

/// What a straight line from cell `a` to cell `b` costs, per cell of distance, sampled every half cell (each sample
/// half a cell's worth of its cell's cost), or None if it passes a closed cell or grazes one to either side.
fn line_cost(a: usize, b: usize, w: usize, open: &dyn Fn(usize) -> bool, cost: &dyn Fn(usize) -> f64) -> Option<f64> {
    let (ax, az) = ((a % w) as f64 + 0.5, (a / w) as f64 + 0.5);
    let (bx, bz) = ((b % w) as f64 + 0.5, (b / w) as f64 + 0.5);
    let length = ((bx - ax).powi(2) + (bz - az).powi(2)).sqrt();
    let steps = (length * 2.0).ceil().max(1.0) as usize;
    let per_step = length / steps as f64;
    let mut total = 0.0;
    for s in 1..=steps {
        let t = s as f64 / steps as f64;
        let (x, z) = (ax + (bx - ax) * t, az + (bz - az) * t);
        for (ox, oz) in [(0.0, 0.0), (0.3, 0.3), (-0.3, -0.3), (0.3, -0.3), (-0.3, 0.3)] {
            let (cx, cz) = ((x + ox).floor(), (z + oz).floor());
            if cx < 0.0 || cz < 0.0 || cx as usize >= w {
                return None;
            }
            if !open(cz as usize * w + cx as usize) {
                return None;
            }
        }
        total += cost(z.floor() as usize * w + x.floor() as usize) * per_step;
    }
    Some(total)
}
