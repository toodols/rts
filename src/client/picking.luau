--!strict
-- Choosing what is selected with the mouse and keys: a click on one of your things, a box dragged over them, everything
-- on screen of the same kind as what is selected (Q), or your commanders in turn (Tab). Only your own things can be
-- selected, and a spectator's anything on a team (world.is_selectable).
-- What the mouse selects is told on the events bus as it happens.

local ReplicatedStorage = game:GetService "ReplicatedStorage"
local Workspace = game:GetService "Workspace"

local types = require(ReplicatedStorage.Shared.types)
local entity_attrs = require(ReplicatedStorage.Shared.entity_attrs)

local world = require(ReplicatedStorage.Client.world)
local selection = require(ReplicatedStorage.Client.selection)
local cursor = require(ReplicatedStorage.Client.cursor)
local events = require(ReplicatedStorage.Client.events)
local camera_mod = require(ReplicatedStorage.Client.camera)
local command_state = require(ReplicatedStorage.Client.command_state)

type EntityId = types.EntityId
type Rect = command_state.Rect

-- What a box takes of a mix, the highest first: armed units, then unarmed units, then buildings.
local ARMED, UNARMED, BUILDING = 3, 2, 1

-- How `model` ranks in a box, or nil if a box does not take it: only your own units and buildings (a spectator's, any
-- on a team), and not what a transport is carrying. A blueprint ranks as whatever it will become.
local function box_rank(model: Model): number?
	local kind = entity_attrs.kind(model)
	if world.is_selectable(model) == false or (kind ~= "unit" and kind ~= "building") then
		return nil
	end
	if entity_attrs.flag(model, "carried") == true then
		return nil
	end
	local def = world.def_of(model)
	return if kind == "building" then BUILDING elseif def ~= nil and def.weapons ~= nil then ARMED else UNARMED
end

-- What a box over `rect` on the screen takes. A box that catches a mix takes only the highest kind of thing in it, so
-- sweeping over an army does not sweep up its construction bots or the base behind them; `take_all` (shift) takes
-- everything.
local function in_box(rect: Rect, take_all: boolean): { EntityId }
	local camera = Workspace.CurrentCamera
	if camera == nil then
		return {}
	end
	local ids: { EntityId } = {}
	local by_rank: { { EntityId } } = { {}, {}, {} }
	for _, model in world.all() do
		local rank = box_rank(model)
		local id = world.id_of(model)
		if rank == nil or id == nil then
			continue
		end
		local point, on_screen = camera:WorldToViewportPoint(world.position_of(model))
		if
			on_screen
			and point.X >= rect.min.X
			and point.X <= rect.max.X
			and point.Y >= rect.min.Y
			and point.Y <= rect.max.Y
		then
			table.insert(ids, id)
			table.insert(by_rank[rank], id)
		end
	end
	if take_all then
		return ids
	end
	for rank = ARMED, BUILDING, -1 do
		if #by_rank[rank] > 0 then
			return by_rank[rank]
		end
	end
	return {}
end

-- A box let go: what it takes becomes the selection, or with `adding` (shift) joins it.
local function select_box(rect: Rect, adding: boolean)
	local ids = in_box(rect, adding)
	if adding then
		selection.add(ids)
	else
		selection.set(ids)
	end
	events.selected.fire("box", ids)
end

-- A click: what is under the cursor becomes the selection, or with `adding` (shift) joins it or leaves it again. A
-- click on anything that is not yours is a click on empty ground, which clears the selection, unless adding.
local function select_click(adding: boolean)
	local target = cursor.entity()
	if target ~= nil and world.is_selectable(target) == false then
		target = nil
	end
	if target == nil then
		if adding == false then
			selection.clear()
		end
		return
	end
	local id = world.id_of(target)
	if id == nil then
		return
	end
	if adding then
		selection.toggle(id)
	else
		selection.set({ id })
	end
	events.selected.fire("click", { id })
end

-- Everything of yours on the screen, or for `whole_map` anywhere, that is the same kind of thing as anything selected.
-- A selection of one grunt becomes every grunt in view, and a mix of grunts and construction bots every grunt and
-- construction bot in view. Blueprints count as what they will become.
local function select_same_type(whole_map: boolean?)
	local camera = Workspace.CurrentCamera
	if camera == nil then
		return
	end
	local wanted: { [string]: boolean } = {}
	for _, id in selection.get() do
		local model = world.get(id)
		local def_name = if model ~= nil then entity_attrs.def_name(model) else nil
		if def_name ~= nil then
			wanted[def_name] = true
		end
	end
	local ids = {}
	for _, model in world.all() do
		local def_name = entity_attrs.def_name(model)
		local id = world.id_of(model)
		if id == nil or def_name == nil or wanted[def_name] ~= true then
			continue
		end
		if world.is_selectable(model) == false or world.is_remains(model) then
			continue
		end
		if whole_map == true or select(2, camera:WorldToViewportPoint(world.position_of(model))) then
			table.insert(ids, id)
		end
	end
	if #ids > 0 then
		selection.set(ids)
	end
end

-- Tab: selects your commander and pans the view to it. With several, each press moves on to the next in id order,
-- wrapping round after the last; with none of them selected it starts at the first.
local function cycle_commander()
	local commanders = world.my_commanders()
	if #commanders == 0 then
		return
	end
	local next_index = 1
	for index, commander in commanders do
		if selection.contains(world.id_of(commander) :: EntityId) then
			next_index = index % #commanders + 1
			break
		end
	end
	local chosen = commanders[next_index]
	selection.set({ world.id_of(chosen) :: EntityId })
	camera_mod.look_at(world.position_of(chosen))
end

return table.freeze({
	cycle_commander = cycle_commander,
	select_box = select_box,
	select_click = select_click,
	select_same_type = select_same_type,
})
