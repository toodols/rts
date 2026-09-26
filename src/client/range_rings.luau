--!strict
-- How far something reaches, as rings on the ground round it (client/hover.luau shows them for what the cursor is over
-- and what is being placed): how far it can build, how far it can shoot, and for an anti-nuke how far out it shoots
-- nukes down; and for a factory, an arrow out of its front, the side its units come out of. The rings are laid on the
-- ground so that they climb hills (markers.draw_ring).

local ReplicatedStorage = game:GetService "ReplicatedStorage"

local types = require(ReplicatedStorage.Shared.types)
local ground_levels = require(ReplicatedStorage.Shared.ground_levels)
local unit_defs = require(ReplicatedStorage.Shared.unit_defs)
local heightmap = require(ReplicatedStorage.Shared.heightmap)
local projectile = require(ReplicatedStorage.Shared.projectile)

local world_fx = require(ReplicatedStorage.Client.world_fx)
local markers = require(ReplicatedStorage.Client.markers)

local palette = require(ReplicatedStorage.ClientShared.palette)

type Pool = world_fx.Pool

local BUILD_RING_COLOR = palette.accent
local ATTACK_RING_COLOR = palette.danger
local INTERCEPT_RING_COLOR = palette.energy
-- The arrow out of a factory's front: how far past the footprint's edge it starts, how long its shaft is, and how long
-- each side of its head.
local FRONT_ARROW_COLOR = palette.text
local FRONT_ARROW_GAP = 1
local FRONT_ARROW_LENGTH = 7
local FRONT_ARROW_HEAD = 2.5
-- How many times the reach of an arcing weapon is worked out again in each direction, for the ground where the
-- last guess put it. The ground changes slowly enough that it settles in a few.
local REACH_ITERATIONS = 4

local ring_pool = world_fx.pool(markers.make_dash)

-- The weapon something of `def` reaches furthest with, which is the one its attack ring is drawn for. An
-- anti-nuke's interceptor has a ring of its own.
local function longest_weapon(def: types.EntityDef): types.Weapon?
	local longest: types.Weapon? = nil
	if def.weapons ~= nil then
		for _, weapon in def.weapons do
			if unit_defs.is_anti_nuke(weapon) == false and (longest == nil or weapon.range > longest.range) then
				longest = weapon
			end
		end
	end
	return longest
end

-- The ground at (x, z), or the water's surface over it.
local function surface_at(x: number, z: number): Vector3
	local ground = heightmap.ground_position(x, z)
	return Vector3.new(x, math.max(ground.Y, ground_levels.WATER_LEVEL), z)
end

-- An arrow on the ground pointing out of the front of something of `def` standing at `center`, turned to `facing`.
local function draw_front_arrow(pool: Pool, center: Vector3, def: types.EntityDef, facing: number)
	local forward = Vector3.new(math.sin(facing), 0, math.cos(facing))
	local start = FRONT_ARROW_GAP + unit_defs.footprint_half_extents(def).Y
	local tail = center + forward * start
	local tip = center + forward * (start + FRONT_ARROW_LENGTH)
	local tip_point = surface_at(tip.X, tip.Z)
	markers.draw_leg(pool, surface_at(tail.X, tail.Z), tip_point, FRONT_ARROW_COLOR)
	for _, side in { 1, -1 } do
		local back = CFrame.Angles(0, side * math.pi * 3 / 4, 0):VectorToWorldSpace(forward) * FRONT_ARROW_HEAD
		local barb = tip + back
		markers.draw_leg(pool, tip_point, surface_at(barb.X, barb.Z), FRONT_ARROW_COLOR)
	end
end

-- How far the attack ring of something of `def` at `center` reaches in each direction, for its longest weapon
-- (`weapon`) of `attack_range`: as far as a shell that arcs under gravity really reaches, which is further over ground
-- lower than `muzzle`, where its shells come from, and less far over ground higher up, the way the server judges it
-- (`projectile.range_to`); anything else, a circle.
local function reach_of(
	center: Vector3,
	attack_range: number,
	weapon: types.Weapon?,
	muzzle: Vector3?
): (direction: Vector3) -> number
	if weapon == nil or weapon.delivery.kind ~= "lobbed" or muzzle == nil then
		return function(_: Vector3): number
			return attack_range
		end
	end
	return function(direction: Vector3): number
		local out = weapon.range
		for _ = 1, REACH_ITERATIONS do
			local ground = heightmap.ground_position(center.X + direction.X * out, center.Z + direction.Z * out)
			out = projectile.range_to(weapon.range, muzzle, ground, weapon.delivery)
		end
		return out
	end
end

-- Shows a build range ring, an attack range ring and an intercept ring, whichever of them apply, around `center`,
-- and, given the way it faces, an arrow out of the front of a factory. The attack ring is as far as the longest weapon
-- really reaches (`reach_of`); one whose longest weapon fires only into a cone ahead (`fire_arc`), like a submarine's
-- torpedo tubes, is drawn as that cone, turned to `facing`.
local function show(
	center: Vector3,
	build_range: number?,
	attack_range: number?,
	def: types.EntityDef?,
	muzzle: Vector3?,
	intercept_range: number?,
	facing: number?
)
	ring_pool.used = 0
	if def ~= nil and facing ~= nil and unit_defs.is_factory(def) then
		draw_front_arrow(ring_pool, center, def, facing)
	end
	if build_range ~= nil then
		markers.draw_circle(ring_pool, center, build_range, BUILD_RING_COLOR)
	end
	if attack_range ~= nil then
		local weapon = if def ~= nil then longest_weapon(def) else nil
		if weapon ~= nil and weapon.range ~= attack_range then
			weapon = nil
		end
		local reach = reach_of(center, attack_range, weapon, muzzle)
		local arc = if weapon ~= nil then weapon.fire_arc else nil
		if arc ~= nil and facing ~= nil and arc < math.pi then
			local left, right =
				markers.draw_arc(ring_pool, center, reach, ATTACK_RING_COLOR, facing - arc, facing + arc)
			markers.draw_leg(ring_pool, center, left, ATTACK_RING_COLOR)
			markers.draw_leg(ring_pool, center, right, ATTACK_RING_COLOR)
		else
			markers.draw_ring(ring_pool, center, reach, ATTACK_RING_COLOR)
		end
	end
	if intercept_range ~= nil then
		markers.draw_circle(ring_pool, center, intercept_range, INTERCEPT_RING_COLOR)
	end
	world_fx.release_rest(ring_pool)
end

local function hide()
	ring_pool.used = 0
	world_fx.release_rest(ring_pool)
end

return table.freeze({
	show = show,
	hide = hide,
})
