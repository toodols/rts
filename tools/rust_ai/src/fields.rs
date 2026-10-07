//! The fields the AI sees the map through, on a grid of FIELD-stud cells. The threat and influence maps are BARb's
//! (CircuitAI barbarian: map/ThreatMap.cpp, map/InfluenceMap.cpp), in studs rather than elmos:
//!
//! - threat, for the surface and for the air: every enemy thing that can fire on that layer adds its threat, its
//!   damage kernel (defs.rs, sqrt(dps) * damage^0.25 / 128) times the square root of its health, over the disc its
//!   weapons reach, fading to half at the edge (1 - 0.5 d / R). The disc is its range with a slack: its splash's
//!   radius, half of DEFAULT_SLACK, a third of a second's walk for what moves (the threat map is redrawn three times a
//!   second) or DEFAULT_SLACK more for what does not, and what its speed adds; and its middle is led by a second of its
//!   velocity, no more than twice DEFAULT_SLACK.
//! - influence: its own things' power, fading to nothing at their range (a static defence's half range), less the
//!   enemy's threat drawn the same way. Positive is its ground, negative the enemy's; the line between is the front.
//!
//! Beside them, of its own: its own threat (drawn as the enemy's is, to see how much of its own fire covers a place),
//! what each side has in each cell that is worth destroying and does not fight (economy, builders, labs), and the
//! metal lying in each cell to be reclaimed.

use crate::defs::Defs;
use crate::map::{Map, P};
use crate::world::World;

pub const FIELD: f64 = 8.0;
/// BARb's DEFAULT_SLACK, 64 elmos, in studs (11 elmos a stud).
const DEFAULT_SLACK: f64 = 64.0 / 11.0;
/// behaviour.json's quota.slack_mod: "all" 0.5, "static" 1.0, "speed" [0.75, 4.0]
const SLACK_ALL: f64 = 0.5;
const SLACK_STATIC: f64 = 1.0;
/// what speed adds to the disc: 0.75 cells of 64 elmos per elmo a frame, at most 4 of them, in studs
const SLACK_SPEED: f64 = 0.75 * 64.0 / 30.0;
const SLACK_SPEED_MAX: f64 = 4.0 * 64.0 / 11.0;
/// the threat map is redrawn this often, in seconds (THREAT_UPDATE_RATE, a third of a second)
const THREAT_UPDATE: f64 = 1.0 / 3.0;

pub struct Fields {
    pub w: usize,
    pub h: usize,
    pub ox: f64,
    pub oz: f64,
    /// the enemy's threat to what is on the surface, and to what flies
    pub e_surf: Vec<f64>,
    pub e_air: Vec<f64>,
    /// its own threat, drawn the same way
    pub o_surf: Vec<f64>,
    pub o_air: Vec<f64>,
    pub influence: Vec<f64>,
    /// BARb's ally-defend influence: its static defences' power over half their range (InfluenceMap AddStaticArmed)
    pub defend: Vec<f64>,
    pub e_value: Vec<f64>,
    pub o_value: Vec<f64>,
    pub reclaim: Vec<f64>,
}

impl Fields {
    pub fn new(map: &Map) -> Fields {
        let w = (map.width_studs() / FIELD).ceil() as usize;
        let h = (map.depth_studs() / FIELD).ceil() as usize;
        let n = w * h;
        Fields {
            w,
            h,
            ox: map.ox,
            oz: map.oz,
            e_surf: vec![0.0; n],
            e_air: vec![0.0; n],
            o_surf: vec![0.0; n],
            o_air: vec![0.0; n],
            influence: vec![0.0; n],
            defend: vec![0.0; n],
            e_value: vec![0.0; n],
            o_value: vec![0.0; n],
            reclaim: vec![0.0; n],
        }
    }

    pub fn index_of(&self, p: P) -> Option<usize> {
        let cx = ((p.x - self.ox) / FIELD).floor() as i64;
        let cz = ((p.z - self.oz) / FIELD).floor() as i64;
        if cx >= 0 && cz >= 0 && (cx as usize) < self.w && (cz as usize) < self.h {
            Some(cz as usize * self.w + cx as usize)
        } else {
            None
        }
    }
    pub fn center(&self, i: usize) -> P {
        P::new(self.ox + ((i % self.w) as f64 + 0.5) * FIELD, self.oz + ((i / self.w) as f64 + 0.5) * FIELD)
    }
    pub fn at(&self, field: &[f64], p: P) -> f64 {
        self.index_of(p).map_or(0.0, |i| field[i])
    }

    /// The enemy's threat to something on the ground at `p` (what BARb's builders check, GetBuilderThreatAt).
    pub fn danger(&self, p: P) -> f64 {
        self.at(&self.e_surf, p)
    }
    /// The enemy's threat to something in the air at `p`.
    pub fn air_danger(&self, p: P) -> f64 {
        self.at(&self.e_air, p)
    }

    /// GetThreatAt for a unit that flies (`air`) or not.
    pub fn threat_at(&self, air: bool, p: P) -> f64 {
        if air {
            self.air_danger(p)
        } else {
            self.danger(p)
        }
    }

    pub fn defend_at(&self, p: P) -> f64 {
        self.at(&self.defend, p)
    }

    pub fn influence_at(&self, p: P) -> f64 {
        self.at(&self.influence, p)
    }

