-- The campaign: missions played alone, which are how a player unlocks what they may build.
--
-- Every player starts with almost everything locked. What they may build is STARTING_UNLOCKS, and each mission they
-- finish adds its `unlocks`. A def is only ever locked if something can build it (it is in some def's
-- `build_options`): a commander, a scavenger beacon or the tutorial's boulder is never locked, since nobody builds it.
--
-- The game server keeps each player's progress in a DataStore (PROGRESS_STORE, keyed by `progress_key`) and publishes
-- what they have unlocked as the UNLOCKS_ATTRIBUTE of their Player, a comma separated list of def names, which both
-- the build menu (to show what is locked) and the lobby read. The server refuses to build anything locked.
--
-- A mission is played alone from the campaign screen, and one with `coop` may also be played together: its co-op lobby
-- is a lobby like any other, but it plays that mission on its map, and nobody can change either. Everyone who wins it
-- has it marked complete.
--
-- A campaign mission is played as a match of its own mode (game_modes, kind "campaign"), on its own map. While one is
-- being played the server sets MISSION_ATTRIBUTE on Workspace to the mission's id, and the client puts the HUD into
-- that mission's state.

local ReplicatedStorage = game:GetService "ReplicatedStorage"
local Workspace = game:GetService "Workspace"

local unit_defs = require(ReplicatedStorage.Shared.unit_defs)
local heightmap = require(ReplicatedStorage.Shared.heightmap)

export type Mission = {
	id: string,
	label: string,
	-- what the campaign screen says about it
	description: string,
	-- the map it is played on, a name from map_presets
	preset: string,
	-- what finishing it unlocks, def names
	unlocks: { string },
	-- how many may play it together, from a co-op lobby (lobby/server/lobbies.luau), for a mission that may be played
	-- that way; nil for one only ever played alone
	coop: number?,
}

-- What a player has done in the campaign, as it is stored.
export type Progress = {
	-- mission ids
	completed: { [string]: boolean },
	-- def names, the starting ones included
	unlocks: { [string]: boolean },
}

-- The tutorial's map, in world (x, z). The map is small: the player's side to the west, the enemy's to the east, and
-- one narrow pass between them, which the boulder fills.
export type TutorialLayout = {
	player_start: Vector2,
	enemy_start: Vector2,
	-- the middle of the pass, where the boulder stands
	chokepoint: Vector2,
	-- where the move step asks the commander to be sent: beside a metal spot, since extractors are built next
	move_target: Vector2,
	-- how close to the move target a right click, or the commander, has to be to count
	move_tolerance: number,
	-- how long a step waits, once it is done, before the next begins
	advance_seconds: number,
	-- how many solar collectors, and how many grunts, their steps ask for
	solars: number,
	grunts: number,
}

-- The second mission's map, in world (x, z) (see map_presets' "overlook", whose numbers these have to agree with). The
-- player starts on a plateau to the west, whose eastern edge is a cliff overlooking the enemy's base on the low ground,
-- with a ramp down near each of the map's north and south edges.
export type OverlookLayout = {
	player_start: Vector2,
	enemy_start: Vector2,
	-- the x the plateau's edge wanders about, where the cliff falls to the low ground
	edge_x: number,
	-- how many thugs the mission's guide asks to be put at the edge, and how far back from it one may stand and count
	edge_thugs: number,
	edge_depth: number,
	-- the metal and the energy a second the guide asks for before the thugs, as the resource bar shows them: the metal
	-- is what the commander and an extractor on each of the player's four spots make together
	metal: number,
	energy: number,
}

