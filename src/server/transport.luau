-- Transports. A transport picks something up, carries it hanging beneath it, and sets it down where it is
-- told to. It can pick up its own side's units and the enemy's, and static defences as well as units, so long
-- as the thing has a weight class the transport can lift. What it carries is kept by `state`, in a hold.
--
-- Something being carried is inactive: it is out of the simulation, so it cannot act and nothing acts on it.
-- It is still drawn, dangling from the transport on a rope, swinging as the transport turns and accelerates.
--
-- Picking something up is delicate. The transport has to come down to it until they are effectively touching,
-- and be very nearly still beside it, so a thing that moves about is harder to catch, an enemy that moves
-- harder still, and a tower that cannot move as easy as anything. A hold has a capacity in slots, and what goes
-- in takes as many as `unit_defs.transport_slots` says. A light transport takes only light things where a
-- heavy one takes light and heavy. A transport that is destroyed takes what it carries down with it.

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

type Entity = types.Entity
type EntityId = types.EntityId

type Placed = {
	position: Vector3,
	half: Vector2,
}

-- How many rings of spots round the drop point are tried for each thing before it is left aboard.
local UNLOAD_RINGS = 6

-- How many slots the transport can hold in all; none if it is not a transport.
local function capacity_of(transport: Entity): number
	local carrying = unit_defs.get(transport.def_name).transport
	if carrying == nil then
		return 0
	end
	return carrying.capacity
end

-- How many of its slots are taken.
local function slots_used(transport_id: EntityId): number
	local used = 0
	for _, cargo in state.cargo_of(transport_id) do
		used += unit_defs.transport_slots(unit_defs.get(cargo.def_name))
	end
	return used
end

-- Whether `transport` can pick `cargo` up at all, if it were in reach. Whose it is does not matter.
local function can_load(transport: Entity, cargo: Entity): boolean
	if transport.alive == false or transport.state ~= "active" or cargo.alive == false or cargo.state ~= "active" then
		return false
	end
	if transport.id == cargo.id or cargo.kind == "wreck" then
		return false
	end
	local cargo_def = unit_defs.get(cargo.def_name)
	if unit_defs.can_carry(unit_defs.get(transport.def_name), cargo_def) == false then
		return false
	end
	return slots_used(transport.id) + unit_defs.transport_slots(cargo_def) <= capacity_of(transport)
end

-- The height the middle of `transport` is at when it hangs just over the top of `cargo`.
local function hook_height(transport: Entity, cargo: Entity): number
	local transport_half = unit_defs.collider_height(unit_defs.get(transport.def_name)) / 2
	local cargo_half = unit_defs.collider_height(unit_defs.get(cargo.def_name)) / 2
	return cargo.position.Y + cargo_half + transport_half + config.TRANSPORT_HOOK_GAP
end

-- Flies `transport` to `cargo`, keeping pace with it, and down over the top of it, ready to be picked up.
local function reach_for(transport: Entity, cargo: Entity)
	movement.set_tracking_goal(transport, cargo.position, config.TRANSPORT_LOAD_RANGE / 2, cargo.velocity)
	movement.set_hover(transport, hook_height(transport, cargo))
end

-- Whether `transport` is close and still enough beside `cargo` to take it aboard this instant: effectively
-- touching it, and moving so little relative to it that the hook can catch. It is stricter for the enemy's
-- things, which makes any of them that are moving hard to get hold of, and easy for a tower, which never moves.
local function in_grasp(transport: Entity, cargo: Entity): boolean
	if geometry.distance_2d(transport.position, cargo.position) > config.TRANSPORT_LOAD_RANGE then
		return false
	end
	local underside = transport.position.Y - unit_defs.collider_height(unit_defs.get(transport.def_name)) / 2
	local top = cargo.position.Y + unit_defs.collider_height(unit_defs.get(cargo.def_name)) / 2
	if underside - top > config.TRANSPORT_LOAD_HEIGHT then
		return false
	end
	local limit = if cargo.team == transport.team
		then config.TRANSPORT_LOAD_SPEED
		else config.TRANSPORT_ENEMY_LOAD_SPEED
	return geometry.flatten(transport.velocity - cargo.velocity).Magnitude <= limit
end

-- Takes `cargo` aboard. Whatever it was doing is forgotten.
local function load(transport: Entity, cargo: Entity)
	cargo.orders = {}
	cargo.velocity = Vector3.zero
	combat.set_forced_target(cargo, nil)
	state.stow(transport.id, cargo)
end

-- Where the cargo at `index` of `count` hangs from `transport`: on a rope below it, spread round its middle if
-- there is more than one thing, and swung back against the way the transport is moving.
local function dangle_position(transport: Entity, cargo: Entity, index: number, count: number): Vector3
	local transport_def = unit_defs.get(transport.def_name)
	local cargo_def = unit_defs.get(cargo.def_name)
	local drop = unit_defs.collider_height(transport_def) / 2
		+ config.TRANSPORT_ROPE
		+ unit_defs.collider_height(cargo_def) / 2

	local spread = Vector3.zero
	if count > 1 then
		local angle = (index - 1) / count * math.pi * 2
		spread = Vector3.new(math.cos(angle), 0, math.sin(angle)) * config.TRANSPORT_CARGO_SPREAD
	end
	local sway = geometry.flatten(transport.velocity) * -config.TRANSPORT_SWAY

	local x = transport.position.X + spread.X + sway.X
	local z = transport.position.Z + spread.Z + sway.Z
	-- it can be lowered no further than the ground
	local y = math.max(transport.position.Y - drop, air.resting_height(cargo_def, x, z))
	return Vector3.new(x, y, z)
end

-- Hangs everything a transport carries from it. Run once a step, after everything has moved.
local function tick()
	for _, transport in state.all() do
		if transport.alive == false or unit_defs.get(transport.def_name).transport == nil then
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
	local def = unit_defs.get(cargo.def_name)
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
	load = load,
	tick = tick,
	unload = unload,
})
