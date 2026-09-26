--!strict
-- A commander's manual weapon, its disintegrator (`EntityDef.manual_weapon`), which only a dgun order or its pilot
-- fires. A rectangle sweeps out from the shooter along the line it is fired down for the weapon's whole range, and
-- everything inside it except the shooter is destroyed outright, with no wreck: it is disintegrated, whoever it belonged
-- to, your own included, as in BAR, and an ally's too with ally griefing on; without it an ally's things are passed
-- through untouched. Only an enemy commander stops it: one in the way blocks the shot, which is BAR's answer to one
-- commander disintegrating another. Anything that even touches the rectangle counts, so each thing counts as a circle
-- its collider wide.

local ReplicatedStorage = game:GetService "ReplicatedStorage"

local types = require(ReplicatedStorage.Shared.types)
local unit_defs = require(ReplicatedStorage.Shared.unit_defs)
local geometry = require(ReplicatedStorage.Shared.geometry)

local state = require(script.Parent.state)
local economy = require(script.Parent.economy)
local spatial = require(script.Parent.spatial)
local alliances = require(script.Parent.alliances)
local air = require(script.Parent.air)
local control = require(script.Parent.control)
local deaths = require(script.Parent.deaths)
local shot_feed = require(script.Parent.shot_feed)

type Entity = types.Entity

-- What came of trying to fire a manual weapon: it "fired"; it is "waiting", for its reload or for energy, and
-- can be tried again; it is "blocked", by an enemy commander in the way, which is no better a moment later; or
-- the shooter is "unable" to, being dead, unfinished or without one.
export type Result = "fired" | "waiting" | "blocked" | "unable"

-- Fires `shooter`'s manual weapon toward `aim`: straight ahead if it was aimed at the shooter itself.
local function fire(shooter: Entity, aim: Vector3): Result
	if shooter.alive == false or shooter.state ~= "active" then
		return "unable"
	end
	local weapon = shooter.def.manual_weapon
	if weapon == nil then
		return "unable"
	end
	if shooter.manual_reload_remaining > 0 or control.can_act(shooter) == false then
		return "waiting"
	end

	local direction = geometry.flatten(aim - shooter.position)
	if direction.Magnitude < 1e-3 then
		direction = Vector3.new(math.sin(shooter.facing), 0, math.cos(shooter.facing))
	else
		direction = direction.Unit
	end
	local sideways = Vector3.new(-direction.Z, 0, direction.X)

	-- Which of the others the rectangle touches. Each counts as a circle its collider wide.
	local inside = {}
	local blocked = false
	-- everything the rectangle could touch is within this of its middle, give or take its own collider
	local middle = shooter.position + direction * (weapon.range / 2)
	local extent = math.sqrt((weapon.range / 2) ^ 2 + weapon.radius ^ 2)
	spatial.each_collider_near(middle.X, middle.Z, extent, function(other: Entity, reach: number)
		-- it sweeps the ground, so an aircraft that is up in the air is over it, and so is what hangs from a transport;
		-- a reclaimable is not harmed by it, as it is by nothing (`damage_immunity`), and is not among the colliders at
		-- all
		if
			other.id == shooter.id
			or air.is_airborne(other)
			or state.carrier_of(other.id) ~= nil
			or alliances.may_harm(shooter.team, other.team) == false
		then
			return
		end
		local offset = geometry.flatten(other.position - shooter.position)
		local along = offset:Dot(direction)
		local across = math.abs(offset:Dot(sideways))
		if along >= -reach and along <= weapon.range + reach and across <= weapon.radius + reach then
			-- an enemy commander in the way blocks the shot entirely: nothing is fired, nothing is spent
			if unit_defs.is_commander(other.def) and alliances.are_allied(shooter.team, other.team) == false then
				blocked = true
			end
			table.insert(inside, other)
		end
	end)
	if blocked then
		return "blocked"
	end

	if economy.spend(shooter.team, 0, weapon.energy_per_shot, shooter.id) == false then
		return "waiting"
	end
	shooter.manual_reload_remaining = weapon.reload

	-- drawn from the commander's gun, sloping down (or up) through the point aimed at and on to the end of its range
	local from = unit_defs.muzzle_of(shooter.def, shooter.position)
	local run = geometry.flatten(aim - from).Magnitude
	local rise = if run < 1e-3 then 0 else (aim.Y - from.Y) / run
	shot_feed.send({
		kind = "sweep",
		from = from,
		to = from + direction * weapon.range + Vector3.new(0, rise * weapon.range, 0),
		radius = weapon.radius,
	})

	for _, other in inside do
		deaths.destroy(other, "disintegrated", shooter)
	end
	return "fired"
end

-- Counts `entity`'s manual weapon's reload down by `delta`, for something that can act at all (weapons' `tick`).
local function reload(entity: Entity, delta: number)
	if entity.manual_reload_remaining > 0 then
		entity.manual_reload_remaining = math.max(0, entity.manual_reload_remaining - delta)
	end
end

return table.freeze({
	fire = fire,
	reload = reload,
})
