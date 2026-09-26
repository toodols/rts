--!strict
-- What the cursor is over, shown and told. Whatever a click would land on is lit, in the colour of the mode that is on,
-- and hovering something shows how far it can build and shoot as rings on the ground around it; what is
-- being placed shows the rings it would have where it would go. Which entity the cursor is over is told to whoever
-- subscribes (`subscribe`), for the HUD to say what it is; nothing about what a click does depends on that.

local ReplicatedStorage = game:GetService "ReplicatedStorage"

local signal = require(ReplicatedStorage.Shared.signal)
local types = require(ReplicatedStorage.Shared.types)
local unit_defs = require(ReplicatedStorage.Shared.unit_defs)
local heightmap = require(ReplicatedStorage.Shared.heightmap)
local order_kinds = require(ReplicatedStorage.Shared.order_kinds)

local world = require(ReplicatedStorage.Client.world)
local cursor = require(ReplicatedStorage.Client.cursor)
local markers = require(ReplicatedStorage.Client.markers)
local range_rings = require(ReplicatedStorage.Client.range_rings)
local build_mode = require(ReplicatedStorage.Client.build_mode)
local command_state = require(ReplicatedStorage.Client.command_state)
local order_modes = require(ReplicatedStorage.Client.order_modes)
local selected = require(ReplicatedStorage.Client.selected)
local commands = require(ReplicatedStorage.Client.commands)

type EntityId = types.EntityId
type EntityDef = types.EntityDef
type State = command_state.State

local HOVER_COLOR = Color3.fromRGB(220, 240, 255)

local hovered = signal.new() :: signal.Signal<EntityId?>
local reported: EntityId? = nil

-- The entity the cursor is over, if any.
local function get(): EntityId?
	return reported
end

local function report(id: EntityId?)
	if id ~= reported then
		reported = id
		hovered.fire(id)
	end
end

-- Shows how far something of `def` standing at `at` can build, how far it can shoot and how far out it shoots nukes
-- down, whichever of them it can, turned to `facing`: a factory shows which way its front is, and a weapon that fires
-- only into a cone ahead shows that cone.
local function show_ranges_of(def: EntityDef, at: Vector3, facing: number)
	-- a builder's reach is its own if it has one, and the usual build range otherwise
	local build_range: number? = nil
	if def.builder ~= nil and (unit_defs.does(def, "assist") or unit_defs.does(def, "repair")) then
		build_range = unit_defs.build_range(def) or order_kinds.BUILD_RANGE
	end
	local attack_range = unit_defs.display_range(def)
	local intercept_range = unit_defs.intercept_range(def)
	if build_range == nil and attack_range == nil and intercept_range == nil and unit_defs.is_factory(def) == false then
		range_rings.hide()
		return
	end
	local ground = heightmap.ground_position(at.X, at.Z)
	local muzzle = unit_defs.muzzle_of(def, ground)
	range_rings.show(ground, build_range, attack_range, def, muzzle, intercept_range, facing)
end

-- What a click would land on in `state`, if anything is lit for it: nothing while a button is held, and in a mode only
-- the entity its click would be aimed at (`commands.aim`).
local function lit(state: State): Model?
	if state.kind == "selecting" or state.kind == "ordering" then
		return nil
	end
	if state.kind == "mode" then
		if state.drag ~= nil then
			return nil
		end
		local info = order_modes.get(state.mode)
		local model = commands.aim(info, selected.for_mode(info))
		return model
	end
	return cursor.entity()
end

-- The rings of what is hovered, when nothing else has the cursor.
local function show_hovered_ranges(model: Model?)
	local def = if model ~= nil then world.def_of(model) else nil
	if model == nil or def == nil or world.is_remains(model) then
		range_rings.hide()
		return
	end
	local front = model:GetPivot().ZVector
	show_ranges_of(def, world.position_of(model), math.atan2(front.X, front.Z))
end

-- Every frame: what is lit for `state`, and the rings, of what is being placed at `placing_at` (where it would go)
-- or else of what is hovered.
local function render(state: State, placing_at: Vector3?)
	local model = lit(state)
	local color = if state.kind == "mode" then order_modes.get(state.mode).color else HOVER_COLOR
	markers.show_hover(model, color)

	-- nothing is over while a box is dragged or an order aimed, when the cursor is busy with the selection rather than
	-- looking at things
	local busy = (state.kind == "selecting" and state.rect ~= nil) or state.kind == "ordering"
	local over = if busy then nil else cursor.entity()
	report(if over ~= nil then world.id_of(over) else nil)

	if state.kind == "placing" then
		if placing_at == nil then
			range_rings.hide()
		else
			show_ranges_of(unit_defs.get(state.def_name), placing_at, build_mode.get_facing())
		end
	elseif state.kind == "idle" then
		show_hovered_ranges(model)
	else
		range_rings.hide()
	end
end

-- Nothing is hovered, for while the cursor is elsewhere (piloting a unit).
local function clear()
	markers.show_hover(nil, HOVER_COLOR)
	range_rings.hide()
	report(nil)
end

return table.freeze({
	render = render,
	clear = clear,
	get = get,
	subscribe = hovered.subscribe,
})
