-- Putting a team's starting force on the map: its commander beside the team's start position.

local ReplicatedStorage = game:GetService "ReplicatedStorage"

local types = require(ReplicatedStorage.Shared.types)
local heightmap = require(ReplicatedStorage.Shared.heightmap)
local starts = require(ReplicatedStorage.Shared.starts)

local state = require(script.Parent.state)
local placement = require(script.Parent.placement)

type TeamId = types.TeamId

local function start_position(team_id: TeamId): Vector3
	local center = starts.center(team_id)
	return heightmap.ground_position(center.X, center.Y)
end

-- Places an entity at the first free spot spiralling out from `around`.
local function spawn_near(def_name: string, team_id: TeamId, around: Vector3, facing: number): types.Entity?
	for ring = 0, 12 do
		for step = 0, math.max(1, ring * 6) - 1 do
			local angle = step * (math.pi * 2 / math.max(1, ring * 6))
			local x = around.X + math.cos(angle) * ring * 6
			local z = around.Z + math.sin(angle) * ring * 6
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

-- Returns whether the commander was placed.
local function give_starting_force(team_id: TeamId): boolean
	local origin = start_position(team_id)
	-- face back toward the middle of the map
	local facing = math.atan2(-origin.X, -origin.Z)
	return spawn_near("commander", team_id, origin, facing) ~= nil
end

return table.freeze({
	give_starting_force = give_starting_force,
	spawn_near = spawn_near,
})
