--!strict
-- What the scavengers can field, worked out from the defs (`SPAWNS`): everything a player can build that fights, so a new
-- unit is in it without being added. A thing's weight is settings.ROSTER_WEIGHT over the square root of its
-- difficulty, so what is cheap is made more often than what is dear without the dear ever quite being left out; and
-- what is worth less than settings.FODDER_SHARE of the hardest thing a beacon could make now is not made, so the
-- easiest things go first as the budget grows, and by the end of the game only the hardest few are made.

local ReplicatedStorage = game:GetService "ReplicatedStorage"

local types = require(ReplicatedStorage.Shared.types)
local unit_defs = require(ReplicatedStorage.Shared.unit_defs)

local settings = require(script.Parent.settings)

type EntityDef = types.EntityDef
type Weapon = types.Weapon

-- One thing a beacon can produce. Whether it is a unit or a defence is the def's own kind, and when it starts to be
-- produced is up to its difficulty and how far the game has got (progress.luau's `budget`).
export type Spawn = {
	def_name: string,
	weight: number,
	-- made by a beacon that floats on the sea, and by no other; everything else is made by a land one, unless it is
	-- amphibious
	sea: boolean?,
	-- an aircraft, a hovercraft or an amphibious walker (`can_cross`): it gets away from wherever it is made, so a
	-- beacon of either kind can make it
	amphibious: boolean?,
}

-- Water this deep is deeper than any sea on the maps, and still within what an amphibious walker goes through (BAR's
-- 5000 elmos, about 454 studs): what a rerolled unit has to manage.
local CROSSING_DEPTH = 400

-- The weapon a unit's willingness to hunt is judged by: its first.
local function main_weapon(def: EntityDef): Weapon?
	if def.weapons ~= nil and #def.weapons > 0 then
		return def.weapons[1]
	end
	-- a carrier has nothing of its own, but its drones do
	if def.carrier ~= nil then
		return main_weapon(unit_defs.get(def.carrier.drone))
	end
	return nil
end

-- How hard something is to face: what it is worth, as the game values everything (`unit_defs.power`, its metal and its
-- energy over 60), which is the scavengers' difficulty.
local function difficulty_of(def_name: string): number
	return unit_defs.power(unit_defs.get(def_name))
end

-- Whether something of `def` can get anywhere there is to get: it flies, or it can go on land and on water of any depth,
-- as a hovercraft or an amphibious walker can.
local function can_cross(def: EntityDef): boolean
	return unit_defs.is_air(def) or unit_defs.tolerates_water(def, 0, CROSSING_DEPTH)
end

-- Everything a player can build that fights, which is everything the scavengers can field: what is listed among what
-- some builder or factory makes, has a weapon or drones to fight with, and is not itself a drone. A beacon on the sea
-- makes what floats, and any other makes the rest; what can cross either (`can_cross`) comes from both. The list is
-- sorted so that it is the same every time.
local function build_roster(): { Spawn }
	local buildable: { [string]: boolean } = {}
	for _, def in unit_defs.defs do
		for _, name in unit_defs.build_options(def) do
			buildable[name] = true
		end
	end

	local roster: { Spawn } = {}
	for name, def in unit_defs.defs do
		if buildable[name] == true and unit_defs.is_drone(def) == false and main_weapon(def) ~= nil then
			table.insert(roster, {
				def_name = name,
				weight = settings.ROSTER_WEIGHT / math.sqrt(difficulty_of(name)),
				sea = unit_defs.floats(def),
				amphibious = can_cross(def),
			})
		end
	end
	table.sort(roster, function(a: Spawn, b: Spawn): boolean
		return a.def_name < b.def_name
	end)
	return roster
end

local SPAWNS: { Spawn } = build_roster()

-- Of the roster, what `wanted` says of each, in order, and what their weights come to.
local function filter(wanted: (Spawn, EntityDef) -> boolean): ({ Spawn }, number)
	local found: { Spawn } = {}
	local total = 0
	for _, option in SPAWNS do
		if wanted(option, unit_defs.get(option.def_name)) then
			table.insert(found, option)
			total += option.weight
		end
	end
	return found, total
end

-- One of `options`, whose weights come to `total`, by weight, with a roll of `random`'s.
local function weighted_pick(options: { Spawn }, total: number, random: Random): Spawn
	local roll = random:NextNumber(0, total)
	for _, option in options do
		roll -= option.weight
		if roll <= 0 then
			return option
		end
	end
	return options[#options]
end

-- The units, or the defences, that are no harder than `headroom`, the budget, and that a beacon on the sea, or on the
-- land, makes, less the fodder; and what their weights come to.
local function spawn_options(defense: boolean, headroom: number, sea: boolean, air_around: boolean): ({ Spawn }, number)
	local options = filter(function(option: Spawn, def: EntityDef): boolean
		local is_defense = def.kind == "building"
		if is_defense ~= defense or (option.amphibious ~= true and (option.sea == true) ~= sea) then
			return false
		end
		-- what only shoots at aircraft is made only while there are aircraft to shoot at
		if air_around == false and unit_defs.is_anti_air_only(def) then
			return false
		end
		return difficulty_of(option.def_name) <= headroom
	end)
	-- what is too easy beside the hardest of it is left out
	local hardest = 0
	for _, option in options do
		hardest = math.max(hardest, difficulty_of(option.def_name))
	end
	local fodder_below = hardest * settings.FODDER_SHARE
	local chosen: { Spawn } = {}
	local total = 0
	for _, option in options do
		if difficulty_of(option.def_name) >= fodder_below then
			table.insert(chosen, option)
			total += option.weight
		end
	end
	return chosen, total
end

-- The units that can get across (`can_cross`) and are no harder than `headroom`, what the units that got nowhere were
-- worth is spent on; and what their weights come to.
local function crossing_options(headroom: number, air_around: boolean): ({ Spawn }, number)
	return filter(function(option: Spawn, def: EntityDef): boolean
		return def.kind == "unit"
			and can_cross(def)
			and difficulty_of(option.def_name) <= headroom
			and (air_around or unit_defs.is_anti_air_only(def) == false)
	end)
end

-- The easiest unit a beacon on the sea, or on the land, makes that goes on the ground or the water (the first by name
-- of those as easy): what a beacon's site is probed with for room for what it makes to get away.
local function first_unit(sea: boolean): EntityDef
	local found: EntityDef? = nil
	local found_difficulty = math.huge
	for _, option in SPAWNS do
		local def = unit_defs.get(option.def_name)
		if def.kind ~= "unit" or unit_defs.is_air(def) or option.amphibious == true or (option.sea == true) ~= sea then
			continue
		end
		local difficulty = difficulty_of(option.def_name)
		if difficulty < found_difficulty then
			found = def
			found_difficulty = difficulty
		end
	end
	assert(found ~= nil, `the scavengers make no unit that goes {if sea then "on the sea" else "on the land"}`)
	return found
end

-- What a beacon on the sea, or on the land, would make of its units, or its defences, if it made one now within
-- `headroom`, and the chance of each from 0 to 1, likeliest first.
local function spawn_chances(
	defense: boolean,
	headroom: number,
	sea: boolean,
	air_around: boolean
): { { def_name: string, chance: number, difficulty: number } }
	local options, total = spawn_options(defense, headroom, sea, air_around)
	local chances = {}
	for _, option in options do
		table.insert(chances, {
			def_name = option.def_name,
			chance = option.weight / total,
			difficulty = difficulty_of(option.def_name),
		})
	end
	table.sort(chances, function(a, b): boolean
		if a.chance ~= b.chance then
			return a.chance > b.chance
		end
		return a.def_name < b.def_name
	end)
	return chances
end

return table.freeze({
	main_weapon = main_weapon,
	difficulty_of = difficulty_of,
	first_unit = first_unit,
	spawn_options = spawn_options,
	crossing_options = crossing_options,
	weighted_pick = weighted_pick,
	spawn_chances = spawn_chances,
})
