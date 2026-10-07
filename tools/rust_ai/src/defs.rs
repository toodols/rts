//! Every def, as the bridge sends it, and what the AI makes of each: what it is for (builds, fights, makes metal),
//! how hard it hits each layer and from how far, and the class a counter is chosen against (raider, skirmisher,
//! artillery, riot, anti-air, assault).

use crate::barb::Barb;
use crate::protocol::{Constants, DefMsg, WeaponMsg};
use crate::HashMap;

pub type DefId = usize;

/// What a fighter is, for choosing what beats it.
#[derive(Clone, Copy, Debug, PartialEq, Eq, Hash)]
pub enum Class {
    /// quick and light: goes for what is undefended
    Raider,
    /// outranges what is sent at it
    Skirmisher,
    /// lobs shells from far off at what stands still
    Artillery,
    /// splashes: good against many small things
    Riot,
    /// shoots aircraft down
    AntiAir,
    /// heavy, the line of battle
    Assault,
    /// flies and hits the ground
    Bomber,
    /// flies and hits aircraft
    Fighter,
    /// what does not fight
    None,
}

#[derive(Clone, Debug)]
pub struct Weapon {
    pub dps: f64,
    pub shot: f64,
    pub range: f64,
    pub splash: f64,
    pub edge: f64,
    pub flight: f64,
    pub scatter: f64,
    pub ground: bool,
    pub air: bool,
    pub anti_air: bool,
    pub group: Option<String>,
    pub reload: f64,
}

#[derive(Clone, Debug)]
pub struct Def {
    pub id: DefId,
    pub m: DefMsg,
    pub name: String,
    pub is_building: bool,
    pub mobile: bool,
    pub air: bool,
    pub cost: f64,
    pub power: f64,
    pub health: f64,
    pub speed: f64,
    /// the weapons that fight: not what fires only when told, shoots nukes down, or only stuns
    pub weapons: Vec<Weapon>,
    pub armed: bool,
    pub dps_ground: f64,
    pub dps_air: f64,
    pub range_ground: f64,
    pub range_air: f64,
    /// the damage-weighted splash of its ground weapons
    pub splash: f64,
    pub anti_air: bool,
    pub lobbed: bool,
    /// a mobile builder that can put up extractors
    pub builder: bool,
    pub factory: bool,
    pub commander: bool,
    pub options: Vec<DefId>,
    pub class: Class,
    pub tech: f64,
    /// metal a second it makes on a spot of multiplier 1, or anywhere, and energy
    pub metal_make: f64,
    pub energy_make: f64,
    /// BARb's roles for it (behaviour.json), the first its main one; made up from `class` where BARb has none
    pub roles: Vec<String>,
    pub attributes: Vec<String>,
    /// BARb's threat kernel against the air and the surface, sqrt(dps) * damage^0.25 / 128 (CircuitDef.cpp), with
    /// behaviour.json's threat modifiers, and its power: the kernel times sqrt(health), with its power modifier
    pub thr_air: f64,
    pub thr_surf: f64,
    pub barb_power: f64,
    /// the share of its health it goes home to be mended at
    pub retreat: f64,
    /// behaviour.json since (seconds), limit, build_mod (economy.json's where not given)
    pub since: f64,
    pub limit: f64,
    pub build_mod: f64,
    /// behaviour.json build_speed, BARb's buildpower (workertime times buildpower_unit where not given)
    pub build_speed: f64,
    /// BARb's weights for making it at each income tier of its own BAR lab, on land and against air, and the tiers
    pub tier_land: Vec<f64>,
    pub tier_air: Vec<f64>,
    pub income_tier: Vec<f64>,
}

pub struct Defs {
    pub list: Vec<Def>,
    pub by_name: HashMap<String, DefId>,
    pub constants: Constants,
    pub plain_extractor: Option<DefId>,
    pub advanced_extractor: Option<DefId>,
    /// labs of each category of units they make ("bots", "vehicles", "aircraft"): (first, advanced)
    pub labs: HashMap<String, (Option<DefId>, Option<DefId>)>,
}

fn weapon_of(w: &WeaponMsg) -> Option<Weapon> {
    if w.manual || w.anti_nuke || w.paralyze || w.dps <= 0.0 || w.shot <= 0.0 {
        return None;
    }
    Some(Weapon {
        dps: w.dps,
        shot: w.shot,
        range: w.range,
        splash: w.splash,
        edge: w.edge,
        flight: w.flight,
        scatter: w.scatter,
        ground: w.ground,
        air: w.air,
        anti_air: w.anti_air,
        group: w.group.clone(),
        reload: w.reload,
    })
}

