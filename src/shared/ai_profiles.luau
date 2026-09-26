--!strict
-- The computer player's personalities. There is one AI (server/ai), and each team it plays carries a profile: the
-- numbers it plays by, which are what makes one AI a turtle and another a raider. A profile says nothing about how it
-- does anything, only how much, how often, with what, and by which of its rules it judges; the default profile is the
-- AI as it always played, and every other is the default with some of its numbers changed (`with`).
--
-- A profile is picked when a team is handed to the AI (ai.spawn_opponent, ai.take_over, ai.add), changed on one it
-- already plays (ai.set_profile), or named on the command bar (ai_add's Profile, ai_profile). A mission builds its own
-- from one of these with `with`.
--
-- This module is plain data and is shared, so that the command bar on the client can suggest the profiles' names.
--
-- Everything a profile holds is how the AI weighs its choices, and so everything one personality may weigh otherwise
-- than another; how it measures the world it weighs them in (how often it thinks, how far apart it tries places, how
-- many routes it may ask for, what the fight predictor counts as joining a fight) is the AI's own (server/ai).
--
-- A number that can be switched off, or that has no limit unless given one, is left out (nil) for off or for no limit;
-- `without` leaves one out of a profile.

local ReplicatedStorage = game:GetService "ReplicatedStorage"

local unit_defs = require(ReplicatedStorage.Shared.unit_defs)

-- Which kind of lab an AI builds its army from.
export type Line = "bot" | "vehicle"

-- How it judges a fight before it commits to one: by the danger field (what the enemy that reaches there is worth,
-- against its own worth) or by the fight predictor (server/ai/combat_sim.luau), which plays the fight out.
export type Rule = "danger" | "sim"

-- What it knows of the enemy: everything the enemy has, wherever it is, or only what stands within sight of its own
-- side's things (server/ai/census.luau).
export type Sight = "all" | "team_sight"

export type Profile = {
	name: string,

	-- What it builds.
	-- The defs it may build or make, as a set; nil for anything. It is held to this on top of whatever the campaign
	-- holds its team to, in what its builders put up and in what its labs make, and from the opening on.
	roster: { [string]: boolean }?,
	-- The labs it builds its army from; nil to choose for itself (bots on rough ground, otherwise either by a toss).
	line: Line?,
	-- How many labs of its line it keeps, 1 and up; each past the first once it makes metal_per_extra_lab metal a second
	-- for every lab it has.
	labs: number,
	metal_per_extra_lab: number,
	-- Its line's advanced lab goes up once it makes this much metal a second.
	advanced_lab_income: number,
	-- Its labs field what costs no more than this many seconds of its metal income, so fewer seconds is a cheaper and
	-- bigger army (5 to 60), and not what is worth less than fodder_share of the dearest of that.
	afford_seconds: number,
	fodder_share: number,
	-- The share of its metal income its labs may spend on fighters, 0.1 to 1: they start one only once that share of
	-- what it has made since, banked up to what its dearest fighter costs, would pay for it; nil for as much as it
	-- likes, so that only what is left over goes into its economy.
	army_share: number?,
	-- How many things each lab keeps queued.
	factory_queue: number,

	-- What it knows of the enemy (`Sight`).
	sees: Sight,

	-- Expansion: how far and how fast it spreads its extractors.
	-- How many extractors the commander puts down in the opening, 0 to 6, and how many wind turbines (or solar
	-- collectors) after them, before its lab.
	opening_extractors: number,
	opening_energy: number,
	-- How many extractors may be under way at once, as a share of its builders (at least one), 0.25 to 1.
	extractor_builders: number,
	-- How far from home its constructors take extractors, in studs; nil for anywhere on the map.
	expansion_radius: number?,
	-- Of the free metal spots, the one it takes first is the one with the least of: how far the builder is from it,
	-- extractor_home_weight times how far it is from home, less extractor_richness_weight for every metal a second it
	-- is worth over the plainest.
	extractor_home_weight: number,
	extractor_richness_weight: number,
	-- How many of the army waiting at home go with each constructor that goes beyond the base, 0 to 4.
	escorts_per_builder: number,
	-- The plain constructors its labs keep: constructors_min, and one more for every metal_per_constructor metal of
	-- income, up to constructors_max (no fewer than constructors_min); and advanced ones, one and one more for every
	-- metal_per_advanced_constructor, up to advanced_constructors_max.
	constructors_min: number,
	constructors_max: number,
	metal_per_constructor: number,
	advanced_constructors_max: number,
	metal_per_advanced_constructor: number,
	-- Rezbots, while there are wrecks lying somewhere quiet: one, and one more for every wrecks_per_rezbot of them, up to
	-- rezbots_max.
	wrecks_per_rezbot: number,
	rezbots_max: number,
	-- Its commander keeps within base_radius of home, and a builder sent further gets its escorts_per_builder.
	base_radius: number,

	-- Defence: how much it spends on standing guard rather than on its army.
	-- The share of its extractors it puts a guard beside, 0 to 1; 1 guards every one.
	extractor_guards: number,
	-- Guards it keeps round home, in front of its labs, 0 to 8.
	home_guards: number,
	-- How many guards it puts up at once.
	guards_at_once: number,
	-- Once the enemy has air_threat_count aircraft up, it wants an anti-air building for every aircraft_per_air_defense
	-- of them, up to air_defenses_max, and puts up its air_defense share of that (0 to 1); and its labs make
	-- anti_air_per_aircraft anti-air units for every one.
	air_threat_count: number,
	aircraft_per_air_defense: number,
	-- The anti-air building it puts up is the dearest it can build that costs no more than this many seconds of its
	-- metal income.
	air_defense_afford_seconds: number,
	air_defenses_max: number,
	air_defense: number,
	anti_air_per_aircraft: number,
	-- How near home an enemy has to come, in studs, and how near one of its extractors, for it to be seen off.
	defend_radius: number,
	extractor_alert_radius: number,

	-- Energy. Builders put up energy at no more than one for every builders_per_energy_build of them at a time. While its
	-- energy piles up (its store over piling_fill full) it builds energy stores until it can hold its storage_seconds of
	-- its energy income and at least converter_storage, or has energy_stores_max of them, and from there energy
	-- converters, converters_at_once at a time.
	builders_per_energy_build: number,
	-- What a constructor builds for energy (advanced solar collectors) once it makes constructor_energy_income energy a
	-- second, and what an advanced constructor builds (fusion reactors) once it makes advanced_energy_income.
	constructor_energy_income: number,
	advanced_energy_income: number,
	piling_fill: number,
	storage_seconds: number,
	converter_storage: number,
	energy_stores_max: number,
	converters_at_once: number,
	-- The converter it builds is the biggest that burns no more than this share of its energy income.
	converter_burn_share: number,
	-- Construction turrets beside its labs: none until it makes turret_income metal, then one for every metal_per_turret
	-- of it up to turrets_max.
	turret_income: number,
	metal_per_turret: number,
	turrets_max: number,
	-- The turret it builds is the dearest that costs no more than this many seconds of its metal income.
	turret_afford_seconds: number,
	-- How it reads its economy: it is stalling on energy while its store is under stall_fill full and it spends at
	-- least stall_spend_share of what comes in; a store over overflow_fill full, energy that still comes in faster than
	-- it goes or metal, is overflowing; and it is short of metal while its store is under short_fill full and it spends
	-- more than comes in.
	stall_fill: number,
	stall_spend_share: number,
	overflow_fill: number,
	short_fill: number,

	-- Danger, in the danger field's units (what the enemy that reaches there is worth): a place and the way to it have
	-- to be under safe_danger for a builder or a rezbot to be sent there (about the worth of a single light raider), one
	-- on its way drops its errand at abort_danger, and a builder out on the map runs home, for flee_seconds, from
	-- flee_danger. The danger a target stands in is the most within target_danger_radius of it.
	safe_danger: number,
	abort_danger: number,
	flee_danger: number,
	flee_seconds: number,
	target_danger_radius: number,

	-- The main army.
	-- It waits rally_offset studs in front of home. It sets out once it is worth wave_base plus wave_income_seconds of
	-- its metal income (in metal, as unit_defs.power counts it), and only at something its attack_rule says it beats:
	-- by "danger", something the danger round which, times attack_superiority, is under its worth, so a lower
	-- superiority attacks against worse odds (0.5 to 3). Only what is waiting at home goes; what is made while a wave is
	-- out waits for the next. Out there the wave pulls back once its retreat_rule says it is outmatched (by "danger",
	-- the danger where it stands over retreat_ratio of its worth), or once it has lost most of what set out, and then
	-- waits regroup_seconds before the next sets out; a wave that has nothing left to attack comes home and the next may
	-- go at once. Most of what set out is lost once it is worth under wave_broken_share of what it was: the danger field
	-- cannot tell what will not die, and a wave that only loses is outmatched whatever the field says.
	rally_offset: number,
	wave_base: number,
	wave_income_seconds: number,
	attack_rule: Rule,
	attack_superiority: number,
	retreat_rule: Rule,
	retreat_ratio: number,
	wave_broken_share: number,
	regroup_seconds: number,
	-- Escalation: what a wave has to be worth grows by this share of itself for every wave it has already sent, 0 to 1,
	-- but never past wave_cap_seconds of its whole income (converters' metal counted), so each wave is bigger than the
	-- last and they keep coming as they grow; nil for no cap.
	wave_growth: number,
	wave_cap_seconds: number?,

	-- Harassment: small raids of its fastest units, apart from the main army, at the enemy's extractors and
	-- constructors, where the danger round them times raid_superiority is under the raid's worth. A raid comes home
	-- once the danger where it stands is over raid_retreat_ratio of its worth, or there is nothing left it may hit.
	-- raid_size units to a raid (2 to 8; nil for no raids), no more than raid_groups out at once, a new one no sooner
	-- than raid_interval seconds after the last. While it is short of raiders its labs make the fastest fighter they
	-- can, and what counts as one of its fastest is what goes raider_speed_share of the speed of the fastest it has.
	raid_size: number?,
	raid_groups: number,
	raid_interval: number,
	raid_superiority: number,
	raid_retreat_ratio: number,
	raider_speed_share: number,
	-- Of the enemy's extractor and constructor nearest a raid, it goes for the constructor unless the constructor is
	-- over this many times as far off as the extractor; 1 for the nearer of the two, more to favour constructors
	-- (0.5 to 4). BARb's raids (CircuitAI's RaidTask::FindTarget) take a builder in reach before anything else.
	raid_builder_preference: number,
	-- How a raid judges its fights, its raid_rule: by "danger" as above; by "sim", a raid that meets danger asks the
	-- fight predictor about what of the enemy is really round it, and goes home only when the fight is predicted to go
	-- against it (under sim_retreat_margin), or slips away to another target on the far side of it from the threat,
	-- rather than whenever the danger field, which remembers where the enemy was a while ago, is over
	-- raid_retreat_ratio of its worth; and it goes from one target to the next, the nearest first, that the predictor
	-- says it beats by sim_attack_margin. BARb's RaidTask chains its targets the same way.
	raid_rule: Rule,

	-- What follows was taken from BAR's own computer player, BARb (CircuitAI's "barbarian" branch, with its settings
	-- in the game's luarules/configs/BARb/stable, "hard"), and adapted. The default profile leaves each of them off, or
	-- where it is a number, at what the AI always did.

	-- Retreat and repair: a fighter down to under this share of its health leaves whatever it is doing and goes home
	-- to be mended, by a construction turret or else by a builder with nothing better to do, and goes back into the
	-- army once it has repaired_share of its health again; nil for never (0.05 to 0.8). BARb's behaviour.json "retreat"
	-- sends a fighter back under half its health (0.5), and its RetreatTask lets it go again once it is at 98%. It is
	-- given up on, and goes back as it is, once it has been repair_patience seconds home with its health not going up,
	-- or retreat_walk_seconds on its way there.
	retreat_health: number?,
	repaired_share: number,
	repair_patience: number,
	retreat_walk_seconds: number,

	-- Defence in proportion: an enemy that has come near home or an extractor is seen off by as much of the army
	-- waiting at home as it takes, the nearest first, and the wave out carries on; only when what waits at home is not
	-- enough, and the enemy is near home rather than an extractor, is the wave called back. How much it takes is its
	-- defend_rule's: by "danger", what is worth defend_share times the danger round the enemy (0.25 to 3). With no
	-- defend_share (nil) the whole army goes, the wave called home, whatever came. BARb sends a defence group sized to
	-- the threat it answers (behaviour.json "thr_mod"."defence" [0.3, 0.5] scales the threat it sizes it by) rather than
	-- its attack groups.
	defend_share: number?,
	defend_rule: Rule,

	-- The energy income it wants for each metal of income, from energy_factor_start when it begins up to
	-- energy_factor_end over energy_factor_seconds, and that from there on: early on its metal is better spent on
	-- extractors and its army than on energy it does not use yet. BARb's economy.json "factor" climbs from 6 at the
	-- start to 20 at five minutes and 30 at seven; the AI always wanted 15 all game.
	energy_factor_start: number,
	energy_factor_end: number,
	energy_factor_seconds: number,

	-- Escorts: only the first escorted_builders builders out on the map at once get escorts (nil for all of them), and
	-- none after the first escort_seconds of the game, once its army has better things to do (nil for always). BARb's
	-- behaviour.json "defence"."escort" is [3, 1, 540]: three builders, one escort each, for the first nine minutes.
	escorted_builders: number?,
	escort_seconds: number?,

	-- Guards by its extractors go up only once it has played guard_after_seconds or makes guard_income metal a
	-- second, whichever comes first, so its first metal goes into more extractors and its army; 0 and 0 for from the
	-- start. BARb's military.as (AiMakeDefence) builds no defences until five minutes in (300) or 10 metal a second.
	guard_after_seconds: number,
	guard_income: number,

	-- The commander helps its lab while it has fewer than this many constructors, and is not short of energy or
	-- metal, so the first come out sooner (0 to 5). BARb's commander.json "assist_fac" is 3.
	commander_assist_constructors: number,

	-- The fight predictor (server/ai/combat_sim.luau): a quick simulation of the fight itself, with each side's weapons,
	-- their reach, what each can be turned on and what splashes, in the spirit of the combat simulator (SparCraft) that
	-- UAlbertaBot asks before it attacks. It answers with a margin from -1 to 1: its own share of its worth left at the
	-- end, less the enemy's share of theirs. By the "sim" rule:
	-- - attack_rule: the wave sets out only at a target the predictor says it beats by at least sim_attack_margin (0 to
	--   1), and of those it goes for the one it beats most cheaply for how far off it is.
	-- - retreat_rule: the fight of a wave that is out is predicted again every few seconds, against what of the enemy is
	--   round it, and it pulls back once the margin falls under sim_retreat_margin (-1 to 0.5).
	-- - defend_rule: what goes to see an intruder off is the fewest of what waits at home, the nearest first, that the
	--   predictor says beat it by sim_defend_margin (0 to 1).
	sim_attack_margin: number,
	sim_retreat_margin: number,
	sim_defend_margin: number,

	-- Hunters: up to hunt_groups small groups at once (nil for none), of the army waiting at home, the quickest to get
	-- there first, sent after the enemy's armed units that come into its territory (within hunt_radius of one of its
	-- extractors, or of the base), each group the fewest that are predicted to beat what they are sent at by hunt_margin
	-- (with neither its attack_rule nor its defend_rule "sim", as much as is worth the danger round it), and home again
	-- once there is nothing left to hunt. An enemy being hunted is left out of what the army turns out for
	-- (defend_radius, extractor_alert_radius). BARb's military manager keeps defence tasks of their own for this, each
	-- with a group sized to its threat.
	hunt_groups: number?,
	hunt_radius: number,
	hunt_margin: number,

	-- Several fronts (with the attack_rule "sim"): besides its wave, up to strike_groups strikes at once (nil for none),
	-- each the fewest of the army waiting at home that are predicted to beat a target of the enemy's elsewhere (an
	-- extractor, an outlying building) by sim_attack_margin, and no more than strike_share of what waits at home; a wave
	-- that sets out with more than its target takes sends what it does not need at another target as a strike. A strike
	-- goes from target to target like a raid. CircuitAI's military manager runs attack, raid and defence tasks side by
	-- side, each with its own group, and hands units to them by need.
	strike_groups: number?,
	strike_share: number,

	-- Spreading out: every group it sends goes to a place of its own for each unit, this many studs apart at the least
	-- (more against the enemy's splash weapons, server/ai/formations.luau), in a line across the way it goes when it
	-- fights and a block round the rally point when it waits, rather than all to one point; nil for one point. BAR's
	-- formation moves (and the line moves players drag) do the same.
	spread: number?,
}

