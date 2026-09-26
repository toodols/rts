--!strict
-- Where the scavengers put things down: where a beacon may stand (`beacon_site`: on dry level ground or afloat on the
-- sea, well away from the players and from other beacons, with room round it for what it makes to get away), the start
-- box their first beacon takes (`free_box`, `first_site`), and the free place round a beacon for what it makes
-- (`spot_near`), each looked for on rings (placement.ring_search).

local Players = game:GetService "Players"
local ReplicatedStorage = game:GetService "ReplicatedStorage"
local ServerScriptService = game:GetService "ServerScriptService"

local types = require(ReplicatedStorage.Shared.types)
local teams = require(ReplicatedStorage.Shared.teams)
local unit_defs = require(ReplicatedStorage.Shared.unit_defs)
local heightmap = require(ReplicatedStorage.Shared.heightmap)
local geometry = require(ReplicatedStorage.Shared.geometry)
local pathfinder = require(ReplicatedStorage.Shared.pathfinder)
local starts = require(ReplicatedStorage.Shared.starts)
local game_phase = require(ReplicatedStorage.Shared.game_phase)

local state = require(ServerScriptService.Server.state)
local placement = require(ServerScriptService.Server.placement)
local spatial = require(ServerScriptService.Server.spatial)
local rng = require(ServerScriptService.Server.rng)

local settings = require(script.Parent.settings)
local roster = require(script.Parent.roster)

type Entity = types.Entity
type EntityDef = types.EntityDef

-- A place something goes down, and which way it faces.
export type Spot = {
	position: Vector3,
	facing: number,
}

