//! The enemy in groups, as BARb's EnemyManager has them (CircuitAI barbarian, unit/enemy/EnemyManager.cpp,
//! KMeansIteration): k-means over everything of the enemy's, K = min(32, 1 + sqrt(count)), one iteration each thought
//! from where the means were left. Each group has what its things threaten together (their influence, the kernel
//! times sqrt(health), each mobile or static one by behaviour.json's thr_mod "mobile" and "static"), what they cost,
//! what of it is in each role, and BARb's "vague metric", (influence + 1) / cost: low for what is worth a lot and
//! guarded little, which an attack goes for first.

use crate::defs::Defs;
use crate::map::P;
use crate::world::World;
use crate::HashMap;

#[derive(Clone, Debug)]
pub struct Group {
    pub p: P,
    /// indices into world.units
    pub units: Vec<usize>,
    pub influence: f64,
    pub cost: f64,
    pub role_cost: HashMap<String, f64>,
    pub vague_metric: f64,
    /// armed worth, for the front map
    pub army: f64,
    pub radius: f64,
}

pub struct Groups {
    pub list: Vec<Group>,
    means: Vec<P>,
}

impl Groups {
    pub fn new() -> Groups {
        Groups { list: Vec::new(), means: Vec::new() }
    }

    pub fn update(&mut self, world: &World, defs: &Defs, mobile_mod: f64, static_mod: f64) {
        let enemies: Vec<usize> = world
            .enemy
            .iter()
            .copied()
            .filter(|&i| !defs.list[world.units[i].def].m.objectify)
            .collect();
        if enemies.is_empty() {
            self.list.clear();
            return;
        }
        let k = (1 + (enemies.len() as f64).sqrt() as usize).min(32);
        let seed = world.units[enemies[0]].p;
        // keep the means from last time; new ones start on things spread through the list
        self.means.truncate(k);
        while self.means.len() < k {
            let pick = enemies[(self.means.len() * 7919) % enemies.len()];
            self.means.push(if self.means.is_empty() { seed } else { world.units[pick].p });
        }
        let mut assigned = vec![0usize; enemies.len()];
        for (n, &i) in enemies.iter().enumerate() {
            let p = world.units[i].p;
            let mut best = 0;
            let mut best_d = f64::MAX;
            for (m, mean) in self.means.iter().enumerate() {
                let d = p.dist2(*mean);
                if d < best_d {
                    best_d = d;
                    best = m;
                }
            }
            assigned[n] = best;
        }
        let mut groups: Vec<Group> = (0..k)
            .map(|_| Group {
                p: P::new(0.0, 0.0),
                units: Vec::new(),
                influence: 0.0,
                cost: 0.0,
                role_cost: HashMap::default(),
                vague_metric: 0.0,
                army: 0.0,
                radius: 0.0,
            })
            .collect();
        for (n, &i) in enemies.iter().enumerate() {
            let g = &mut groups[assigned[n]];
            let u = &world.units[i];
            let d = &defs.list[u.def];
            g.p = g.p.add(u.p);
            g.units.push(i);
            let share = if u.built { 1.0 } else { u.progress };
            g.cost += d.cost * share;
            for role in &d.roles {
                *g.role_cost.entry(role.clone()).or_insert(0.0) += d.cost * share;
            }
            if u.built && d.armed {
                let kernel = d.thr_surf.max(d.thr_air);
                g.influence += kernel * u.hp.max(0.0).sqrt() * if d.mobile { mobile_mod } else { static_mod };
                g.army += d.power * u.health_share();
            }
        }
        let mut kept = Vec::new();
        self.means.clear();
        for mut g in groups {
            if g.units.is_empty() {
                continue;
            }
            g.p = g.p.scale(1.0 / g.units.len() as f64);
            g.radius = g.units.iter().map(|&i| world.units[i].p.dist(g.p)).fold(0.0, f64::max);
            g.vague_metric = (g.influence + 1.0) / (g.cost + 1e-6);
            self.means.push(g.p);
            kept.push(g);
        }
        self.list = kept;
    }

    /// The group whose things are most dangerous, and the one before it (BARb's "pre-max" group threat, which sizes a
    /// defence).
    pub fn pre_max_influence(&self) -> f64 {
        let mut values: Vec<f64> = self.list.iter().map(|g| g.influence).collect();
        values.sort_by(f64::total_cmp);
        if values.len() >= 2 {
            values[values.len() - 2]
        } else {
            values.last().copied().unwrap_or(0.0)
        }
    }
}
