--!strict
-- Beam weapons: lasers and lightning guns (`types.Beam`). A beam strikes the first thing on the line to what it is
-- fired at (`sight.first_hit`), which is the target itself unless something stands between. It stays up for its `time`,
-- and deals its damage over that time rather than all at once when it fires: a slice every tick, the first as it fires.
-- Each slice after the first is aimed again from where the shooter is at what it was fired at, and strikes the first
-- thing on that line, as the first did, so a friend that walks into the beam takes the rest of it. It goes out when the
-- shooter dies or its target does, or what it was fired at gets out of reach, and what was left of it is lost. A lightning gun's
-- bolt also throws sparks from where it strikes (`types.Lightning`).

local ReplicatedStorage = game:GetService "ReplicatedStorage"

local types = require(ReplicatedStorage.Shared.types)
local tick_rate = require(ReplicatedStorage.Shared.tick_rate)
local unit_defs = require(ReplicatedStorage.Shared.unit_defs)
local geometry = require(ReplicatedStorage.Shared.geometry)
local teams = require(ReplicatedStorage.Shared.teams)

local state = require(script.Parent.state)
local sight = require(script.Parent.sight)
local spatial = require(script.Parent.spatial)
local damage = require(script.Parent.damage)
local muzzles = require(script.Parent.muzzles)
local shot_feed = require(script.Parent.shot_feed)

type Entity = types.Entity
type EntityId = types.EntityId
type Weapon = types.Weapon
type Aim = sight.Aim

-- A beam still burning after the tick it was fired in.
type Burning = {
	shooter_id: EntityId,
	weapon: Weapon,
	-- which of its shooter's weapons it is, for where it is fired from (`muzzles`)
	index: number,
	-- what it was fired at: a target, or for an attack-ground order a bare point
	target_id: EntityId?,
	point: Vector3?,
	slices_left: number,
	slice: number,
}
local burning: { Burning } = {}

-- How many ticks `beam` burns for, and so how many slices its damage comes in: at least one, for a beam that is up for
-- less than a tick, or has no time at all.
local function slices_of(beam: types.Beam): number
	return math.max(1, math.round((beam.time or 0) / tick_rate.TICK_DELTA))
end

-- Starts `beam`, weapon `index` of `attacker`'s, at `aim`, which has already struck `struck`, if anything, with its
-- first slice: the rest follow in the ticks after this one (see `tick`).
local function burn(attacker: Entity, weapon: Weapon, index: number, beam: types.Beam, struck: Entity?, aim: Aim)
	local slices = slices_of(beam)
	local slice = weapon.damage / slices
	if struck ~= nil then
		damage.hit(struck, slice, weapon, attacker.id, attacker.team, true)
	end
	if slices > 1 then
		local target = sight.target_of(aim)
		table.insert(burning, {
			shooter_id = attacker.id,
			weapon = weapon,
			index = index,
			target_id = if target ~= nil then target.id else nil,
			point = if target == nil then sight.position_of(aim) else nil,
			slices_left = slices - 1,
			slice = slice,
		})
	end
end

-- Whether any of `def`'s weapons is a lightning gun, which makes it proof against lightning's sparks, as in BAR.
local lightning_proof: { [types.EntityDef]: boolean } = {}
local function is_lightning_proof(def: types.EntityDef): boolean
	local cached = lightning_proof[def]
	if cached == nil then
		cached = false
		local weapons = def.weapons
		if weapons ~= nil then
			for _, weapon in weapons do
				local delivery = weapon.delivery
				if delivery.kind == "beam" and delivery.lightning ~= nil then
					cached = true
				end
			end
		end
		lightning_proof[def] = cached
	end
	return cached
end