-- A computer opponent put down once the game begins, with the line and the profile it plays, where they are said.
export type Opponent = { line: Line?, profile: Profile? }

-- How a tool that searches for the best profile (tools/ai_arena) goes over one of its numbers: from `low` to `high`,
-- evenly, on a log scale or in whole numbers; for a number that can be left out, the `absent_share` of the way at the
-- `absent_at` end of it stands for leaving it out; and a number `at_least` another is never under it.
export type Range = {
	low: number,
	high: number,
	scale: "linear" | "log" | "int",
	absent_at: ("bottom" | "top")?,
	absent_share: number?,
	at_least: string?,
}

-- What each key a profile may leave out is when it is given: a number, a set of def names, or one of its CHOICES; and
-- what each key that is one of a few may be.
local OPTIONAL: { [string]: string } = table.freeze({
	roster = "defs",
	line = "choice",
	expansion_radius = "number",
	wave_cap_seconds = "number",
	raid_size = "number",
	retreat_health = "number",
	defend_share = "number",
	escorted_builders = "number",
	escort_seconds = "number",
	army_share = "number",
	hunt_groups = "number",
	strike_groups = "number",
	spread = "number",
})
local CHOICES: { [string]: { string } } = table.freeze({
	line = { "bot", "vehicle" },
	sees = { "all", "team_sight" },
	attack_rule = { "danger", "sim" },
	retreat_rule = { "danger", "sim" },
	defend_rule = { "danger", "sim" },
	raid_rule = { "danger", "sim" },
})

