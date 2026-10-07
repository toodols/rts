//! The map: the game's grid of CELL-stud cells, which cells each kind of ground unit may stand on (a "ground", keyed as
//! shared/pathfinder keys them), which of those are joined to which (`components`, so nothing is sent where it cannot
//! walk), the metal spots, and where buildings stand now (`occupied`), which routes go round.

use crate::protocol::MapMsg;
use crate::HashMap;
use std::collections::VecDeque;

#[derive(Clone, Copy, Debug, PartialEq)]
pub struct P {
    pub x: f64,
    pub z: f64,
}

impl P {
    pub fn new(x: f64, z: f64) -> P {
        P { x, z }
    }
    pub fn dist(self, o: P) -> f64 {
        ((self.x - o.x).powi(2) + (self.z - o.z).powi(2)).sqrt()
    }
    pub fn dist2(self, o: P) -> f64 {
        (self.x - o.x).powi(2) + (self.z - o.z).powi(2)
    }
    pub fn add(self, o: P) -> P {
        P::new(self.x + o.x, self.z + o.z)
    }
    pub fn sub(self, o: P) -> P {
        P::new(self.x - o.x, self.z - o.z)
    }
    pub fn scale(self, s: f64) -> P {
        P::new(self.x * s, self.z * s)
    }
    pub fn len(self) -> f64 {
        (self.x * self.x + self.z * self.z).sqrt()
    }
    pub fn norm(self) -> P {
        let l = self.len();
        if l < 1e-9 {
            P::new(0.0, 0.0)
        } else {
            self.scale(1.0 / l)
        }
    }
    pub fn lerp(self, o: P, t: f64) -> P {
        P::new(self.x + (o.x - self.x) * t, self.z + (o.z - self.z) * t)
    }
}

pub struct Ground {
    pub open: Vec<bool>,
    /// which joined patch each open cell is in (u32::MAX for closed)
    pub component: Vec<u32>,
}

#[derive(Clone, Debug)]
pub struct Spot {
    pub p: P,
    pub mult: f64,
}

pub struct Map {
    pub w: usize,
    pub h: usize,
    pub cell: f64,
    pub ox: f64,
    pub oz: f64,
    pub grounds: HashMap<String, Ground>,
    /// the ground's height at each cell's middle, and the geothermal vents: kept for what shoots over hills and
    /// what builds on vents, which nothing does yet
    #[allow(dead_code)]
    pub heights: Vec<f64>,
    pub metal: Vec<Spot>,
    #[allow(dead_code)]
    pub geo: Vec<P>,
    pub starts: HashMap<i64, P>,
    /// cells under a building, by the building's team (0 for none), refreshed each thought
    pub occupied: Vec<i64>,
}

impl Map {
    pub fn new(m: MapMsg) -> Map {
        let w = m.cells_x;
        let h = m.cells_z;
        let mut grounds = HashMap::default();
        for (key, bits) in m.grounds {
            let open: Vec<bool> = bits.bytes().map(|b| b == b'1').collect();
            let component = label(&open, w, h);
            grounds.insert(key, Ground { open, component });
        }
        let starts = m
            .starts
            .into_iter()
            .filter_map(|(k, v)| k.parse::<i64>().ok().map(|t| (t, P::new(v.x, v.z))))
            .collect();
        Map {
            w,
            h,
            cell: m.cell,
            ox: m.origin_x,
            oz: m.origin_z,
            grounds,
            heights: m.heights,
            metal: m.metal.into_iter().map(|s| Spot { p: P::new(s.x, s.z), mult: s.m }).collect(),
            geo: m.geo.into_iter().map(|s| P::new(s.x, s.z)).collect(),
            starts,
            occupied: vec![0; w * h],
        }
    }

    pub fn width_studs(&self) -> f64 {
        self.w as f64 * self.cell
    }
    pub fn depth_studs(&self) -> f64 {
        self.h as f64 * self.cell
    }

    pub fn cell_of(&self, p: P) -> (i64, i64) {
        (((p.x - self.ox) / self.cell).floor() as i64, ((p.z - self.oz) / self.cell).floor() as i64)
    }

    pub fn in_grid(&self, cx: i64, cz: i64) -> bool {
        cx >= 0 && cz >= 0 && (cx as usize) < self.w && (cz as usize) < self.h
    }

    pub fn index(&self, cx: i64, cz: i64) -> usize {
        cz as usize * self.w + cx as usize
    }

    pub fn center(&self, cx: i64, cz: i64) -> P {
        P::new(self.ox + (cx as f64 + 0.5) * self.cell, self.oz + (cz as f64 + 0.5) * self.cell)
    }

