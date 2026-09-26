--!strict
-- What every campaign mission's server part (server/missions) is, and what they put their maps' things down with.

local ReplicatedStorage = game:GetService "ReplicatedStorage"
local ServerScriptService = game:GetService "ServerScriptService"

local types = require(ReplicatedStorage.Shared.types)
local world_scale = require(ReplicatedStorage.Shared.world_scale)
local heightmap = require(ReplicatedStorage.Shared.heightmap)
local spots = require(ReplicatedStorage.Shared.spots)
local unit_defs = require(ReplicatedStorage.Shared.unit_defs)
local geometry = require(ReplicatedStorage.Shared.geometry)
local teams = require(ReplicatedStorage.Shared.teams)
local game_modes = require(ReplicatedStorage.Shared.game_modes)
local mission_state = require(ReplicatedStorage.Shared.mission_state)
local campaign = require(ReplicatedStorage.Shared.campaign)

local state = require(ServerScriptService.Server.state)
local spawning = require(ServerScriptService.Server.spawning)
local placement = require(ServerScriptService.Server.placement)

type TeamId = types.TeamId
type EntityId = types.EntityId

-- The mission being played, and whether in its hard mode, which is harder in whatever way its handler makes it.
export type Playing = {
	mission: campaign.Mission,
	hard: boolean,
}

-- A mission, as the game server plays it: what it starts with, and whatever it does besides being won by destroying
-- its enemy, all of it optional but `setup`.
export type Handler = {
	-- Puts down what the mission starts with, its map just built and its enemy playing as `enemy`.
	setup: (enemy: TeamId, playing: Playing) -> (),
	-- Forgets whatever it kept of the mission, which is being begun again or left for another.
	reset: (() -> ())?,
	-- Runs it on by `delta` seconds, every step until it has ended.
	tick: ((delta: number) -> ())?,
	-- The commander of the players' team `team_id` has gone down, the game beginning for them.
	on_commander_down: ((team_id: TeamId) -> ())?,
	-- Whether its enemy having nothing left beats it yet; always, for a mission that does not say.
	is_beaten: (() -> boolean)?,
	-- How many of its enemy's units are on their way onto the field, still to come down; none for a mission that does
	-- not say.
	arriving: (() -> number)?,
	-- How many of its enemy's things stand, told every time the mission looks (`enemy_left`).
	on_enemy_counted: ((enemy_left: number) -> ())?,
	-- How a team of the players' is out (server/elimination.luau): "units", once it has nothing left, for a mission
	-- that does not say; "commanders", once its commander has been on the field and is dead, whatever else it has.
	end_mode: game_modes.EndMode?,
	-- How its enemy is out, the same way: "units" for a mission that does not say.
	enemy_end_mode: game_modes.EndMode?,
	-- What the HUD shows of it (shared/mission_state.luau), `enemy_left` being how many of the enemy's things stand;
	-- nothing, for a mission that does not say. Published with the rest of what the players are sent, outside the
	-- simulation's steps.
	hud: ((enemy_left: number) -> mission_state.Hud?)?,
	-- Re-times it, for a developer (the command bar's `mission_timing`) or a test: `prep` seconds to prepare before
	-- whatever it brings, and `pace` times as long between what comes after, either nil for its usual.
	retime: ((prep: number?, pace: number?) -> ())?,
	-- Something is gone, which it need not remember.
	forget: ((id: EntityId) -> ())?,
}

-- Something a mission puts down: what, and where in world (x, z).
export type Placed = { def_name: string, at: Vector2 }

-- The extractor a mission puts on a metal spot.
local EXTRACTOR_DEF = "metal_extractor"
local EAST = math.pi / 2
local WEST = -math.pi / 2

-- Whether `team_id` is one of the players' in a mission whose enemy plays as `enemy`: anybody's but the enemy's,
-- nobody's and the scavengers'.
local function is_players(team_id: TeamId, enemy: TeamId?): boolean
	return team_id ~= enemy and teams.is_playable(team_id)
end

-- Where an extractor built on each metal spot that `wanted` picks stands, facing `facing`.
local function extractor_sites(wanted: (spot: Vector3) -> boolean, facing: number): { Vector3 }
	local sites: { Vector3 } = {}
	for _, spot in spots.all "metal" do
		if wanted(spot.position) == false then
			continue
		end
		local center = placement.resolve_center(EXTRACTOR_DEF, spot.position.X, spot.position.Z, facing, nil)
		if center == nil or placement.can_place(EXTRACTOR_DEF, center, facing, nil) == false then
			warn(`the mission could not put an extractor on the spot at {spot.position}`)
			continue
		end
		table.insert(sites, center)
	end
	return sites
end

-- A finished extractor of `team_id` on each of `sites` (extractor_sites), facing `facing`.
local function place_extractors(team_id: TeamId, sites: { Vector3 }, facing: number)
	for _, center in sites do
		state.create_entity(EXTRACTOR_DEF, team_id, center, facing, "active")
	end
end

-- The wreck of a finished `def_name` standing at `center`, as its death would have left it.
local function place_wreck(def_name: string, center: Vector3, facing: number)
	state.create_wreck(def_name, center, facing)
end

-- Where on the ground a finished `def_name` put down at (x, z) stands: a building on the building grid.
local function standing_center(def_name: string, x: number, z: number, facing: number): Vector3
	local def = unit_defs.get(def_name)
	if def.kind == "building" then
		local half = geometry.rotated_half_extents(unit_defs.footprint_half_extents(def), facing)
		x, z = geometry.snap_center(x, z, half, world_scale.CELL_STUDS)
	end
	return placement.ground_center(def_name, x, z)
end

-- Puts `placed` down for `team_id`, facing `facing`, each as near where it says as there is room.
local function place_all(placed: { Placed }, team_id: TeamId, facing: number)
	for _, each in placed do
		local at = heightmap.ground_position(each.at.X, each.at.Y)
		if spawning.spawn_near(each.def_name, team_id, at, facing) == nil then
			warn(`the mission found no room for {each.def_name} at {each.at}`)
		end
	end
end

return table.freeze({
	EXTRACTOR_DEF = EXTRACTOR_DEF,
	EAST = EAST,
	WEST = WEST,
	is_players = is_players,
	extractor_sites = extractor_sites,
	place_extractors = place_extractors,
	place_wreck = place_wreck,
	standing_center = standing_center,
	place_all = place_all,
})
