--!strict
-- The ground as both sides keep it: built from the map the server publishes (shared/map_state.luau) and kept up with as
-- it is edited (server/deformation.luau), the same way on each, so that what the server finds can be walked is what a
-- client finds when it lays out a route (shared/order_routes.luau).
--
-- An edit is a flat list of sample index and its new height, `{ index, height, index, height, ... }`, as heightmap
-- keeps them and the server sends them.

local ReplicatedStorage = game:GetService "ReplicatedStorage"

local heightmap = require(ReplicatedStorage.Shared.heightmap)
local map_state = require(ReplicatedStorage.Shared.map_state)
local passability = require(ReplicatedStorage.Shared.passability)
local pathfinder = require(ReplicatedStorage.Shared.pathfinder)
local walls = require(ReplicatedStorage.Shared.walls)

type MapState = map_state.MapState

-- Builds `built`: its heightmap and all laid out on it, and then everything worked out from the ground, afresh.
local function rebuild(built: MapState)
	map_state.apply(built)
	passability.initialize()
	walls.reset()
	pathfinder.reset()
end

-- The cells, first to last each way, whose surface the samples `changes` edit move: a sample moves the four cells
-- around it.
local function edited_cells(changes: { number }): (number, number, number, number)
	local across = heightmap.samples_across()
	local first_x, first_z, last_x, last_z = math.huge, math.huge, -math.huge, -math.huge
	for at = 1, #changes - 1, 2 do
		local sample_x = (changes[at] - 1) % across
		local sample_z = (changes[at] - 1) // across
		first_x = math.min(first_x, sample_x)
		first_z = math.min(first_z, sample_z)
		last_x = math.max(last_x, sample_x)
		last_z = math.max(last_z, sample_z)
	end
	return first_x - 1, first_z - 1, last_x, last_z
end

-- Works out again what can be walked over the cells first to last each way, whose ground has been edited.
local function refresh(first_x: number, first_z: number, last_x: number, last_z: number)
	passability.refresh(first_x, first_z, last_x, last_z)
	pathfinder.refresh(first_x, first_z, last_x, last_z)
end

-- Lays the edits `changes`, made on the other side, onto the ground here and works out again what can be walked where
-- they moved it.
local function apply_edits(changes: { number })
	if #changes == 0 then
		return
	end
	heightmap.apply_heights(changes)
	refresh(edited_cells(changes))
end

return table.freeze({
	rebuild = rebuild,
	edited_cells = edited_cells,
	refresh = refresh,
	apply_edits = apply_edits,
})
