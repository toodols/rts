//! The battle simulator: a fight played out before it is fought, thing by thing, so the AI knows whether to take it.
//!
//! Where BARb weighs a fight by comparing its group's power with the threat where it is going, and server/ai's fight
//! predictor (combat_sim.luau) lumps things into groups by def and place, this plays every thing on its own, by the
//! game's own rules as far as they decide a fight:
//!
//! - each weapon fires shot by shot, a shot every `shot / dps` seconds (which is its reload with its burst folded in),
//!   and a shot does no more than the health of what it hits (the rest is wasted, as it is in the game);
//! - it fires at what is in its reach that the game's targeting would rather hit (targeting.luau's reward: worth for
//!   the health it takes to kill, times the share of its damage it does to that layer; nearest on a tie), and keeps at
//!   it while it lives and stays in reach, as the game's does;
//! - a lobbed shell comes down where its target was when it was fired, which a walking target has left by its speed
//!   times the shell's time in the air, and a shot that strays lands anywhere in its cone: it lands on the target as
//!   often as the target's size and the blast cover where it may come down (as combat_sim.luau reckons it);
//! - a blast hurts everything of the other side within its radius, falling off to its edge, and a thing that dies goes
//!   up in its death explosion, which hurts friend and foe;
//! - what moves walks at its top speed toward the nearest thing it can shoot, and stops once that is within 0.85 of
//!   its reach, as a unit on a fight order does; what has nothing it can shoot makes for the other side's middle;
//! - it mends by its autoheal.
//!
//! It is exact about none of this (no terrain, no collisions, no turning or aiming), but it is the fight, not a sum.

use crate::defs::{DefId, Defs};
use crate::map::P;

#[derive(Clone, Debug)]
pub struct Fighter {
    pub def: DefId,
    pub p: P,
    pub hp: f64,
}

#[derive(Clone, Copy, Debug)]
pub struct Options {
    pub horizon: f64,
    pub step: f64,
    /// the first side holds its ground rather than closing in (what defends)
    pub a_holds: bool,
    pub b_holds: bool,
    /// the first side's units that outrange what they shoot keep out of its reach
    pub a_kites: bool,
    /// print the fight as it goes, a line a second, to stderr (for rust_ai --predict)
    pub trace: bool,
}

impl Default for Options {
    fn default() -> Self {
        Options { horizon: 35.0, step: 0.25, a_holds: false, b_holds: false, a_kites: false, trace: false }
    }
}

#[derive(Clone, Debug, Default)]
pub struct Outcome {
    /// what each side's armed things were worth at the start and are at the end (power for the share of health left)
    pub start: [f64; 2],
    pub end: [f64; 2],
    /// the worth each side lost, armed or not
    pub lost: [f64; 2],
    /// the first side's share of its worth left less the second's, -1 to 1
    pub margin: f64,
    pub seconds: f64,
}

impl Outcome {
    /// Whether the first side comes out ahead by `margin` or more.
    pub fn wins_by(&self, margin: f64) -> bool {
        self.margin >= margin
    }
    /// What the first side gains: what it destroyed less what it lost.
    pub fn trade(&self) -> f64 {
        self.lost[1] - self.lost[0]
    }
}

struct Body {
    side: usize,
    def: DefId,
    p: P,
    hp: f64,
    max_hp: f64,
    alive: bool,
    moved: bool,
    reload: Vec<f64>,
    target: Vec<usize>,
}

const NONE: usize = usize::MAX;
const SPACING: f64 = 1.6;

/// A lobbed shell or a missile in the air.
struct Shell {
    lands: f64,
    target: usize,
    at: P,
    side: usize,
    air: bool,
    shot: f64,
    splash: f64,
    edge: f64,
    anti_air: bool,
    accuracy: f64,
}