-- A set of names.
local function set(names: { string }): { [string]: boolean }
	local result: { [string]: boolean } = {}
	for _, name in names do
		result[name] = true
	end
	return table.freeze(result)
end

-- `names` less `left_out`, as a set.
local function set_without(names: { [string]: boolean }, left_out: { string }): { [string]: boolean }
	local result = table.clone(names)
	for _, name in left_out do
		result[name] = nil
	end
	return table.freeze(result)
end

-- The AI as it always played.
local DEFAULT: Profile = table.freeze({
	name = "default",
	roster = nil,
	line = nil,
	labs = 1,
	metal_per_extra_lab = 10,
	advanced_lab_income = 40,
	afford_seconds = 20,
	fodder_share = 0.15,
	army_share = nil,
	factory_queue = 2,
	sees = "all" :: Sight,
	opening_extractors = 3,
	opening_energy = 4,
	extractor_builders = 0.5,
	expansion_radius = nil,
	extractor_home_weight = 0.5,
	extractor_richness_weight = 10,
	escorts_per_builder = 2,
	constructors_min = 2,
	constructors_max = 8,
	metal_per_constructor = 6,
	advanced_constructors_max = 4,
	metal_per_advanced_constructor = 25,
	wrecks_per_rezbot = 6,
	rezbots_max = 4,
	base_radius = 70,
	extractor_guards = 1,
	home_guards = 0,
	guards_at_once = 2,
	air_threat_count = 4,
	aircraft_per_air_defense = 2,
	air_defense_afford_seconds = 40,
	air_defenses_max = 12,
	air_defense = 1,
	anti_air_per_aircraft = 0.75,
	defend_radius = 110,
	extractor_alert_radius = 40,
	builders_per_energy_build = 3,
	constructor_energy_income = 200,
	advanced_energy_income = 1000,
	piling_fill = 0.7,
	storage_seconds = 12,
	converter_storage = 6000,
	energy_stores_max = 6,
	converters_at_once = 2,
	converter_burn_share = 0.5,
	turret_income = 12,
	metal_per_turret = 12,
	turrets_max = 8,
	turret_afford_seconds = 14,
	stall_fill = 0.1,
	stall_spend_share = 0.9,
	overflow_fill = 0.9,
	short_fill = 0.05,
	safe_danger = 20,
	abort_danger = 30,
	flee_danger = 40,
	flee_seconds = 12,
	target_danger_radius = 24,
	rally_offset = 40,
	wave_base = 600,
	wave_income_seconds = 40,
	attack_rule = "danger" :: Rule,
	attack_superiority = 1.5,
	retreat_rule = "danger" :: Rule,
	retreat_ratio = 1.5,
	wave_broken_share = 0.4,
	regroup_seconds = 30,
	wave_growth = 0,
	wave_cap_seconds = nil,
	raid_size = nil,
	raid_groups = 1,
	raid_interval = 60,
	raid_superiority = 1.5,
	raid_retreat_ratio = 1,
	raider_speed_share = 0.8,
	raid_builder_preference = 1,
	raid_rule = "danger" :: Rule,
	retreat_health = nil,
	repaired_share = 0.98,
	repair_patience = 30,
	retreat_walk_seconds = 120,
	defend_share = nil,
	defend_rule = "danger" :: Rule,
	energy_factor_start = 15,
	energy_factor_end = 15,
	energy_factor_seconds = 420,
	escorted_builders = nil,
	escort_seconds = nil,
	guard_after_seconds = 0,
	guard_income = 0,
	commander_assist_constructors = 0,
	sim_attack_margin = 0.3,
	sim_retreat_margin = 0,
	sim_defend_margin = 0.3,
	hunt_groups = nil,
	hunt_radius = 60,
	hunt_margin = 0.3,
	strike_groups = nil,
	strike_share = 0.5,
	spread = nil,
})

