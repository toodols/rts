-- Drones. A carrier keeps `carrier.count` drones parked on top of it. While an enemy is within its engage range
-- they take off and each attacks it with its own weapon, through the ordinary attack order; when nothing is in
-- range any longer they are sent back and park again, and a parked one is mended by its carrier. One that is shot
-- down is replaced after a delay. When
-- the carrier goes, so do they. Nothing here belongs to any one unit: any def with a `carrier` is served.

local ReplicatedStorage = game:GetService "ReplicatedStorage"

local types = require(ReplicatedStorage.Shared.types)
local unit_defs = require(ReplicatedStorage.Shared.unit_defs)
local geometry = require(ReplicatedStorage.Shared.geometry)

local state = require(script.Parent.state)
local movement = require(script.Parent.movement)
local combat = require(script.Parent.combat)
local docking = require(script.Parent.docking)

type Entity = types.Entity
type EntityId = types.EntityId

type Slot = {
	-- the drone in this slot, or nil while it is being replaced
	id: EntityId?,
	respawn_left: number,
}

-- How close, across the ground and in height, a returning drone has to be to settle onto its perch.
local PARK_RADIUS = 6
local PARK_HEIGHT = 4

local carriers: { [EntityId]: { Slot } } = {}

-- Where drone number `index` of `count` sits on `carrier`: a ring round the top of it.
local function perch(
	carrier: Entity,
	def: types.EntityDef,
	drone_def: types.EntityDef,
	index: number,
	count: number
): Vector3
	local angle = (index - 1) / count * math.pi * 2
	local ring = unit_defs.collider_radius(def) * 0.5
	local top = carrier.position.Y + unit_defs.collider_height(def) / 2 + unit_defs.collider_height(drone_def) / 2
	return Vector3.new(carrier.position.X + math.cos(angle) * ring, top, carrier.position.Z + math.sin(angle) * ring)
end

local function spawn(carrier: Entity, def: types.EntityDef, spec: types.Carrier, index: number): Slot
	local drone_def = unit_defs.get(spec.drone)
	local at = perch(carrier, def, drone_def, index, spec.count)
	local drone = state.create_entity(spec.drone, carrier.team, at, carrier.facing, "active")
	docking.set(drone.id, true)
	return { id = drone.id, respawn_left = 0 }
end

-- The nearest enemy the drones can fight, in range of the carrier.
local function find_target(carrier: Entity, spec: types.Carrier, drone_def: types.EntityDef): Entity?
	local weapon = drone_def.weapon
	local best: Entity? = nil
	local best_distance = spec.engage_range
	for _, other in state.all() do
		if
			combat.is_enemy(carrier, other)
			and (weapon == nil or combat.can_target(weapon, other))
			and other.kind ~= "wreck"
		then
			local distance = geometry.distance_2d(carrier.position, other.position)
			if distance <= best_distance then
				best = other
				best_distance = distance
			end
		end
	end
	return best
end

local function serve(carrier: Entity, def: types.EntityDef, spec: types.Carrier, delta: number)
	local slots = carriers[carrier.id]
	if slots == nil then
		slots = {}
		for index = 1, spec.count do
			slots[index] = spawn(carrier, def, spec, index)
		end
		carriers[carrier.id] = slots
		return
	end

	local drone_def = unit_defs.get(spec.drone)
	local target = find_target(carrier, spec, drone_def)

	for index, slot in slots do
		local drone = if slot.id ~= nil then state.get(slot.id) else nil
		if drone == nil or drone.alive == false then
			-- shot down: a new one is made after a while
			if slot.id ~= nil then
				docking.forget(slot.id)
				slot.id = nil
				slot.respawn_left = spec.respawn_seconds
			end
			slot.respawn_left -= delta
			if slot.respawn_left <= 0 then
				slots[index] = spawn(carrier, def, spec, index)
			end
			continue
		end

		local seat = perch(carrier, def, drone_def, index, spec.count)
		if target ~= nil then
			docking.set(drone.id, false)
			local first = drone.orders[1]
			if first == nil or first.kind ~= "attack" or first.target_id ~= target.id then
				drone.orders = { { kind = "attack", position = nil, target_id = target.id } }
			end
		elseif docking.is_docked(drone.id) then
			-- parked: carried along with the carrier
			drone.position = seat
			drone.velocity = Vector3.zero
			drone.facing = carrier.facing
			movement.set_hover(drone, seat.Y)
			-- and mended, for as long as it stays there
			drone.health = math.min(drone.max_health, drone.health + spec.repair_per_second * delta)
		elseif
			geometry.distance_2d(drone.position, seat) <= PARK_RADIUS
			and math.abs(drone.position.Y - seat.Y) <= PARK_HEIGHT
		then
			docking.set(drone.id, true)
			drone.orders = {}
			drone.position = seat
			drone.velocity = Vector3.zero
		else
			-- nothing to fight: back to the perch, which moves with the carrier
			drone.orders = { { kind = "move", position = seat, target_id = nil } }
			movement.set_hover(drone, seat.Y)
		end
	end
end

-- Serves every carrier, and sends its drones down with it if it is gone. Runs once a tick, after the movement
-- goals are cleared and before orders read them.
local function tick(delta: number)
	for _, entity in state.all() do
		if entity.alive == false or entity.kind ~= "unit" or entity.state ~= "active" then
			continue
		end
		local def = unit_defs.get(entity.def_name)
		if def.carrier ~= nil then
			serve(entity, def, def.carrier, delta)
		end
	end

	for carrier_id, slots in carriers do
		local carrier = state.get(carrier_id)
		if carrier ~= nil and carrier.alive then
			continue
		end
		for _, slot in slots do
			local drone = if slot.id ~= nil then state.get(slot.id) else nil
			if drone ~= nil then
				docking.forget(drone.id)
				state.mark_dead(drone)
			end
		end
		carriers[carrier_id] = nil
	end
end

return table.freeze({
	tick = tick,
})
