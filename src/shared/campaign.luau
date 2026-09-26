--!strict
-- The campaign: missions played alone, which are how a player unlocks what they may build.
--
-- Every player starts with almost everything locked. What they may build is STARTING_UNLOCKS, and each mission they
-- finish adds its `unlocks`. A def is only ever locked if something can build it (it is in some def's builder's
-- `options`): a commander, a scavenger beacon or the tutorial's boulder is never locked, since nobody builds it.
--
-- What each player has finished and unlocked is their progress (campaign_progress.luau), kept in a DataStore and
-- published on their Player, which both the build menu (to show what is locked) and the lobby read. The server refuses
-- to build anything locked.
--
-- A mission is played alone from the campaign screen, and one with `coop` may also be played together: its co-op lobby
-- is a lobby like any other, but it plays that mission on its map, and nobody can change either. Everyone who wins it
-- has it marked complete. Played together, its players are either allied teams of their own or all on one team, as
-- its `coop_kind` says.
--
-- A mission may have a hard mode: the same map and mostly the same start, with no guide and a harder enemy (what is
-- harder is the mission's own, server/missions'), open once the mission has been finished. It is named by the key
-- `key(id, true)`, the id with HARD_SUFFIX after it ("overlook_hard"), wherever one id has to name either: among the
-- missions a player has finished, and when the campaign screen asks for one to be played. Finishing it finishes the
-- mission as well, and unlocks its `hard_mode_unlocks` besides its `unlocks` (`unlocks_for`).
--
-- A campaign mission is played as a match of its own mode (game_modes, kind "campaign"), on its own map, whose preset
-- names the places the mission is built around (shared/mission_map.luau). The player has no start to choose: their
-- commander goes down at the map's PLAYER_START, unless it names none, as one of the usual maps a game against the
-- computer is played on (`ai_profile`) does. What the mission starts with and how it is won is the game server's
-- (server/missions), what it guides its player through the client's (client/missions); both find a mission's part by
-- its id. While one is being played the server publishes its id (shared/mission_state.luau), and the client puts the
-- HUD into that mission's state: its `hud`.
--
-- The missions are played in the order MISSIONS lists them: one is open to a player once they have finished every one
-- before it (`is_open`), and winning one offers the next (`next_mission`).

local ReplicatedStorage = game:GetService "ReplicatedStorage"

local unit_defs = require(ReplicatedStorage.Shared.unit_defs)

-- How a mission played together seats its players: each on a team of their own, the teams allied ("allied"), or all
-- on one team, commanding everything it has and spending from one bank, as StarCraft's archon mode has it ("shared").
export type CoopKind = "allied" | "shared"

