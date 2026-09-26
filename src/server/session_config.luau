--!strict
-- What this server plays, decided once, as it starts (bootstrap.luau takes it from here), from everything that may have
-- a say, the first that does winning:
--
-- 1. A Studio test this session was started to run (test_request.luau): the session the test asks for
--    (tests.session_for), the same one the headless runner starts it in (tools/headless_tests). Nobody plays it: see
--    `unplayed`.
-- 2. The match a lobby started on this server, if a lobby reserved it (match_sources.luau).
-- 3. Played straight from Studio, the Studio inputs (below): `CampaignMission`, a campaign mission's id ("tutorial"),
--    or its hard mode's ("overlook_hard", campaign.key), for the match a lobby would start for it, on its map, seating
--    whoever joins first (match_sources.for_mission); or
--    `MapPreset`, a map's name from map_presets, to play that map. With `Spectate` set, whoever joins only watches,
--    with no team, as a spectator the lobby sent would, and the game begins at once without waiting for them: to watch
--    the AIs play each other.
-- 4. Otherwise MAP_PRESET, from MAP_SEED, with no match: the game anyone who joins a public server plays.
--
-- Computer opponents are put down in any game but a test's or a campaign mission's (which has its own enemy) as the
-- `AiOpponents` input says, at free starts once the game begins; `AiLines` ("bot,vehicle", say) and `AiProfiles`
-- ("sim_barb,raider") give the first few their lines and profiles, in order ("any" or "default" for one left as it
-- would be). Whether the scavengers play is decided here too, once: as the match's mode has them, or with no match,
-- config's default, but never in a session nobody plays that was handed no match.
--
-- The Studio inputs are the Workspace's attributes, which a developer sets by hand in the place before pressing Play.
-- They are read here and nowhere else, and nothing in the game writes them: what the server tells the clients is
-- replicated state, kept apart (shared/replicated.luau).
--
-- A map that is not there, as a BAR map its makers have not cleared is only there in Studio (see
-- shared/bar_maps/rights.luau), is map_presets.DEFAULT instead.

local ReplicatedStorage = game:GetService "ReplicatedStorage"
local RunService = game:GetService "RunService"
local Workspace = game:GetService "Workspace"

local game_modes = require(ReplicatedStorage.Shared.game_modes)
local map_presets = require(ReplicatedStorage.Shared.map_presets)
local campaign = require(ReplicatedStorage.Shared.campaign)
local ai_profiles = require(ReplicatedStorage.Shared.ai_profiles)
local switches = require(ReplicatedStorage.Shared.switches)

local match_sources = require(script.Parent.match_sources)
local test_request = require(script.Parent.test_request)
-- The tests are only loaded into a session a Studio test was started in, never into a live server.
local tests = if test_request.request ~= nil then require(script.Parent.tests) else nil

type Match = game_modes.Match
type Opponent = ai_profiles.Opponent

-- What map is played, and what campaign mission on it, if any, and whether in its hard mode.
export type Map = {
	preset: string,
	seed: number,
	mission: string?,
	hard: boolean,
}