-- The third mission's, played on the overlook's map just after the second (so campaign.OVERLOOK's numbers hold for it
-- too), in world (x, z). The enemy's base below the cliff is wrecks now, and the player holds the plateau with what they
-- took it with; after `prep_seconds` the enemy's reinforcements start to arrive in waves at the far, east end of the
-- map, half of each at each of `arrivals`, and make for the player's base up the ramps. The way to hold is to raise the
-- old base's guards with rezbots before they come, and turn them on the waves.
export type CounterattackLayout = {
	-- where the waves come in: the north one's make for the north ramp, and the south one's for the south
	arrivals: { Vector2 },
	-- The west edge of the enemy zone, the strip of the map's east end the waves arrive in: whatever the player has east
	-- of it is destroyed when a wave arrives, and they are warned of that as they build there. All of the old base lies
	-- west of it, so that whatever is raised of it stays.
	zone_x: number,
	-- how long the player has to prepare before the first wave, in seconds
	prep_seconds: number,
	-- how many guards' wrecks the old base leaves, which the mission's guide asks to be raised
	old_guards: number,
}

-- The Workspace attributes the server publishes the third mission's state in (server/counterattack.luau), for the HUD:
-- the enemy zone's west edge (a number, set as the mission is set up), how many waves have arrived (0 while the player
-- prepares) and how many there are, the whole seconds until the next arrives (none once the last has), and how many of
-- the enemy's things are left standing.
local COUNTERATTACK_ATTRIBUTES = table.freeze({
	zone_x = "campaign_zone_x",
	wave = "campaign_wave",
	waves = "campaign_waves",
	wave_in = "campaign_wave_in",
	enemies_left = "campaign_enemies_left",
})

local STARTING_UNLOCKS: { string } =
	{ "bot_lab", "construction_bot", "grunt", "guard", "solar_collector", "metal_extractor" }

local UNLOCKS_ATTRIBUTE = "campaign_unlocks"
local MISSION_ATTRIBUTE = "campaign_mission"
local PROGRESS_STORE = "campaign_progress_v1"

local TUTORIAL: TutorialLayout = table.freeze({
	player_start = Vector2.new(-110, 0),
	enemy_start = Vector2.new(110, 0),
	chokepoint = Vector2.new(0, 0),
	move_target = Vector2.new(-82, -38),
	move_tolerance = 12,
	advance_seconds = 3,
	solars = 3,
	grunts = 3,
})

local OVERLOOK: OverlookLayout = table.freeze({
	player_start = Vector2.new(-53, 0),
	enemy_start = Vector2.new(42, 0),
	edge_x = -18,
	edge_thugs = 4,
	edge_depth = 8,
	metal = 10,
	energy = 60,
})
local COUNTERATTACK: CounterattackLayout = table.freeze({
	arrivals = table.freeze({ Vector2.new(68, 26), Vector2.new(68, -26) }),
	zone_x = 60,
	prep_seconds = 300,
	old_guards = 8,
})
-- Going east, the overlook's cliff edge is where the ground first falls more steeply than this (rise over run, about 40
-- degrees), looked for every EDGE_STEP studs.
local EDGE_STEEPNESS = 0.85
local EDGE_STEP = 0.5

local MISSIONS: { Mission } = {
	{
		id = "tutorial",
		label = "Tutorial",
		description = "Learn the basics.",
		preset = "tutorial",
		unlocks = { "wind_turbine", "energy_storage", "thug", "aggravator" },
		coop = nil,
	},
	{
		id = "overlook",
		label = "The Overlook",
		description = "Destroy a fortified base from the heights.",
		preset = "overlook",
		unlocks = { "graverobber", "thistle", "twin_guard", "warden" },
		coop = 4,
	},
	{
		id = "counterattack",
		label = "Counterattack",
		description = "Raise the old base's guards. Hold the heights.",
		preset = "overlook",
		unlocks = { "vehicle_lab", "incisor", "brute", "tick", "rascal" },
		coop = 4,
	},
}

local mission_by_id: { [string]: Mission } = {}
for _, mission in MISSIONS do
	mission_by_id[mission.id] = mission
end

