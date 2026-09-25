-- Transports. A transport picks something up, carries it hanging beneath it, and sets it down where it is
-- told to. It can pick up its own side's units and the enemy's, and static defences as well as units, so long
-- as the thing has a weight class the transport can lift, with the one exception of an enemy commander. What it
-- carries is kept by `state`, in a hold.
--
-- Something being carried is inactive: it is out of the simulation, so it cannot act. It is still drawn, dangling
-- on a rope straight beneath the transport, and it can still be shot at where it hangs and reclaimed from under it
-- (`state.find`); what kills it there drops its wreck to the ground under it.
--
-- Picking something up is delicate. The transport has to come down to it until they are effectively touching,
-- and be very nearly still beside it, so a thing that moves about is harder to catch, an enemy that moves
-- harder still, and a tower that cannot move as easy as anything. A hold has a capacity in slots, and what goes
-- in takes as many as `unit_defs.transport_slots` says. A light transport takes only light things where a
-- heavy one takes light and heavy. A transport that is lost kills what it carries (combat.lose_cargo), which
-- falls to the ground where it hung; a commander always leaves its wreck there.

local ReplicatedStorage = game:GetService "ReplicatedStorage"

local types = require(ReplicatedStorage.Shared.types)
local config = require(ReplicatedStorage.Shared.config)
local unit_defs = require(ReplicatedStorage.Shared.unit_defs)
local geometry = require(ReplicatedStorage.Shared.geometry)

local state = require(script.Parent.state)
local placement = require(script.Parent.placement)
local combat = require(script.Parent.combat)
local movement = require(script.Parent.movement)
local air = require(script.Parent.air)
local alliances = require(script.Parent.alliances)

type Entity = types.Entity
type EntityId = types.EntityId

type Placed = {
	position: Vector3,
	half: Vector2,
}

-- How many rings of spots round the drop point are tried for each thing before it is left aboard.
local UNLOAD_RINGS = 6
-- A transport comes down to pick something up over it or over one of this many spots this far from it, in studs,
-- whichever it can come lowest over; somewhere other than straight over it has to be at least HOOK_SPOT_PREFERENCE
-- studs lower to be worth it.
local HOOK_SPOTS = 8
local HOOK_SPOT_REACH = 2
local HOOK_SPOT_PREFERENCE = 0.25

-- How many slots the transport can hold in all; none if it is not a transport.
local function capacity_of(transport: Entity): number
	local carrying = unit_defs.of(transport).transport
	if carrying == nil then
		return 0
	end
	return carrying.capacity
end

-- How many of its slots are taken.
local function slots_used(transport_id: EntityId): number
	local used = 0
	for _, cargo in state.cargo_of(transport_id) do
		used += unit_defs.transport_slots(unit_defs.of(cargo))
	end
	return used
end

-- Whether `transport` can pick `cargo` up at all, if it were in reach. Whose it is does not matter, except that
-- an enemy commander can never be carried off.
local function can_load(transport: Entity, cargo: Entity): boolean
	if transport.alive == false or transport.state ~= "active" or cargo.alive == false or cargo.state ~= "active" then
		return false
	end
	if transport.id == cargo.id or cargo.kind == "wreck" or cargo.kind == "reclaimable" then
		return false
	end
	-- what is already in a hold is not taken out of it by another transport
	if state.carrier_of(cargo.id) ~= nil then
		return false
	end
	local cargo_def = unit_defs.of(cargo)
	if cargo_def.nametag == true and alliances.are_allied(transport.team, cargo.team) == false then
		return false
	end
	if unit_defs.can_carry(unit_defs.of(transport), cargo_def) == false then
		return false
	end
	return slots_used(transport.id) + unit_defs.transport_slots(cargo_def) <= capacity_of(transport)
end

-- The height the middle of `transport` is at when it hangs just over the top of `cargo`.
local function hook_height(transport: Entity, cargo: Entity): number
	local transport_half = unit_defs.collider_height(unit_defs.of(transport)) / 2
	local cargo_half = unit_defs.collider_height(unit_defs.of(cargo)) / 2
	return cargo.position.Y + cargo_half + transport_half + config.TRANSPORT_HOOK_GAP
end

