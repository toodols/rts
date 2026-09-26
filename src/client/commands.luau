--!strict
-- What the selection is told by a click or a drag on the map: a right click's order, whatever it lands on, a line of
-- moves, and each mode's click, line and circle (order_modes.luau). Each tells the selected things that can do the job,
-- through `orders`, puts dots down where they were sent, and says whether it gave an order at all.

local ReplicatedStorage = game:GetService "ReplicatedStorage"

local types = require(ReplicatedStorage.Shared.types)
local unit_defs = require(ReplicatedStorage.Shared.unit_defs)
local entity_attrs = require(ReplicatedStorage.Shared.entity_attrs)
local order_kinds = require(ReplicatedStorage.Shared.order_kinds)

local world = require(ReplicatedStorage.Client.world)
local selection = require(ReplicatedStorage.Client.selection)
local cursor = require(ReplicatedStorage.Client.cursor)
local markers = require(ReplicatedStorage.Client.markers)
local events = require(ReplicatedStorage.Client.events)
local orders = require(ReplicatedStorage.Client.orders)
local order_modes = require(ReplicatedStorage.Client.order_modes)
local selected = require(ReplicatedStorage.Client.selected)
local drag_trace = require(ReplicatedStorage.Client.drag_trace)

type EntityId = types.EntityId
type Command = order_kinds.Command
type Queueing = orders.Queueing
type ModeInfo = order_modes.ModeInfo
type Entry = selected.Entry

-- How long the dots stay up after the order has gone out.
local ORDER_MARKER_SECONDS = 1

local function send_move(ids: { EntityId }, positions: { Vector3 }, queueing: Queueing)
	if #ids == 0 then
		return
	end
	orders.send("move", ids, { aim = "spots", positions = positions }, queueing)
	events.moved.fire(ids, positions)
end

-- Gives `ids` an order of `kind` at `target`.
local function send_at(kind: Command, ids: { EntityId }, target: Model, queueing: Queueing)
	local target_id = world.id_of(target)
	if target_id ~= nil then
		orders.send(kind, ids, { aim = "entity", id = target_id }, queueing)
	end
end

