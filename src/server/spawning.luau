-- Putting a team's starting force on the map: its commander beside the team's start position, where its player chose
-- to start (see pregame.luau), or the start numbered the same as the team for a team nobody chose one for; and, for a
-- team nobody chose a start for (a computer player's), the start furthest from everyone (`free_start`, `box_start`).

local Players = game:GetService "Players"
local ReplicatedStorage = game:GetService "ReplicatedStorage"

local types = require(ReplicatedStorage.Shared.types)
local heightmap = require(ReplicatedStorage.Shared.heightmap)
local starts = require(ReplicatedStorage.Shared.starts)
local geometry = require(ReplicatedStorage.Shared.geometry)
local game_phase = require(ReplicatedStorage.Shared.game_phase)
local teams = require(ReplicatedStorage.Shared.teams)

local state = require(script.Parent.state)
local placement = require(script.Parent.placement)
local players = require(script.Parent.players)

type TeamId = types.TeamId

-- What every side starts the game with, on its start: its commander.
local STARTING_UNIT = "commander"
-- How far a commander put down with no spot given has to stand from everything already on the map.
local MIN_START_SPACING = 100
-- How far apart the places tried are when no start is that far from everyone and the whole map is looked across instead.
local SPREAD_STEP = 24

-- Where each team's player chose to start, as (x, z).
local start_by_team: { [TeamId]: Vector2 } = {}

local function set_start(team_id: TeamId, at: Vector2)
	start_by_team[team_id] = at
end

local function start_position(team_id: TeamId): Vector3
	local center = start_by_team[team_id] or starts.center(team_id)
	return heightmap.ground_position(center.X, center.Y)
end

-- Places a finished `def_name` of team `team_id` at (x, z), where it rests there, turned to `facing`, if it can go there.
local function place(def_name: string, team_id: TeamId, x: number, z: number, facing: number): types.Entity?
	local center = placement.ground_center(def_name, x, z)
	if placement.can_place(def_name, center, facing, nil) == false then
		return nil
	end
	local entity = state.create_entity(def_name, team_id, center, facing, "active")
	return entity
end

-- How far out from where it is asked for something is spawned, in rings of places `SPAWN_SPACING` apart.
local SPAWN_RINGS = 12
local SPAWN_SPACING = 6

-- Places an entity at the first free spot spiralling out from `around`: of those `allowed` allows, if it is given, which
-- is asked of each spot's (x, z).
local function spawn_near(
	def_name: string,
	team_id: TeamId,
	around: Vector3,
	facing: number,
	allowed: ((x: number, z: number) -> boolean)?
): types.Entity?
	local center = placement.find_free_spot(
		def_name,
		around,
		facing,
		SPAWN_RINGS,
		SPAWN_SPACING,
		if allowed ~= nil
			then function(spot: Vector3): boolean
				return allowed(spot.X, spot.Z)
			end
			else nil
	)
	if center == nil then
		return nil
	end
	local entity = state.create_entity(def_name, team_id, center, facing, "active")
	return entity
end

-- Whether team `team_id` has anything on the map: a team with players who share it gets its starting force once, from
-- whichever of them comes first.
local function owns_anything(team_id: TeamId): boolean
	for _, entity in state.all() do
		if entity.team == team_id and entity.alive then
			return true
		end
	end
	return false
end

-- Returns whether the commander was placed.
local function give_starting_force(team_id: TeamId): boolean
	local origin = start_position(team_id)
	-- face back toward the middle of the map
	local facing = math.atan2(-origin.X, -origin.Z)
	return spawn_near(STARTING_UNIT, team_id, origin, facing) ~= nil
end

-- Everywhere someone is or is about to be: everything any team has on the map, and where each player on a team starts.
-- Before the game begins nobody has a commander yet, so a player counts where they chose to start or, if they have not
-- chosen, where their box's usual start is; without them an AI put down then saw an empty map, took the first box and
-- so stood where the first player was about to.
local function taken_places(): { Vector3 }
	local places: { Vector3 } = {}
	for _, other in state.all() do
		if state.is_present(other) and other.team ~= teams.NEUTRAL then
			table.insert(places, other.position)
		end
	end
	for _, player in Players:GetPlayers() do
		if players.team_of(player) == nil then
			continue
		end
		local chosen = game_phase.start_of(player)
		local box = game_phase.box_of(player)
		if chosen ~= nil then
			table.insert(places, chosen)
		elseif box ~= nil then
			local spot = starts.default_spot(box)
			table.insert(places, Vector3.new(spot.X, 0, spot.Y))
		end
	end
	return places
end

-- Of `candidates`, the one whose nearest neighbour in `places` is furthest off, and how far off that is; the first of
-- them on a tie. Only a candidate `usable` says a team can start on counts.
local function furthest_from(
	candidates: { Vector2 },
	places: { Vector3 },
	usable: ((spot: Vector2) -> boolean)?
): (Vector2?, number)
	local best: Vector2? = nil
	local best_distance = -1
	for _, spot in candidates do
		local at = Vector3.new(spot.X, 0, spot.Y)
		local nearest = math.huge
		for _, taken in places do
			nearest = math.min(nearest, geometry.distance_2d(at, taken))
			if nearest <= best_distance then
				break
			end
		end
		if nearest > best_distance and (usable == nil or usable(spot)) then
			best = spot
			best_distance = nearest
		end
	end
	return best, best_distance
end

local function can_start(spot: Vector2): boolean
	return starts.can_start_at(spot.X, spot.Y)
end

-- Every place a team could start in the rectangle from `min` to `max`, SPREAD_STEP apart, to be checked with
-- `can_start`.
local function spread_over(min: Vector2, max: Vector2): { Vector2 }
	local spread: { Vector2 } = {}
	for x = min.X, max.X, SPREAD_STEP do
		for z = min.Y, max.Y, SPREAD_STEP do
			table.insert(spread, Vector2.new(x, z))
		end
	end
	return spread
end

-- The start furthest from everyone (`taken_places`): of the usual starts of the map's boxes and the starts on its ring,
-- the one whose nearest neighbour is furthest off. The boxes come first, so an empty map puts the AI in the first box.
-- When every start has someone within MIN_START_SPACING it looks across the whole map for the ground furthest from
-- everyone, and returns nil if even that is too close.
local function free_start(): Vector2?
	local candidates: { Vector2 } = {}
	for index = 1, starts.box_count() do
		table.insert(candidates, starts.default_spot(index))
	end
	for slot = 1, starts.count() do
		table.insert(candidates, starts.center(slot))
	end
	local places = taken_places()
	local best, distance = furthest_from(candidates, places)
	if best ~= nil and distance >= MIN_START_SPACING then
		return best
	end
	local half_x, half_z = heightmap.half_extents()
	best, distance =
		furthest_from(spread_over(Vector2.new(-half_x, -half_z), Vector2.new(half_x, half_z)), places, can_start)
	return if best ~= nil and distance >= MIN_START_SPACING then best else nil
end

-- Where to put a commander in start box `index`: the box's usual start, or if someone is within MIN_START_SPACING of
-- it, the ground in the box furthest from everyone; nil if all of the box is that close to someone.
local function box_start(index: number): Vector2?
	local places = taken_places()
	local usual = starts.default_spot(index)
	local best, distance = furthest_from({ usual }, places)
	if best ~= nil and distance >= MIN_START_SPACING then
		return best
	end
	local box = starts.box(index)
	best, distance = furthest_from(spread_over(box.min, box.max), places, can_start)
	return if best ~= nil and distance >= MIN_START_SPACING then best else nil
end

return table.freeze({
	MIN_START_SPACING = MIN_START_SPACING,
	free_start = free_start,
	box_start = box_start,
	set_start = set_start,
	give_starting_force = give_starting_force,
	owns_anything = owns_anything,
	spawn_near = spawn_near,
	place = place,
})
