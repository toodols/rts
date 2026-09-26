--!strict
-- A brain's fighters as groups: what a group is worth and where its middle is, where the army waits (`rally_point`, the
-- profile's rally_offset in front of home), and sending units somewhere (`send`, `send_all`), which each remembers so
-- that it is not sent there again. With the profile's spread a group sent somewhere spreads out (`formation`) rather
-- than all going to one point: units stand the spread apart, or SPLASH_SPACING times the widest splash of the enemy's
-- that is no wider than MAX_SPACING (`widest_splash`), whichever is more, the front of a line FRONT_RATIO units wide for
-- each rank deep; a unit within SETTLED of its place is not sent to it again.

local ReplicatedStorage = game:GetService "ReplicatedStorage"
local ServerScriptService = game:GetService "ServerScriptService"

local types = require(ReplicatedStorage.Shared.types)
local unit_defs = require(ReplicatedStorage.Shared.unit_defs)
local heightmap = require(ReplicatedStorage.Shared.heightmap)
local geometry = require(ReplicatedStorage.Shared.geometry)

local orders = require(ServerScriptService.Server.orders)

local brains = require(script.Parent.brains)
local routes = require(script.Parent.routes)

type Entity = types.Entity
type EntityId = types.EntityId
type EntityDef = types.EntityDef
type OrderKind = types.OrderKind
type Brain = brains.Brain

-- A unit sent to the rally point is there within this of it.
local RALLY_SLACK = 25
-- An army unit is sent again when where it should be has moved this far from where it was sent.
local GOAL_DRIFT = 25
local SPLASH_SPACING = 2
local MAX_SPACING = 14
local FRONT_RATIO = 2
local SETTLED = 3

local function worth_of(units: { Entity }): number
	local total = 0
	for _, unit in units do
		total += unit_defs.power(unit.def)
	end
	return total
end

local function centroid(units: { Entity }): Vector3
	local sum = Vector3.zero
	for _, unit in units do
		sum += unit.position
	end
	return sum / math.max(1, #units)
end

local function rally_point(brain: Brain): Vector3
	local point = brain.home + brain.forward * brain.profile.rally_offset
	if heightmap.in_bounds(point.X, point.Z) == false then
		point = brain.home
	end
	return heightmap.ground_position(point.X, point.Z)
end

-- Sends `unit` to `goal`, fighting its way there or only moving, by a route if it needs one. Returns whether it went:
-- it waits for the next thought when there are no routes left to give in this one.
local function send(brain: Brain, unit: Entity, goal: Vector3, kind: OrderKind): boolean
	local chain = routes.orders_to(brain, unit, goal, kind)
	if chain == nil then
		return false
	end
	orders.issue(unit, chain, false, false)
	brain.goals[unit.id] = goal
	return true
end

-- The widest splash of the enemy's weapons that can be turned on the ground, no wider than MAX_SPACING (a nuke's is not
-- spread out against), for `formation`.
local function widest_splash(enemies: { Entity }): number
	local widest = 0
	local seen: { [EntityDef]: boolean } = {}
	for _, enemy in enemies do
		if seen[enemy.def] then
			continue
		end
		seen[enemy.def] = true
		local weapons: { types.Weapon } = enemy.def.weapons or {}
		for _, weapon in weapons do
			local projectile = unit_defs.projectile_of(weapon)
			if projectile ~= nil and weapon.target_layer ~= "air" and projectile.aoe_radius <= MAX_SPACING then
				widest = math.max(widest, projectile.aoe_radius)
			end
		end
	end
	return widest
end