-- The range each number of a profile is looked for in, for a tool that searches for the best of them (an AI arena,
-- tools/ai_arena/profiles.py, which reads these through the arena's "profiles" mode): the least and the most that make
-- sense, and how the search goes over it (`Range`).
local RANGES: { [string]: Range } = {
	labs = { low = 1, high = 3, scale = "int" },
	afford_seconds = { low = 5, high = 60, scale = "log" },
	army_share = { low = 0.1, high = 1, scale = "linear", absent_at = "top", absent_share = 0.2 },
	opening_extractors = { low = 0, high = 6, scale = "int" },
	extractor_builders = { low = 0.25, high = 1, scale = "linear" },
	expansion_radius = {
		low = 80,
		high = 600,
		scale = "linear",
		absent_at = "top",
		absent_share = 0.2,
	},
	escorts_per_builder = { low = 0, high = 4, scale = "int" },
	constructors_min = { low = 1, high = 4, scale = "int" },
	constructors_max = { low = 4, high = 14, scale = "int", at_least = "constructors_min" },
	extractor_guards = { low = 0, high = 1, scale = "linear" },
	home_guards = { low = 0, high = 8, scale = "int" },
	air_defense = { low = 0, high = 1, scale = "linear" },
	defend_radius = { low = 0, high = 200, scale = "linear" },
	extractor_alert_radius = { low = 0, high = 80, scale = "linear" },
	wave_base = { low = 200, high = 2000, scale = "log" },
	wave_income_seconds = { low = 10, high = 120, scale = "linear" },
	attack_superiority = { low = 0.5, high = 3, scale = "linear" },
	retreat_ratio = { low = 0.5, high = 3, scale = "linear" },
	regroup_seconds = { low = 0, high = 90, scale = "linear" },
	wave_growth = { low = 0, high = 1, scale = "linear" },
	wave_cap_seconds = { low = 30, high = 240, scale = "log", absent_at = "top", absent_share = 0.2 },
	raid_size = { low = 2, high = 8, scale = "int", absent_at = "bottom", absent_share = 0.1875 },
	raid_groups = { low = 1, high = 3, scale = "int" },
	raid_interval = { low = 20, high = 120, scale = "log" },
	raid_superiority = { low = 0.5, high = 3, scale = "linear" },
	raid_retreat_ratio = { low = 0.5, high = 3, scale = "linear" },
	raid_builder_preference = { low = 0.5, high = 4, scale = "linear" },
	retreat_health = {
		low = 0.05,
		high = 0.8,
		scale = "linear",
		absent_at = "bottom",
		absent_share = 0.1,
	},
	defend_share = { low = 0.25, high = 3, scale = "linear", absent_at = "bottom", absent_share = 0.1 },
	energy_factor_start = { low = 4, high = 20, scale = "linear" },
	energy_factor_end = { low = 10, high = 60, scale = "linear" },
	energy_factor_seconds = { low = 60, high = 900, scale = "linear" },
	escorted_builders = { low = 1, high = 8, scale = "int", absent_at = "top", absent_share = 0.2 },
	escort_seconds = { low = 120, high = 900, scale = "linear", absent_at = "top", absent_share = 0.2 },
	guard_after_seconds = { low = 0, high = 600, scale = "linear" },
	guard_income = { low = 0, high = 30, scale = "linear" },
	commander_assist_constructors = { low = 0, high = 5, scale = "int" },
	sim_attack_margin = { low = 0, high = 1, scale = "linear" },
	sim_retreat_margin = { low = -1, high = 0.5, scale = "linear" },
	sim_defend_margin = { low = 0, high = 1, scale = "linear" },
	hunt_groups = { low = 1, high = 4, scale = "int", absent_at = "bottom", absent_share = 0.2 },
	hunt_radius = { low = 20, high = 120, scale = "linear" },
	hunt_margin = { low = 0, high = 1, scale = "linear" },
	strike_groups = { low = 1, high = 4, scale = "int", absent_at = "bottom", absent_share = 0.2 },
	strike_share = { low = 0.1, high = 1, scale = "linear" },
	spread = { low = 1, high = 12, scale = "linear", absent_at = "bottom", absent_share = 0.1 },
}
for _, range in RANGES do
	table.freeze(range)
end
table.freeze(RANGES)

-- What `key` of a profile is: one of its CHOICES, a set of def names, or a number or a name (DEFAULT's kind); nil for
-- no key a profile has.
local function kind_of(key: string): string?
	if CHOICES[key] ~= nil then
		return "choice"
	end
	local default = (DEFAULT :: any)[key]
	return if default ~= nil then typeof(default) else OPTIONAL[key]
end

-- Checks that `profile` holds together: every key one a profile has and of its kind, each choice one there is, each
-- def of its roster one there is, every key it may not leave out there, and every number at least what its range says
-- it is at least.
local function validate(profile: { [string]: any })
	for key, value in profile do
		local kind = kind_of(key)
		assert(kind ~= nil, `an AI profile has no "{key}"`)
		if kind == "choice" then
			assert(table.find(CHOICES[key], value) ~= nil, `an AI profile's "{key}" cannot be "{value}"`)
		elseif kind == "defs" then
			assert(typeof(value) == "table", `an AI profile's "{key}" is a set of defs`)
			for def_name in value do
				assert(unit_defs.defs[def_name] ~= nil, `an AI profile's "{key}" has "{def_name}", which is no def`)
			end
		else
			assert(typeof(value) == kind, `an AI profile's "{key}" is a {kind}, not a {typeof(value)}`)
		end
	end
	for key in DEFAULT :: any do
		assert(profile[key] ~= nil, `an AI profile has no "{key}", which every profile has`)
	end
	for key, range in RANGES do
		local floor = range.at_least
		if floor ~= nil and profile[key] ~= nil then
			assert(profile[key] >= profile[floor], `an AI profile's "{key}" is under its "{floor}"`)
		end
	end
end

-- A copy of `base` with `changes` over it: a profile, which has to hold together (`validate`).
local function with(base: Profile, changes: { [string]: any }): Profile
	local result: { [string]: any } = table.clone(base) :: any
	for key, value in changes do
		result[key] = value
	end
	validate(result)
	return table.freeze(result) :: any
end

-- A copy of `base` with each of `keys`, which it may leave out, left out: switched off, or with no limit.
local function without(base: Profile, keys: { string }): Profile
	local result: { [string]: any } = table.clone(base) :: any
	for _, key in keys do
		assert(OPTIONAL[key] ~= nil, `an AI profile cannot leave out "{key}"`)
		result[key] = nil
	end
	validate(result)
	return table.freeze(result) :: any
end

validate(DEFAULT :: any)

-- The first tier of the bot line: a bot lab and what it makes, and what its constructors put up, but for the air lab,
-- the shipyard and the hovercraft platform, and no advanced lab. It never gets past the first tier.
local BOT_T1 = set({
	"bot_lab",
	"construction_bot",
	"grunt",
	"tick",
	"thug",
	"aggravator",
	"trasher",
	"graverobber",
	"metal_extractor",
	"wind_turbine",
	"solar_collector",
	"energy_storage",
	"metal_storage",
	"energy_converter",
	"construction_turret",
	"guard",
	"thistle",
})

-- Cheap bots only, for a swarm: the first tier less its heavier bots, leaving the lab's raiders and its light assault
-- bot.
local BOT_SWARM = set_without(BOT_T1, { "aggravator", "trasher" })

local PROFILES: { [string]: Profile } = {
	default = DEFAULT,
	-- Harasses: bots of the first tier, a few raids out all the time at the enemy's extractors and constructors, and
	-- next to nothing standing guard; it spreads its extractors across the map with no escort, so its income is out
	-- there to be raided in turn. Its main army is the usual.
	raider = with(DEFAULT, {
		name = "raider",
		roster = BOT_T1,
		line = "bot",
		opening_extractors = 4,
		extractor_builders = 0.75,
		escorts_per_builder = 0,
		constructors_max = 10,
		extractor_guards = 0,
		air_defense = 0.25,
		extractor_alert_radius = 0,
		raid_size = 4,
		raid_groups = 2,
		raid_interval = 40,
	}),
	-- Harasses as the raider does, and grows a swarm of cheap bots from two labs that goes out in waves which get
	-- bigger each time, so that an enemy who does not raid its extractors is steamrolled.
	swarm = with(DEFAULT, {
		name = "swarm",
		roster = BOT_SWARM,
		line = "bot",
		labs = 2,
		afford_seconds = 8,
		opening_extractors = 4,
		extractor_builders = 0.75,
		escorts_per_builder = 0,
		constructors_max = 10,
		extractor_guards = 0.2,
		air_defense = 0.25,
		extractor_alert_radius = 0,
		wave_base = 400,
		wave_income_seconds = 30,
		attack_superiority = 1,
		wave_growth = 0.25,
		wave_cap_seconds = 120,
		raid_size = 3,
		raid_groups = 1,
		raid_interval = 60,
	}),
	-- Sits tight: a guard by everything, guards round home, anti-air early, and an army that goes only when it far
	-- outnumbers what it goes at. For contrast, and for players who want a slower game.
	turtle = with(DEFAULT, {
		name = "turtle",
		home_guards = 4,
		wave_base = 1200,
		wave_income_seconds = 60,
		attack_superiority = 2.5,
		escorts_per_builder = 3,
		defend_radius = 160,
		extractor_alert_radius = 60,
	}),
	-- Builds up: its economy grows as the default's does, but only a quarter of its metal goes on fighters, a guard
	-- stands by only one extractor in four and not before five minutes or 10 metal, it never raids, and its army goes
	-- only at what it far outnumbers. It still sees off whatever comes near home. For an easier game.
	passive = with(DEFAULT, {
		name = "passive",
		army_share = 0.25,
		extractor_guards = 0.25,
		air_defense = 0.5,
		guard_after_seconds = 300,
		guard_income = 10,
		attack_superiority = 2.5,
		regroup_seconds = 90,
	}),
	-- The default with what was taken from BARb, BAR's own computer player, at BARb's numbers: hurt fighters go home to
	-- be mended; an intruder is met by as much of the army at home as it takes, and the wave out keeps going; energy
	-- grows with the game rather than at one rate all along; the first few builders out get one escort each for the
	-- first nine minutes; guards wait for five minutes or 10 metal; the commander helps its lab until it has three
	-- constructors; and a raid of three of its fastest goes out after the enemy's constructors first, as BARb's labs
	-- open with raiders. Two small groups of what waits at home hunt down the enemy's units that come into its territory,
	-- as BARb's defence tasks do, and every group it sends spreads out (spread) rather than bunching up, as BAR's
	-- formation moves do.
	barb = with(DEFAULT, {
		name = "barb",
		escorts_per_builder = 1,
		escorted_builders = 3,
		escort_seconds = 540,
		retreat_health = 0.5,
		defend_share = 1,
		energy_factor_start = 6,
		energy_factor_end = 30,
		energy_factor_seconds = 420,
		guard_after_seconds = 300,
		guard_income = 10,
		commander_assist_constructors = 3,
		raid_size = 3,
		raid_groups = 1,
		raid_interval = 60,
		raid_builder_preference = 2,
		hunt_groups = 2,
		hunt_radius = 100,
		spread = 6,
	}),
}

-- The default with the fight predictor (server/ai/combat_sim.luau) deciding its fights: whether and where its wave sets
-- out, and when it pulls back. The rest is as the default plays.
PROFILES.sim = with(DEFAULT, {
	name = "sim",
	attack_rule = "sim",
	retreat_rule = "sim",
})
-- BARb's profile with the fight predictor on as well, which also sizes what it sends to see an intruder off and its
-- hunters. With the predictor to judge its fights by, it also fights on several fronts: up to three raids at once,
-- which go from one undefended target to the next and turn back only from a fight they are predicted to lose; and up
-- to two strikes, the fewest of what waits at home that beat a target away from the wave, and what a wave does not
-- need to beat its target goes as one. And it guards its extractors from the start rather than after five minutes
-- (BARb's guard_after_seconds): in the arena against the raider, hunters alone did not keep its extractors standing
-- (4.9 lost in the first ten minutes, and 4.0 with guards from the start).
PROFILES.sim_barb = with(PROFILES.barb, {
	name = "sim_barb",
	attack_rule = "sim",
	retreat_rule = "sim",
	defend_rule = "sim",
	raid_rule = "sim",
	raid_groups = 3,
	strike_groups = 2,
	guard_after_seconds = 0,
	guard_income = 0,
})

-- The profile called `name`, if there is one.
local function get(name: string): Profile?
	return PROFILES[name]
end

-- Every profile's name, sorted.
local function names(): { string }
	local list: { string } = {}
	for name in PROFILES do
		table.insert(list, name)
	end
	table.sort(list)
	return list
end

return table.freeze({
	DEFAULT = DEFAULT,
	RANGES = RANGES,
	get = get,
	names = names,
	with = with,
	without = without,
})
