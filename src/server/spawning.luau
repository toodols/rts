-- Putting a team's starting force on the map: its commander beside the team's start position, where its player chose
-- to start (see lobby.luau), or the start numbered the same as the team for a team nobody chose one for.

local ReplicatedStorage = game:GetService "ReplicatedStorage"

local types = require(ReplicatedStorage.Shared.types)
local config = require(ReplicatedStorage.Shared.config)
local geometry = require(ReplicatedStorage.Shared.geometry)
local heightmap = require(ReplicatedStorage.Shared.heightmap)
local starts = require(ReplicatedStorage.Shared.starts)
local unit_defs = require(ReplicatedStorage.Shared.unit_defs)

local state = require(script.Parent.state)
local placement = require(script.Parent.placement)

type TeamId = types.TeamId

-- Where each team's player chose to start, as (x, z).
local start_by_team: { [TeamId]: Vector2 } = {}

local function set_start(team_id: TeamId, at: Vector2)
	start_by_team[team_id] = at
end

local function start_position(team_id: TeamId): Vector3
	local center = start_by_team[team_id] or starts.center(team_id)
	return heightmap.ground_position(center.X, center.Y)
end

-- Places an entity at the first free spot spiralling out from `around`: of those `allowed` allows, if it is given, which
-- is asked of each spot's (x, z).
local function spawn_near(
	def_name: string,
	team_id: TeamId,
	around: Vector3,
	facing: number,
	allowed: ((x: number, z: number) -> boolean)?
): types.Entity?
	-- a building only stands on the building grid, so each place tried is moved onto it
	local def = unit_defs.get(def_name)
	local half = geometry.rotated_half_extents(unit_defs.footprint_half_extents(def), facing)
	for ring = 0, 12 do
		for step = 0, math.max(1, ring * 6) - 1 do
			local angle = step * (math.pi * 2 / math.max(1, ring * 6))
			local x = around.X + math.cos(angle) * ring * 6
			local z = around.Z + math.sin(angle) * ring * 6
			if def.kind == "building" then
				x, z = geometry.snap_center(x, z, half, config.CELL_STUDS)
			end
			if allowed ~= nil and allowed(x, z) == false then
				continue
			end
			local center = placement.ground_center(def_name, x, z)
			local placeable = placement.can_place(def_name, center, facing, nil)
			if placeable then
				local entity = state.create_entity(def_name, team_id, center, facing, "active")
				-- publish immediately so the next unit in the starting force sees it as occupied
				state.flush()
				return entity
			end
		end
	end
	return nil
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
	return spawn_near("commander", team_id, origin, facing) ~= nil
end

return table.freeze({
	set_start = set_start,
	give_starting_force = give_starting_force,
	owns_anything = owns_anything,
	spawn_near = spawn_near,
})
