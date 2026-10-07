//! Where it is winning and where it is losing, and how the game is going on the whole.
//!
//! The map is cut into square regions (`front_region` studs). In each, every thought, it counts both sides' power
//! there (the armed things standing in it: BARb's kernel times the square root of health), what each side has there
//! that does not fight (economy, labs, builders), and what each side has lost there lately (what was lost since the
//! last thought, by its worth, fading over `front_memory` seconds). A region's verdict is the geometric mean of the
//! two ratios, strength (its power to the enemy's) and trade (what the enemy lost there to what it lost): past
//! `front_contest` it is winning there, under its inverse losing, and in between contested. Regions where nothing of
//! either side is, and nothing was lost, have no verdict.
//!
//! Its standing is what it has (armed worth, buildings' worth, and `standing_income_weight` seconds of metal income)
//! over what the enemy has. It keeps the last two minutes of it, and its trend is how much of it was lost or gained
//! in the last minute, as a share. Desperation is how far its standing is below `desperation_threshold`, toward
//! `desperation_full` (0 to 1), plus `desperation_trend` for each share of standing lost in the last minute while it
//! is behind, smoothed. What desperation does is the army's and the economy's to say (military.rs, economy.rs).

use crate::brain::Seen;
use crate::defs::Defs;
use crate::fields::Fields;
use crate::map::{Map, P};
use crate::params::Params;
use crate::world::World;
use std::collections::VecDeque;

#[derive(Clone, Debug, Default)]
pub struct Region {
    pub own_power: f64,
    pub enemy_power: f64,
    pub own_value: f64,
    pub enemy_value: f64,
    pub own_lost: f64,
    pub enemy_lost: f64,
    /// 1 winning, -1 losing, 0 contested; None where there is nothing
    pub verdict: Option<i8>,
    pub score: f64,
}

pub struct Fronts {
    size: f64,
    w: usize,
    h: usize,
    ox: f64,
    oz: f64,
    pub regions: Vec<Region>,
    pub winning: Vec<usize>,
    pub losing: Vec<usize>,
    pub contested: Vec<usize>,
    pub standing: f64,
    pub trend: f64,
    pub desperation: f64,
    pub own_total: f64,
    pub enemy_total: f64,
    history: VecDeque<(f64, f64)>,
    last: f64,
}

impl Fronts {
    pub fn new(map: &Map, size: f64) -> Fronts {
        let size = size.max(16.0);
        let w = (map.width_studs() / size).ceil() as usize;
        let h = (map.depth_studs() / size).ceil() as usize;
        Fronts {
            size,
            w,
            h,
            ox: map.ox,
            oz: map.oz,
            regions: vec![Region::default(); w * h],
            winning: Vec::new(),
            losing: Vec::new(),
            contested: Vec::new(),
            standing: 1.0,
            trend: 0.0,
            desperation: 0.0,
            own_total: 0.0,
            enemy_total: 0.0,
            history: VecDeque::new(),
            last: 0.0,
        }
    }

    pub fn index_of(&self, p: P) -> Option<usize> {
        let cx = ((p.x - self.ox) / self.size).floor() as i64;
        let cz = ((p.z - self.oz) / self.size).floor() as i64;
        if cx >= 0 && cz >= 0 && (cx as usize) < self.w && (cz as usize) < self.h {
            Some(cz as usize * self.w + cx as usize)
        } else {
            None
        }
    }

    pub fn center(&self, i: usize) -> P {
        P::new(self.ox + ((i % self.w) as f64 + 0.5) * self.size, self.oz + ((i / self.w) as f64 + 0.5) * self.size)
    }

    pub fn verdict_at(&self, p: P) -> Option<i8> {
        self.index_of(p).and_then(|i| self.regions[i].verdict)
    }