-- Where over `cargo` the transport comes down to pick it up: of the spots within its reach of it, the one it can
-- come lowest over, so that ground rising beside the thing, like the foot of a slope, does not hold it up out of
-- reach. Straight over it unless somewhere else is clearly lower.
local function hook_spot(transport: Entity, cargo: Entity): Vector3
	local def = unit_defs.of(transport)
	local at = cargo.position
	local best = at
	local lowest = air.resting_height(def, at.X, at.Z) - HOOK_SPOT_PREFERENCE
	for index = 0, HOOK_SPOTS - 1 do
		local angle = index * (2 * math.pi / HOOK_SPOTS)
		local x = at.X + math.cos(angle) * HOOK_SPOT_REACH
		local z = at.Z + math.sin(angle) * HOOK_SPOT_REACH
		local height = air.resting_height(def, x, z)
		if height < lowest then
			best = Vector3.new(x, at.Y, z)
			lowest = height
		end
	end
	return best
end

-- Flies `transport` to `cargo`, keeping pace with it, and down over the top of it, ready to be picked up. It
-- flies there at its usual height, and only comes down once it is over the thing: coming down on the way would
-- drag it along any ground between them that is higher than where the thing stands.
local function reach_for(transport: Entity, cargo: Entity)
	local spot = hook_spot(transport, cargo)
	-- it stops close enough to the spot to be well within its reach of the thing
	local stop_radius = (config.TRANSPORT_LOAD_RANGE - HOOK_SPOT_REACH) / 2
	movement.set_tracking_goal(transport, spot, stop_radius, cargo.velocity)
	if geometry.distance_2d(transport.position, cargo.position) <= config.TRANSPORT_DESCEND_RANGE then
		movement.set_hover(transport, hook_height(transport, cargo))
	end
end

-- Whether `transport` is close and still enough beside `cargo` to take it aboard this instant: effectively
-- touching it, or as near as the ground lets it come and within a rope's length, and moving so little relative
-- to it that the hook can catch. It is stricter for the enemy's
-- things, which makes any of them that are moving hard to get hold of, and easy for a tower, which never moves.
-- Whether `cargo` is within the reach of `transport`'s hook, however they are moving: the first half of `in_grasp`, and
-- all a pilot has to manage (see server/possession.luau).
local function in_reach(transport: Entity, cargo: Entity): boolean
	if geometry.distance_2d(transport.position, cargo.position) > config.TRANSPORT_LOAD_RANGE then
		return false
	end
	local transport_def = unit_defs.of(transport)
	local position = transport.position
	local underside = position.Y - unit_defs.collider_height(transport_def) / 2
	local top = cargo.position.Y + unit_defs.collider_height(unit_defs.of(cargo)) / 2
	-- one that can come no lower, held up by ground rising beside the thing, lets its hook down on the rope
	local reach = config.TRANSPORT_LOAD_HEIGHT
	if position.Y <= air.resting_height(transport_def, position.X, position.Z) + config.TRANSPORT_LOAD_HEIGHT then
		reach += config.TRANSPORT_ROPE
	end
	return underside - top <= reach
end

local function in_grasp(transport: Entity, cargo: Entity): boolean
	if in_reach(transport, cargo) == false then
		return false
	end
	local limit = if cargo.team == transport.team
		then config.TRANSPORT_LOAD_SPEED
		else config.TRANSPORT_ENEMY_LOAD_SPEED
	return geometry.flatten(transport.velocity - cargo.velocity).Magnitude <= limit
end

-- Takes `cargo` aboard. Its orders are kept, not forgotten: nothing runs them while it is in the hold, and it
-- takes them up again once it is set down.
local function load(transport: Entity, cargo: Entity)
	cargo.velocity = Vector3.zero
	combat.set_forced_target(cargo, nil)
	state.stow(transport.id, cargo)
end

-- Where the cargo at `index` of `count` hangs from `transport`: on a rope straight below it, spread round its
-- middle if there is more than one thing. Never offset by the transport's velocity: that trails the cargo behind
-- it for as long as it flies, which reads as lag, not swing.
local function dangle_position(transport: Entity, cargo: Entity, index: number, count: number): Vector3
	local transport_def = unit_defs.of(transport)
	local cargo_def = unit_defs.of(cargo)
	local drop = unit_defs.collider_height(transport_def) / 2
		+ config.TRANSPORT_ROPE
		+ unit_defs.collider_height(cargo_def) / 2

	local spread = Vector3.zero
	if count > 1 then
		local angle = (index - 1) / count * math.pi * 2
		spread = Vector3.new(math.cos(angle), 0, math.sin(angle)) * config.TRANSPORT_CARGO_SPREAD
	end

	local x = transport.position.X + spread.X
	local z = transport.position.Z + spread.Z
	-- it can be lowered no further than the ground
	local y = math.max(transport.position.Y - drop, air.resting_height(cargo_def, x, z))
	return Vector3.new(x, y, z)
