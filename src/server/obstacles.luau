--!strict
-- Buildings are walls (shared/walls.luau): the ground under one is ground nothing walks on, from the moment its
-- blueprint goes down until it is gone, so movement stops or slides a unit at its edge and the pathfinder routes round
-- it, or up to it when there is no way round. Everything else that stands only pushes units away from it (movement's
-- separation), which a unit set on getting by can push through.
--
-- Once `init` has been called, each building is marked as it is made (`state.on_created`), and it is taken away as it
-- is forgotten (`forget`, which the server hands to `state.on_forget`, bootstrap.luau). The pathfinder works out again
-- the ground round each one as it comes and goes.

local ReplicatedStorage = game:GetService "ReplicatedStorage"

local types = require(ReplicatedStorage.Shared.types)
local walls = require(ReplicatedStorage.Shared.walls)
local pathfinder = require(ReplicatedStorage.Shared.pathfinder)

local state = require(script.Parent.state)

type Entity = types.Entity
type EntityId = types.EntityId

-- The walls standing, by entity id, with the cells each covers.
local standing: { [EntityId]: walls.Cells } = {}

-- Makes `entity` a wall if it is a building.
local function add(entity: Entity)
	if entity.kind ~= "building" or standing[entity.id] ~= nil then
		return
	end
	local cells = walls.cells_of(entity.def, entity.position, entity.facing)
	standing[entity.id] = cells
	walls.add(cells)
	pathfinder.refresh(cells.first_x, cells.first_z, cells.last_x, cells.last_z)
end

-- The entity `id` is gone: if it was a wall, the ground under it is open again, unless another wall shares it.
local function forget(id: EntityId)
	local cells = standing[id]
	if cells == nil then
		return
	end
	standing[id] = nil
	if walls.remove(cells) then
		pathfinder.refresh(cells.first_x, cells.first_z, cells.last_x, cells.last_z)
	end
end

-- Whether `entity_id` is standing as a wall.
local function blocks(entity_id: EntityId): boolean
	return standing[entity_id] ~= nil
end

-- Stands every building up as a wall as it is created; each is taken down as it is forgotten (`forget`).
local function init()
	state.on_created(add)
end

return table.freeze({
	init = init,
	forget = forget,
	blocks = blocks,
})
