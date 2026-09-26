-- Drones. A carrier keeps up to `carrier.count` drones out, parked on top of it. While an enemy is within its engage
-- range they take off and each attacks it with its own weapon, through the ordinary attack order; when nothing is in
-- range any longer they are sent back and park again, and a parked one is mended by its carrier. Drones are a
-- stockpile, as a silo's missiles are (`stockpiles`): the carrier builds them ahead of time and pays for each, and
-- a free place on it is filled at once from what it holds. One that is shot down is spent, like a missile that has
-- been fired, and only comes back out of the stockpile. When the carrier goes, so do they. Nothing here belongs to
-- any one unit: any def with a `carrier` is served.

local ReplicatedStorage = game:GetService "ReplicatedStorage"

local types = require(ReplicatedStorage.Shared.types)
local unit_defs = require(ReplicatedStorage.Shared.unit_defs)
local geometry = require(ReplicatedStorage.Shared.geometry)

local state = require(script.Parent.state)
local movement = require(script.Parent.movement)
local shot_rules = require(script.Parent.shot_rules)
local targeting = require(script.Parent.targeting)
local control = require(script.Parent.control)
local stockpiles = require(script.Parent.stockpiles)
local spatial = require(script.Parent.spatial)
local alliances = require(script.Parent.alliances)
local deaths = require(script.Parent.deaths)
local orders = require(script.Parent.orders)

type Entity = types.Entity
type EntityId = types.EntityId

type Slot = {
	-- the drone in this place on the carrier, or nil while it has none
	id: EntityId?,
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
	control.dock(drone.id, true)
	return { id = drone.id }
end

-- The nearest enemy the drones can fight, in range of the carrier, and not hanging from a transport.
local function find_target(carrier: Entity, spec: types.Carrier, drone_def: types.EntityDef): Entity?
	local best: Entity? = nil
	local best_distance = spec.engage_range
	local position = carrier.position
	spatial.each_target(position.X, position.Z, best_distance, alliances.root_of(carrier.team), function(other: Entity)
		if state.carrier_of(other.id) ~= nil then
			return nil
		end
		if
			targeting.is_enemy(carrier, other)
			and (drone_def.weapons == nil or shot_rules.reach_against(drone_def, other) ~= nil)
		then
			local distance = geometry.distance_2d(carrier.position, other.position)
			if distance <= best_distance and targeting.spots(other, distance) then
				best = other
				best_distance = distance
			end
		end
		return nil
	end)
	return best
end

local function serve(carrier: Entity, def: types.EntityDef, spec: types.Carrier, delta: number)
	-- the next drone is built whatever the ones out are doing
	local reserve = carrier.drone_stockpile :: types.Stocked
	stockpiles.grow(carrier, spec.stockpile, reserve, delta)

	local slots = carriers[carrier.id]
	if slots == nil then
		-- it comes with its first few for nothing
		slots = {}
		for index = 1, spec.count do
			slots[index] = if index <= spec.starting then spawn(carrier, def, spec, index) else { id = nil }
		end
		carriers[carrier.id] = slots
		return
	end

	local drone_def = unit_defs.get(spec.drone)
	local target = find_target(carrier, spec, drone_def)

	for index, slot in slots do
		local drone = if slot.id ~= nil then state.get(slot.id) else nil
		if drone == nil then
			-- shot down, it is spent; the place is filled from the stockpile, if there is one ready
			slot.id = nil
			if reserve.held >= 1 then
				reserve.held -= 1
				slots[index] = spawn(carrier, def, spec, index)
			end
			continue
		end

		local seat = perch(carrier, def, drone_def, index, spec.count)
		if target ~= nil then
			control.dock(drone.id, false)
			local first = drone.orders[1]
			if first == nil or first.kind ~= "attack" or first.target_id ~= target.id then
				orders.issue(drone, { { kind = "attack", position = nil, target_id = target.id } }, false, false)
			end
		elseif control.mode_of(drone) == "docked" then
			-- parked: carried along with the carrier, as cargo hangs from a transport
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
			control.dock(drone.id, true)
			orders.issue(drone, {}, false, false)
			drone.position = seat
			drone.velocity = Vector3.zero
		else
			-- nothing to fight: back to the perch, which moves with the carrier
			orders.push_move(drone, seat, false)
			movement.set_hover(drone, seat.Y)
		end
	end
end

-- Serves every carrier that can act (`control.can_act`): one that is stunned builds, sends and mends nothing, and its
-- drones stay as they are until it comes round. Runs once a tick, after the movement goals are cleared and before
-- orders read them. A carrier may be a unit, like the Mantis, or a building, like the Rampart.
local function tick(delta: number)
	for _, entity in state.all() do
		local def = entity.def
		if def.carrier ~= nil and control.can_act(entity) then
			serve(entity, def, def.carrier, delta)
		end
	end
end

-- A carrier that is gone takes its drones with it.
local function forget(carrier_id: EntityId)
	local slots = carriers[carrier_id]
	if slots == nil then
		return
	end
	carriers[carrier_id] = nil
	for _, slot in slots do
		local drone = if slot.id ~= nil then state.get(slot.id) else nil
		if drone ~= nil then
			deaths.destroy(drone, "removed")
		end
	end
end

return table.freeze({
	forget = forget,
	tick = tick,
})