export type Session = {
	-- the match played, if the game is one
	match: Match?,
	map: Map,
	-- how many computer opponents are put down at free starts once the game begins, the first few as
	-- `ai_opponent_orders` says, in order
	ai_opponents: number,
	ai_opponent_orders: { Opponent },
	-- whether anyone plays in it; one nobody plays in, a test's or a Run's, plays from the start, waiting for nobody
	played: boolean,
	-- whether whoever joins only watches, with no team (Studio's `Spectate`)
	spectate: boolean,
	-- whether the scavengers play
	scavengers: boolean,
	-- whether the rocks and trees the map starts with are kept
	scenery: boolean,
	-- what everything the game leaves to chance is rolled from, if it is to play the same every time
	random_seed: number?,
	-- the test this session runs, with what it was started with (tests/init.luau), if it runs one
	test: { [string]: any }?,
}

-- What a session nobody plays in is started with (`unplayed`).
export type Unplayed = {
	-- a match handed in the way a lobby hands one over (shared/game_modes.luau); the scavengers are then as it has
	-- them, and off without one. It need only say its mode, map and seats: the rest is as a new lobby has it.
	match: any?,
	-- the map; if not given, the match's, or else MAP_PRESET and MAP_SEED; a map asked for plays on MAP_SEED
	preset: string?,
	seed: number?,
	-- keep the rocks and trees the map starts with, which are otherwise taken away
	scenery: boolean?,
	-- what everything the game leaves to chance is rolled from; with `seeded`, the map's seed if none is given
	random_seed: number?,
	seeded: boolean?,
	test: { [string]: any }?,
}

-- What the ground is like: a name from shared/map_presets.luau, like "highlands", "koth" or one of the BAR maps
-- ("supreme_isthmus", "folsom_dam", "greenest_fields" and the rest in shared/bar_maps).
local MAP_PRESET = "highlands"
local MAP_SEED = 1337

-- The Studio inputs, by the Workspace attribute each is set as.
local STUDIO_MISSION_INPUT = "CampaignMission"
local STUDIO_PRESET_INPUT = "MapPreset"
local OPPONENTS_INPUT = "AiOpponents"
local LINES_INPUT = "AiLines"
local PROFILES_INPUT = "AiProfiles"
local SPECTATE_INPUT = "Spectate"

-- `preset` if it is a map here, or else map_presets.DEFAULT.
local function available(preset: string): string
	return if map_presets.presets[preset] ~= nil then preset else map_presets.DEFAULT
end

-- The campaign mission `match` plays, if it plays one, and whether in its hard mode.
local function mission_of(match: Match?): (string?, boolean)
	local mode = if match ~= nil then game_modes.get(match.mode) else nil
	return if mode ~= nil then mode.mission else nil, mode ~= nil and mode.hard
end

-- Whether the scavengers play in `match`: as its mode has them.
local function scavengers_in(match: Match): boolean
	local mode = game_modes.get(match.mode)
	return mode ~= nil and mode.difficulty ~= nil
end

-- The Studio input `input`, set to a string, if it is set.
local function input_string(input: string): string?
	local value = Workspace:GetAttribute(input)
	return if typeof(value) == "string" and value ~= "" then value else nil
end

-- The Studio input `input`, set to a string, if it is set and this is Studio.
local function studio_string(input: string): string?
	return if RunService:IsStudio() then input_string(input) else nil
end

-- The words of the comma-separated list the Studio input `input` is set to, in order.
local function listed(input: string): { string }
	local words: { string } = {}
	for word in string.gmatch(input_string(input) or "", "[^,%s]+") do
		table.insert(words, word)
	end
	return words
end

-- The lines and profiles `AiLines` and `AiProfiles` ask for, by position.
local function ai_opponent_orders(): { Opponent }
	local orders: { Opponent } = {}
	local function at(index: number): Opponent
		local order = orders[index]
		if order == nil then
			order = { line = nil, profile = nil }
			orders[index] = order
		end
		return order
	end
	for index, word in listed(LINES_INPUT) do
		local order = at(index)
		if word == "bot" or word == "vehicle" then
			order.line = word
		end
	end
	for index, word in listed(PROFILES_INPUT) do
		local profile = ai_profiles.get(word)
		if profile == nil and word ~= "any" and word ~= "default" then
			warn(`{PROFILES_INPUT}: there is no AI profile "{word}"`)
		end
		at(index).profile = profile
	end
	return orders
end

-- A session nobody plays in, as a Studio test is run in, and the arena (tools/ai_arena) plays: from the start, with no
-- scavengers unless a match handed in has them, and the rocks and trees the map starts with taken away unless asked
-- for.
local function unplayed(given: Unplayed): Session
	local match: Match? = nil
	if given.match ~= nil then
		local handed = given.match
		local whole: { [string]: any } = game_modes.encode(game_modes.new_match(handed.mode, handed.preset, {}))
		for key, value in handed do
			whole[key] = value
		end
		match = game_modes.decode(whole)
		if match == nil then
			warn "the match handed in is not one; playing the usual game"
		end
	end
	local preset = given.preset or (if match ~= nil then match.preset else MAP_PRESET)
	local seed = given.seed or (if given.preset == nil and match ~= nil then match.seed else MAP_SEED)
	local mission, hard = mission_of(match)
	return {
		match = match,
		map = { preset = available(preset), seed = seed, mission = mission, hard = hard },
		ai_opponents = 0,
		ai_opponent_orders = {},
		played = false,
		spectate = false,
		scavengers = if match ~= nil then scavengers_in(match) else false,
		scenery = given.scenery == true,
		random_seed = given.random_seed or (if given.seeded == true then seed else nil),
		test = given.test,
	}
end

-- What this server plays (see the top of this file). Yields while it finds the match a lobby started, and for a
-- campaign mission played straight from Studio, until someone joins to play it.
local function resolve(): Session
	local request = test_request.request
	if tests ~= nil and request ~= nil then
		return unplayed(tests.session_for(request))
	end

	local match = match_sources.from_reservation()
	local studio_mission = studio_string(STUDIO_MISSION_INPUT)
	if match == nil and studio_mission ~= nil and campaign.parse_key(studio_mission) ~= nil then
		match = match_sources.for_mission(studio_mission)
	end
	local opponents = Workspace:GetAttribute(OPPONENTS_INPUT)
	local mission, hard = mission_of(match)
	local spectate = RunService:IsStudio() and Workspace:GetAttribute(SPECTATE_INPUT) == true
	return {
		match = match,
		map = {
			preset = available(if match ~= nil then match.preset else studio_string(STUDIO_PRESET_INPUT) or MAP_PRESET),
			seed = if match ~= nil then match.seed else MAP_SEED,
			mission = mission,
			hard = hard,
		},
		ai_opponents = if mission == nil and typeof(opponents) == "number" then opponents else 0,
		ai_opponent_orders = ai_opponent_orders(),
		-- nobody plays a Run, or a game only watched; a playtest waits for its player, whatever else is set
		played = RunService:IsRunMode() == false and spectate == false,
		spectate = spectate,
		scavengers = if match ~= nil then scavengers_in(match) else switches.default "scavengers",
		scenery = true,
		random_seed = nil,
		test = nil,
	}
end

return table.freeze({
	MAP_PRESET = MAP_PRESET,
	MAP_SEED = MAP_SEED,
	unplayed = unplayed,
	resolve = resolve,
})