impl Defs {
    pub fn new(messages: Vec<DefMsg>, constants: Constants, barb: &Barb) -> Defs {
        let mut by_name = HashMap::default();
        for (index, m) in messages.iter().enumerate() {
            by_name.insert(m.name.clone(), index);
        }
        let mut list = Vec::with_capacity(messages.len());
        for (id, m) in messages.into_iter().enumerate() {
            let weapons: Vec<Weapon> = m.weapons.iter().filter_map(weapon_of).collect();
            let mut dps_ground = 0.0;
            let mut dps_air = 0.0;
            let mut range_ground: f64 = 0.0;
            let mut range_air: f64 = 0.0;
            let mut splash_weighted = 0.0;
            let mut lobbed = false;
            let mut anti_air = false;
            let mut seen_groups: Vec<&str> = Vec::new();
            for w in &weapons {
                // weapons sharing a reload fire one at a time: count the group's first only
                if let Some(group) = &w.group {
                    if seen_groups.contains(&group.as_str()) {
                        continue;
                    }
                    seen_groups.push(group);
                }
                if w.ground {
                    let d = if w.anti_air { w.dps.min(constants.aa_non_air_damage / w.reload.max(0.03)) } else { w.dps };
                    dps_ground += d;
                    range_ground = range_ground.max(w.range);
                    splash_weighted += w.splash * d;
                    if w.flight > 0.0 {
                        lobbed = true;
                    }
                }
                if w.air {
                    let d = if w.anti_air { w.dps } else { w.dps * constants.non_aa_air_fraction };
                    dps_air += d;
                    range_air = range_air.max(w.range);
                }
                if w.anti_air {
                    anti_air = true;
                }
            }
            if m.carrier_range > 0.0 {
                range_ground = range_ground.max(m.carrier_range);
            }
            let splash = if dps_ground > 0.0 { splash_weighted / dps_ground } else { 0.0 };
            let is_unit = m.kind == "unit";
            let mobile = is_unit && m.speed > 0.0;
            let options: Vec<DefId> = m.options.iter().filter_map(|o| by_name.get(o).copied()).collect();
            let metal_make = m.metal_income;
            let energy_make = m.energy_income;
            let def = Def {
                id,
                name: m.name.clone(),
                is_building: m.kind == "building",
                mobile,
                air: m.air,
                cost: m.metal + m.energy / 60.0,
                power: m.power,
                health: m.health.max(1.0),
                speed: m.speed,
                armed: dps_ground > 0.0 || dps_air > 0.0 || m.carrier_range > 0.0,
                weapons,
                dps_ground,
                dps_air,
                range_ground,
                range_air,
                splash,
                anti_air,
                lobbed,
                builder: false,
                factory: m.factory,
                commander: m.commander,
                options,
                class: Class::None,
                tech: m.tech,
                metal_make,
                energy_make,
                roles: Vec::new(),
                attributes: Vec::new(),
                thr_air: 0.0,
                thr_surf: 0.0,
                barb_power: 0.0,
                retreat: 0.0,
                since: 0.0,
                limit: f64::MAX,
                build_mod: 1000.0,
                build_speed: 0.0,
                tier_land: Vec::new(),
                tier_air: Vec::new(),
                income_tier: Vec::new(),
                m,
            };
            list.push(def);
        }

        let plain_extractor = list
            .iter()
            .filter(|d| d.m.spot.as_deref() == Some("metal") && d.m.upgrades.is_empty())
            .min_by(|a, b| a.cost.total_cmp(&b.cost))
            .map(|d| d.id);
        let advanced_extractor = plain_extractor.and_then(|plain| {
            let plain_name = list[plain].name.clone();
            list.iter()
                .filter(|d| d.m.spot.as_deref() == Some("metal") && d.m.upgrades.contains(&plain_name))
                .min_by(|a, b| a.cost.total_cmp(&b.cost))
                .map(|d| d.id)
        });
        for def in list.iter_mut() {
            let builds_extractor = plain_extractor.map_or(false, |p| def.options.contains(&p))
                || advanced_extractor.map_or(false, |p| def.options.contains(&p));
            def.builder = def.mobile && !def.air && def.m.assists && def.m.buildpower > 0.0 && builds_extractor;
        }

        // the labs of each category: the one whose constructor is of tech 1, and of tech 2
        let mut labs: HashMap<String, (Option<DefId>, Option<DefId>)> = HashMap::default();
        let mut factories: Vec<&Def> = list.iter().filter(|d| d.factory && d.is_building).collect();
        factories.sort_by(|a, b| a.cost.total_cmp(&b.cost));
        for lab in factories {
            for &option in &lab.options {
                let product = &list[option];
                if product.m.buildpower > 0.0 && product.mobile {
                    let entry = labs.entry(product.m.category.clone()).or_insert((None, None));
                    if product.tech <= 1.0 && entry.0.is_none() {
                        entry.0 = Some(lab.id);
                    } else if product.tech >= 2.0 && product.tech < 3.0 && entry.1.is_none() {
                        entry.1 = Some(lab.id);
                    }
                }
            }
        }

        let mut defs = Defs { list, by_name, constants, plain_extractor, advanced_extractor, labs };
        defs.classify();
        defs.apply_barb(barb);
        defs
    }

