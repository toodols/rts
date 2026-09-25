-- The computer player's personalities. There is one AI (server/ai.luau), and each team it plays carries a profile: the
-- numbers it plays by, which are what makes one AI a turtle and another a raider. A profile says nothing about how it
-- does anything, only how much, how often and with what; the default profile is the AI as it always played, and every
-- other is the default with some of its numbers changed (`with`).
--
-- A profile is picked when a team is handed to the AI (ai.spawn_opponent, ai.take_over, ai.add), changed on one it
-- already plays (ai.set_profile), or named on the command bar (ai_add's Profile, ai_profile). A mission builds its own
-- from one of these with `with`.
--
-- This module is plain data and is shared, so that the command bar on the client can suggest the profiles' names.

-- Which kind of lab an AI builds its army from.
export type Line = "bot" | "vehicle"

export type Profile = {
	name: string,

	-- What it builds.
	-- The defs it may build or make, as a set; nil for anything. It is held to this on top of whatever the campaign
	-- holds its team to, in what its builders put up and in what its labs make, and from the opening on.
	roster: { [string]: boolean }?,
	-- The labs it builds its army from; nil to choose for itself (bots on rough ground, otherwise either by a toss).
	line: Line?,
	-- How many labs of its line it keeps, 1 and up; each past the first once it makes METAL_PER_EXTRA_LAB metal a second
	-- for every lab it has.
	labs: number,
	-- Its labs field what costs no more than this many seconds of its metal income, so fewer seconds is a cheaper and
	-- bigger army; 5 to 60.
	afford_seconds: number,

	-- Expansion: how far and how fast it spreads its extractors.
	-- How many extractors the commander puts down in the opening, 0 to 6.
	opening_extractors: number,
	-- How many extractors may be under way at once, as a share of its builders (at least one), 0.25 to 1.
	extractor_builders: number,
	-- How far from home its constructors take extractors, in studs; math.huge for anywhere on the map.
	expansion_radius: number,
	-- How many of the army waiting at home go with each constructor that goes beyond the base, 0 to 4.
	escorts_per_builder: number,
	-- The plain constructors its labs keep: CONSTRUCTORS_MIN, and one more for every few metal of income, up to this.
	constructors_min: number,
	constructors_max: number,

	-- Defence: how much it spends on standing guard rather than on its army.
	-- The share of its extractors it puts a guard beside, 0 to 1; 1 guards every one.
	extractor_guards: number,
	-- Guards it keeps round home, in front of its labs, 0 to 8.
	home_guards: number,
	-- The share of the anti-air buildings it would put up against the enemy's aircraft that it does, 0 to 1.
	air_defense: number,
	-- How near home an enemy has to come, in studs, and how near one of its extractors, for the whole army to turn on
	-- it; 0 for never.
	defend_radius: number,
	extractor_alert_radius: number,

	-- The main army.
	-- It sets out once it is worth wave_base plus wave_income_seconds of its metal income (in metal, as unit_defs.power
	-- counts it), and only at something the danger round which, times attack_superiority, is under its worth; so a
	-- lower superiority attacks against worse odds (0.5 to 3). Only what is waiting at home goes; what is made while a
	-- wave is out waits for the next. Out there the wave pulls back when the danger where it stands is over
	-- retreat_ratio of its worth, or once it has lost most of what set out, and then waits regroup_seconds before the
	-- next sets out; a wave that has nothing left to attack comes home and the next may go at once.
	wave_base: number,
	wave_income_seconds: number,
	attack_superiority: number,
	retreat_ratio: number,
	regroup_seconds: number,
	-- Escalation: what a wave has to be worth grows by this share of itself for every wave it has already sent, 0 to 1,
	-- but never past wave_cap_seconds of its whole income (converters' metal counted), so each wave is bigger than the
	-- last and they keep coming as they grow; math.huge for no cap.
	wave_growth: number,
	wave_cap_seconds: number,

	-- Harassment: small raids of its fastest units, apart from the main army, at the enemy's extractors and
	-- constructors, where the danger round them times raid_superiority is under the raid's worth. A raid comes home
	-- once the danger where it stands is over raid_retreat_ratio of its worth, or there is nothing left it may hit.
	-- raid_size units to a raid (0 for none, 2 to 8), no more than raid_groups out at once, a new one no sooner than
	-- raid_interval seconds after the last. While it is short of raiders its labs make the fastest fighter they can.
	raid_size: number,
	raid_groups: number,
	raid_interval: number,
	raid_superiority: number,
	raid_retreat_ratio: number,
}

-- A set of def names.
local function set(names: { string }): { [string]: boolean }
	local result: { [string]: boolean } = {}
	for _, name in names do
		result[name] = true
	end
	return table.freeze(result)
end

-- The AI as it always played.
local DEFAULT: Profile = table.freeze({
	name = "default",
	roster = nil,
	line = nil,
	labs = 1,
	afford_seconds = 20,
	opening_extractors = 3,
	extractor_builders = 0.5,
	expansion_radius = math.huge,
	escorts_per_builder = 2,
	constructors_min = 2,
	constructors_max = 8,
	extractor_guards = 1,
	home_guards = 0,
	air_defense = 1,
	defend_radius = 110,
	extractor_alert_radius = 40,
	wave_base = 600,
	wave_income_seconds = 40,
	attack_superiority = 1.5,
	retreat_ratio = 1.5,
	regroup_seconds = 30,
	wave_growth = 0,
	wave_cap_seconds = math.huge,
	raid_size = 0,
	raid_groups = 0,
	raid_interval = 60,
	raid_superiority = 1.5,
	raid_retreat_ratio = 1,
})

-- A copy of `base` with `changes` over it. Every key in `changes` has to be one a profile has.
local function with(base: Profile, changes: { [string]: any }): Profile
	local result: { [string]: any } = table.clone(base) :: any
	for key, value in changes do
		assert(DEFAULT[key] ~= nil or key == "roster" or key == "line", `an AI profile has no "{key}"`)
		result[key] = value
	end
	return table.freeze(result) :: any
end

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

-- Cheap bots only, for a swarm: the lab's raiders and its light assault bot.
local BOT_SWARM = set({
	"bot_lab",
	"construction_bot",
	"grunt",
	"tick",
	"thug",
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
}

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
	get = get,
	names = names,
	with = with,
	set = set,
})