end

-- The height the middle of `transport` is at when what it carries hangs just clear of the ground under it: low
-- enough to set it down, and no lower, so that nothing it carries is dragged along the ground on the way.
local function set_down_height(transport: Entity): number
	local transport_def = unit_defs.of(transport)
	local x = transport.position.X
	local z = transport.position.Z
	local height = air.resting_height(transport_def, x, z)
	for _, cargo in state.cargo_of(transport.id) do
		local cargo_def = unit_defs.of(cargo)
		local drop = unit_defs.collider_height(transport_def) / 2
			+ config.TRANSPORT_ROPE
			+ unit_defs.collider_height(cargo_def) / 2
		height = math.max(height, air.resting_height(cargo_def, x, z) + drop + config.TRANSPORT_HOOK_GAP)
	end
	return height
end

-- Whether `transport` is low enough to let go of what it carries.
local function low_enough(transport: Entity): boolean
	return transport.position.Y <= set_down_height(transport) + config.TRANSPORT_LOAD_HEIGHT
end

-- Brings `transport` down to set what it carries down, and returns whether it is low enough to let go of it.
local function lower(transport: Entity): boolean
	movement.set_hover(transport, set_down_height(transport))
	return low_enough(transport)
end

-- Hangs everything a transport carries from it. Run once a step, after everything has moved.
local function tick()
	for _, transport in state.all() do
		if transport.alive == false or unit_defs.of(transport).transport == nil then
			continue
		end
		local cargo_list = state.cargo_of(transport.id)
		for index, cargo in cargo_list do
			cargo.position = dangle_position(transport, cargo, index, #cargo_list)
			cargo.facing = transport.facing
			cargo.velocity = transport.velocity
		end
	end
end

-- The first free spot for `cargo` on the rings round `at`, one that clears the ground and everything on it,
-- and the things already set down in this same unloading, which are not in the world yet.
local function find_spot(cargo: Entity, at: Vector3, placed: { Placed }): Vector3?
	local def = unit_defs.of(cargo)
	local half = placement.half_extents_for(cargo)
	local step = unit_defs.collider_radius(def) * 2 + config.TRANSPORT_UNLOAD_GAP

	for ring = 0, UNLOAD_RINGS do
		local count = math.max(1, ring * 6)
		for index = 0, count - 1 do
			local angle = index * (math.pi * 2 / count)
			-- a building is put on the grid, wherever it is that the ring puts it
			local center = placement.resolve_center(
				cargo.def_name,
				at.X + math.cos(angle) * ring * step,
				at.Z + math.sin(angle) * ring * step,
				cargo.facing
			)
			if center == nil then
				continue
			end
			local placeable = placement.can_place(cargo.def_name, center, cargo.facing, nil)
			if placeable == false then
				continue
			end

			local free = true
			for _, other in placed do
				if geometry.aabb_overlap(center, half, other.position, other.half, 0) then
					free = false
					break
				end
			end
			if free then
				return center
			end
		end
	end
	return nil
end

-- Sets everything `transport` carries down around `at`, as many as there is room for. What has no spot
-- stays aboard.
local function unload(transport: Entity, at: Vector3)
	local placed: { Placed } = {}
	for _, cargo in table.clone(state.cargo_of(transport.id)) do
		-- a building only stands square to the grid, and a thing that was swung round stands the way it hangs
		if cargo.kind == "building" then
			cargo.facing = geometry.snap_facing(cargo.facing)
		end
		local spot = find_spot(cargo, at, placed)
		if spot ~= nil then
			table.insert(placed, { position = spot, half = placement.half_extents_for(cargo) })
			state.unstow(transport.id, cargo, spot)
		end
	end
end

return table.freeze({
	capacity_of = capacity_of,
	slots_used = slots_used,
	can_load = can_load,
	reach_for = reach_for,
	in_grasp = in_grasp,
	in_reach = in_reach,
	load = load,
	lower = lower,
	low_enough = low_enough,
	tick = tick,
	unload = unload,
})