    /// BARb's threat and power for each def (CircuitDef.cpp: the kernel sqrt(dps) * damage^0.25 * THREAT_MOD, times
    /// sqrt(health)), and its roles, retreat and lab weights from behaviour.json and factory.json.
    fn apply_barb(&mut self, barb: &Barb) {
        const THREAT_MOD: f64 = 1.0 / 128.0;
        let non_aa = self.constants.non_aa_air_fraction;
        let aa_ground = self.constants.aa_non_air_damage;
        for d in self.list.iter_mut() {
            let (mut air_dmg, mut air_dps, mut surf_dmg, mut surf_dps) = (0.0, 0.0, 0.0, 0.0);
            for w in &d.weapons {
                let cycles = w.dps / w.shot.max(1e-6);
                if w.air {
                    let dmg = if w.anti_air { w.shot } else { w.shot * non_aa };
                    air_dmg += dmg;
                    air_dps += dmg * cycles;
                }
                if w.ground {
                    let dmg = if w.anti_air { w.shot.min(aa_ground) } else { w.shot };
                    surf_dmg += dmg;
                    surf_dps += dmg * cycles;
                }
            }
            let kernel = |dps: f64, dmg: f64| dps.max(0.0).sqrt() * dmg.max(0.0).powf(0.25) * THREAT_MOD;
            let info = barb.units.get(&d.name);
            let threat = info.and_then(|i| i.threat.clone()).unwrap_or_default();
            let default_mod = threat.default.unwrap_or(1.0);
            d.thr_air = kernel(air_dps, air_dmg) * threat.air.unwrap_or(default_mod);
            d.thr_surf = kernel(surf_dps, surf_dmg) * threat.surf.unwrap_or(default_mod);
            let def_kernel = kernel(air_dps.max(surf_dps), air_dmg.max(surf_dmg));
            let power_mod = info.and_then(|i| i.power).unwrap_or(1.0);
            d.barb_power = def_kernel * power_mod * d.health.sqrt();
            let fallback = || -> Vec<String> {
                let mut roles = Vec::new();
                if d.commander || d.builder {
                    roles.push("builder".to_string());
                } else if d.is_building && d.armed {
                    roles.push(if d.anti_air { "anti_air" } else { "static" }.to_string());
                } else {
                    let r = match d.class {
                        Class::Raider => "raider",
                        Class::Skirmisher => "skirmish",
                        Class::Artillery => "artillery",
                        Class::Riot => "riot",
                        Class::AntiAir | Class::Fighter => "anti_air",
                        Class::Assault => "assault",
                        Class::Bomber => "bomber",
                        Class::None => "support",
                    };
                    roles.push(r.to_string());
                }
                if d.air {
                    roles.push("air".to_string());
                }
                if d.health >= 3000.0 && d.mobile && !d.builder {
                    roles.push("heavy".to_string());
                }
                roles
            };
            d.roles = match info {
                Some(i) if !i.role.is_empty() => {
                    let mut r = i.role.clone();
                    if d.air && !r.iter().any(|x| x == "air") {
                        r.push("air".to_string());
                    }
                    r
                }
                _ => fallback(),
            };
            d.attributes = info.map(|i| i.attribute.clone()).unwrap_or_default();
            if d.commander && !d.attributes.iter().any(|a| a == "commander") {
                d.attributes.push("commander".to_string());
            }
            let default_retreat = if d.builder || d.commander { barb.retreat_builder } else { barb.retreat_fighter };
            d.retreat = info.and_then(|i| i.retreat).unwrap_or(default_retreat);
            d.since = info.and_then(|i| i.since).unwrap_or(0.0);
            d.limit = info.and_then(|i| i.limit).unwrap_or(f64::MAX);
            d.build_mod = info.and_then(|i| i.build_mod).unwrap_or(barb.economy.build_mod);
            d.build_speed = info.and_then(|i| i.build_speed).unwrap_or(d.m.buildpower * 0.05);
            if let Some(i) = info {
                d.tier_land = i.tiers.get("land").cloned().unwrap_or_default();
                d.tier_air = i.tiers.get("air").cloned().unwrap_or_else(|| d.tier_land.clone());
                d.income_tier = i.income_tier.clone();
            }
        }
    }