-- A place of its own for each of `army` sent to `goal` (the profile's spread, `spread` studs apart at the least), or nil
-- for one point for all: round `goal` in a block for a move, each keeping the place it was last sent to if it is still
-- one of them, so that one more coming does not shuffle the rest; and for a fight in a line across the way from where
-- the group stands to `goal`, ranks deep behind it, each unit taking the place in the line on its own side, so that the
-- group spreads across its front rather than scattering and still comes into reach together. As BAR's formation moves.
-- `splash` is the widest splash of the enemy's (`widest_splash`), `forward` the way to face with no way to go, and
-- `sent` where each unit was last sent.
local function formation(
	army: { Entity },
	goal: Vector3,
	kind: OrderKind,
	spread: number?,
	splash: number,
	forward: Vector3,
	sent: { [EntityId]: Vector3 }
): { [EntityId]: Vector3 }?
	if spread == nil or spread <= 0 or #army < 2 then
		return nil
	end
	local spacing = math.clamp(splash * SPLASH_SPACING, spread, math.max(spread, MAX_SPACING))
	local count = #army
	local places: { [EntityId]: Vector3 } = {}
	if kind == "move" then
		local points: { Vector3 } = {}
		local rings = math.ceil(math.sqrt(count)) + 1
		for i = -rings, rings do
			for j = -rings, rings do
				local point = Vector3.new(goal.X + i * spacing, goal.Y, goal.Z + j * spacing)
				if heightmap.in_bounds(point.X, point.Z) then
					table.insert(points, point)
				end
			end
		end
		table.sort(points, function(a, b): boolean
			local da, db = geometry.distance_2d(a, goal), geometry.distance_2d(b, goal)
			if da ~= db then
				return da < db
			end
			if a.X ~= b.X then
				return a.X < b.X
			end
			return a.Z < b.Z
		end)
		local taken: { [number]: boolean } = {}
		local waiting: { Entity } = {}
		for _, unit in army do
			local last: Vector3? = sent[unit.id]
			local kept = false
			if last ~= nil then
				for index = 1, math.min(count, #points) do
					if taken[index] == nil and geometry.distance_2d(points[index], last) < 0.5 then
						taken[index] = true
						places[unit.id] = points[index]
						kept = true
						break
					end
				end
			end
			if kept == false then
				table.insert(waiting, unit)
			end
		end
		for _, unit in waiting do
			local best: number? = nil
			local best_distance = math.huge
			for index = 1, math.min(count, #points) do
				local distance = geometry.distance_2d(points[index], unit.position)
				if taken[index] == nil and distance < best_distance then
					best = index
					best_distance = distance
				end
			end
			if best ~= nil then
				taken[best] = true
				places[unit.id] = points[best]
			end
		end
		return places
	end
	local middle = centroid(army)
	local way = geometry.flatten(goal - middle)
	local ahead = if way.Magnitude > 1 then way.Unit else forward
	local across = Vector3.new(-ahead.Z, 0, ahead.X)
	local width = math.max(1, math.ceil(math.sqrt(count * FRONT_RATIO)))
	local slots: { { point: Vector3, side: number } } = {}
	for index = 0, count - 1 do
		local rank = index // width
		local file = index % width
		local in_rank = math.min(width, count - rank * width)
		local side = (file - (in_rank - 1) / 2) * spacing
		local point = goal + across * side - ahead * (rank * spacing)
		table.insert(slots, { point = if heightmap.in_bounds(point.X, point.Z) then point else goal, side = side })
	end
	table.sort(slots, function(a, b): boolean
		return a.side < b.side
	end)
	local order = table.clone(army)
	local sides: { [Entity]: number } = {}
	for _, unit in order do
		sides[unit] = (unit.position - middle):Dot(across)
	end
	table.sort(order, function(a, b): boolean
		return sides[a] < sides[b]
	end)
	for index, unit in order do
		places[unit.id] = slots[index].point
	end
	return places
end

-- Sends every unit of `army` that is not already on its way to `goal` there, but, for a move, those already within
-- `slack` of it: each to its own place round it if the profile spreads its units out (`formation`), within SETTLED of
-- which it is there.
local function send_all(brain: Brain, army: { Entity }, goal: Vector3, kind: OrderKind, slack: number)
	local places = formation(army, goal, kind, brain.profile.spread, brain.splash, brain.forward, brain.goals)
	for _, unit in army do
		local at = if places ~= nil then places[unit.id] or goal else goal
		local sent: Vector3? = brain.goals[unit.id]
		local settled = geometry.distance_2d(unit.position, at)
			<= (if places ~= nil then math.min(slack, SETTLED) else slack)
		if kind == "move" and settled then
			continue
		end
		if sent ~= nil and #unit.orders > 0 and geometry.distance_2d(sent, at) <= GOAL_DRIFT then
			continue
		end
		send(brain, unit, at, kind)
	end
end

return table.freeze({
	RALLY_SLACK = RALLY_SLACK,
	worth_of = worth_of,
	centroid = centroid,
	rally_point = rally_point,
	widest_splash = widest_splash,
	formation = formation,
	send_all = send_all,
})
