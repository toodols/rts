-- Entities that are walls. Everything else that stands only pushes units away from it (movement's separation), which a
-- unit set on getting by can push through; the ground under one of these is instead marked in every passability map as
-- ground nothing can stand on, just as a cliff is, so movement stops or slides a unit at its edge and the pathfinder
-- routes round it, or up to it when there is no way round. When it goes, the ground under it is worked out again from
-- the heightmap. Only the server's maps know: a client's route through one is refused (commands' with_route) and the
-- unit walks up to it.
--
-- Which defs are walls is WALLS below; a mission that puts one down calls `add`. Craters redraw the passability of the
-- cells they touch, so `restamp` puts the walls back after (deformation.flush).

local ReplicatedStorage = game:GetService "ReplicatedStorage"

local types = require(ReplicatedStorage.Shared.types)
local unit_defs = require(ReplicatedStorage.Shared.unit_defs)
local heightmap = require(ReplicatedStorage.Shared.heightmap)
local geometry = require(ReplicatedStorage.Shared.geometry)
local passability = require(ReplicatedStorage.Shared.passability)
local pathfinder = require(ReplicatedStorage.Shared.pathfinder)

type Entity = types.Entity
type EntityId = types.EntityId

-- The cells a wall stands on, inclusive, counted from 0 at the map's low corner.
type Cells = {
	first_x: number,
	first_z: number,
	last_x: number,
	last_z: number,
}

-- The defs that are walls.
local WALLS: { [string]: boolean } = {
	tutorial_boulder = true,
}

-- Every slope class anything has, so that every passability map is marked.
local SLOPE_CLASSES: { string } = {}
do
	local seen: { [string]: boolean } = {}
	for _, def in unit_defs.defs do
		local class = def.slope_class
		if class ~= nil and seen[class] == nil then
			seen[class] = true
			table.insert(SLOPE_CLASSES, class)
		end
	end
end

-- The walls standing, by entity id, with the cells each covers.
local standing: { [EntityId]: Cells } = {}

-- Every cell whose middle is inside `entity`'s footprint. A unit's middle stops at the edge of those, so it stands with
-- its front a little into the footprint, as it would against anything else it pushed up to; and something that reaches
-- from its face to its middle, like a commander's disintegrator, can.
local function cells_of(entity: Entity): Cells
	local half =
		geometry.rotated_half_extents(unit_defs.footprint_half_extents(unit_defs.get(entity.def_name)), entity.facing)
	local low_x, low_z = heightmap.world_to_grid(entity.position.X - half.X, entity.position.Z - half.Y)
	local high_x, high_z = heightmap.world_to_grid(entity.position.X + half.X, entity.position.Z + half.Y)
	local cells_x, cells_z = heightmap.cells()
	-- cell c's middle is at c + 0.5 on the grid
	return {
		first_x = math.max(0, math.floor(low_x - 0.5) + 1),
		first_z = math.max(0, math.floor(low_z - 0.5) + 1),
		last_x = math.min(cells_x - 1, math.ceil(high_x - 0.5) - 1),
		last_z = math.min(cells_z - 1, math.ceil(high_z - 0.5) - 1),
	}
end

-- Marks `cells` as ground nothing can stand on, in every passability map.
local function stamp(cells: Cells)
	for _, class in SLOPE_CLASSES do
		local map = passability.map_for(class) :: passability.PassabilityMap
		for cz = cells.first_z, cells.last_z do
			for cx = cells.first_x, cells.last_x do
				buffer.writeu8(map.cells, cz * map.width + cx, 0)
			end
		end
	end
end

-- Whether `def_name` is a wall.
local function is_wall(def_name: string): boolean
	return WALLS[def_name] == true
end

-- Makes `entity`, which stands where it is for good, a wall, if its def is one. Returns whether it is.
local function add(entity: Entity): boolean
	if is_wall(entity.def_name) == false then
		return false
	end
	local cells = cells_of(entity)
	standing[entity.id] = cells
	stamp(cells)
	pathfinder.refresh(cells.first_x, cells.first_z, cells.last_x, cells.last_z)
	return true
end

-- Puts every wall back into the passability maps, after they have been worked out again from the heightmap. The caller
-- refreshes the pathfinder over what it redrew.
local function restamp()
	for _, cells in standing do
		stamp(cells)
	end
end

-- The entity `id` is gone: if it was a wall, the ground under it is worked out again from the heightmap.
local function forget(id: EntityId)
	local cells = standing[id]
	if cells == nil then
		return
	end
	standing[id] = nil
	passability.refresh(cells.first_x, cells.first_z, cells.last_x, cells.last_z)
	-- a wall beside it may share a cell
	restamp()
	pathfinder.refresh(cells.first_x, cells.first_z, cells.last_x, cells.last_z)
end

-- Whether any cell under `entity` is still marked as a wall.
local function blocks(entity_id: EntityId): boolean
	return standing[entity_id] ~= nil
end

return table.freeze({
	is_wall = is_wall,
	add = add,
	restamp = restamp,
	forget = forget,
	blocks = blocks,
})
