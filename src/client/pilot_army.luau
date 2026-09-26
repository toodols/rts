--!strict
-- The army of a piloted unit (client/pilot.luau): every armed unit of the player's that can walk, other than the one
-- piloted, and the orders the pilot gives it from the saddle: stand in formation behind it (hold), guard it wherever it
-- goes (follow), and attack everything round a point (attack). Each is given through `orders`, as any order is, and
-- shown with the markers a move, a guard or an attack circle has.

local ReplicatedStorage = game:GetService "ReplicatedStorage"

local types = require(ReplicatedStorage.Shared.types)
local unit_defs = require(ReplicatedStorage.Shared.unit_defs)
local surface = require(ReplicatedStorage.Shared.surface)
local heightmap = require(ReplicatedStorage.Shared.heightmap)
local geometry = require(ReplicatedStorage.Shared.geometry)
local piloting = require(ReplicatedStorage.Shared.piloting)
local entity_attrs = require(ReplicatedStorage.Shared.entity_attrs)

local world = require(ReplicatedStorage.Client.world)
local orders = require(ReplicatedStorage.Client.orders)
local markers = require(ReplicatedStorage.Client.markers)

type EntityId = types.EntityId
type EntityDef = types.EntityDef

export type Unit = { id: EntityId, model: Model, def: EntityDef }

-- How far apart the units of a hold stand, beyond their own widths, in studs, and how far behind the pilot the first
-- row stands.
local FORMATION_GAP = 3
local FORMATION_BEHIND = 4
-- How long the dots a hold or a follow puts down, and an attack's circle, stay up.
local MARKER_SECONDS = 1.5
-- How far round the crosshair the army attacks everything, in studs.
local ATTACK_RADIUS = 40

-- How many attack circles have been shown, so that one taken down late does not take down one shown since.
local circles_shown = 0

-- Every armed unit of this player's that can walk, other than `piloted`: what hold, follow and attack send, and what
-- the HUD counts. Builders are left to their work.
local function of(piloted: EntityId?): { Unit }
	local result = {}
	for _, model in world.all() do
		local id = world.id_of(model)
		local def = world.def_of(model)
		if
			id == nil
			or id == piloted
			or def == nil
			or world.is_mine(model) == false
			or entity_attrs.kind(model) ~= "unit"
			or entity_attrs.state(model) ~= "active"
			or entity_attrs.flag(model, "carried") == true
		then
			continue
		end
		if piloting.can_pilot(def) and def.weapons ~= nil and def.builder == nil then
			table.insert(result, { id = id, model = model, def = def })
		end
	end
	return result
end

-- The army of the unit `pilot_id` in `pilot_model` comes to stand in rows behind it, facing `forward` (with `right` to
-- its right), as square a block as they make, each taking the nearest place left, nearest of them first.
local function hold(pilot_model: Model, pilot_id: EntityId, forward: Vector3, right: Vector3)
	local units = of(pilot_id)
	if #units == 0 then
		return
	end
	local center = world.position_of(pilot_model)
	local pilot_def = world.def_of(pilot_model)
	local spacing = 0
	for _, unit in units do
		spacing = math.max(spacing, 2 * unit_defs.collider_radius(unit.def))
	end
	spacing += FORMATION_GAP
	local columns = math.ceil(math.sqrt(#units))
	local behind = (if pilot_def ~= nil then unit_defs.collider_radius(pilot_def) else 0) + FORMATION_BEHIND
	local hx, hz = heightmap.half_extents()
	local slots: { Vector3 } = {}
	for index = 0, #units - 1 do
		local row = index // columns
		local in_row = math.min(columns, #units - row * columns)
		local column = index % columns
		local at = center - forward * (behind + spacing * (row + 0.5)) + right * ((column - (in_row - 1) / 2) * spacing)
		local x = math.clamp(at.X, -hx + 1, hx - 1)
		local z = math.clamp(at.Z, -hz + 1, hz - 1)
		table.insert(slots, heightmap.ground_position(x, z))
	end

	table.sort(units, function(a: Unit, b: Unit): boolean
		return geometry.distance_2d(world.position_of(a.model), center)
			< geometry.distance_2d(world.position_of(b.model), center)
	end)
	local ids: { EntityId } = {}
	local positions: { Vector3 } = {}
	for _, unit in units do
		local from = world.position_of(unit.model)
		local best = 1
		for index = 2, #slots do
			if geometry.distance_2d(slots[index], from) < geometry.distance_2d(slots[best], from) then
				best = index
			end
		end
		table.insert(ids, unit.id)
		table.insert(positions, surface.position(unit.def, slots[best].X, slots[best].Z))
		table.remove(slots, best)
	end
	orders.send("move", ids, { aim = "spots", positions = positions }, orders.NOW)
	-- where each will stand, as a move's dots show it
	markers.flash_points(positions, MARKER_SECONDS, "move")
end

-- The army of the unit `pilot_id` attacks everything of the enemy's within ATTACK_RADIUS of `center`, one thing at a
-- time, as an attack circle dragged out on the map has it do.
local function attack(pilot_id: EntityId, center: Vector3)
	local ids: { EntityId } = {}
	for _, unit in of(pilot_id) do
		table.insert(ids, unit.id)
	end
	if #ids == 0 then
		return
	end
	local ground = heightmap.ground_position(center.X, center.Z)
	orders.send("area_attack", ids, { aim = "area", position = ground, radius = ATTACK_RADIUS }, orders.NOW)
	-- the circle, for a moment
	markers.show_area(ground, ATTACK_RADIUS, "attack")
	circles_shown += 1
	local this_circle = circles_shown
	task.delay(MARKER_SECONDS, function()
		if circles_shown == this_circle then
			markers.hide_area()
		end
	end)
end

-- The army of the unit `pilot_id` guards it, following it wherever it goes.
local function follow(pilot_id: EntityId)
	local ids: { EntityId } = {}
	local under: { Vector3 } = {}
	for _, unit in of(pilot_id) do
		table.insert(ids, unit.id)
		local at = world.position_of(unit.model)
		table.insert(under, heightmap.ground_position(at.X, at.Z))
	end
	if #ids == 0 then
		return
	end
	-- a dot under each one that is coming, in the guard order's colour
	markers.flash_points(under, MARKER_SECONDS, "guard")
	orders.send("guard", ids, { aim = "entity", id = pilot_id }, orders.NOW)
end

return table.freeze({
	of = of,
	hold = hold,
	attack = attack,
	follow = follow,
})