-- The first beacon is looked for in rings this far apart round its start box's start, as far as the box goes.
local START_SEARCH_STEP = 8
-- What a beacon makes goes down on rings this far apart, SPAWN_RINGS of them, from as near its middle as asked.
local SPAWN_RING_STEP = 5
local SPAWN_RINGS = 8
-- A beacon site needs room to move: this many of the 8 directions round it have to be open for this far to the first
-- unit it makes (roster.luau's `first_unit`), or whatever it made would be stranded on the spot it appeared. It is short
-- enough for a small island.
local BEACON_OPEN_DIRECTIONS = 3
local BEACON_PROBE_LENGTH = 40

-- The beacon that stands on the land, and the one that floats on the sea: the defs whose role is "beacon".
local function find_beacons(): { land: EntityDef, sea: EntityDef }
	local land: EntityDef? = nil
	local sea: EntityDef? = nil
	for _, def in unit_defs.defs do
		if unit_defs.is_beacon(def) then
			if unit_defs.floats(def) then
				sea = def
			else
				land = def
			end
		end
	end
	assert(land ~= nil and sea ~= nil, "the scavengers need a beacon for the land and one for the sea")
	return table.freeze({ land = land, sea = sea })
end
local BEACONS = find_beacons()

local function is_scavenger(entity: Entity): boolean
	return entity.team == teams.SCAVENGER
end

-- The beacon def for the sea, or for the land.
local function beacon_def(sea: boolean): EntityDef
	return if sea then BEACONS.sea else BEACONS.land
end

-- Whether something that walks could get away from `center`: enough of the directions round it are open.
local function has_room_to_roam(center: Vector3, sea: boolean): boolean
	local probe = roster.first_unit(sea)
	local open_directions = 0
	for step = 0, 7 do
		local angle = step * (math.pi / 4)
		local to = center + Vector3.new(math.cos(angle), 0, math.sin(angle)) * BEACON_PROBE_LENGTH
		if pathfinder.has_straight_path(probe, center, to) then
			open_directions += 1
		end
	end
	return open_directions >= BEACON_OPEN_DIRECTIONS
end

-- Whether `other`, `distance` from a place for a beacon, stands too near it: another beacon within
-- settings.BEACON_SPACING, or anything of a player's within settings.BEACON_PLAYER_CLEARANCE.
local function crowds(other: Entity, distance: number): boolean
	if is_scavenger(other) then
		return unit_defs.is_beacon(other.def) and distance < settings.BEACON_SPACING
	end
	return distance < settings.BEACON_PLAYER_CLEARANCE
end

-- Whether a beacon could stand at `center` without being on top of a player or another beacon, one just made this
-- step, which has not joined the world yet, among them.
local function is_beacon_site_clear(center: Vector3): boolean
	local crowded = false
	local reach = math.max(settings.BEACON_SPACING, settings.BEACON_PLAYER_CLEARANCE)
	spatial.each_present(center, reach, function(other: Entity, distance: number): boolean?
		crowded = crowds(other, distance)
		return crowded
	end)
	if crowded then
		return false
	end
	for _, made in state.pending() do
		if state.is_present(made) and crowds(made, geometry.distance_2d(center, made.position)) then
			return false
		end
	end
	return true
end

-- Where a beacon would stand near (x, z), and whether it is a sea one, if it can stand there at all: on dry level
-- ground, or floating on the sea where there is water at the spot, well away from the players and other beacons, and
-- with room round it for what it makes to get away.
local function beacon_site(x: number, z: number, allow_sea: boolean): (Vector3?, boolean)
	local half_x, half_z = heightmap.half_extents()
	local margin = settings.BEACON_EDGE_MARGIN
	if math.abs(x) > half_x - margin or math.abs(z) > half_z - margin then
		return nil, false
	end
	local sea = allow_sea and heightmap.water_depth(x, z) > 0
	local def_name = beacon_def(sea).name
	local center = placement.resolve_center(def_name, x, z, 0)
	if
		center ~= nil
		and placement.can_place(def_name, center, 0, nil)
		and is_beacon_site_clear(center)
		and has_room_to_roam(center, sea)
	then
		return center, sea
	end
	return nil, false
end

-- Whether anything of anyone's but the scavengers' stands on the map.
local function anything_of_players(): boolean
	return spatial.nearest(Vector3.zero, math.huge, function(other: Entity): boolean
		return is_scavenger(other) == false
	end) ~= nil
end

-- The start box no player has been given that is furthest from everything of the players', by index, if there is one.
local function free_box(): number?
	local taken: { [number]: boolean } = {}
	for _, player in Players:GetPlayers() do
		local index = game_phase.box_of(player)
		if index ~= nil then
			taken[index] = true
		end
	end
	local best: number? = nil
	local best_distance = -1
	for index = 1, starts.box_count() do
		if taken[index] then
			continue
		end
		local box = starts.box(index)
		local middle = (box.min + box.max) / 2
		local at = Vector3.new(middle.X, 0, middle.Y)
		local found = spatial.nearest(at, math.huge, function(other: Entity): boolean
			return is_scavenger(other) == false
		end)
		local nearest = if found ~= nil then geometry.distance_2d(at, found.position) else math.huge
		if nearest > best_distance then
			best = index
			best_distance = nearest
		end
	end
	return best
end

-- Where the first beacon goes in start box `index`: on the land, as near the box's start as it will stand.
local function first_site(index: number): Vector3?
	local box = starts.box(index)
	local spot = starts.default_spot(index)
	return placement.ring_search(
		Vector3.new(spot.X, 0, spot.Y),
		0,
		(box.max - box.min).Magnitude,
		START_SEARCH_STEP,
		rng.stream "scavengers",
		function(x: number, z: number): Vector3?
			return (beacon_site(x, z, false))
		end,
		function(x: number, z: number): boolean
			return starts.in_box(index, x, z)
		end
	)
end

-- The first free place for `def_name` on rings round `around`, no nearer than `start`. Units face away from the
-- middle; a building stays square to the grid.
local function spot_near(def_name: string, around: Vector3, start: number): Spot?
	local building = unit_defs.get(def_name).kind == "building"
	local outer = start + (SPAWN_RINGS - 1) * SPAWN_RING_STEP
	return placement.ring_search(
		around,
		start,
		outer,
		SPAWN_RING_STEP,
		rng.stream "scavengers",
		function(x: number, z: number, angle: number): Spot?
			local facing = if building then 0 else math.atan2(math.cos(angle), math.sin(angle))
			local center = placement.resolve_center(def_name, x, z, facing)
			if center ~= nil and placement.can_place(def_name, center, facing, nil) then
				return { position = center, facing = facing }
			end
			return nil
		end
	)
end

return table.freeze({
	beacon_def = beacon_def,
	beacon_site = beacon_site,
	anything_of_players = anything_of_players,
	free_box = free_box,
	first_site = first_site,
	spot_near = spot_near,
})
