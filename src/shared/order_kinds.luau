--!strict
-- What each kind of order is, as data: what it is aimed at, who may be given it, and how close it has to get. The
-- server checks every order a player sends against this (server/commands.luau), and the client reads the same.
--
-- A player's command is one of these kinds (`Command`): an order that goes into a unit's queue (types.OrderKind), or
-- one of the two that act at once instead, `stop` (drop every order, and call off a self-destruct) and `self_destruct`
-- (start its countdown, or call it off).

local ReplicatedStorage = game:GetService "ReplicatedStorage"

local types = require(ReplicatedStorage.Shared.types)
local unit_defs = require(ReplicatedStorage.Shared.unit_defs)

type EntityDef = types.EntityDef
type OrderKind = types.OrderKind

export type Command = OrderKind | "stop" | "self_destruct"

-- What an order is aimed at, as a player gives it:
-- - "entity": something on the field, by id (`target_id`), which has to be there;
-- - "spot": one spot on the ground for everyone given it, or, where it may be `spread`, a spot of its own for each;
-- - "area": a spot on the ground and a radius round it;
-- - "formation": a spot of its own for each unit, on the water's surface for a ship, as a move is dragged out;
-- - "none": nothing, for what acts at once.
export type Aim = "entity" | "spot" | "area" | "formation" | "none"

-- How close something has to get to carry an order out (`reach`): within its manual weapon's range, its weapons'
-- range, its buildpower's for building, reclaiming or raising, or all the way.
export type Reach = "manual_weapon" | "weapons" | "build" | "reclaim" | "resurrect" | "touch"

-- Where a queued order is drawn (client/queue_paths.luau): at its spot on the ground; where the unit itself goes there,
-- on the water's surface for a ship (`travelled`); where what it builds rests, on the water if that floats (`built`);
-- on what it is aimed at, where that is now (`target`); or following what it is aimed at, which moves, under a glow
-- (`follows_target`), which is also where the unit is taken to end up.
export type DrawnAt = "ground" | "travelled" | "built" | "target" | "follows_target"

export type Kind = {
	aim: Aim,
	-- a spot order a line of units may be given spread out along it, a spot of its own for each
	spread: boolean,
	-- whether a player sends it as an order (IssueOrder); a building is ordered by placing it (PlaceBlueprint)
	issued: boolean,
	-- whether a lab keeps it in its queue for the units it makes; what a lab's units are not there yet to do, it is
	-- not given
	lab_ok: boolean,
	-- only for something with a manual weapon (`EntityDef.manual_weapon`)
	needs_manual_weapon: boolean,
	-- whether it may be a launch (`Order.launch`), firing the manual-fire weapons instead of the rest
	launches: boolean,
	-- aimed only at one's own things or an ally's, never an enemy's: following one would be a free look at where it goes
	friendly_only: boolean,
	-- given at where its target stands now, so that its route ends there however the target moves or goes
	pins_target: boolean,
	-- whether its route (commands' routes) has to reach all the way to its spot, not only to within `reach`
	walks_up_to: boolean,
	-- what the waypoints of a route laid ahead of it are: moves, or for a fight, fights all along the way
	route_as: OrderKind,
	reach: Reach,
	drawn_at: DrawnAt,
}

-- How far a builder reaches with its buildpower, where its def does not say (`EntityDef.builder`), and how close a
-- resurrecting unit has to be to the wreck.
local BUILD_RANGE = 24
local RECLAIM_RANGE = 24
local RESURRECT_RANGE = 24
-- How far into a range a unit closes in on what it is ordered at, as a fraction of the range: a little inside it, so
-- that one drifting by a stud does not fall back out of range at once and start chasing again.
local RANGE_MARGIN = 0.85

local function kind(fields: { [string]: any }): Kind
	local made: { [string]: any } = {
		aim = "entity",
		spread = false,
		issued = true,
		lab_ok = true,
		needs_manual_weapon = false,
		launches = false,
		friendly_only = false,
		pins_target = false,
		walks_up_to = false,
		route_as = "move",
		reach = "touch",
		drawn_at = "ground",
	}
	for key, value in fields do
		assert(made[key] ~= nil, `order kinds have no "{key}"`)
		made[key] = value
	end
	return table.freeze(made) :: any
end

local KINDS: { [Command]: Kind } = {
	move = kind({ aim = "formation", walks_up_to = true, drawn_at = "travelled" }),
	fight = kind({ aim = "spot", spread = true, walks_up_to = true, route_as = "fight", drawn_at = "travelled" }),
	dgun = kind({ aim = "spot", lab_ok = false, needs_manual_weapon = true, reach = "manual_weapon" }),
	attack = kind({ launches = true, reach = "weapons" }),
	attack_ground = kind({ aim = "spot", spread = true, launches = true, reach = "weapons" }),
	reclaim = kind({ pins_target = true, reach = "reclaim", drawn_at = "target" }),
	resurrect = kind({ reach = "resurrect", drawn_at = "target" }),
	assist = kind({ reach = "build" }),
	guard = kind({ friendly_only = true, drawn_at = "follows_target" }),
	repair = kind({ reach = "build" }),
	build = kind({ aim = "spot", issued = false, reach = "build", drawn_at = "built" }),
	load = kind({ lab_ok = false }),
	unload = kind({ aim = "spot", spread = true, lab_ok = false }),
	area_reclaim = kind({ aim = "area" }),
	area_repair = kind({ aim = "area" }),
	area_resurrect = kind({ aim = "area" }),
	area_attack = kind({ aim = "area" }),
	stop = kind({ aim = "none" }),
	self_destruct = kind({ aim = "none" }),
}
table.freeze(KINDS)

-- A command a player may send (IssueOrder), as a decoder reads one (shared/decode.luau): its name, if it is one.
local function issued(value: unknown): (boolean, Command)
	local found = if typeof(value) == "string" then KINDS[value :: Command] else nil
	if found == nil or found.issued == false then
		return false, nil :: any
	end
	return true, value :: Command
end

local function get(name: Command): Kind
	return KINDS[name]
end

-- How close something of `def` has to get to what an order of `order_kind` is aimed at to carry it out: within reach
-- for what is done from a distance, and all the way for anything else; for a launch (`launch`), within reach of its
-- manual-fire weapons. Where a route laid for the order can stop, and where the client draws a queue as ending. Units
-- close in to a little inside a range, not right up to it, as `orders` has them (RANGE_MARGIN).
local function reach(def: EntityDef, order_kind: Command, launch: boolean?): number
	local margin = RANGE_MARGIN
	local how = KINDS[order_kind].reach
	if how == "manual_weapon" then
		return if def.manual_weapon ~= nil then def.manual_weapon.range * margin else 0
	elseif how == "weapons" then
		local range = unit_defs.order_range(def, launch == true)
		return if range ~= nil then range * margin else 0
	end
	local builder_range = if def.builder ~= nil then def.builder.range else nil
	if how == "build" then
		return (builder_range or BUILD_RANGE) * margin
	elseif how == "reclaim" then
		return (builder_range or RECLAIM_RANGE) * margin
	elseif how == "resurrect" then
		return (builder_range or RESURRECT_RANGE) * margin
	end
	return 0
end

return table.freeze({
	BUILD_RANGE = BUILD_RANGE,
	RECLAIM_RANGE = RECLAIM_RANGE,
	RESURRECT_RANGE = RESURRECT_RANGE,
	RANGE_MARGIN = RANGE_MARGIN,
	issued = issued,
	get = get,
	reach = reach,
})
