-- Mouse and keyboard command handling.
--
-- Left button:
--   click on empty ground          clears the selection
--   click on an entity             selects exactly that entity
--   shift-click on an entity       adds it to, or removes it from, the selection
--   drag                           box-selects your own units, shift keeps the existing selection
--   click while placing a building confirms the placement
--
-- Right button:
--   click on ground                move there
--   click on an entity            attack, reclaim or assist depending on what it is
--
-- In fight and unload mode the left button can also be dragged, and the units are spread
-- along the shape they trace the way a right-drag spreads a move.
-- In attack, reclaim, repair, and resurrect mode the left button can instead be dragged out into a
-- circle: every unit that can do the job is sent an area order for whatever of the right kind turns up
-- inside it, one thing at a time, going back to the area order once each is done, until the circle has
-- nothing left in it.
-- Attack mode (A) sends the next left click as an attack: on an enemy it attacks that enemy, and anywhere
-- else it attacks that spot on the ground and keeps shooting at it. Fight mode (F) sends it as a fight
-- waypoint: the units walk there, stopping to shoot whatever they can on the way. Unload mode (U) sends it as an
-- unload order: the units go there and drop what they carry. A move needs no mode of its own to find its way: the
-- server works out a route for each unit round whatever it cannot cross, and gives it the waypoints of the way.
-- G stops: every selected unit drops all its orders.
--   drag a line                   spread the selection evenly along the shape the drag traces
--   shift                         queues the order instead of replacing the queue
--   click while placing a building cancels placement
--
-- A factory's build orders always queue, shift or not, so they never go through here.

local ContextActionService = game:GetService "ContextActionService"
local ReplicatedStorage = game:GetService "ReplicatedStorage"
local RunService = game:GetService "RunService"
local UserInputService = game:GetService "UserInputService"
local Workspace = game:GetService "Workspace"

local types = require(ReplicatedStorage.Shared.types)
local config = require(ReplicatedStorage.Shared.config)
local unit_defs = require(ReplicatedStorage.Shared.unit_defs)
local heightmap = require(ReplicatedStorage.Shared.heightmap)
local geometry = require(ReplicatedStorage.Shared.geometry)

local world = require(ReplicatedStorage.Client.world)
local camera_mod = require(ReplicatedStorage.Client.camera)
local selection = require(ReplicatedStorage.Client.selection)
local build_mode = require(ReplicatedStorage.Client.build_mode)
local markers = require(ReplicatedStorage.Client.markers)
local routes = require(ReplicatedStorage.Client.routes)

type EntityId = types.EntityId

type DragRect = {
	min: Vector2,
	max: Vector2,
}

local issue_order: RemoteEvent = ReplicatedStorage.Shared.IssueOrder
local place_blueprint: RemoteEvent = ReplicatedStorage.Shared.PlaceBlueprint

-- How long the dots stay up after the order has gone out.
local ORDER_MARKER_SECONDS = 1

-- Set while a manual weapon is aimed: the next left click fires it instead of selecting.
local manual_aiming = false
-- Set to "attack", "fight", "reclaim", "repair", "guard", "resurrect", "load" or "unload" while that mode is on: the next left click on an entity sends
-- the selected units that can do it at that entity, in attack mode a click on the ground attacks that spot, and
-- in fight mode a click sends them to fight their way to it.
local target_mode: string? = nil

local left_down_at: Vector2? = nil
-- Set while a building is being dragged out with shift held: where the line or grid starts.
local placing_from: Vector3? = nil
local right_down_world: Vector3? = nil
-- Where the left button went down in a location-based mode (attack, fight, path, unload): letting go on
-- the same spot is the click, and letting go further off is a line of them.
local mode_drag_from: Vector3? = nil
-- The same, but for the right button: a plain right click still cancels the mode, but dragging lays
-- the same line of orders down instead of cancelling.
local right_mode_drag_from: Vector3? = nil
-- Where the left button went down in an area mode (reclaim, repair, resurrect, attack): letting go on
-- the same spot is the click, and dragging out from it draws a circle instead, centred there.
local area_drag_from: Vector3? = nil
local drag_rect: DragRect? = nil
local rect_listeners: { (rect: DragRect?) -> () } = {}
local mode_listeners: { (mode: string?) -> () } = {}
local hover_listeners: { (id: EntityId?) -> () } = {}
local reported_hover: EntityId? = nil
local reported_mode: string? = nil

local function subscribe_rect(listener: (rect: DragRect?) -> ()): () -> ()
	table.insert(rect_listeners, listener)
	return function()
		local index = table.find(rect_listeners, listener)
		if index ~= nil then
			table.remove(rect_listeners, index)
		end
	end
end

-- Tells `listener` whenever the mode the cursor is in changes: "attack", "fight", "reclaim", "repair", "guard", "resurrect", "load", "unload" or "disintegrator"
-- while one is on, and nil otherwise.
local function subscribe_mode(listener: (mode: string?) -> ()): () -> ()
	table.insert(mode_listeners, listener)
	return function()
		local index = table.find(mode_listeners, listener)
		if index ~= nil then
			table.remove(mode_listeners, index)
		end
	end
end

-- Tells `listener` which entity the cursor is over, whoever it belongs to, and nil when it is over none. It
-- is for the HUD to say what something is; nothing about what a click does depends on it.
local function subscribe_hover(listener: (id: EntityId?) -> ()): () -> ()
	table.insert(hover_listeners, listener)
	return function()
		local index = table.find(hover_listeners, listener)
		if index ~= nil then
			table.remove(hover_listeners, index)
		end
	end
end

local function set_rect(rect: DragRect?)
	drag_rect = rect
	for _, listener in rect_listeners do
		listener(rect)
	end
end

local function mouse_ray(): Ray?
	local camera = Workspace.CurrentCamera
	if camera == nil then
		return nil
	end
	local location = UserInputService:GetMouseLocation()
	return camera:ViewportPointToRay(location.X, location.Y)
end

-- Where the cursor meets the ground. It comes from the heightmap, not from casting a ray at the world:
-- placing a building, ordering a move or aiming a weapon should not depend on what happens to be
-- under the cursor, and whether an action succeeds is a matter of range alone.
local GROUND_RAY_LENGTH = 3000

local function ground_point(): Vector3?
	local ray = mouse_ray()
	if ray == nil then
		return nil
	end
	return heightmap.ray_to_ground(ray.Origin, ray.Direction, GROUND_RAY_LENGTH)
end

local function entity_under_mouse(): Model?
	local ray = mouse_ray()
	if ray == nil then
		return nil
	end
	local params = RaycastParams.new()
	params.FilterType = Enum.RaycastFilterType.Include
	params.FilterDescendantsInstances = { world.container() }
	local result = Workspace:Raycast(ray.Origin, ray.Direction * 5000, params)
	if result == nil then
		return nil
	end
	return world.from_instance(result.Instance)
end

local function shift_held(): boolean
	return UserInputService:IsKeyDown(Enum.KeyCode.LeftShift) or UserInputService:IsKeyDown(Enum.KeyCode.RightShift)
end

local function alt_held(): boolean
	return UserInputService:IsKeyDown(Enum.KeyCode.LeftAlt) or UserInputService:IsKeyDown(Enum.KeyCode.RightAlt)
end

