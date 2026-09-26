--!strict
-- Marks every building the client is shown as a wall (shared/walls.luau), as the server marks its own
-- (server/obstacles.luau), and takes it away when its model goes. Every building is shown to every client, so the
-- routes worked out here (client/orders.luau) go round the same buildings the server checks them against
-- (shared/order_routes.luau).
-- They are all marked again on a map just built (map_events).

local ReplicatedStorage = game:GetService "ReplicatedStorage"

local types = require(ReplicatedStorage.Shared.types)
local entity_attrs = require(ReplicatedStorage.Shared.entity_attrs)
local walls = require(ReplicatedStorage.Shared.walls)
local pathfinder = require(ReplicatedStorage.Shared.pathfinder)

local world = require(ReplicatedStorage.Client.world)
local map_events = require(ReplicatedStorage.Client.map_events)

type EntityId = types.EntityId

-- The buildings marked, with the cells each covers.
local marked: { [Model]: walls.Cells } = {}

-- Marks `model` as a wall, if it is a building's (not its wreck's). It is where the server put it, by its pivot,
-- turned as it is.
local function mark(model: Model)
	if marked[model] ~= nil or entity_attrs.kind(model) ~= "building" then
		return
	end
	local def = world.def_of(model)
	if def == nil then
		return
	end
	local pivot = model:GetPivot()
	local _, facing = pivot:ToOrientation()
	local cells = walls.cells_of(def, pivot.Position, facing)
	marked[model] = cells
	walls.add(cells)
	pathfinder.refresh(cells.first_x, cells.first_z, cells.last_x, cells.last_z)
end

local function unmark(model: Model, _id: EntityId)
	local cells = marked[model]
	if cells == nil then
		return
	end
	marked[model] = nil
	if walls.remove(cells) then
		pathfinder.refresh(cells.first_x, cells.first_z, cells.last_x, cells.last_z)
	end
end

-- Marks every building still shown again, on a map just built (after `walls.reset`).
local function rebuild()
	local shown: { Model } = {}
	for model in marked do
		table.insert(shown, model)
	end
	table.clear(marked)
	for _, model in shown do
		if model.Parent ~= nil then
			mark(model)
		end
	end
end

local function init()
	world.subscribe_listed(mark)
	world.subscribe_removed(unmark)
	map_events.on_rebuilt(rebuild)
	for _, model in world.all() do
		mark(model)
	end
end

return table.freeze({
	init = init,
})