    /// The most enemy threat on the straight way from `a` to `b`.
    pub fn peak_danger(&self, a: P, b: P, air: bool) -> f64 {
        let steps = (a.dist(b) / (FIELD * 0.5)).ceil().max(1.0) as usize;
        let field = if air { &self.e_air } else { &self.e_surf };
        let mut peak: f64 = 0.0;
        for s in 0..=steps {
            peak = peak.max(self.at(field, a.lerp(b, s as f64 / steps as f64)));
        }
        peak
    }

    /// Adds `amount` over the disc of `radius` round `p`, falling off to `1 - fade` of it at the edge.
    fn stamp(&self, field: &mut [f64], p: P, radius: f64, amount: f64, fade: f64) {
        if radius <= 0.0 || amount == 0.0 {
            return;
        }
        let (w, h, ox, oz) = (self.w, self.h, self.ox, self.oz);
        let x0 = (((p.x - radius - ox) / FIELD).floor() as i64).max(0);
        let x1 = (((p.x + radius - ox) / FIELD).floor() as i64).min(w as i64 - 1);
        let z0 = (((p.z - radius - oz) / FIELD).floor() as i64).max(0);
        let z1 = (((p.z + radius - oz) / FIELD).floor() as i64).min(h as i64 - 1);
        for z in z0..=z1 {
            for x in x0..=x1 {
                let c = P::new(ox + (x as f64 + 0.5) * FIELD, oz + (z as f64 + 0.5) * FIELD);
                let d = c.dist(p);
                if d <= radius {
                    field[z as usize * w + x as usize] += amount * (1.0 - fade * d / radius);
                }
            }
        }
    }

    pub fn refresh(&mut self, world: &World, defs: &Defs) {
        let n = self.w * self.h;
        let mut e_surf = vec![0.0; n];
        let mut e_air = vec![0.0; n];
        let mut o_surf = vec![0.0; n];
        let mut o_air = vec![0.0; n];
        let mut ally_infl = vec![0.0; n];
        let mut defend = vec![0.0; n];
        let mut enemy_infl = vec![0.0; n];
        let mut e_value = vec![0.0; n];
        let mut o_value = vec![0.0; n];
        let mut reclaim = vec![0.0; n];
        for (enemy, list) in [(true, &world.enemy), (false, &world.own)] {
            for &i in list.iter() {
                let u = &world.units[i];
                let d = &defs.list[u.def];
                let share = if u.built { 1.0 } else { u.progress };
                if !d.armed || !u.built || u.emp >= 1.0 {
                    if !d.air {
                        let value = if enemy { &mut e_value } else { &mut o_value };
                        if let Some(idx) = self.index_of(u.p) {
                            // what makes metal and what builds counts double: an economy grows from them
                            let weight = if d.metal_make > 0.0 || d.builder || d.factory { 2.0 } else { 1.0 };
                            value[idx] += d.power * share * weight;
                        }
                    }
                    continue;
                }
                // BARb's slack round a thing's reach, and where its threat is drawn from
                let speed = u.v.len();
                let mut slack = FIELD - 0.1 + d.splash / 2.0 + DEFAULT_SLACK * SLACK_ALL;
                slack += if d.mobile { THREAT_UPDATE * d.speed } else { DEFAULT_SLACK * SLACK_STATIC };
                slack += (speed * SLACK_SPEED).min(SLACK_SPEED_MAX);
                let lead_cap = DEFAULT_SLACK * 2.0;
                let lead = if speed * 1.0 > lead_cap { u.v.norm().scale(lead_cap) } else { u.v };
                let at = u.p.add(lead);
                let health = u.hp.max(0.0).sqrt();
                let threat_surf = d.thr_surf * health;
                let threat_air = d.thr_air * health;
                if enemy {
                    if d.range_ground > 0.0 {
                        let r = d.range_ground + slack;
                        self.stamp(&mut e_surf, at, r, threat_surf, 0.5);
                        let infl_r = if d.mobile { r } else { r / 2.0 };
                        self.stamp(&mut enemy_infl, u.p, infl_r, threat_surf, 1.0);
                    }
                    if d.range_air > 0.0 {
                        self.stamp(&mut e_air, at, d.range_air + slack, threat_air, 0.5);
                    }
                } else {
                    if d.range_ground > 0.0 {
                        let r = d.range_ground + slack;
                        self.stamp(&mut o_surf, at, r, threat_surf, 0.5);
                        let infl_r = if d.mobile { r } else { r / 2.0 };
                        self.stamp(&mut ally_infl, u.p, infl_r, d.barb_power, 1.0);
                        if !d.mobile {
                            self.stamp(&mut defend, u.p, infl_r, d.barb_power, 1.0);
                        }
                    }
                    if d.range_air > 0.0 {
                        self.stamp(&mut o_air, at, d.range_air + slack, threat_air, 0.5);
                    }
                }
            }
        }
        for r in &world.remains {
            if let Some(idx) = self.index_of(r.p) {
                reclaim[idx] += r.metal;
            }
        }
        for i in 0..n {
            self.influence[i] = ally_infl[i] - enemy_infl[i];
            self.defend[i] = defend[i];
        }
        self.e_surf = e_surf;
        self.e_air = e_air;
        self.o_surf = o_surf;
        self.o_air = o_air;
        self.e_value = e_value;
        self.o_value = o_value;
        self.reclaim = reclaim;
    }
}