/// Plays out a fight between `a` and `b`.
pub fn simulate(defs: &Defs, a: &[Fighter], b: &[Fighter], options: Options) -> Outcome {
    let mut bodies: Vec<Body> = Vec::with_capacity(a.len() + b.len());
    for (side, list) in [(0usize, a), (1usize, b)] {
        for f in list {
            let d = &defs.list[f.def];
            if f.hp <= 0.0 {
                continue;
            }
            bodies.push(Body {
                side,
                def: f.def,
                p: f.p,
                hp: f.hp.min(d.health),
                max_hp: d.health,
                alive: true,
                moved: false,
                reload: vec![0.0; d.weapons.len()],
                target: vec![NONE; d.weapons.len()],
            });
        }
    }
    let worth = |bodies: &[Body], side: usize, armed_only: bool| -> f64 {
        bodies
            .iter()
            .filter(|b| b.alive && b.side == side && (!armed_only || defs.list[b.def].armed))
            .map(|b| defs.list[b.def].power * b.hp / b.max_hp)
            .sum()
    };
    let total = |bodies: &[Body], side: usize| -> f64 {
        bodies.iter().filter(|b| b.side == side).map(|b| defs.list[b.def].power * if b.alive { 1.0 - b.hp / b.max_hp } else { 1.0 }).sum()
    };
    let start = [worth(&bodies, 0, true), worth(&bodies, 1, true)];
    let n = bodies.len();
    let mut damage = vec![0.0; n];
    let mut shells: Vec<Shell> = Vec::new();
    let mut t = 0.0;
    let step = options.step;
    let mut quiet = 0.0;
    while t < options.horizon {
        let armed = [0, 1].map(|s| bodies.iter().any(|b| b.alive && b.side == s && defs.list[b.def].armed));
        if !armed[0] || !armed[1] {
            break;
        }
        t += step;
        for v in damage.iter_mut() {
            *v = 0.0;
        }
        let mut acted = false;
        // shells that come down this step: on their target if it is still where it was, and on all round
        let mut k = 0;
        while k < shells.len() {
            if shells[k].lands > t {
                k += 1;
                continue;
            }
            let s = shells.swap_remove(k);
            acted = true;
            for j in 0..n {
                let b = &bodies[j];
                if !b.alive || b.side != s.side {
                    continue;
                }
                let od = &defs.list[b.def];
                if od.air != s.air {
                    continue;
                }
                let dd = (b.p.dist(s.at) - od.m.radius).max(0.0);
                let full = defs.damage_against(s.anti_air, od, s.shot);
                let dmg = if j == s.target && dd <= 0.5 {
                    full * s.accuracy
                } else if s.splash > 0.0 && dd < s.splash {
                    full * (1.0 - (1.0 - s.edge) * dd / s.splash) * s.accuracy.max(0.5)
                } else {
                    0.0
                };
                if dmg > 0.0 {
                    let left = (b.hp - damage[j]).max(0.0);
                    damage[j] += dmg.min(left);
                }
            }
        }
        // fire
        for i in 0..n {
            if !bodies[i].alive {
                continue;
            }
            let d = &defs.list[bodies[i].def];
            if d.weapons.is_empty() {
                continue;
            }
            let mut in_reach = false;
            let mut fired_groups: Vec<&str> = Vec::new();
            for wi in 0..d.weapons.len() {
                let w = &d.weapons[wi];
                if let Some(g) = &w.group {
                    if fired_groups.contains(&g.as_str()) {
                        continue;
                    }
                }
                // keep the target while it lives and is in reach; otherwise choose again
                let mut tgt = bodies[i].target[wi];
                let valid = |j: usize, bodies: &[Body]| -> bool {
                    if j == NONE || !bodies[j].alive {
                        return false;
                    }
                    let td = &defs.list[bodies[j].def];
                    let layer_ok = if td.air { w.air } else { w.ground };
                    layer_ok && bodies[i].p.dist(bodies[j].p) <= w.range + td.m.radius
                };
                if !valid(tgt, &bodies) {
                    tgt = NONE;
                    let mut best = -1.0;
                    let mut best_d = f64::MAX;
                    for j in 0..n {
                        let o = &bodies[j];
                        if !o.alive || o.side == bodies[i].side {
                            continue;
                        }
                        let od = &defs.list[o.def];
                        if !(if od.air { w.air } else { w.ground }) || od.m.immune {
                            continue;
                        }
                        let dist = bodies[i].p.dist(o.p);
                        if dist > w.range + od.m.radius {
                            continue;
                        }
                        let reward = od.power * defs.damage_against(w.anti_air, od, 1.0) / o.hp.max(1e-3);
                        if reward > best || (reward == best && dist < best_d) {
                            best = reward;
                            best_d = dist;
                            tgt = j;
                        }
                    }
                    bodies[i].target[wi] = tgt;
                }
                if tgt == NONE {
                    bodies[i].reload[wi] = (bodies[i].reload[wi] - step).max(0.0);
                    continue;
                }
                in_reach = true;
                if let Some(g) = &w.group {
                    fired_groups.push(g);
                }
                bodies[i].reload[wi] -= step;
                let period = (w.shot / w.dps.max(1e-6)).max(1.0 / 30.0);
                while bodies[i].reload[wi] <= 0.0 {
                    bodies[i].reload[wi] += period;
                    let target = &bodies[tgt];
                    let td = &defs.list[target.def];
                    let dist = bodies[i].p.dist(target.p);
                    let reach = td.m.radius + w.splash;
                    let mut accuracy = 1.0;
                    if w.scatter > 0.0 {
                        let strays_by = dist * w.scatter.tan();
                        accuracy *= (reach / strays_by.max(1e-3)).powi(2).min(1.0);
                    }
                    // a shell in flight: it comes down where the target was when it was fired, some seconds on
                    if w.flight > 0.0 {
                        shells.push(Shell {
                            lands: t + w.flight * dist,
                            target: tgt,
                            at: target.p,
                            side: target.side,
                            air: td.air,
                            shot: w.shot,
                            splash: w.splash,
                            edge: w.edge,
                            anti_air: w.anti_air,
                            accuracy,
                        });
                        continue;
                    }
                    let hit = defs.damage_against(w.anti_air, td, w.shot);
                    // what is already coming its way this step counts against what is left of it
                    let left = (target.hp - damage[tgt]).max(0.0);
                    damage[tgt] += (hit * accuracy).min(left);
                    if w.splash > 0.0 {
                        let at = target.p;
                        let side = target.side;
                        for j in 0..n {
                            if j == tgt || !bodies[j].alive || bodies[j].side != side {
                                continue;
                            }
                            let od = &defs.list[bodies[j].def];
                            if od.air != td.air {
                                continue;
                            }
                            let dd = (bodies[j].p.dist(at) - od.m.radius).max(0.0);
                            if dd < w.splash {
                                let fall = 1.0 - (1.0 - w.edge) * dd / w.splash;
                                let dmg = defs.damage_against(w.anti_air, od, w.shot) * fall * accuracy.max(0.5);
                                let left = (bodies[j].hp - damage[j]).max(0.0);
                                damage[j] += dmg.min(left);
                            }
                        }
                    }
                }
            }
            if in_reach {
                acted = true;
            }
        }
        // move: what has nothing in reach closes in on the nearest thing it can shoot
        let mut middles = [P::new(0.0, 0.0); 2];
        let mut counts = [0.0; 2];
        for b in &bodies {
            if b.alive {
                middles[b.side] = middles[b.side].add(b.p);
                counts[b.side] += 1.0;
            }
        }
        for s in 0..2 {
            if counts[s] > 0.0 {
                middles[s] = middles[s].scale(1.0 / counts[s]);
            }
        }
        for i in 0..n {
            bodies[i].moved = false;
            if !bodies[i].alive {
                continue;
            }
            let d = &defs.list[bodies[i].def];
            let holds = if bodies[i].side == 0 { options.a_holds } else { options.b_holds };
            if !d.mobile || holds || d.weapons.is_empty() {
                continue;
            }
            let side = bodies[i].side;
            let has_target = bodies[i].target.iter().any(|&t| t != NONE);
            // the nearest enemy it can shoot, and how far its weapons reach it
            let mut nearest = NONE;
            let mut nearest_d = f64::MAX;
            let mut reach: f64 = 0.0;
            for j in 0..n {
                let o = &bodies[j];
                if !o.alive || o.side == side {
                    continue;
                }
                let od = &defs.list[o.def];
                let r = if od.air { d.range_air } else { d.range_ground };
                if r <= 0.0 {
                    continue;
                }
                let dist = bodies[i].p.dist(o.p) - od.m.radius;
                if dist < nearest_d {
                    nearest_d = dist;
                    nearest = j;
                    reach = r;
                }
            }
            let kites = side == 0 && options.a_kites;
            if has_target && !kites {
                continue;
            }
            let (goal, stop) = if nearest != NONE {
                (bodies[nearest].p, reach * defs.constants.range_margin)
            } else if counts[1 - side] > 0.0 {
                (middles[1 - side], 0.0)
            } else {
                continue;
            };
            let dist = bodies[i].p.dist(goal);
            let mut go = 0.0;
            if kites && nearest != NONE {
                // keep just inside its own reach and outside the target's
                let od = &defs.list[bodies[nearest].def];
                let their = if d.air { od.range_air } else { od.range_ground };
                if their + 4.0 < reach && dist < their + 6.0 {
                    go = -(d.speed * step).min(their + 6.0 - dist);
                } else if dist > stop {
                    go = (d.speed * step).min(dist - stop);
                }
            } else if dist > stop {
                go = (d.speed * step).min(dist - stop);
            }
            if go.abs() > 1e-6 && dist > 1e-6 {
                let dir = goal.sub(bodies[i].p).scale(1.0 / dist);
                bodies[i].p = bodies[i].p.add(dir.scale(go));
                bodies[i].moved = true;
                acted = true;
            }
        }
        // nothing on the ground stands inside anything else: what walked is pushed out of what it walked into, so a
        // crowd reaches the front a few at a time
        for i in 0..n {
            if !bodies[i].alive || !bodies[i].moved {
                continue;
            }
            let di = &defs.list[bodies[i].def];
            if di.air {
                continue;
            }
            let mut push = P::new(0.0, 0.0);
            for j in 0..n {
                if i == j || !bodies[j].alive {
                    continue;
                }
                let dj = &defs.list[bodies[j].def];
                if dj.air {
                    continue;
                }
                // things keep more room between them than their colliders need: 1.6 widths apart, as
                // server/ai/combat_sim.luau's SPACING was set against the real game
                let gap = (di.m.radius + dj.m.radius) * SPACING;
                let rel = bodies[i].p.sub(bodies[j].p);
                let d = rel.len();
                if d < gap && d > 1e-6 {
                    push = push.add(rel.scale((gap - d) / d * if dj.mobile { 0.5 } else { 1.0 }));
                } else if d <= 1e-6 {
                    push = push.add(P::new((i as f64 * 0.37).sin(), (i as f64 * 0.37).cos()).scale(gap * 0.5));
                }
            }
            bodies[i].p = bodies[i].p.add(push);
        }

        if options.trace && ((t / 1.0).round() - t / 1.0).abs() < 1e-6 {
            let mut line = format!("t={t:>5.1}");
            for side in 0..2 {
                let alive: Vec<&Body> = bodies.iter().filter(|b| b.alive && b.side == side).collect();
                let hp: f64 = alive.iter().map(|b| b.hp).sum();
                let targeting = alive.iter().filter(|b| b.target.iter().any(|&x| x != NONE)).count();
                let c = alive.iter().fold(P::new(0.0, 0.0), |s, b| s.add(b.p)).scale(1.0 / alive.len().max(1) as f64);
                line += &format!(" | side{side}: {} alive, hp {:.0}, firing {}, at ({:.0},{:.0})", alive.len(), hp, targeting, c.x, c.z);
            }
            let dealt: [f64; 2] = [0, 1].map(|s| (0..n).filter(|&j| bodies[j].side != s).map(|j| damage[j]).sum());
            line += &format!(" | dmg this step {:.0}/{:.0}, shells {}", dealt[0], dealt[1], shells.len());
            eprintln!("{line}");
        }

        // settle the damage, mend, and let what died go up
        let mut blasts: Vec<(P, f64, f64)> = Vec::new();
        for i in 0..n {
            if !bodies[i].alive {
                continue;
            }
            let d = &defs.list[bodies[i].def];
            bodies[i].hp -= damage[i];
            if bodies[i].hp > 0.0 && d.m.autoheal > 0.0 {
                bodies[i].hp = (bodies[i].hp + d.m.autoheal * step).min(bodies[i].max_hp);
            }
            if bodies[i].hp <= 0.0 {
                bodies[i].alive = false;
                if d.m.death_radius > 0.0 && d.m.death_damage > 0.0 {
                    blasts.push((bodies[i].p, d.m.death_radius, d.m.death_damage));
                }
            }
        }
        for (at, radius, strength) in blasts {
            for b in bodies.iter_mut() {
                if !b.alive || defs.list[b.def].air {
                    continue;
                }
                let dd = b.p.dist(at);
                if dd < radius {
                    b.hp -= strength * (1.0 - 0.75 * dd / radius);
                    if b.hp <= 0.0 {
                        b.alive = false;
                    }
                }
            }
        }
        if !acted {
            quiet += step;
            if quiet >= 2.0 {
                break;
            }
        } else {
            quiet = 0.0;
        }
    }
    let end = [worth(&bodies, 0, true), worth(&bodies, 1, true)];
    let lost = [total(&bodies, 0), total(&bodies, 1)];
    let share = |s: usize| if start[s] > 0.0 { end[s] / start[s] } else { 0.0 };
    Outcome { start, end, lost, margin: share(0) - share(1), seconds: t }
}