    #[allow(clippy::too_many_arguments)]
    pub fn update(&mut self, world: &World, defs: &Defs, _fields: &Fields, lost: &[Seen], params: &Params, now: f64, me: i64) {
        let dt = (now - self.last).max(0.0);
        self.last = now;
        let fade = (-dt / params.front_memory.max(1.0)).exp();
        for r in self.regions.iter_mut() {
            r.own_power = 0.0;
            r.enemy_power = 0.0;
            r.own_value = 0.0;
            r.enemy_value = 0.0;
            r.own_lost *= fade;
            r.enemy_lost *= fade;
        }
        for s in lost {
            let d = &defs.list[s.def];
            let worth = if s.built { d.power } else { d.power * 0.3 };
            if let Some(i) = self.index_of(s.p) {
                if s.team == me {
                    self.regions[i].own_lost += worth;
                } else if world.enemies.contains(&s.team) {
                    self.regions[i].enemy_lost += worth;
                }
            }
        }
        let mut own_army = 0.0;
        let mut own_buildings = 0.0;
        let mut enemy_army = 0.0;
        let mut enemy_buildings = 0.0;
        for (mine, list) in [(true, &world.own), (false, &world.enemy)] {
            for &i in list.iter() {
                let u = &world.units[i];
                let d = &defs.list[u.def];
                let share = if u.built { u.health_share() } else { u.progress * 0.5 };
                let Some(ri) = self.index_of(u.p) else { continue };
                let r = &mut self.regions[ri];
                if d.armed && u.built && d.mobile {
                    let power = d.thr_surf.max(d.thr_air) * u.hp.max(0.0).sqrt();
                    if mine {
                        r.own_power += power;
                        own_army += d.power * share;
                    } else {
                        r.enemy_power += power;
                        enemy_army += d.power * share;
                    }
                } else {
                    let armed_static = d.armed && u.built;
                    if armed_static {
                        let power = d.thr_surf.max(d.thr_air) * u.hp.max(0.0).sqrt();
                        if mine {
                            r.own_power += power;
                        } else {
                            r.enemy_power += power;
                        }
                    }
                    if mine {
                        r.own_value += d.power * share;
                        own_buildings += d.power * share;
                    } else {
                        r.enemy_value += d.power * share;
                        enemy_buildings += d.power * share;
                    }
                }
            }
        }
        self.winning.clear();
        self.losing.clear();
        self.contested.clear();
        for (i, r) in self.regions.iter_mut().enumerate() {
            // a region is fought over only where both sides are, or were: the enemy's own base, where it has nothing
            // and lost nothing, is not somewhere it is losing
            let own_there = r.own_power > 0.5 || r.own_value > 0.0 || r.own_lost > 5.0;
            let enemy_there = r.enemy_power > 0.5 || r.enemy_lost > 5.0 || r.own_lost > 5.0;
            let meaningful = own_there && enemy_there;
            if !meaningful {
                r.verdict = None;
                r.score = 1.0;
                continue;
            }
            let strength = (r.own_power + 1.0) / (r.enemy_power + 1.0);
            let trade = (r.enemy_lost + 20.0) / (r.own_lost + 20.0);
            r.score = (strength * trade).sqrt();
            r.verdict = Some(if r.score >= params.front_contest {
                1
            } else if r.score <= 1.0 / params.front_contest {
                -1
            } else {
                0
            });
            match r.verdict {
                Some(1) => self.winning.push(i),
                Some(-1) => self.losing.push(i),
                _ => self.contested.push(i),
            }
        }

        let own_team = world.my_team();
        let enemy_team = world.enemy_team();
        self.own_total = own_army + own_buildings + own_team.metal_income * params.standing_income_weight;
        self.enemy_total = enemy_army + enemy_buildings + enemy_team.metal_income * params.standing_income_weight;
        self.standing = ((self.own_total + 50.0) / (self.enemy_total + 50.0)).min(20.0);
        self.history.push_back((now, self.standing));
        while self.history.front().map_or(false, |(t, _)| now - t > 120.0) {
            self.history.pop_front();
        }
        let minute_ago = self.history.iter().find(|(t, _)| now - t <= 60.0).map(|(_, s)| *s).unwrap_or(self.standing);
        self.trend = (self.standing - minute_ago) / minute_ago.max(0.05);

        // desperation: only once the game is under way, and only while behind
        let below = ((params.desperation_threshold - self.standing)
            / (params.desperation_threshold - params.desperation_full).max(1e-3))
        .clamp(0.0, 1.0);
        let falling = if self.standing < 1.0 { (-self.trend).max(0.0) * params.desperation_trend } else { 0.0 };
        let raw = if now < 150.0 { 0.0 } else { (below + falling).clamp(0.0, 1.0) };
        self.desperation = self.desperation * 0.8 + raw * 0.2;
        if self.desperation < 0.02 {
            self.desperation = 0.0;
        }
    }

    /// The regions it is losing that hold something of its own worth defending, most valuable first.
    pub fn losing_holdings(&self) -> Vec<(P, f64)> {
        let mut out: Vec<(P, f64)> = self
            .losing
            .iter()
            .chain(self.contested.iter())
            .filter(|&&i| self.regions[i].own_value > 0.0 && self.regions[i].enemy_power > 0.5)
            .map(|&i| (self.center(i), self.regions[i].own_value))
            .collect();
        out.sort_by(|a, b| b.1.total_cmp(&a.1));
        out
    }
}