-- Sends `ids` to where `target` stands.
local function walk_to(ids: { EntityId }, target: Model, queueing: Queueing)
	local at = world.position_of(target)
	local positions = table.create(#ids, at)
	send_move(ids, positions, queueing)
end

-- Splits `entries` into those that `can` and, of the rest, those that can go.
local function split(entries: { Entry }, can: (Entry) -> boolean): ({ EntityId }, { EntityId })
	local able: { EntityId } = {}
	local walkers: { EntityId } = {}
	for _, entry in entries do
		if can(entry) then
			table.insert(able, entry.id)
		elseif order_modes.can_go(entry.def) then
			table.insert(walkers, entry.id)
		end
	end
	return able, walkers
end

-- Whether a transport of `carrier` can pick `target` up, on an allied side or not (`unit_defs.can_load`).
local function loads(carrier: types.EntityDef, target: Model, allied: boolean): boolean
	local target_def = world.def_of(target)
	local state: types.EntityState? = entity_attrs.state(target)
	if target_def == nil or state == nil then
		return false
	end
	return unit_defs.can_load(carrier, target_def, state, entity_attrs.flag(target, "carried") == true, allied)
end

-- A right click on an enemy's: a transport picks it up if it can (never a commander); everything that can shoot or go
-- attacks it.
local function right_click_enemy(entries: { Entry }, target: Model, queueing: Queueing)
	local loaders: { EntityId } = {}
	local attackers: { EntityId } = {}
	for _, entry in entries do
		if loads(entry.def, target, false) then
			table.insert(loaders, entry.id)
		elseif order_modes.can_go(entry.def) or unit_defs.order_range(entry.def, false) ~= nil then
			table.insert(attackers, entry.id)
		end
	end
	send_at("load", loaders, target, queueing)
	send_at("attack", attackers, target, queueing)
end

-- A right click on something of the selection's own side, or an ally's: a blueprint is helped with by whoever builds,
-- and anything else is guarded, followed or for builders helped, except that a transport takes aboard what it can
-- carry instead. What cannot help walks over.
local function right_click_friend(entries: { Entry }, target: Model, queueing: Queueing)
	local target_id = world.id_of(target)
	if entity_attrs.state(target) == "blueprint" then
		local builders, walkers = split(entries, function(entry: Entry): boolean
			return unit_defs.does(entry.def, "assist")
		end)
		send_at("assist", builders, target, queueing)
		walk_to(walkers, target, queueing)
		return
	end
	local loaders: { EntityId } = {}
	local guards: { EntityId } = {}
	for _, entry in entries do
		if entry.id == target_id then
			continue
		elseif loads(entry.def, target, true) then
			table.insert(loaders, entry.id)
		else
			table.insert(guards, entry.id)
		end
	end
	send_at("load", loaders, target, queueing)
	send_at("guard", guards, target, queueing)
end

-- A right click on `target`: what it means depends on whose side it is on, judged from the first selected thing,
-- which in godmode need not be on the player's own team. Only what can do the job is given it, and the rest walk over.
local function right_click_entity(target: Model, queueing: Queueing)
	local entries = selected.entries(false)
	local first = entries[1]
	if first == nil or world.id_of(target) == nil then
		return
	end
	local side = world.relation(target, first.model)
	if side == "enemy" then
		right_click_enemy(entries, target, queueing)
	elseif side == "own" or side == "ally" then
		right_click_friend(entries, target, queueing)
	elseif world.is_remains(target) then
		-- a wreck, or a rock or tree lying about, is reclaimed by whoever can
		local reclaimers, walkers = split(entries, function(entry: Entry): boolean
			return unit_defs.does(entry.def, "reclaim")
		end)
		send_at("reclaim", reclaimers, target, queueing)
		walk_to(walkers, target, queueing)
	else
		walk_to(selected.ids_of(selected.movers()), target, queueing)
	end
end

-- A right click on the ground: everything that can go goes there.
local function right_click_ground(point: Vector3, queueing: Queueing)
	local ids = selected.ids_of(selected.movers())
	if #ids == 0 then
		return
	end
	local grounded = drag_trace.waypoint_ground(point.X, point.Z)
	markers.flash_points({ grounded }, ORDER_MARKER_SECONDS, "move")
	send_move(ids, table.create(#ids, grounded), queueing)
end

-- A right click: an order at whatever is under the cursor, or a move to the ground there.
local function right_click(queueing: Queueing)
	if selection.count() == 0 then
		return
	end
	local target = cursor.entity()
	if target ~= nil then
		right_click_entity(target, queueing)
		return
	end
	local point = cursor.ground_point()
	if point ~= nil then
		right_click_ground(point, queueing)
	end
end

-- `entries` sent along `path` with an order of `kind`, each to a spot of its own, spread evenly along it in the order
-- they already lie along it so their paths do not cross.
local function send_along(kind: Command, entries: { Entry }, path: { Vector3 }, queueing: Queueing, launch: boolean)
	drag_trace.sort_along(entries, path)
	local positions = drag_trace.formation_points(path, #entries)
	local ids = selected.ids_of(entries)
	markers.flash_points(positions, ORDER_MARKER_SECONDS, kind)
	if kind == "move" then
		send_move(ids, positions, queueing)
	else
		orders.send(kind, ids, { aim = "spots", positions = positions }, queueing, launch)
	end
end

-- A right drag: everything that can go is spread along the shape it traced.
local function move_along(path: { Vector3 }, queueing: Queueing)
	local entries = selected.movers()
	if #entries > 0 then
		send_along("move", entries, path, queueing, false)
	end
end

-- A line dragged out in the mode `info`: those who can take part are spread along it, each given the mode's line
-- order at its own spot.
local function mode_line(info: ModeInfo, path: { Vector3 }, queueing: Queueing): boolean
	local kind: Command? = info.line
	local entries = selected.for_mode(info)
	if kind == nil then
		return false
	elseif #entries == 0 then
		return false
	end
	send_along(kind, entries, path, queueing, info.launch)
	return true
end

-- A circle dragged out in the mode `info`: whoever can take part is given the mode's area order over it, for
-- whatever of the right kind turns up inside it, one thing at a time, until it has nothing left in it.
local function mode_area(info: ModeInfo, center: Vector3, radius: number, queueing: Queueing): boolean
	local kind: Command? = info.area
	local ids = selected.ids_of(selected.for_mode(info))
	if kind == nil then
		return false
	elseif #ids == 0 then
		return false
	end
	markers.flash_points({ center }, ORDER_MARKER_SECONDS, kind)
	orders.send(kind, ids, { aim = "area", position = center, radius = radius }, queueing)
	return true
end

-- The ground under the cursor, where an order to a spot is sent, as the selection would stand on it.
local function spot_under_cursor(): Vector3?
	local point = cursor.ground_point()
	return if point ~= nil then drag_trace.waypoint_ground(point.X, point.Z) else nil
end

-- What a click in the mode `info` by `entries` would land on: an entity, or else a spot on the ground, or neither when
-- the click would do nothing.
-- - "attack": the enemy under the cursor, judged from the first attacker's side, or a wreck, and anything else means
--   the spot on the ground under it;
-- - "spot" and "manual": the ground under the cursor, whatever is on it;
-- - "entity": what is under the cursor, but not what the order may not be aimed at (an enemy, for a guard), nor the one
--   thing that would be given it.
local function aim(info: ModeInfo, entries: { Entry }): (Model?, Vector3?)
	if #entries == 0 then
		return nil, nil
	end
	local target = cursor.entity()
	if target ~= nil and world.id_of(target) == nil then
		target = nil
	end
	if info.click == "attack" then
		if target ~= nil and world.is_attackable(target, entries[1].model) then
			return target, nil
		end
		return nil, spot_under_cursor()
	elseif info.click == "entity" then
		if
			target ~= nil
			and order_kinds.get(info.order).friendly_only
			and world.is_guardable(target, entries[1].model) == false
		then
			return nil, nil
		end
		if target ~= nil and #entries == 1 and entries[1].model == target then
			return nil, nil
		end
		return target, nil
	end
	return nil, spot_under_cursor()
end

-- An "attack" click: the enemy aimed at is attacked, or else the spot on the ground, which is shot at until told
-- otherwise.
local function click_attack(info: ModeInfo, entries: { Entry }, queueing: Queueing): boolean
	local target, spot = aim(info, entries)
	local target_id = if target ~= nil then world.id_of(target) else nil
	local ids = selected.ids_of(entries)
	if target_id ~= nil then
		orders.send(info.order, ids, { aim = "entity", id = target_id }, queueing, info.launch)
		return true
	elseif spot == nil then
		return false
	end
	markers.flash_points({ spot }, ORDER_MARKER_SECONDS, "attack_ground")
	orders.send("attack_ground", ids, { aim = "spot", position = spot }, queueing, info.launch)
	return true
end

-- A "spot" or "manual" click: the mode's order to the ground under the cursor, whatever is on it.
local function click_spot(info: ModeInfo, entries: { Entry }, queueing: Queueing): boolean
	local _, spot = aim(info, entries)
	if spot == nil then
		return false
	end
	markers.flash_points({ spot }, ORDER_MARKER_SECONDS, info.order)
	orders.send(info.order, selected.ids_of(entries), { aim = "spot", position = spot }, queueing, info.launch)
	return true
end

-- An "entity" click: the mode's order at what is aimed at, given by everyone who can but that thing itself.
local function click_entity(info: ModeInfo, entries: { Entry }, queueing: Queueing): boolean
	local target = aim(info, entries)
	local target_id = if target ~= nil then world.id_of(target) else nil
	if target_id == nil then
		return false
	end
	local ids = {}
	for _, entry in entries do
		if entry.id ~= target_id then
			table.insert(ids, entry.id)
		end
	end
	orders.send(info.order, ids, { aim = "entity", id = target_id }, queueing)
	return true
end

local CLICKS: { [order_modes.Click]: (ModeInfo, { Entry }, Queueing) -> boolean } = table.freeze({
	attack = click_attack,
	spot = click_spot,
	manual = click_spot,
	entity = click_entity,
})

-- A click in the mode `info`: those who can take part are given its order, as its `click` says. Says whether they
-- were; a click that finds nobody to send, or nothing to send them at, is just another action.
local function mode_click(info: ModeInfo, queueing: Queueing): boolean
	local entries = selected.for_mode(info)
	if #entries == 0 then
		return false
	end
	return CLICKS[info.click](info, entries, queueing)
end

-- G: everything selected drops all its orders, and anything counting down to destroy itself stops. The server sorts
-- out which of them take orders.
local function stop()
	orders.send("stop", selection.get(), { aim = "none" }, orders.NOW)
end

-- Ctrl+B: everything selected starts counting down to destroy itself, or stops if it already is.
local function self_destruct()
	orders.send("self_destruct", selection.get(), { aim = "none" }, orders.NOW)
end

-- K: every switched shield in the selection (a commander's) goes up, or down if it is up.
local function toggle_shield()
	orders.send("shield", selection.get(), { aim = "none" }, orders.NOW)
end

return table.freeze({
	aim = aim,
	right_click = right_click,
	move_along = move_along,
	mode_click = mode_click,
	mode_line = mode_line,
	mode_area = mode_area,
	stop = stop,
	self_destruct = self_destruct,
	toggle_shield = toggle_shield,
})