export type Mission = {
	id: string,
	label: string,
	-- what the campaign screen says about it
	description: string,
	-- the map it is played on, a name from map_presets
	preset: string,
	-- what finishing it unlocks, def names
	unlocks: { string },
	-- whether it has a hard mode (see the top of this file), what finishing that unlocks besides `unlocks`, and what the
	-- campaign screen says about it, if anything
	hard_mode: boolean,
	hard_mode_unlocks: { string }?,
	hard_mode_description: string?,
	-- how many may play it together, from a co-op lobby (lobby/server/lobbies.luau), for a mission that may be played
	-- that way, and how they are seated; nil for one only ever played alone
	coop: number?,
	coop_kind: CoopKind?,
	-- for a mission played as a game against the computer, the AI profile (shared/ai_profiles.luau) its enemy plays by,
	-- and in its hard mode: the enemy is then an AI with a commander like any opponent's (server/missions/skirmish.luau);
	-- nil for a mission that puts its enemy down
	ai_profile: string?,
	hard_mode_ai_profile: string?,
	-- How much of the HUD it shows: "simple" pares the selection panel down to a name, a team and a health bar (the
	-- tutorial's); "full" is the usual. What its guide keeps off the HUD until a step has taught it is the guide's.
	hud: "full" | "simple",
}

local STARTING_UNLOCKS: { string } =
	{ "bot_lab", "construction_bot", "grunt", "guard", "solar_collector", "metal_extractor" }

local HARD_SUFFIX = "_hard"

local MISSIONS: { Mission } = {
	{
		id = "tutorial",
		label = "Tutorial",
		description = "Learn the basics!",
		preset = "tutorial",
		unlocks = { "wind_turbine", "energy_storage", "thug", "aggravator" },
		hard_mode = false,
		coop = nil,
		coop_kind = nil,
		hud = "simple",
	},
	{
		id = "overlook",
		label = "The Overlook",
		description = "Destroy a fortified base from the heights. With so much defense, grunts are not going to cut it.",
		preset = "overlook",
		unlocks = { "graverobber", "thistle", "trasher", "twin_guard", "construction_turret" },
		-- the enemy has an agitator in its base as well
		hard_mode = true,
		hard_mode_unlocks = { "warden", "centurion" },
		coop = 2,
		coop_kind = "shared",
		hud = "full",
	},
	{
		id = "counterattack",
		label = "Look Who's Back",
		description = "Guess who's back? The enemy, and they are not happy that you destroyed their base.",
		preset = "overlook",
		unlocks = { "vehicle_lab", "construction_vehicle", "incisor", "brute", "tick", "rascal" },
		-- fifteen waves rather than eight, with pounders and januses among them (server/missions/counterattack.luau)
		hard_mode = true,
		hard_mode_unlocks = { "pounder", "janus", "lasher", "wolverine" },
		hard_mode_description = "This time with way more waves",
		coop = 2,
		coop_kind = "shared",
		hud = "full",
	},
	{
		id = "prairie",
		label = "Prairie Skirmish",
		description = "A real game on open grassland against an ai enemy. Kill its commander to win! Fast moving vehicles may now be your best choice.",
		preset = "prairie",
		unlocks = { "tidal_generator", "shipyard", "supporter", "riptide", "construction_ship", "garpike" },
		-- the enemy plays as BARb does, with the fight predictor
		hard_mode = true,
		hard_mode_description = "This time with a smarter enemy",
		hard_mode_ai_profile = "sim_barb",
		hard_mode_unlocks = { "energy_converter", "advanced_solar_collector", "metal_storage" },
		coop = 2,
		coop_kind = "allied",
		ai_profile = "passive",
		hud = "full",
	},
	{
		id = "channel",
		label = "Channel Crossing",
		description = "The enemy has fortified the far side of the channel and builds no ships. Cross it and kill their commander before time runs out.",
		preset = "channel",
		unlocks = { "urchin", "coral", "herring", "slingshot", "agitator" },
		-- bomber raids, a Coral past each end of the line, an Agitator, and less time (server/missions/channel.luau)
		hard_mode = true,
		hard_mode_description = "With enemy bombers",
		hard_mode_unlocks = { "oppressor" },
		coop = 2,
		coop_kind = "allied",
		hud = "full",
	},
	{
		id = "blockade",
		label = "Blockade",
		description = "Enemy fleets are sailing through the channel. Don't let too many get past.",
		preset = "channel",
		unlocks = { "orca", "hovercraft_platform", "construction_hovercraft", "goon" },
		-- twelve waves rather than seven, with cruisers (server/missions/blockade.luau)
		hard_mode = true,
		hard_mode_description = "More waves, with cruisers",
		hard_mode_unlocks = { "halberd", "birdeater" },
		coop = 2,
		coop_kind = "shared",
		hud = "full",
	},
}

local mission_by_id: { [string]: Mission } = {}
for _, mission in MISSIONS do
	mission_by_id[mission.id] = mission
end

-- Everything some def can build: only these are ever locked.
local lockable: { [string]: boolean } = {}
for _, def in unit_defs.defs do
	for _, option in unit_defs.build_options(def) do
		lockable[option] = true
	end
end

local function get(id: string): Mission?
	return mission_by_id[id]
end

-- The key that names `id`'s hard mode, or `id` itself for its normal one (see HARD_SUFFIX).
local function key(id: string, hard: boolean): string
	return if hard then id .. HARD_SUFFIX else id
end

-- The mission a key names (`key`), and whether it names its hard mode; nil for no mission, or the hard mode of one
-- that has none.
local function parse_key(value: string): (Mission?, boolean)
	local plain = mission_by_id[value]
	if plain ~= nil then
		return plain, false
	end
	if string.sub(value, -#HARD_SUFFIX) == HARD_SUFFIX then
		local mission = mission_by_id[string.sub(value, 1, -#HARD_SUFFIX - 1)]
		if mission ~= nil and mission.hard_mode then
			return mission, true
		end
	end
	return nil, false
end

-- What finishing `mission` unlocks, in its hard mode for `hard`: its hard mode's unlocks as well.
local function unlocks_for(mission: Mission, hard: boolean): { string }
	local names = table.clone(mission.unlocks)
	local hard_unlocks: { string } = mission.hard_mode_unlocks or {}
	if hard then
		for _, name in hard_unlocks do
			table.insert(names, name)
		end
	end
	return names
end

-- The mission after `id` in MISSIONS, which finishing it leads on to; nil after the last, or for no mission.
local function next_mission(id: string): Mission?
	for index, mission in MISSIONS do
		if mission.id == id then
			return MISSIONS[index + 1]
		end
	end
	return nil
end

-- Whether the mission the key `mission_key` names (`key`) may be played by someone who has finished `completed`: every
-- one before it has to be finished, and for a hard mode, the mission itself. Any mission already finished may be played
-- again.
local function is_open(completed: { [string]: boolean }, mission_key: string): boolean
	local named, hard = parse_key(mission_key)
	if named == nil then
		return false
	end
	if hard then
		return completed[named.id] == true
	end
	for _, mission in MISSIONS do
		if mission.id == named.id then
			return true
		end
		if completed[mission.id] ~= true then
			return false
		end
	end
	return false
end

local function is_lockable(def_name: string): boolean
	return lockable[def_name] == true
end

-- The unlocks a new player has.
local function starting_unlocks(): { [string]: boolean }
	local set: { [string]: boolean } = {}
	for _, name in STARTING_UNLOCKS do
		set[name] = true
	end
	return set
end

-- Whether `def_name` may be built by someone who has unlocked `unlocks`.
local function is_unlocked(unlocks: { [string]: boolean }, def_name: string): boolean
	return lockable[def_name] ~= true or unlocks[def_name] == true
end

return table.freeze({
	MISSIONS = MISSIONS,
	STARTING_UNLOCKS = STARTING_UNLOCKS,
	get = get,
	key = key,
	parse_key = parse_key,
	unlocks_for = unlocks_for,
	next_mission = next_mission,
	is_open = is_open,
	is_lockable = is_lockable,
	starting_unlocks = starting_unlocks,
	is_unlocked = is_unlocked,
})
