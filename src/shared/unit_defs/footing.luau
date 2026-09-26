--!strict
-- Footings (`types.Footing`), for the defs to say where each thing can be: a unit's from its BAR movement class
-- (shared/move_classes), with what its own file says on top, and a building's or a reclaimable's from where it may be
-- built or lie.

local ReplicatedStorage = game:GetService "ReplicatedStorage"

local types = require(ReplicatedStorage.Shared.types)
local move_classes = require(ReplicatedStorage.Shared.move_classes)

type Footing = types.Footing
type MoveClassName = types.MoveClassName

local function footing(
	class: MoveClassName?,
	water: types.WaterMode,
	max_depth: number,
	min_depth: number,
	waterline: number
): Footing
	local made: Footing =
		{ class = class, water = water, max_depth = max_depth, min_depth = min_depth, waterline = waterline }
	return table.freeze(made)
end

-- On dry ground only: a building, a reclaimable.
local LAND = footing(nil, "ground", 0, 0, 0)

-- On the ground, however deep the water over it: an extractor, which stands on dry land or on the sea floor, and an
-- aircraft, which lands wherever it is.
local ANYWHERE = footing(nil, "ground", math.huge, 0, 0)

-- A unit that moves by movement class `class`. `max_depth` is for a unit whose own file lets it into deeper water than
-- its class does.
local function moves(class: MoveClassName, max_depth: number?): Footing
	local move = move_classes.get(class)
	return footing(class, move.water, max_depth or move.max_water_depth or math.huge, 0, 0)
end

-- A ship of movement class `class`, which needs water at least `min_depth` deep, from its own file (BAR's
-- `minwaterdepth`); for a submarine, `waterline` is how far under the surface its underside rides.
local function ship(class: MoveClassName, min_depth: number, waterline: number?): Footing
	local move = move_classes.get(class)
	assert(move.water == "float", `movement class "{class}" is not a ship's`)
	return footing(class, move.water, move.max_water_depth or math.huge, min_depth, waterline or 0)
end

-- A building that floats on the sea, in water at least `min_depth` deep.
local function afloat(min_depth: number): Footing
	return footing(nil, "float", math.huge, min_depth, 0)
end

return table.freeze({
	LAND = LAND,
	ANYWHERE = ANYWHERE,
	moves = moves,
	ship = ship,
	afloat = afloat,
})