-- Everything some def can build: only these are ever locked.
local lockable: { [string]: boolean } = {}
for _, def in unit_defs.defs do
	if def.build_options ~= nil then
		for _, option in def.build_options do
			lockable[option] = true
		end
	end
end

local function get(id: string): Mission?
	return mission_by_id[id]
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

-- `unlocks` as the attribute carries it: the names, sorted, comma separated.
local function encode_unlocks(unlocks: { [string]: boolean }): string
	local names: { string } = {}
	for name, unlocked in unlocks do
		if unlocked then
			table.insert(names, name)
		end
	end
	table.sort(names)
	return table.concat(names, ",")
end

-- The unlocks an attribute holds. The starting ones are always in it, and anything that is not a string is nothing
-- more than them.
local function decode_unlocks(value: any): { [string]: boolean }
	local set = starting_unlocks()
	if typeof(value) ~= "string" then
		return set
	end
	for _, name in string.split(value, ",") do
		if name ~= "" then
			set[name] = true
		end
	end
	return set
end

-- What `player` has unlocked, as published on them; only the starting unlocks until the server has published any.
local function unlocks_of(player: Player): { [string]: boolean }
	return decode_unlocks(player:GetAttribute(UNLOCKS_ATTRIBUTE))
end

-- The mission being played in this game, or nil for any other game.
local function current_mission(): string?
	local value = Workspace:GetAttribute(MISSION_ATTRIBUTE)
	return if typeof(value) == "string" and value ~= "" then value else nil
end

-- The x of the overlook's cliff edge at `z`, on the map as it is built: where, going east across the plateau, the ground
-- first starts to fall away steeply, which is as far east as anything on the plateau can stand there.
local function overlook_edge_at(z: number): number
	local x = OVERLOOK.player_start.X
	while x < OVERLOOK.enemy_start.X do
		if heightmap.height_at(x, z) - heightmap.height_at(x + EDGE_STEP, z) > EDGE_STEEPNESS * EDGE_STEP then
			return x
		end
		x += EDGE_STEP
	end
	return OVERLOOK.edge_x
end

local function progress_key(user_id: number): string
	return `player_{user_id}`
end

-- A fresh player's progress.
local function new_progress(): Progress
	return { completed = {}, unlocks = starting_unlocks() }
end

-- The progress a value read from the store holds; a new player's for anything that is not one.
local function decode_progress(value: any): Progress
	local progress = new_progress()
	if typeof(value) ~= "table" then
		return progress
	end
	if typeof(value.completed) == "table" then
		for id, done in value.completed do
			if typeof(id) == "string" and done == true then
				progress.completed[id] = true
			end
		end
	end
	if typeof(value.unlocks) == "table" then
		for name, unlocked in value.unlocks do
			if typeof(name) == "string" and unlocked == true then
				progress.unlocks[name] = true
			end
		end
	end
	return progress
end

return table.freeze({
	MISSIONS = MISSIONS,
	STARTING_UNLOCKS = STARTING_UNLOCKS,
	UNLOCKS_ATTRIBUTE = UNLOCKS_ATTRIBUTE,
	MISSION_ATTRIBUTE = MISSION_ATTRIBUTE,
	PROGRESS_STORE = PROGRESS_STORE,
	TUTORIAL = TUTORIAL,
	OVERLOOK = OVERLOOK,
	COUNTERATTACK = COUNTERATTACK,
	COUNTERATTACK_ATTRIBUTES = COUNTERATTACK_ATTRIBUTES,
	get = get,
	next_mission = next_mission,
	is_lockable = is_lockable,
	starting_unlocks = starting_unlocks,
	is_unlocked = is_unlocked,
	encode_unlocks = encode_unlocks,
	decode_unlocks = decode_unlocks,
	unlocks_of = unlocks_of,
	current_mission = current_mission,
	overlook_edge_at = overlook_edge_at,
	progress_key = progress_key,
	new_progress = new_progress,
	decode_progress = decode_progress,
})
