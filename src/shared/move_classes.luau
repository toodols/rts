--!strict
-- BAR's movement classes, from gamedata/movedefs.lua, by the name a unit's file gives as its `movementclass`: the
-- steepest ground each can stand on (its `maxslope`, in degrees: 54 for bots, the amphibious bots and the commander,
-- `SLOPE.DIFFICULT`, 27 for tanks, `SLOPE.MINIMUM`, 33 for hovercraft, `SLOPE.MODERATE`), how it meets the water, and
-- whether it runs on tracks or wheels. Passability keeps a map of the ground for each slope (shared/passability), and
-- a unit's footing (unit_defs/footing.luau) is built from its class.
--
-- The water depths follow BAR's too, except that land classes do not wade at all here: they stand only on dry ground.
-- The amphibious classes go anywhere (BAR's `DEPTH.AMPHIBIOUS`, 5000 elmos). A hovercraft rides over the water
-- rather than going into it, and a ship floats on it, so neither has a limit; how shallow a ship's water may be is its
-- own file's `minwaterdepth`, and differs from ship to ship.

local ReplicatedStorage = game:GetService "ReplicatedStorage"

local world_scale = require(ReplicatedStorage.Shared.world_scale)
local types = require(ReplicatedStorage.Shared.types)

type MoveClass = types.MoveClass
type MoveClassName = types.MoveClassName

local AMPHIBIOUS_DEPTH = 5000 / world_scale.ELMOS_PER_STUD

-- A class that stands on the ground, holding it to `max_slope` and to water no deeper than `max_water_depth`.
local function on_ground(max_slope: number, max_water_depth: number, vehicle: boolean): MoveClass
	local class: MoveClass =
		{ max_slope = max_slope, water = "ground", max_water_depth = max_water_depth, vehicle = vehicle }
	return table.freeze(class)
end

local function bot(max_slope: number): MoveClass
	return on_ground(max_slope, 0, false)
end

local function tank(max_slope: number): MoveClass
	return on_ground(max_slope, 0, true)
end

local function amphibious(max_slope: number, vehicle: boolean): MoveClass
	return on_ground(max_slope, AMPHIBIOUS_DEPTH, vehicle)
end

local HOVER: MoveClass = { max_slope = 33, water = "hover", max_water_depth = nil, vehicle = false }
table.freeze(HOVER)
local BOAT: MoveClass = { max_slope = nil, water = "float", max_water_depth = nil, vehicle = false }
table.freeze(BOAT)

local CLASSES: { [MoveClassName]: MoveClass } = {
	COMMANDERBOT = amphibious(54, false),
	BOT2 = bot(54),
	BOT3 = bot(54),
	ABOT3 = amphibious(54, false),
	SBOT2 = bot(54),
	HBOT4 = bot(54),
	HBOT7 = bot(54),
	VBOT6 = amphibious(54, false),
	HABOT5 = amphibious(54, false),
	TBOT3 = bot(90),
	HTBOT6 = bot(90),
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

return table.freeze({
	CLASSES = table.freeze(CLASSES),
	get = get,
	of = of,
})
