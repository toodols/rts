--!strict
-- The ground that buildings stand on, which nothing walks on: a wall to everything that moves on the ground or the
-- water, as a cliff is to a tank. It is kept apart from the passability maps (which only the ground's shape decides,
-- and which a crater redraws) and read beside them: by movement, which stops or slides a unit at a wall's edge, and
-- by the pathfinder, which routes round one. As in BAR, a building is a wall from the moment its blueprint goes down.
--
-- A cell is a wall while any building covers it, so each cell holds how many do: buildings that share a cell, like a
-- mex built over another, each take their own away when they go. The server marks what its world holds
-- (server/obstacles.luau) and each client what it is shown (client/building_walls.luau), which is every building, so
-- the routes a client works out agree with the server that checks them.
--
-- A cell is a wall when its middle is inside a building's footprint. A unit's middle stops at the edge of those, so it
-- stands with its front a little into the footprint, as it would against anything else it pushed up to.
--
-- `reset` must be called whenever a map is built, since maps are not all the same size. It starts a new generation:
-- a building marked before it is not taken away from the new map's cells when it goes (`remove`).

local ReplicatedStorage = game:GetService "ReplicatedStorage"

local types = require(ReplicatedStorage.Shared.types)
local heightmap = require(ReplicatedStorage.Shared.heightmap)
local geometry = require(ReplicatedStorage.Shared.geometry)
local unit_defs = require(ReplicatedStorage.Shared.unit_defs)

type EntityDef = types.EntityDef

-- The cells a building covers, inclusive, counted from 0 at the map's low corner, and the generation of the map they
-- were marked on.
export type Cells = {
	first_x: number,
	first_z: number,
	last_x: number,
	last_z: number,
	generation: number,
}

local width, depth = heightmap.cells()
local counts = buffer.create(width * depth)
local generation = 0

-- Forgets every wall, and takes the size of the map now, for a map just built.
local function reset()
	width, depth = heightmap.cells()
	counts = buffer.create(width * depth)
	generation += 1
end

-- Every cell whose middle is inside the footprint of something of `def` at `position`, turned by `facing`. None (a
-- last cell before the first) for a footprint that covers no cell's middle.
local function cells_of(def: EntityDef, position: Vector3, facing: number): Cells
	local half = geometry.rotated_half_extents(unit_defs.footprint_half_extents(def), facing)
	local low_x, low_z = heightmap.world_to_grid(position.X - half.X, position.Z - half.Y)
	local high_x, high_z = heightmap.world_to_grid(position.X + half.X, position.Z + half.Y)
	-- cell c's middle is at c + 0.5 on the grid
	return {
		first_x = math.max(0, math.floor(low_x - 0.5) + 1),
		first_z = math.max(0, math.floor(low_z - 0.5) + 1),
		last_x = math.min(width - 1, math.ceil(high_x - 0.5) - 1),
		last_z = math.min(depth - 1, math.ceil(high_z - 0.5) - 1),
		generation = generation,
	}
end

-- Marks `cells` as a wall.
local function add(cells: Cells)
	if cells.generation ~= generation then
		return
	end
	for cz = cells.first_z, cells.last_z do
		for cx = cells.first_x, cells.last_x do
			local at = cz * width + cx
			buffer.writeu8(counts, at, math.min(255, buffer.readu8(counts, at) + 1))
		end
	end
end

-- Takes away a wall `add` marked. Returns whether the cells were this map's, and so whether anything changed.
local function remove(cells: Cells): boolean
	if cells.generation ~= generation then
		return false
	end
	for cz = cells.first_z, cells.last_z do
		for cx = cells.first_x, cells.last_x do
			local at = cz * width + cx
			buffer.writeu8(counts, at, math.max(0, buffer.readu8(counts, at) - 1))
		end
	end
	return true
end

-- Whether cell (cx, cz), which is on the map, is a wall.
local function blocked_cell(cx: number, cz: number): boolean
	return buffer.readu8(counts, cz * width + cx) > 0
end

-- Whether the point (x, z) in the world is on a wall. Off the map is not: the map's edge is the ground's business.
local function blocked_at(x: number, z: number): boolean
	local gx, gz = heightmap.world_to_grid(x, z)
	local cx = math.floor(gx)
	local cz = math.floor(gz)
	if cx < 0 or cx >= width or cz < 0 or cz >= depth then
		return false
	end
	return buffer.readu8(counts, cz * width + cx) > 0
end

-- Every wall as it stands, and the generation of the map they were marked on, for what keeps the game (server/snapshot);
-- and every wall put back as they were kept, on a map of the same size.
export type Kept = { counts: buffer, generation: number }
local function kept(): Kept
	return { counts = counts, generation = generation }
end
local function put_back(saved: Kept)
	assert(buffer.len(saved.counts) == width * depth, "walls kept on a map of another size")
	counts = saved.counts
	generation = saved.generation
end

return table.freeze({
	reset = reset,
	kept = kept,
	put_back = put_back,
	cells_of = cells_of,
	add = add,
	remove = remove,
	blocked_cell = blocked_cell,
	blocked_at = blocked_at,
})