    pub fn clamp(&self, p: P) -> P {
        let margin = self.cell * 2.0;
        P::new(
            p.x.clamp(self.ox + margin, self.ox + self.width_studs() - margin),
            p.z.clamp(self.oz + margin, self.oz + self.depth_studs() - margin),
        )
    }

    #[allow(dead_code)]
    pub fn height(&self, p: P) -> f64 {
        let (cx, cz) = self.cell_of(p);
        if self.in_grid(cx, cz) {
            self.heights[self.index(cx, cz)]
        } else {
            0.0
        }
    }

    /// Whether ground `key` (None: what flies) may stand at `p`.
    pub fn open(&self, key: Option<&str>, p: P) -> bool {
        let (cx, cz) = self.cell_of(p);
        if !self.in_grid(cx, cz) {
            return false;
        }
        match key.and_then(|k| self.grounds.get(k)) {
            None => true,
            Some(g) => g.open[self.index(cx, cz)],
        }
    }

    /// The open cell of ground `key` nearest `p`, within `radius` cells, as a point.
    pub fn nearest_open(&self, key: Option<&str>, p: P, radius: i64) -> Option<P> {
        let ground = match key.and_then(|k| self.grounds.get(k)) {
            None => return Some(self.clamp(p)),
            Some(g) => g,
        };
        let (cx, cz) = self.cell_of(p);
        if self.in_grid(cx, cz) && ground.open[self.index(cx, cz)] {
            return Some(p);
        }
        for r in 1..=radius {
            let mut best: Option<(f64, P)> = None;
            for dz in -r..=r {
                for dx in -r..=r {
                    if dx.abs() != r && dz.abs() != r {
                        continue;
                    }
                    let (x, z) = (cx + dx, cz + dz);
                    if self.in_grid(x, z) && ground.open[self.index(x, z)] {
                        let c = self.center(x, z);
                        let d = c.dist2(p);
                        if best.map_or(true, |(bd, _)| d < bd) {
                            best = Some((d, c));
                        }
                    }
                }
            }
            if let Some((_, c)) = best {
                return Some(c);
            }
        }
        None
    }

    /// The joined patch of ground `key` at `p`, looking a few cells round for one if `p` is on closed ground; None for
    /// what flies (it reaches everywhere) or nowhere open near.
    pub fn component(&self, key: Option<&str>, p: P) -> Option<u32> {
        let ground = self.grounds.get(key?)?;
        let q = self.nearest_open(key, p, 4)?;
        let (cx, cz) = self.cell_of(q);
        if !self.in_grid(cx, cz) {
            return None;
        }
        let c = ground.component[self.index(cx, cz)];
        if c == u32::MAX {
            None
        } else {
            Some(c)
        }
    }

    /// Whether something on ground `key` at `from` can walk to near `to`.
    pub fn reachable(&self, key: Option<&str>, from: P, to: P) -> bool {
        if key.is_none() {
            return true;
        }
        match (self.component(key, from), self.component(key, to)) {
            (Some(a), Some(b)) => a == b,
            _ => false,
        }
    }

    pub fn clear_occupied(&mut self) {
        for v in self.occupied.iter_mut() {
            *v = 0;
        }
    }

    pub fn mark_building(&mut self, p: P, half_x: f64, half_z: f64, team: i64) {
        let (x0, z0) = self.cell_of(P::new(p.x - half_x, p.z - half_z));
        let (x1, z1) = self.cell_of(P::new(p.x + half_x - 0.01, p.z + half_z - 0.01));
        for z in z0.max(0)..=z1.min(self.h as i64 - 1) {
            for x in x0.max(0)..=x1.min(self.w as i64 - 1) {
                let i = self.index(x, z);
                self.occupied[i] = team;
            }
        }
    }
}

/// Labels the joined patches of open cells (4-way).
fn label(open: &[bool], w: usize, h: usize) -> Vec<u32> {
    let mut component = vec![u32::MAX; w * h];
    let mut next = 0u32;
    let mut queue = VecDeque::new();
    for start in 0..w * h {
        if !open[start] || component[start] != u32::MAX {
            continue;
        }
        component[start] = next;
        queue.push_back(start);
        while let Some(i) = queue.pop_front() {
            let (x, z) = (i % w, i / w);
            let mut visit = |j: usize| {
                if open[j] && component[j] == u32::MAX {
                    component[j] = next;
                    queue.push_back(j);
                }
            };
            if x > 0 {
                visit(i - 1);
            }
            if x + 1 < w {
                visit(i + 1);
            }
            if z > 0 {
                visit(i - w);
            }
            if z + 1 < h {
                visit(i + w);
            }
        }
        next += 1;
    }
    component
}