    pub fn has_role(&self, def: DefId, role: &str) -> bool {
        self.list[def].roles.iter().any(|r| r == role)
    }

    pub fn main_role(&self, def: DefId) -> &str {
        self.list[def].roles.first().map(|s| s.as_str()).unwrap_or("support")
    }

    /// BARb's weight for making `def` with `income` metal a second (factory.json: the tier is how many of its own lab's
    /// income tiers the income has reached), on land or, when the enemy's aircraft outweigh its anti-air, against air.
    pub fn tier_weight(&self, def: DefId, income: f64, air: bool) -> f64 {
        let d = &self.list[def];
        let table = if air { &d.tier_air } else { &d.tier_land };
        if table.is_empty() {
            return 0.0;
        }
        let mut tier = 0;
        while tier < d.income_tier.len() && income >= d.income_tier[tier] {
            tier += 1;
        }
        table[tier.min(table.len() - 1)]
    }

    /// Files each armed mobile unit under a class, against the others of its category: the quickest are raiders, the
    /// longest reaching skirmishers or artillery (if they lob), the widest splashing riots.
    fn classify(&mut self) {
        let mut by_category: HashMap<String, Vec<DefId>> = HashMap::default();
        for d in &self.list {
            if d.mobile && d.armed && !d.commander {
                by_category.entry(d.m.category.clone()).or_default().push(d.id);
            }
        }
        let mut classes = vec![Class::None; self.list.len()];
        for ids in by_category.values() {
            let mut speeds: Vec<f64> = ids.iter().map(|&i| self.list[i].speed).collect();
            let mut ranges: Vec<f64> = ids.iter().map(|&i| self.list[i].range_ground).collect();
            speeds.sort_by(f64::total_cmp);
            ranges.sort_by(f64::total_cmp);
            let median_speed = speeds[speeds.len() / 2];
            let median_range = ranges[ranges.len() / 2];
            for &i in ids {
                let d = &self.list[i];
                classes[i] = if d.air {
                    if d.dps_ground > d.dps_air { Class::Bomber } else { Class::Fighter }
                } else if d.anti_air && d.dps_air > d.dps_ground {
                    Class::AntiAir
                } else if d.lobbed && d.range_ground > median_range * 1.3 {
                    Class::Artillery
                } else if d.splash >= 3.0 && d.range_ground <= median_range * 1.2 {
                    Class::Riot
                } else if d.speed >= median_speed * 1.25 && d.health < 1500.0 {
                    Class::Raider
                } else if d.range_ground >= median_range * 1.25 {
                    Class::Skirmisher
                } else {
                    Class::Assault
                };
            }
        }
        for (i, class) in classes.into_iter().enumerate() {
            self.list[i].class = class;
        }
    }

    pub fn get(&self, name: &str) -> Option<DefId> {
        self.by_name.get(name).copied()
    }

    /// What one hit of `amount` from a weapon that is dedicated anti-air or not comes to against `target`.
    pub fn damage_against(&self, anti_air: bool, target: &Def, amount: f64) -> f64 {
        if target.air && !anti_air {
            amount * self.constants.non_aa_air_fraction
        } else if !target.air && anti_air {
            amount.min(self.constants.aa_non_air_damage)
        } else {
            amount
        }
    }

    /// The constructor a lab makes (its cheapest mobile builder).
    pub fn constructor_of(&self, lab: DefId) -> Option<DefId> {
        self.list[lab]
            .options
            .iter()
            .copied()
            .filter(|&o| self.list[o].builder)
            .min_by(|&a, &b| self.list[a].cost.total_cmp(&self.list[b].cost))
    }
}