-- Where a waypoint at (x, z) sits for what is selected: on the water's surface if a selected unit that
-- moves floats there, and on the ground otherwise, so a ship's path is drawn on the sea and not on the sea
-- floor beneath it.
local function waypoint_ground(x: number, z: number): Vector3
	for _, id in selection.get() do
		local model = world.get(id)
		local def_name = if model ~= nil then model:GetAttribute "def_name" else nil
		local def = if typeof(def_name) == "string" then unit_defs.defs[def_name] else nil
		if def ~= nil and def.max_speed ~= nil and unit_defs.floats(def) then
			return unit_defs.surface_position(def, x, z)
		end
	end
	return heightmap.ground_position(x, z)
end

-- The ground the cursor has passed over in the drag going on now, from where it began: the shape a line of orders is
-- spread along, however it winds. A point is added once the cursor is TRACE_STEP studs on from the last one.
local TRACE_STEP = 1
local drag_trace: { Vector3 } = {}

local function begin_trace(point: Vector3?)
	drag_trace = if point ~= nil then { point } else {}
end

local function extend_trace()
	local last = drag_trace[#drag_trace]
	local point = ground_point()
	if last ~= nil and point ~= nil and geometry.distance_2d(last, point) >= TRACE_STEP then
		table.insert(drag_trace, point)
	end
end

-- How far along the ground `path` runs, however it winds. For a drag it is what decides whether it is a line or
-- only a click, so a drag that comes back round to where it began is still a line.
local function path_length(path: { Vector3 }): number
	local length = 0
	for index = 2, #path do
		length += geometry.distance_2d(path[index - 1], path[index])
	end
	return length
end

-- Whether `path` has gone far enough to be a line of orders rather than a click.
local function is_line(path: { Vector3 }): boolean
	return #path >= 2 and path_length(path) >= config.FORMATION_DRAG_THRESHOLD
end

-- The trace as it stands when the button comes up, taken on to wherever the cursor let go, and cleared for the
-- next drag.
local function finish_trace(): { Vector3 }
	local path = drag_trace
	drag_trace = {}
	markers.hide_trace()
	local last = path[#path]
	local point = ground_point()
	if last ~= nil and point ~= nil and geometry.distance_2d(last, point) > 1e-3 then
		table.insert(path, point)
	end
	return path
end

-- Where a drag along `path` would put `count` units: spread evenly along it and dropped onto the ground. The
-- preview drawn during the drag and the order sent when it ends both come from here, so what is shown is what
-- is ordered.
local function formation_points(path: { Vector3 }, count: number): { Vector3 }
	local points = geometry.points_along_path(path, count)
	local grounded = table.create(count)
	for index, point in points do
		grounded[index] = waypoint_ground(point.X, point.Z)
	end
	return grounded
end

-- Puts `entries` in the order they lie along the way from the start of `path` to its end, so that giving the
-- first one the first point, the next the next, and so on, does not send their paths across each other.
local function sort_along(entries: { { id: EntityId, model: Model, def: types.EntityDef } }, path: { Vector3 })
	local direction = geometry.flatten(path[#path] - path[1])
	direction = if direction.Magnitude < 1e-3 then Vector3.new(1, 0, 0) else direction.Unit
	table.sort(entries, function(a, b)
		return world.position_of(a.model):Dot(direction) < world.position_of(b.model):Dot(direction)
	end)
end

-- Only your own things can be box-selected; wrecks and enemies are skipped. A box that catches a
-- mix takes only the highest kind of thing in it - armed units, then unarmed units, then buildings -
-- so sweeping over an army does not sweep up its construction_bots or the base behind them. A blueprint
-- ranks as whatever it will become. Holding shift (`take_all`) takes everything.
local function box_select(rect: DragRect, take_all: boolean): { EntityId }
	local camera = Workspace.CurrentCamera
	if camera == nil then
		return {}
	end

	local ids = {}
	-- selectable things by rank: 3 armed units, 2 unarmed units, 1 buildings
	local by_rank: { { EntityId } } = { {}, {}, {} }
	for _, model in world.all() do
		if world.is_mine(model) == false then
			continue
		end
		local kind = model:GetAttribute "kind"
		if kind ~= "unit" and kind ~= "building" then
			continue
		end
		if model:GetAttribute "carried" == true then
			continue
		end
		local point, on_screen = camera:WorldToViewportPoint(world.position_of(model))
		if on_screen == false then
			continue
		end
		if point.X < rect.min.X or point.X > rect.max.X then
			continue
		end
		if point.Y < rect.min.Y or point.Y > rect.max.Y then
			continue
		end
		local id = world.id_of(model)
		if id ~= nil then
			table.insert(ids, id)
			local def_name = model:GetAttribute "def_name"
			local def = if typeof(def_name) == "string" then unit_defs.defs[def_name] else nil
			local rank = if kind == "building" then 1 elseif def ~= nil and def.weapons ~= nil then 3 else 2
			table.insert(by_rank[rank], id)
		end
	end
	if take_all then
		return ids
	end
	for rank = 3, 1, -1 do
		if #by_rank[rank] > 0 then
			return by_rank[rank]
		end
	end
	return {}
end

-- Q: selects everything of yours on the screen that is the same kind of thing as anything selected. A
-- selection of one grunt becomes every grunt in view, and a mix of grunts and construction_bots becomes
-- every grunt and construction_bot in view. Blueprints count as what they will become.
local function select_same_type()
	local camera = Workspace.CurrentCamera
	if camera == nil then
		return
	end

	local wanted: { [string]: boolean } = {}
	for _, id in selection.get() do
		local model = world.get(id)
		local def_name = if model ~= nil then model:GetAttribute "def_name" else nil
		if typeof(def_name) == "string" then
			wanted[def_name] = true
		end
	end

	local ids = {}
	for _, model in world.all() do
		local def_name = model:GetAttribute "def_name"
		local id = world.id_of(model)
		if id == nil or typeof(def_name) ~= "string" or wanted[def_name] ~= true then
			continue
		end
		if world.is_mine(model) == false or model:GetAttribute "kind" == "wreck" then
			continue
		end
		local _, on_screen = camera:WorldToViewportPoint(world.position_of(model))
		if on_screen then
			table.insert(ids, id)
		end
	end

	if #ids > 0 then
		selection.set(ids)
	end
end

-- The selected things that can take orders: units, and buildings that work, like a construction
-- turret. An unfinished one takes them just like a finished one and carries them out once it is
-- built. `active_only` drops unfinished ones, for what only a finished one can do, like building or
-- firing a weapon.
local function selected_with_def(active_only: boolean): { { id: EntityId, model: Model, def: types.EntityDef } }
	local result = {}
	for _, id in selection.get() do
		local model = world.get(id)
		if model == nil then
			continue
		end
		if active_only and model:GetAttribute "state" ~= "active" then
			continue
		end
		local def_name = model:GetAttribute "def_name"
		if typeof(def_name) ~= "string" then
			continue
		end
		local def = unit_defs.defs[def_name]
		if def == nil or (unit_defs.takes_orders(def) == false and unit_defs.is_factory(def) == false) then
			continue
		end
		table.insert(result, { id = id, model = model, def = def })
	end
	return result
end

-- Held while giving an order to put it at the front of the queue instead of replacing it.
local function space_held(): boolean
	return UserInputService:IsKeyDown(Enum.KeyCode.Space)
end

local function send_move(ids: { EntityId }, positions: { Vector3 }, queue: boolean)
	if #ids == 0 then
		return
	end
	local front = space_held()
	issue_order:FireServer({
		kind = "move",
		ids = ids,
		positions = positions,
		routes = routes.for_units(ids, "move", function(index: number): Vector3?
			return positions[index]
		end, nil, queue, front),
		queue = queue,
		front = front,
	})
end

local function send_targeted(kind: string, ids: { EntityId }, target_id: EntityId, queue: boolean)
	if #ids == 0 then
		return
	end
	local front = space_held()
	local target = world.get(target_id)
	local at = if target ~= nil then world.position_of(target) else nil
	issue_order:FireServer({
		kind = kind,
		ids = ids,
		target_id = target_id,
		routes = routes.for_units(ids, kind, function(_: number): Vector3?
			return at
		end, nil, queue, front),
		queue = queue,
		front = front,
	})
end

local function send_ground_attack(ids: { EntityId }, point: Vector3, queue: boolean)
	if #ids == 0 then
		return
	end
	local front = space_held()
	issue_order:FireServer({
		kind = "attack_ground",
		ids = ids,
		position = point,
		routes = routes.for_units(ids, "attack_ground", function(_: number): Vector3?
			return point
		end, nil, queue, front),
		queue = queue,
		front = front,
	})
end

-- An order that is to a single point on the ground: "fight" or "dgun".
local function send_point_order(kind: string, ids: { EntityId }, point: Vector3, queue: boolean)
	if #ids == 0 then
		return
	end
	local front = space_held()
	issue_order:FireServer({
		kind = kind,
		ids = ids,
		position = point,
		routes = routes.for_units(ids, kind, function(_: number): Vector3?
			return point
		end, nil, queue, front),
		queue = queue,
		front = front,
	})
end

-- The area order each mode that supports one sends, and the target kind whose colour and worker
-- filter it borrows (an area order works exactly like that single order, just spread over a circle
-- instead of aimed at one thing).
local AREA_KINDS: { [string]: string } = {
	reclaim = "area_reclaim",
	repair = "area_repair",
	resurrect = "area_resurrect",
	attack = "area_attack",
}

local function send_area(mode: string, ids: { EntityId }, center: Vector3, radius: number, queue: boolean)
	if #ids == 0 then
		return
	end
	local front = space_held()
	issue_order:FireServer({
		kind = AREA_KINDS[mode],
		ids = ids,
		position = center,
		radius = radius,
		routes = routes.for_units(ids, AREA_KINDS[mode], function(_: number): Vector3?
			return center
		end, radius, queue, front),
		queue = queue,
		front = front,
	})
end

local function send_unload(ids: { EntityId }, point: Vector3, queue: boolean)
	if #ids == 0 then
		return
	end
	issue_order:FireServer({
		kind = "unload",
		ids = ids,
		position = point,
		queue = queue,
		front = space_held(),
	})
end

-- Whether something can be sent somewhere: what can move, and the labs, whose units go there once they are made.
local function can_go(def: types.EntityDef): boolean
	return def.max_speed ~= nil or unit_defs.is_factory(def)
end

-- Decides what right-clicking `target` means for the current selection, splitting it so that only
-- units that can do the job get the specialised order and the rest simply walk over.
-- The selected things that can move, for anything that sends them somewhere.
local function mobile_entries(): { { id: EntityId, model: Model, def: types.EntityDef } }
	local result = {}
	for _, entry in selected_with_def(false) do
		if can_go(entry.def) then
			table.insert(result, entry)
		end
	end
	return result
end

local function order_on_entity(target: Model, queue: boolean)
	local entries = selected_with_def(false)
	local first = entries[1]
	local target_id = world.id_of(target)
	if target_id == nil or first == nil then
		return
	end
	-- What an order means depends on whose side the target is on, judged from the first selected
	-- unit. That is the player's own team in a normal game; in godmode it can be any team. An ally's
	-- things are treated the same as your own: `ally_group` is the same for every team in an
	-- alliance, itself included, so this catches both without the client needing the alliance graph.
	local own_group = first.model:GetAttribute "ally_group"

	local target_team = target:GetAttribute "team"
	local target_group = target:GetAttribute "ally_group"
	local target_kind = target:GetAttribute "kind"
	local target_state = target:GetAttribute "state"
	local target_position = world.position_of(target)

	local capable: { EntityId } = {}
	local leftover: { EntityId } = {}

	if target_kind ~= "wreck" and target_group ~= own_group and target_team ~= 0 then
		-- a transport picks up an enemy it can carry, a tower or a unit; everything else attacks it
		local target_def_name = target:GetAttribute "def_name"
		local target_def = if typeof(target_def_name) == "string" then unit_defs.defs[target_def_name] else nil
		local ids = {}
		local loaders = {}
		for _, entry in entries do
			if target_def ~= nil and target_state == "active" and unit_defs.can_carry(entry.def, target_def) then
				table.insert(loaders, entry.id)
			elseif can_go(entry.def) or unit_defs.attack_range(entry.def) ~= nil then
				table.insert(ids, entry.id)
			end
		end
		send_targeted("load", loaders, target_id, queue)
		send_targeted("attack", ids, target_id, queue)
		return
	end

	-- a wreck, or a rock or tree lying about, is reclaimed by whoever can
	if target_kind == "wreck" or target_kind == "reclaimable" then
		for _, entry in entries do
			if entry.def.reclaiming then
				table.insert(capable, entry.id)
			else
				if can_go(entry.def) then
					table.insert(leftover, entry.id)
				end
			end
		end
		send_targeted("reclaim", capable, target_id, queue)
	elseif target_group == own_group and target_state == "blueprint" then
		for _, entry in entries do
			if entry.def.assisting then
				table.insert(capable, entry.id)
			else
				if can_go(entry.def) then
					table.insert(leftover, entry.id)
				end
			end
		end
		send_targeted("assist", capable, target_id, queue)
	elseif target_group == own_group then
		-- anything else of yours is guarded: followed, or for builders, helped. A transport takes aboard
		-- what it can carry instead, and guards what it cannot.
		local target_def_name = target:GetAttribute "def_name"
		local target_def = if typeof(target_def_name) == "string" then unit_defs.defs[target_def_name] else nil
		local loaders: { EntityId } = {}
		for _, entry in entries do
			if entry.id == target_id then
				continue
			end
			if target_def ~= nil and unit_defs.can_carry(entry.def, target_def) then
				table.insert(loaders, entry.id)
			else
				table.insert(capable, entry.id)
			end
		end
		send_targeted("load", loaders, target_id, queue)
		send_targeted("guard", capable, target_id, queue)
	else
		for _, entry in entries do
			if can_go(entry.def) then
				table.insert(leftover, entry.id)
			end
		end
	end

	if #leftover > 0 then
		local positions = table.create(#leftover)
		for index = 1, #leftover do
			positions[index] = target_position
		end
		send_move(leftover, positions, queue)
	end
end

-- What a move order goes to: what can move, and the labs, which take it as the place their units go.
local function move_entries(): { { id: EntityId, model: Model, def: types.EntityDef } }
	local result = {}
	for _, id in selection.get() do
		local model = world.get(id)
		local def_name = if model ~= nil then model:GetAttribute "def_name" else nil
		local def = if typeof(def_name) == "string" then unit_defs.defs[def_name] else nil
		if def == nil or model == nil then
			continue
		end
		if (unit_defs.takes_orders(def) and def.max_speed ~= nil) or unit_defs.is_factory(def) then
			table.insert(result, { id = id, model = model, def = def })
		end
	end
	return result
end

-- G: every selected unit forgets all its orders.
local function send_stop()
	local ids = {}
	for _, entry in selected_with_def(false) do
		table.insert(ids, entry.id)
	end
	for _, entry in move_entries() do
		if table.find(ids, entry.id) == nil then
			table.insert(ids, entry.id)
		end
	end
	if #ids == 0 then
		return
	end
	issue_order:FireServer({
		kind = "stop",
		ids = ids,
	})
end

-- Spreads the selection along the dragged path, assigning units to points in the order they
-- already lie along it so their paths do not cross.
local function order_along_trace(path: { Vector3 }, queue: boolean)
	local entries = move_entries()
	if #entries == 0 then
		return
	end
	sort_along(entries, path)

	local positions = formation_points(path, #entries)
	local ids = table.create(#entries)
	for index, entry in entries do
		ids[index] = entry.id
	end

	markers.flash_points(positions, ORDER_MARKER_SECONDS, "move")
	send_move(ids, positions, queue)
end

local function order_at_point(point: Vector3, queue: boolean)
	local entries = move_entries()
	if #entries == 0 then
		return
	end
	local ids = table.create(#entries)
	local positions = table.create(#entries)
	local grounded = waypoint_ground(point.X, point.Z)
	for index, entry in entries do
		ids[index] = entry.id
		positions[index] = grounded
	end
	markers.flash_points({ grounded }, ORDER_MARKER_SECONDS, "move")
	send_move(ids, positions, queue)
end

-- The first selected unit that can build `def_name`, the same one the server treats as the builder
-- for spot-snapping (placement.resolve_center takes only one), so the client's own metal-spot search
-- exempts the same builder's queue that the server's does.
local function primary_builder_id(def_name: string): EntityId?
	for _, entry in selected_with_def(false) do
		if entry.def.build_options ~= nil and table.find(entry.def.build_options, def_name) ~= nil then
			return entry.id
		end
	end
	return nil
end

-- Sends every selected builder to put `def_name` at each of `centers` that fits. They go out in order, or
-- backwards when the orders go on the front of the queue, so the first place ends up first.
local function send_placements(def_name: string, centers: { Vector3 })
	local ids = {}
	for _, entry in selected_with_def(false) do
		if entry.def.build_options ~= nil and table.find(entry.def.build_options, def_name) ~= nil then
			table.insert(ids, entry.id)
		end
	end
	if #ids == 0 then
		return
	end

	local front = space_held()
	local queue = shift_held()
	local facing = build_mode.get_facing()
	local placeable = {}
	for index, center in centers do
		placeable[index] = build_mode.can_place(def_name, center, facing)
	end
	-- each builder's way to each site, worked out in the order they will be built, each from the one before
	local ways: { { { Vector3 } } } = {}
	local starts: { [EntityId]: Vector3? } = {}
	for _, id in ids do
		starts[id] = routes.start_of(id, queue and front == false)
	end
	for index, center in centers do
		if placeable[index] then
			local each = table.create(#ids)
			for position, id in ids do
				local from = starts[id]
				each[position] = if from ~= nil then routes.waypoints(id, from, "build", center, nil) else {}
				starts[id] = center
			end
			ways[index] = each
		end
	end
	local first = if front then #centers else 1
	local last = if front then 1 else #centers
	for index = first, last, if front then -1 else 1 do
		if placeable[index] then
			place_blueprint:FireServer({
				def_name = def_name,
				position = centers[index],
				facing = facing,
				ids = ids,
				routes = ways[index],
				queue = queue,
				front = front,
			})
		end
	end
end

local function confirm_placement()
	local def_name = build_mode.active()
	if def_name == nil then
		return
	end
	local center, valid = build_mode.update(ground_point(), primary_builder_id(def_name))
	if center == nil or valid == false then
		return
	end
	send_placements(def_name, { center })

	-- holding shift keeps placing the same building, matching how build orders chain
	if shift_held() == false then
		build_mode.exit()
	end
end

-- The line or grid a shift-drag has laid out so far, from where it began to where the cursor is.
local function dragged_layout(def_name: string, from: Vector3): { Vector3 }
	local center = build_mode.update(ground_point(), primary_builder_id(def_name))
	if center == nil then
		return { from }
	end
	return build_mode.layout(def_name, from, center, alt_held())
end

-- Ends a shift-drag: everything that fits along the line, or across the grid, is ordered at once.
local function finish_placement_drag()
	local from = placing_from
	placing_from = nil
	local def_name = build_mode.active()
	if from == nil or def_name == nil then
		build_mode.clear_preview()
		return
	end
	send_placements(def_name, dragged_layout(def_name, from))
	build_mode.clear_preview()
	if shift_held() == false then
		build_mode.exit()
	end
end

-- Selected units that have a manual weapon, ready or not.
local function manual_shooters(): { { id: EntityId, model: Model, def: types.EntityDef } }
	local shooters = {}
	for _, entry in selected_with_def(true) do
		if entry.def.manual_weapon ~= nil then
			table.insert(shooters, entry)
		end
	end
	return shooters
end

local function stop_manual_aim()
	manual_aiming = false
	markers.hide_blast()
end

local function start_manual_aim()
	if #manual_shooters() == 0 then
		return
	end
	build_mode.exit()
	target_mode = nil
	manual_aiming = true
end

-- Whether something of this def can do the job of `mode`: attack, which anything that can shoot can, fight,
-- which anything that can move can (what cannot shoot just moves), unload, which a transport can, or a kind
-- of work, which needs buildpower as well.
local function can_do(mode: string, def: types.EntityDef): boolean
	if mode == "attack" then
		return unit_defs.attack_range(def) ~= nil or unit_defs.is_factory(def)
	end
	if mode == "fight" then
		return can_go(def)
	end
	if mode == "guard" then
		return true
	end
	if mode == "unload" or mode == "load" then
		return def.transport ~= nil
	end
	local able = if mode == "repair"
		then def.repairing
		elseif mode == "resurrect" then def.resurrecting
		else def.reclaiming
	return able and def.buildpower ~= nil
end

-- Selected units that can do the job of `mode`: attack, reclaim, repair or resurrect. An unfinished one counts: what
-- it is told waits in its orders until it is done.
local function workers(mode: string): { EntityId }
	local ids = {}
	for _, entry in selected_with_def(false) do
		if can_do(mode, entry.def) then
			table.insert(ids, entry.id)
		end
	end
	return ids
end

-- An area command dragged out in `mode` (reclaim, repair, resurrect or attack): every selected unit
-- that can do the job is sent an area order for the circle at `center`, `radius` studs across. The
-- mode then ends, unless shift is held, which also queues the order and keeps it on.
local function order_area_mode(mode: string, center: Vector3, radius: number)
	local ids = workers(mode)
	if #ids == 0 then
		target_mode = nil
		return
	end
	local queue = shift_held()
	markers.flash_points({ center }, ORDER_MARKER_SECONDS, mode)
	send_area(mode, ids, center, radius, queue)
	if queue == false then
		target_mode = nil
	end
end

local function start_target_mode(mode: string)
	if #workers(mode) == 0 then
		return
	end
	build_mode.exit()
	stop_manual_aim()
	target_mode = mode
end

-- Attack mode's click: an enemy under the cursor is attacked, and anything else means the spot on the
-- ground under it. The mode then ends, unless shift is held, which also queues the order and keeps it on.
local function click_attack_mode()
	local ids = {}
	local first: Model? = nil
	for _, entry in selected_with_def(false) do
		if can_do("attack", entry.def) then
			table.insert(ids, entry.id)
			if first == nil then
				first = entry.model
			end
		end
	end
	if first == nil then
		target_mode = nil
		return
	end

	local queue = shift_held()
	local target = entity_under_mouse()
	local target_id = if target ~= nil then world.id_of(target) else nil
	-- an enemy is judged from the first attacker's side, which in godmode need not be your own; a
	-- wreck is neutral, team 0, same as any other piece of scenery, but is a valid target in its own
	-- right, and an ally is never a valid target at all
	local own_group = first:GetAttribute "ally_group"
	local is_wreck = target ~= nil and target:GetAttribute "kind" == "wreck"
	local is_ally = target ~= nil and target:GetAttribute "ally_group" == own_group
	if target ~= nil and target_id ~= nil and (is_wreck or (is_ally == false and target:GetAttribute "team" ~= 0)) then
		send_targeted("attack", ids, target_id, queue)
	else
		local point = ground_point()
		if point == nil then
			target_mode = nil
			return
		end
		local grounded = waypoint_ground(point.X, point.Z)
		markers.flash_points({ grounded }, ORDER_MARKER_SECONDS, "attack_ground")
		send_ground_attack(ids, grounded, queue)
	end

	if queue == false then
		target_mode = nil
	end
end

-- The selected units a line of orders in `mode` (attack, fight, or unload) spreads over.
local function line_entries(mode: string): { { id: EntityId, model: Model, def: types.EntityDef } }
	if mode == "fight" then
		return mobile_entries()
	end
	local result = {}
	for _, entry in selected_with_def(false) do
		if can_do(if mode == "unload" then "unload" else "attack", entry.def) then
			table.insert(result, entry)
		end
	end
	return result
end

-- The order a line dragged in `mode` gives each unit: attacking the ground at its point, fighting, or unloading.
local function line_kind(mode: string): string
	if mode == "attack" then
		return "attack_ground"
	end
	return mode
end

-- Location-based mode dragged: the units are spread along the path the way a move is, each going to, or
-- fighting/attacking/unloading at, its own point. The mode ends, unless shift is held, which also queues
-- the orders and keeps it on.
local function order_mode_line(mode: string, path: { Vector3 })
	local entries = line_entries(mode)
	if #entries == 0 then
		target_mode = nil
		return
	end
	sort_along(entries, path)

	local positions = formation_points(path, #entries)
	local ids = table.create(#entries)
	for index, entry in entries do
		ids[index] = entry.id
	end

	local queue = shift_held()
	markers.flash_points(positions, ORDER_MARKER_SECONDS, line_kind(mode))

	local kind = line_kind(mode)
	local front = space_held()
	issue_order:FireServer({
		kind = kind,
		ids = ids,
		positions = positions,
		routes = routes.for_units(ids, kind, function(index: number): Vector3?
			return positions[index]
		end, nil, queue, front),
		queue = queue,
		front = front,
	})

	if queue == false then
		target_mode = nil
	end
end

-- Fight mode's click: every selected unit that can move is sent to the spot on the ground under the cursor
-- as a fight waypoint, whatever is under the cursor, so a group that includes units that cannot shoot
-- stays together. The mode then ends, unless shift is held, which also queues the waypoint after what they
-- are doing and keeps the mode on, so a route of them can be laid.
local function click_walk_mode(kind: string)
	local entries = mobile_entries()
	local point = ground_point()
	if #entries == 0 or point == nil then
		target_mode = nil
		return
	end

	local ids = table.create(#entries)
	for index, entry in entries do
		ids[index] = entry.id
	end

	local queue = shift_held()
	local grounded = waypoint_ground(point.X, point.Z)
	markers.flash_points({ grounded }, ORDER_MARKER_SECONDS, line_kind(kind))
	send_point_order(kind, ids, grounded, queue)

	if queue == false then
		target_mode = nil
	end
end

-- Unload mode's click: every selected transport is sent to the spot on the ground under the cursor, and sets
-- what it carries down there. The mode then ends, unless shift is held, which also queues the order and
-- keeps it on.
local function click_unload_mode()
	local ids = workers "unload"
	local point = ground_point()
	if #ids == 0 or point == nil then
		target_mode = nil
		return
	end

	local queue = shift_held()
	local grounded = waypoint_ground(point.X, point.Z)
	markers.flash_points({ grounded }, ORDER_MARKER_SECONDS, "unload")
	send_unload(ids, grounded, queue)

	if queue == false then
		target_mode = nil
	end
end

-- Sends every selected unit that can at whatever is under the cursor. The mode then ends, unless
-- shift is held, which also queues the order and keeps the mode on for the next one.
local function click_target_mode()
	local mode = target_mode
	if mode == nil then
		return
	end
	if mode == "attack" then
		click_attack_mode()
		return
	end
	if mode == "fight" then
		click_walk_mode(mode)
		return
	end
	if mode == "unload" then
		click_unload_mode()
		return
	end
	local target = entity_under_mouse()
	local target_id = if target ~= nil then world.id_of(target) else nil
	local ids = {}
	if target_id ~= nil then
		for _, id in workers(mode) do
			if id ~= target_id then
				table.insert(ids, id)
			end
		end
	end
	-- a click on nothing, or with nobody left to send, is just another action and ends the mode
	if target_id == nil or #ids == 0 then
		target_mode = nil
		return
	end
	send_targeted(mode, ids, target_id, shift_held())
	if shift_held() == false then
		target_mode = nil
	end
end

-- The disintegrator is an order like any other: `dgun`, at the spot under the cursor. Each shooter closes in
-- until the spot is in range and fires when its weapon is ready, so it does not have to be ready now, and
-- shift queues the shot behind what it is doing and keeps aiming, while space puts it at the front.
local function fire_manual()
	local point = ground_point()
	if point == nil then
		return
	end
	local ids = {}
	for _, entry in manual_shooters() do
		table.insert(ids, entry.id)
	end
	if #ids == 0 then
		return
	end
	local queue = shift_held()
	local grounded = waypoint_ground(point.X, point.Z)
	markers.flash_points({ grounded }, ORDER_MARKER_SECONDS, "dgun")
	send_point_order("dgun", ids, grounded, queue)
	-- one shot per press of D, unless shift is held to keep firing
	if queue == false then
		stop_manual_aim()
	end
end

-- Shows the rectangle the first shooter's shot would sweep, from it toward the cursor out to its range. With
-- shift held the shot is queued behind everything it has to do first, so the rectangle starts where it is
-- expected to be once that is done, and not where it stands now.
local function preview_manual()
	local point = ground_point()
	local shooters = manual_shooters()
	local first = shooters[1]
	if point == nil or first == nil then
		markers.hide_blast()
		return
	end
	local weapon = first.def.manual_weapon
	if weapon == nil then
		return
	end
	local at = if shift_held() then markers.expected_end(first.model) else world.position_of(first.model)
	local direction = geometry.flatten(point - at)
	if direction.Magnitude < 1e-3 then
		markers.hide_blast()
		return
	end
	local far = at + direction.Unit * weapon.range
	markers.show_blast(heightmap.ground_position(at.X, at.Z), heightmap.ground_position(far.X, far.Z), weapon.radius)
end

local function on_left_down()
	if target_mode == "fight" or target_mode == "unload" then
		-- what it does waits for the button to come up, to tell a click from a line
		mode_drag_from = ground_point()
		begin_trace(mode_drag_from)
		if mode_drag_from == nil then
			click_target_mode()
		end
		return
	end
	if target_mode ~= nil and AREA_KINDS[target_mode] ~= nil then
		-- what it does waits for the button to come up, to tell a click from a drag
		area_drag_from = ground_point()
		if area_drag_from == nil then
			click_target_mode()
		end
		return
	end
	if target_mode ~= nil then
		click_target_mode()
		return
	end
	if manual_aiming then
		fire_manual()
		return
	end
	if build_mode.active() ~= nil then
		if shift_held() then
			-- shift starts a line, or with alt a grid, that the drag stretches and letting go places
			local center = build_mode.update(ground_point(), primary_builder_id(build_mode.active() :: string))
			placing_from = center
		else
			confirm_placement()
		end
		return
	end
	left_down_at = UserInputService:GetMouseLocation()
end

local function on_left_up()
	local mode_from = mode_drag_from
	mode_drag_from = nil
	if mode_from ~= nil then
		markers.clear_points()
		local path = finish_trace()
		local mode = target_mode
		if mode == "fight" or mode == "unload" then
			if is_line(path) then
				order_mode_line(mode, path)
			else
				click_target_mode()
			end
		end
		return
	end
	local area_from = area_drag_from
	area_drag_from = nil
	if area_from ~= nil then
		markers.hide_area()
		local mode = target_mode
		local point = ground_point()
		local radius = if point ~= nil then geometry.distance_2d(area_from, point) else 0
		if mode ~= nil and AREA_KINDS[mode] ~= nil and radius >= config.FORMATION_DRAG_THRESHOLD then
			order_area_mode(mode, area_from, radius)
		else
			click_target_mode()
		end
		return
	end
	if placing_from ~= nil then
		finish_placement_drag()
		return
	end
	local started = left_down_at
	left_down_at = nil
	local rect = drag_rect
	set_rect(nil)

	if started == nil then
		return
	end

	if rect ~= nil then
		local ids = box_select(rect, shift_held())
		if shift_held() then
			selection.add(ids)
		else
			selection.set(ids)
		end
		return
	end

	-- a click, not a drag. Only what is yours can be selected, so clicking anything else is like clicking
	-- empty ground; in godmode everything on a real team is yours.
	local target = entity_under_mouse()
	if target ~= nil and world.is_mine(target) == false then
		target = nil
	end
	if target == nil then
		if shift_held() == false then
			selection.clear()
		end
		return
	end

	local id = world.id_of(target)
	if id == nil then
		return
	end
	if shift_held() then
		selection.toggle(id)
	else
		selection.set({ id })
	end
end

local function on_right_down()
	if target_mode == "attack" or target_mode == "fight" or target_mode == "unload" then
		-- what it does waits for the button to come up, so a plain right click can still cancel the
		-- mode while a right-drag lays down a line of orders instead
		right_mode_drag_from = ground_point()
		begin_trace(right_mode_drag_from)
		if right_mode_drag_from == nil then
			target_mode = nil
		end
		return
	end
	if target_mode ~= nil then
		target_mode = nil
		right_down_world = nil
		if area_drag_from ~= nil then
			area_drag_from = nil
			markers.hide_area()
		end
		return
	end
	if manual_aiming then
		stop_manual_aim()
		right_down_world = nil
		return
	end
	if build_mode.active() ~= nil then
		placing_from = nil
		build_mode.exit()
		right_down_world = nil
		return
	end
	right_down_world = ground_point()
	begin_trace(right_down_world)
end

local function on_right_up()
	local mode_from = right_mode_drag_from
	right_mode_drag_from = nil
	if mode_from ~= nil then
		markers.clear_points()
		local path = finish_trace()
		local mode = target_mode
		if mode ~= nil and is_line(path) then
			order_mode_line(mode, path)
		else
			-- a right click with no drag cancels the mode, unlike a left click, which places a single order
			target_mode = nil
		end
		return
	end

	local started = right_down_world
	right_down_world = nil
	-- the preview belongs to the held button; whatever happens next puts its own dots up
	markers.clear_points()
	local path = finish_trace()
	if started == nil then
		return
	end
	if selection.count() == 0 then
		return
	end

	local queue = shift_held()
	local finished = ground_point()

	-- a long enough right-drag is a formation along the shape it traced; anything shorter is a plain right-click
	if is_line(path) then
		order_along_trace(path, queue)
		return
	end

	local target = entity_under_mouse()
	if target ~= nil then
		order_on_entity(target, queue)
		return
	end
	if finished ~= nil then
		order_at_point(finished, queue)
	end
end

type BuildCategory = {
	name: string,
	-- what the category's own key places
	primary: { string },
	-- what other keys place while something in the category is being placed
	-- (a key with several is for whichever the selection can build, the first of them if none)
	options: { [Enum.KeyCode]: { string } },
}

-- Buildings are grouped into categories, each with a key of its own: Z economy, X offense, C utility, V
-- production. Its key places the category's main building, which is the advanced one for a construction_bot that
-- can build it, and Z does the same once something in the category is being placed. Once something from a category is being
-- placed, a few more keys pick other buildings in it, and they mean that instead of whatever they are
-- otherwise, so X is the guard on its own but the solar collector among the economy buildings, the
-- twin guard among the offense ones and the vehicle lab among the production ones, where A is the
-- construction turret, S the advanced lab (the bot one or the vehicle one, whichever the selection can
-- build), V the shipyard and C the air lab. Among the offense ones W is the agitator, C the warden, A the thistle, S the screamer, V the catalyst and E the apocalypse. Utility has nothing
-- in it yet.
local BUILD_CATEGORIES: { [Enum.KeyCode]: BuildCategory } = {
	[Enum.KeyCode.Z] = {
		name = "Economy",
		primary = { "advanced_metal_extractor", "metal_extractor" },
		options = {
			[Enum.KeyCode.X] = { "fusion_reactor", "solar_collector" },
			[Enum.KeyCode.Q] = { "hardened_energy_storage", "energy_storage" },
			[Enum.KeyCode.W] = { "hardened_metal_storage", "metal_storage" },
			[Enum.KeyCode.A] = { "advanced_energy_converter", "energy_converter" },
			[Enum.KeyCode.C] = { "advanced_fusion_reactor", "wind_turbine" },
			[Enum.KeyCode.E] = { "epic_fusion_reactor" },
			[Enum.KeyCode.T] = { "epic_energy_converter" },
			[Enum.KeyCode.V] = { "advanced_solar_collector" },
			[Enum.KeyCode.S] = { "tidal_generator" },
			-- the geothermal plants, on a vent: the advanced one for whoever can build it, and its sidegrade
			[Enum.KeyCode.D] = { "advanced_geothermal_powerplant", "geothermal_powerplant" },
			[Enum.KeyCode.F] = { "rampart" },
		},
	},
	[Enum.KeyCode.X] = {
		name = "Combat",
		primary = { "scorpion", "guard" },
		options = {
			[Enum.KeyCode.X] = { "pulsar", "twin_guard" },
			[Enum.KeyCode.C] = { "warden", "persecutor" },
			[Enum.KeyCode.W] = { "agitator", "calamity" },
			[Enum.KeyCode.D] = { "prevailer" },
			[Enum.KeyCode.A] = { "thistle" },
			[Enum.KeyCode.S] = { "screamer" },
			[Enum.KeyCode.V] = { "catalyst" },
			[Enum.KeyCode.E] = { "apocalypse" },
		},
	},
	[Enum.KeyCode.C] = {
		name = "Utility",
		primary = {},
		options = {
			[Enum.KeyCode.Q] = { "overseer" },
		},
	},
	[Enum.KeyCode.V] = {
		name = "Production",
		primary = { "bot_lab" },
		options = {
			-- construction turret is A while advanced construction turret is C. This is intentional, copied from BAR.
			[Enum.KeyCode.X] = { "vehicle_lab" },
			[Enum.KeyCode.A] = { "construction_turret", "experimental_gantry" },
			[Enum.KeyCode.S] = { "advanced_bot_lab", "advanced_vehicle_lab" },
			[Enum.KeyCode.V] = { "shipyard" },
			[Enum.KeyCode.C] = { "air_lab", "advanced_construction_turret" },
		},
	},
}

-- The categories as the build menu shows them, one tab each in this order: the name, the key that starts it
-- and every building it holds.
export type BuildTab = {
	name: string,
	key: string,
	defs: { string },
	-- what the key places, best first: the one the first page of the menu offers
	primary: { string },
	-- the key that places each of them once something in the category is being placed
	keys: { [string]: string },
}

local BUILD_TABS: { BuildTab } = {}
for _, key in { Enum.KeyCode.Z, Enum.KeyCode.X, Enum.KeyCode.C, Enum.KeyCode.V } do
	local category = BUILD_CATEGORIES[key]
	local defs: { string } = {}
	local keys: { [string]: string } = {}
	for _, def_name in category.primary do
		table.insert(defs, def_name)
		keys[def_name] = "Z"
	end
	for option_key, candidates in category.options do
		for _, def_name in candidates do
			if table.find(defs, def_name) == nil then
				table.insert(defs, def_name)
				keys[def_name] = option_key.Name
			end
		end
	end
	table.insert(
		BUILD_TABS,
		{ name = category.name, key = key.Name, defs = defs, primary = category.primary, keys = keys }
	)
end
table.freeze(BUILD_TABS)

-- The category a building belongs to, if any.
local function category_of(def_name: string): BuildCategory?
	for _, category in BUILD_CATEGORIES do
		if table.find(category.primary, def_name) ~= nil then
			return category
		end
		for _, option in category.options do
			if table.find(option, def_name) ~= nil then
				return category
			end
		end
	end
	return nil
end

-- An unfinished builder counts: what it is told to build waits in its orders until it is done.
local function selection_can_build(def_name: string): boolean
	for _, entry in selected_with_def(false) do
		local builds = entry.def.build_options
		if entry.def.assisting and builds ~= nil and table.find(builds, def_name) ~= nil then
			return true
		end
	end
	return false
end

-- The building a key places right now, if it places one. The category of whatever is being placed comes
-- first, whichever way placing it was started.
-- The first of `candidates` the selection can build, or the first of them if it can build none.
local function first_buildable(candidates: { string }): string?
	for _, candidate in candidates do
		if selection_can_build(candidate) then
			return candidate
		end
	end
	return candidates[1]
end

local function build_hotkey(key: Enum.KeyCode): string?
	local placing = build_mode.active()
	local current = if placing ~= nil then category_of(placing) else nil
	if current ~= nil and current.options[key] ~= nil then
		return first_buildable(current.options[key])
	end
	-- Z is always the primary building of the category being placed, as it is the economy's own key
	if current ~= nil and key == Enum.KeyCode.Z then
		return first_buildable(current.primary)
	end
	local category = BUILD_CATEGORIES[key]
	if category ~= nil then
		return first_buildable(category.primary)
	end
	return nil
end

local function on_input_began(input: InputObject, processed: boolean)
	if processed then
		return
	end
	if input.UserInputType == Enum.UserInputType.MouseButton1 then
		on_left_down()
	elseif input.UserInputType == Enum.UserInputType.MouseButton2 then
		on_right_down()
	elseif build_hotkey(input.KeyCode) ~= nil then
		target_mode = nil
		local def_name = build_hotkey(input.KeyCode)
		if def_name ~= nil and selection_can_build(def_name) then
			build_mode.enter(def_name)
		end
	elseif input.KeyCode == Enum.KeyCode.G then
		target_mode = nil
		send_stop()
	elseif input.KeyCode == Enum.KeyCode.Q then
		-- only reached when Q is not picking a building, which it does while an economy building is placed
		select_same_type()
	elseif input.KeyCode == Enum.KeyCode.D then
		target_mode = nil
		start_manual_aim()
	elseif input.KeyCode == Enum.KeyCode.A then
		start_target_mode "attack"
	elseif input.KeyCode == Enum.KeyCode.F then
		start_target_mode "fight"
	elseif input.KeyCode == Enum.KeyCode.E then
		start_target_mode "reclaim"
	elseif input.KeyCode == Enum.KeyCode.R then
		start_target_mode "repair"
	elseif input.KeyCode == Enum.KeyCode.W then
		start_target_mode "resurrect"
	elseif input.KeyCode == Enum.KeyCode.J then
		start_target_mode "load"
	elseif input.KeyCode == Enum.KeyCode.U then
		start_target_mode "unload"
	elseif input.KeyCode == Enum.KeyCode.LeftBracket then
		build_mode.rotate(1)
	elseif input.KeyCode == Enum.KeyCode.RightBracket then
		build_mode.rotate(-1)
	elseif input.KeyCode == Enum.KeyCode.Escape then
		build_mode.exit()
		stop_manual_aim()
		target_mode = nil
	end
end

local COMMANDER_ACTION = "rts_cycle_commander"

-- Tab: selects your commander and pans the camera to it. With several, each press moves on to the
-- next in id order, wrapping round after the last; with none selected it starts at the first.
local function cycle_commander(_, input_state: Enum.UserInputState): Enum.ContextActionResult
	if input_state ~= Enum.UserInputState.Begin then
		return Enum.ContextActionResult.Pass
	end

	local commanders: { { id: EntityId, model: Model } } = {}
	for _, model in world.all() do
		local id = world.id_of(model)
		if id ~= nil and world.is_mine(model) and model:GetAttribute "def_name" == "commander" then
			table.insert(commanders, { id = id, model = model })
		end
	end
	if #commanders == 0 then
		return Enum.ContextActionResult.Sink
	end
	table.sort(commanders, function(a, b)
		return a.id < b.id
	end)

	local next_index = 1
	for index, commander in commanders do
		if selection.contains(commander.id) then
			next_index = index % #commanders + 1
			break
		end
	end

	local chosen = commanders[next_index]
	selection.set({ chosen.id })
	camera_mod.look_at(world.position_of(chosen.model))
	return Enum.ContextActionResult.Sink
end

local GUARD_ACTION = "rts_guard_mode"

-- O: starts guard mode. Bound above the default so that Roblox's own reserved use of O never sees
-- it (as with Tab above), even though nothing else in the game wants it.
local function start_guard_mode(_, input_state: Enum.UserInputState): Enum.ContextActionResult
	if input_state ~= Enum.UserInputState.Begin then
		return Enum.ContextActionResult.Pass
	end
	start_target_mode "guard"
	return Enum.ContextActionResult.Sink
end

local function on_input_ended(input: InputObject)
	if input.UserInputType == Enum.UserInputType.MouseButton1 then
		on_left_up()
	elseif input.UserInputType == Enum.UserInputType.MouseButton2 then
		on_right_up()
	end
end

-- While a button is held to drag out a line of `count` orders of `kind`, shows the shape traced so far, in that
-- order's colour, and one dot per unit along it where each would land. Until the drag is long enough to be a line,
-- a move shows a single dot under the cursor (`single`), and anything else nothing.
local function preview_trace(count: number, kind: string, single: boolean)
	extend_trace()
	if count > 0 and is_line(drag_trace) then
		markers.show_trace(drag_trace, kind)
		markers.show_points(formation_points(drag_trace, count), kind)
		return
	end
	markers.hide_trace()
	local to = ground_point()
	if count > 0 and single and to ~= nil then
		markers.show_points({ waypoint_ground(to.X, to.Z) }, kind)
	else
		markers.clear_points()
	end
end

-- Hovering something shows how far it can build and how far it can shoot, as rings on the ground
-- around it. Nothing shows while the cursor is busy with something else.
local HOVER_COLOR = Color3.fromRGB(220, 240, 255)
local HOVER_REPAIR_COLOR = Color3.fromRGB(255, 230, 64)
local HOVER_RECLAIM_COLOR = Color3.fromRGB(236, 184, 68)
local HOVER_RESURRECT_COLOR = Color3.fromRGB(176, 96, 240)
local HOVER_ATTACK_COLOR = Color3.fromRGB(238, 88, 74)

local function update_hover()
	-- whatever is under the cursor is lit, so it is plain what a click would land on. The colour follows
	-- the mode: yellow for repairing, amber for reclaiming.
	local dragging = right_down_world ~= nil
		or left_down_at ~= nil
		or mode_drag_from ~= nil
		or right_mode_drag_from ~= nil
		or area_drag_from ~= nil
	-- a fight click lands on the ground whatever is under it, so nothing is lit for it
	local model = if dragging or target_mode == "fight" then nil else entity_under_mouse()
	local color = HOVER_COLOR
	if target_mode == "repair" then
		color = HOVER_REPAIR_COLOR
	elseif target_mode == "reclaim" then
		color = HOVER_RECLAIM_COLOR
	elseif target_mode == "resurrect" then
		color = HOVER_RESURRECT_COLOR
	elseif target_mode == "attack" then
		color = HOVER_ATTACK_COLOR
	end
	markers.show_hover(model, color)

	if build_mode.active() ~= nil or manual_aiming or target_mode ~= nil or dragging then
		markers.hide_ranges()
		return
	end

	local def_name = if model ~= nil then model:GetAttribute "def_name" else nil
	local def = if typeof(def_name) == "string" then unit_defs.defs[def_name] else nil
	local kind = if model ~= nil then model:GetAttribute "kind" else nil
	if model == nil or def == nil or kind == "wreck" or kind == "reclaimable" then
		markers.hide_ranges()
		return
	end

	-- a builder's reach is its own if it has one, and the usual build range otherwise
	local build_range: number? = nil
	if def.buildpower ~= nil and (def.assisting or def.repairing) then
		build_range = if def.build_range ~= nil then def.build_range else config.BUILD_RANGE
	end
	local attack_range = unit_defs.display_range(def)
	if build_range == nil and attack_range == nil then
		markers.hide_ranges()
		return
	end

	-- shots leave from a quarter of its height above its middle, as the server has them (`sight.muzzle_of`)
	local at = world.position_of(model)
	local muzzle = at + Vector3.new(0, unit_defs.collider_height(def) * 0.25, 0)
	markers.show_ranges(heightmap.ground_position(at.X, at.Z), build_range, attack_range, def, muzzle)
end

-- Reports a change of what the cursor is over. It says nothing while a box is being dragged or an order is
-- being aimed with the right button, when the cursor is busy with the selection rather than looking at things.
local function report_hover()
	local id: EntityId? = nil
	if drag_rect == nil and right_down_world == nil then
		local model = entity_under_mouse()
		id = if model ~= nil then world.id_of(model) else nil
	end
	if id == reported_hover then
		return
	end
	reported_hover = id
	for _, listener in hover_listeners do
		listener(id)
	end
end

-- Reports a change of mode. The modes are set from a dozen places, so it is noticed here, once a frame,
-- rather than at each of them.
local function report_mode()
	local mode: string? = nil
	if target_mode ~= nil then
		mode = target_mode
	elseif manual_aiming then
		mode = "disintegrator"
	end
	if mode == reported_mode then
		return
	end
	reported_mode = mode
	for _, listener in mode_listeners do
		listener(mode)
	end
end

local function on_render()
	report_mode()
	report_hover()
	if build_mode.active() ~= nil then
		local def_name = build_mode.active() :: string
		build_mode.update(ground_point(), primary_builder_id(def_name))
		local from = placing_from
		if from ~= nil then
			build_mode.show_layout(dragged_layout(def_name, from))
		end
	else
		placing_from = nil
	end
	update_hover()

	if manual_aiming then
		preview_manual()
	end

	if right_down_world ~= nil then
		preview_trace(#move_entries(), "move", true)
	end

	local mode = target_mode
	if (mode_drag_from ~= nil or right_mode_drag_from ~= nil) and mode ~= nil then
		preview_trace(#line_entries(mode), line_kind(mode), false)
	end

	if area_drag_from ~= nil and mode ~= nil then
		local point = ground_point()
		local radius = if point ~= nil then geometry.distance_2d(area_drag_from, point) else 0
		if radius >= config.FORMATION_DRAG_THRESHOLD then
			markers.show_area(area_drag_from, radius, mode)
		else
			markers.hide_area()
		end
	end

	local started = left_down_at
	if started == nil then
		return
	end
	local now = UserInputService:GetMouseLocation()
	if (now - started).Magnitude < config.SELECTION_DRAG_THRESHOLD then
		return
	end
	set_rect({
		min = Vector2.new(math.min(started.X, now.X), math.min(started.Y, now.Y)),
		max = Vector2.new(math.max(started.X, now.X), math.max(started.Y, now.Y)),
	})
end

local function init()
	-- bound above the default so that Roblox's own use of Tab (the player list) never sees it
	ContextActionService:BindActionAtPriority(
		COMMANDER_ACTION,
		cycle_commander,
		false,
		Enum.ContextActionPriority.High.Value,
		Enum.KeyCode.Tab
	)
	ContextActionService:BindActionAtPriority(
		GUARD_ACTION,
		start_guard_mode,
		false,
		Enum.ContextActionPriority.High.Value,
		Enum.KeyCode.O
	)
	UserInputService.InputBegan:Connect(on_input_began)
	UserInputService.InputEnded:Connect(on_input_ended)
	-- after the camera, which it casts rays through
	RunService:BindToRenderStep("rts_input", Enum.RenderPriority.Camera.Value + 1, on_render)
end

-- Every mode the cursor can be put in, in the order the command panel lists them, with the key that
-- starts each. `subscribe_mode` reports these same names.
export type Command = {
	mode: string,
	label: string,
	key: string,
}

local COMMANDS: { Command } = table.freeze({
	{ mode = "attack", label = "Attack", key = "A" },
	{ mode = "fight", label = "Fight", key = "F" },
	{ mode = "reclaim", label = "Reclaim", key = "E" },
	{ mode = "repair", label = "Repair", key = "R" },
	{ mode = "resurrect", label = "Resurrect", key = "W" },
	{ mode = "load", label = "Load", key = "J" },
	{ mode = "unload", label = "Unload", key = "U" },
	{ mode = "guard", label = "Guard", key = "O" },
	{ mode = "disintegrator", label = "Disintegrator", key = "D" },
})

-- Whether something of this def can use the command: the disintegrator needs a manual weapon, and the
-- rest are what `can_do` says.
local function can_command(mode: string, def: types.EntityDef): boolean
	if mode == "disintegrator" then
		return def.manual_weapon ~= nil
	end
	return can_do(mode, def)
end

-- What clicking a command in the panel does: the same as pressing its key, or leaving the mode if it is
-- the one that is on.
local function toggle_mode(mode: string)
	local current = if manual_aiming then "disintegrator" else target_mode
	if current == mode then
		target_mode = nil
		stop_manual_aim()
		return
	end
	if mode == "disintegrator" then
		target_mode = nil
		start_manual_aim()
	else
		start_target_mode(mode)
	end
end

return table.freeze({
	init = init,
	commands = COMMANDS,
	build_tabs = BUILD_TABS,
	can_command = can_command,
	toggle_mode = toggle_mode,
	subscribe_rect = subscribe_rect,
	subscribe_mode = subscribe_mode,
	subscribe_hover = subscribe_hover,
	ground_point = ground_point,
	entity_under_mouse = entity_under_mouse,
})
