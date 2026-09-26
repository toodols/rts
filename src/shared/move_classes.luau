--!strict
-- BAR's movement classes, from gamedata/movedefs.lua, by the name a unit's file gives as its `movementclass`: the
-- steepest ground each can stand on (its `maxslope`, in degrees: 54 for bots, the amphibious bots and the commander,
-- `SLOPE.DIFFICULT`, 27 for tanks, `SLOPE.MINIMUM`, 33 for hovercraft, `SLOPE.MODERATE`), how it meets the water, and
-- whether it runs on tracks or wheels. Passability keeps a map of the ground for each slope (shared/passability), and
-- a unit's footing (unit_defs/footing.luau) is built from its class.
--
-- The water depths are BAR's `maxwaterdepth`s. A land class wades into water as deep as that and no deeper:
-- `DEPTH.MAX_SHALLOW`, 20 elmos, for bots and tanks alike, and `DEPTH.TICK`, 5, for the smallest bots. It is the class's
-- depth that holds a unit, as in BAR, whose engine takes a mobile unit's water limit from its movement class and not
-- its own file (`CGameHelper::CheckTerrainConstraints`, rts/Game/GameHelper.cpp), so a unit's own `maxwaterdepth` is
-- not used. The amphibious classes go anywhere (`DEPTH.AMPHIBIOUS`, 5000 elmos). A hovercraft rides over the water
-- rather than going into it, and a ship floats on it, so neither has a limit; how shallow a ship's water may be is its
-- own file's `minwaterdepth`, and differs from ship to ship.
--
-- A land class also slows in the water, as BAR's do by their `depthModParams` (`depthModGeneric` in movedefs.lua):
-- `speed_in_water`.

local ReplicatedStorage = game:GetService "ReplicatedStorage"

local world_scale = require(ReplicatedStorage.Shared.world_scale)
local types = require(ReplicatedStorage.Shared.types)

type MoveClass = types.MoveClass
type MoveClassName = types.MoveClassName
type DepthMod = types.DepthMod

local ELMOS_PER_STUD = world_scale.ELMOS_PER_STUD

-- bar: movedefs.lua's DEPTH, in elmos
local AMPHIBIOUS_DEPTH = 5000 / ELMOS_PER_STUD
local MAX_SHALLOW_DEPTH = 20 / ELMOS_PER_STUD
local TICK_DEPTH = 5 / ELMOS_PER_STUD

-- bar: movedefs.lua's `depthModGeneric`, which every land class that wades has: no slower in water shallower than 4
-- elmos, and in deeper water 1 / (1 + 0.03 * depth) as fast. Its `maxValue = 0.7` is no key the engine reads (BAR's
-- own TODO says it should be `maxScale`), so the slowing has no cap short of the depth that stops the unit.
local GENERIC_DEPTH_MOD: DepthMod = table.freeze({
	min_depth = 4,
	constant = 1,
	linear = 0.03,
	quadratic = 0,
	max_scale = math.huge,
})

-- A class that stands on the ground, holding it to `max_slope` and to water no deeper than `max_water_depth`, and
-- slowing it in the water by `depth_mod`, if it has one.
local function on_ground(max_slope: number, max_water_depth: number, vehicle: boolean, depth_mod: DepthMod?): MoveClass
	local class: MoveClass = {
		max_slope = max_slope,
		water = "ground",
		max_water_depth = max_water_depth,
		vehicle = vehicle,
		depth_mod = depth_mod,
	}
	return table.freeze(class)
end

local function bot(max_slope: number, max_water_depth: number): MoveClass
	return on_ground(max_slope, max_water_depth, false, GENERIC_DEPTH_MOD)
end

local function tank(max_slope: number): MoveClass
	return on_ground(max_slope, MAX_SHALLOW_DEPTH, true, GENERIC_DEPTH_MOD)
end

-- The amphibious classes are no slower under the water: BAR gives them `depthMod = 0`, all but the commander's.
-- divergence from bar: COMMANDERBOT's `depthModCommanders` would slow the commander under deep water, to two thirds of
-- its speed at most; it is left out, so that the commander goes under the water as it always has here.
local function amphibious(max_slope: number, vehicle: boolean): MoveClass
	return on_ground(max_slope, AMPHIBIOUS_DEPTH, vehicle, nil)
end

local HOVER: MoveClass = { max_slope = 33, water = "hover", max_water_depth = nil, vehicle = false, depth_mod = nil }
table.freeze(HOVER)
local BOAT: MoveClass = { max_slope = nil, water = "float", max_water_depth = nil, vehicle = false, depth_mod = nil }
table.freeze(BOAT)

local CLASSES: { [MoveClassName]: MoveClass } = {
	COMMANDERBOT = amphibious(54, false),
	BOT2 = bot(54, MAX_SHALLOW_DEPTH),
	BOT3 = bot(54, MAX_SHALLOW_DEPTH),
	ABOT3 = amphibious(54, false),
	SBOT2 = bot(54, TICK_DEPTH),
	HBOT4 = bot(54, MAX_SHALLOW_DEPTH),
	HBOT7 = bot(54, MAX_SHALLOW_DEPTH),
	VBOT6 = amphibious(54, false),
	HABOT5 = amphibious(54, false),
	TBOT3 = bot(90, MAX_SHALLOW_DEPTH),
	HTBOT6 = bot(90, MAX_SHALLOW_DEPTH),
	TANK2 = tank(27),
	TANK3 = tank(27),
	HTANK4 = tank(27),
	HTANK7 = tank(33),
	MTANK3 = tank(27),
	ATANK3 = amphibious(54, true),
	HOVER2 = HOVER,
	HOVER3 = HOVER,
	BOAT3 = BOAT,
	BOAT4 = BOAT,
	BOAT5 = BOAT,
	BOAT9 = BOAT,
	UBOAT4 = BOAT,
}

local function get(name: MoveClassName): MoveClass
	local class = CLASSES[name]
	assert(class ~= nil, `unknown movement class "{name}"`)
	return class
end

-- The class called `name`, or nil for no name, what moves by no class.
local function of(name: MoveClassName?): MoveClass?
	return if name ~= nil then CLASSES[name] else nil
end

-- The share of its top speed something of `class` keeps in water `depth` studs deep: BAR's `MoveDef::GetDepthMod`
-- (rts/Sim/MoveTypes/MoveDefHandler.cpp), 1 over its `depthModParams`' quadratic in the depth in elmos, clamped between
-- 0.01 and the params' `maxScale`, and all of it in water shallower than their `minHeight` or for a class with none.
-- BAR takes the depth at the highest corner of the square under the unit, 8 elmos across; here it is the depth right
-- under it, which is the same depth to within the slope of a square.
local function speed_in_water(class: MoveClass, depth: number): number
	local mod = class.depth_mod
	if mod == nil then
		return 1
	end
	local elmos = depth * ELMOS_PER_STUD
	if elmos < mod.min_depth then
		return 1
	end
	local scale = mod.quadratic * elmos * elmos + mod.linear * elmos + mod.constant
	return 1 / math.clamp(scale, 0.01, mod.max_scale)
end

return table.freeze({
	CLASSES = table.freeze(CLASSES),
	get = get,
	of = of,
	speed_in_water = speed_in_water,
})