-- A bolt of `weapon`'s, a lightning gun fired by `attacker` whose sparks are `lightning`, has ended at `at`, striking
-- `struck` if anything: its sparks jump to what is nearest there (`types.Lightning`), friend and foe alike, each thing
-- measured to the nearest point of its collider as a blast measures it. Returns where each spark went, for the clients
-- to draw.
local function spark(
	attacker: Entity,
	weapon: Weapon,
	lightning: types.Lightning,
	at: Vector3,
	struck: Entity?
): { Vector3 }
	local near: { Entity } = {}
	local distances: { [Entity]: number } = {}
	-- no side is left out, the attacker's own included; what is nobody's, remains and scenery, is
	spatial.each_target(at.X, at.Z, lightning.range + spatial.TARGET_CELL, nil, function(other: Entity): boolean?
		if other.alive == false or other.team == teams.NEUTRAL or (struck ~= nil and other.id == struck.id) then
			return nil
		end
		local def = other.def
		if is_lightning_proof(def) or unit_defs.submerged(def, other.position) then
			return nil
		end
		local position = other.position
		local sideways =
			math.max(0, Vector2.new(position.X - at.X, position.Z - at.Z).Magnitude - unit_defs.collider_radius(def))
		local vertical = math.max(0, math.abs(position.Y - at.Y) - unit_defs.collider_height(def) / 2)
		local distance = math.sqrt(sideways * sideways + vertical * vertical)
		if distance <= lightning.range then
			table.insert(near, other)
			distances[other] = distance
		end
		return nil
	end)
	table.sort(near, function(a: Entity, b: Entity): boolean
		return distances[a] < distances[b]
	end)
	local ends: { Vector3 } = {}
	for index = 1, math.min(lightning.forks, #near) do
		local other = near[index]
		table.insert(ends, other.position)
		damage.hit(other, weapon.damage * lightning.fork_damage, weapon, attacker.id, attacker.team, false)
	end
	return ends
end

-- Tells the clients about a beam of weapon `index` of `attacker`'s from `from` to `to`, a lightning gun's with its
-- sparks, which it throws now: the bolt strikes `struck` before its sparks jump, which leave out what it struck even
-- when that is now dead.
local function show(
	attacker: Entity,
	weapon: Weapon,
	index: number,
	beam: types.Beam,
	from: Vector3,
	to: Vector3,
	struck: Entity?
)
	local lightning = beam.lightning
	if lightning ~= nil then
		shot_feed.send({
			kind = "lightning",
			def_name = attacker.def_name,
			skin = attacker.skin,
			weapon = index,
			from = from,
			to = to,
			team = attacker.team,
			sparks = spark(attacker, weapon, lightning, to, struck),
		})
	else
		shot_feed.send({
			kind = "beam",
			def_name = attacker.def_name,
			skin = attacker.skin,
			weapon = index,
			from = from,
			to = to,
			team = attacker.team,
		})
	end
end

-- Fires `beam`, weapon `index` of `attacker`'s, from `origin` at `aim`: it strikes the first thing on the line
-- (`sight.first_hit`), and with nothing there, aimed at a bare point, it goes into the ground there. It is drawn as far
-- as where it goes into what it strikes, about where the line meets its collider, and no further than what it was aimed
-- at.
local function fire(attacker: Entity, weapon: Weapon, index: number, beam: types.Beam, origin: Vector3, aim: Aim)
	local struck = sight.first_hit(attacker, aim, origin)
	local to = sight.position_of(aim)
	local line = to - origin
	if struck ~= nil and line.Magnitude > 1e-3 then
		local direction = line.Unit
		local along = (struck.position - origin):Dot(direction) - unit_defs.collider_radius(struck.def)
		to = origin + direction * math.clamp(along, 0, line.Magnitude)
	end
	burn(attacker, weapon, index, beam, struck, aim)
	show(attacker, weapon, index, beam, origin, to, struck)
end

-- Burns every beam that is still up for one more tick: each deals its next slice to whatever is first on the line
-- from where its shooter is now to what it was fired at, and goes out once it has dealt its last, or has nothing
-- left to burn at.
local function tick()
	local index = 1
	while index <= #burning do
		local beam = burning[index]
		local shooter = state.get(beam.shooter_id)
		local struck: Entity? = nil
		local lit = shooter ~= nil
		if shooter ~= nil then
			local origin = muzzles.origin_of(shooter, muzzles.frame_of(shooter), beam.index)
			local aim: Aim? = if beam.target_id ~= nil then state.get(beam.target_id, true) else beam.point
			if aim == nil or geometry.distance_2d(shooter.position, sight.position_of(aim)) > beam.weapon.range then
				lit = false
			else
				struck = sight.first_hit(shooter, aim, origin)
			end
		end
		if shooter ~= nil and struck ~= nil then
			damage.hit(struck, beam.slice, beam.weapon, shooter.id, shooter.team, true)
		end
		beam.slices_left -= 1
		if lit == false or beam.slices_left <= 0 then
			burning[index] = burning[#burning]
			burning[#burning] = nil
		else
			index += 1
		end
	end
end

return table.freeze({
	fire = fire,
	tick = tick,
})
