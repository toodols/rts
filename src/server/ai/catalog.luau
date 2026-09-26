--!strict
-- What the AI makes of the defs: what each one is to it (`role_of`), and which defs it builds for each thing it wants,
-- worked out once from the defs themselves (what they make, store, burn and shoot at, and what builds them), so that a
-- def is built for what it does and not for what it is called.

local ReplicatedStorage = game:GetService "ReplicatedStorage"

local types = require(ReplicatedStorage.Shared.types)
local unit_defs = require(ReplicatedStorage.Shared.unit_defs)
local ai_profiles = require(ReplicatedStorage.Shared.ai_profiles)

type EntityDef = types.EntityDef
type Line = ai_profiles.Line

-- What a def is, to the AI.
export type Role = {
	-- a unit that builds: a commander or a constructor
	builder: boolean,
	-- the commander, which builds and fights both
	commander: boolean,
	-- a builder that can put up the advanced economy (advanced extractors, fusion reactors)
	advanced: boolean,
	rezbot: boolean,
	factory: boolean,
	extractor: boolean,
	-- has a weapon (or drones) that can be turned on the ground, and one that can be turned on aircraft
	hits_ground: boolean,
	hits_air: boolean,
	-- has a weapon made for shooting aircraft down
	anti_air: boolean,
	-- how far its weapons reach, on either layer; 0 for none
	reach: number,
}

-- The labs of a line: the first, and the advanced one.
export type Labs = {
	first: string,
	advanced: string,
}

-- Every line, in the order a team that has labs of more than one is taken to play them, and what each line's units are
-- filed under.
local LINES: { Line } = { "bot", "vehicle" }
table.freeze(LINES)
local LINE_CATEGORIES: { [Line]: types.Category } = table.freeze({ bot = "bots", vehicle = "vehicles" })

-- Every def's name, in order, so that what is worked out from them comes out the same every time.
local NAMES: { string } = {}
for name in unit_defs.defs do
	table.insert(NAMES, name)
end
table.sort(NAMES)

-- The names of the defs `wanted` says of, cheapest in metal first (by name on a tie).
local function defs_where(wanted: (EntityDef) -> boolean): { string }
	local found: { string } = {}
	for _, name in NAMES do
		if wanted(unit_defs.get(name)) then
			table.insert(found, name)
		end
	end
	table.sort(found, function(a: string, b: string): boolean
		local a_cost, b_cost = unit_defs.get(a).metal_cost, unit_defs.get(b).metal_cost
		if a_cost ~= b_cost then
			return a_cost < b_cost
		end
		return a < b
	end)
	return table.freeze(found)
end

-- What tier of builder `def` is, a mobile one: the commander 0, and the rest their tech level.
local function builder_tier(def: EntityDef): number
	return if unit_defs.is_commander(def) then 0 else def.tech_level or 1
end

-- The least tier of mobile builder that has `name` among what it builds; math.huge for none.
local function tier_of(name: string): number
	local tier = math.huge
	for _, builder_name in NAMES do
		local def = unit_defs.get(builder_name)
		if def.kind == "unit" and table.find(unit_defs.build_options(def), name) ~= nil then
			tier = math.min(tier, builder_tier(def))
		end
	end
	return tier
end

-- A building that goes up anywhere: on no metal spot or vent, and not on the sea.
local function stands_anywhere(def: EntityDef): boolean
	return def.kind == "building" and def.spot == nil and def.footing.water ~= "float" and def.tidal_multiplier == nil
end

-- The extractor that goes on a bare metal spot, and the one built over it.
local PLAIN_EXTRACTOR = defs_where(function(def: EntityDef): boolean
	return def.spot == "metal" and def.upgrades == nil
end)[1]
local ADVANCED_EXTRACTOR = defs_where(function(def: EntityDef): boolean
	return def.spot == "metal" and def.upgrades ~= nil and table.find(def.upgrades, PLAIN_EXTRACTOR) ~= nil
end)[1]

-- What makes energy of the economy's, anywhere or not.
local ENERGY_DEFS: { [string]: boolean } = {}
for _, name in
	defs_where(function(def: EntityDef): boolean
		return def.category == "economy"
			and ((def.energy_income or 0) > 0 or def.wind_multiplier ~= nil or def.tidal_multiplier ~= nil)
	end)
do
	ENERGY_DEFS[name] = true
end
table.freeze(ENERGY_DEFS)

-- What makes energy anywhere, as tiers: what the commander builds, what a constructor builds, and what an advanced one
-- builds, each tier's cheapest first.
local ENERGY_TIERS: { { string } } = {}
for tier = 0, 2 do
	table.insert(
		ENERGY_TIERS,
		defs_where(function(def: EntityDef): boolean
			return ENERGY_DEFS[def.name] == true and stands_anywhere(def) and tier_of(def.name) == tier
		end)
	)
end
table.freeze(ENERGY_TIERS)

-- What turns energy into metal, cheapest first.
local CONVERTER_DEFS = defs_where(function(def: EntityDef): boolean
	return def.energy_conversion ~= nil
end)

-- What only stores energy, cheapest first.
local ENERGY_STORES = defs_where(function(def: EntityDef): boolean
	return def.category == "economy"
		and (def.energy_storage or 0) > 0
		and ENERGY_DEFS[def.name] == nil
		and def.energy_conversion == nil
		and def.builder == nil
end)

-- What only stores metal.
local METAL_STORES = defs_where(function(def: EntityDef): boolean
	return def.category == "economy" and (def.metal_storage or 0) > 0 and def.metal_income == nil and def.builder == nil
end)

-- Buildings that help build, cheapest first: the construction turrets.
local TURRET_DEFS = defs_where(function(def: EntityDef): boolean
	return def.kind == "building" and unit_defs.is_factory(def) == false and unit_defs.does(def, "assist")
end)

-- Defences against what walks and drives, and against aircraft, cheapest first.
local GROUND_DEFENSES = defs_where(function(def: EntityDef): boolean
	local ground = unit_defs.reaches(def)
	return def.category == "defences" and ground ~= nil and unit_defs.defends_against_air(def) == false
end)
local AIR_DEFENSES = defs_where(function(def: EntityDef): boolean
	return def.category == "defences" and unit_defs.defends_against_air(def)
end)

-- The labs of each line: the lab whose constructor is of the first tier, and the one whose is of the second.
local function labs_of(line: Line): Labs
	local found: { [number]: string } = {}
	for _, name in
		defs_where(function(def: EntityDef): boolean
			return unit_defs.is_factory(def)
		end)
	do
		for _, option in unit_defs.build_options(unit_defs.get(name)) do
			local def = unit_defs.get(option)
			if def.category == LINE_CATEGORIES[line] and def.builder ~= nil and found[def.tech_level or 1] == nil then
				found[def.tech_level or 1] = name
			end
		end
	end
	return table.freeze({ first = found[1], advanced = found[2] })
end
local LABS: { [Line]: Labs } = table.freeze({ bot = labs_of "bot", vehicle = labs_of "vehicle" })

local roles: { [string]: Role } = {}

local function role_of(def_name: string): Role
	local cached = roles[def_name]
	if cached ~= nil then
		return cached
	end
	local def = unit_defs.get(def_name)
	local options = unit_defs.build_options(def)
	local ground_reach, air_reach = unit_defs.reaches(def)
	local mobile_builder = def.kind == "unit"
		and unit_defs.is_air(def) == false
		and def.builder ~= nil
		and unit_defs.does(def, "assist")
	local role: Role = {
		builder = mobile_builder
			and (table.find(options, PLAIN_EXTRACTOR) ~= nil or table.find(options, ADVANCED_EXTRACTOR) ~= nil),
		commander = unit_defs.is_commander(def),
		advanced = table.find(options, ADVANCED_EXTRACTOR) ~= nil,
		rezbot = def.kind == "unit" and unit_defs.does(def, "resurrect"),
		factory = unit_defs.is_factory(def),
		extractor = def.spot == "metal",
		hits_ground = ground_reach ~= nil,
		hits_air = air_reach ~= nil,
		anti_air = unit_defs.defends_against_air(def),
		reach = math.max(ground_reach or 0, air_reach or 0),
	}
	roles[def_name] = role
	return role
end

-- The constructor a lab of `line` makes first.
local function constructor_of(line: Line): string
	for _, option in unit_defs.build_options(unit_defs.get(LABS[line].first)) do
		if role_of(option).builder then
			return option
		end
	end
	error(`the {line} lab makes no constructor`)
end

-- Where a new block of `def_name` starts: beside a lab for a construction turret, off to one side of the energy for a
-- store or a converter, and otherwise behind home.
local function block_of(def_name: string): "turret" | "store" | "economy"
	if table.find(TURRET_DEFS, def_name) ~= nil then
		return "turret"
	end
	if
		table.find(ENERGY_STORES, def_name) ~= nil
		or table.find(METAL_STORES, def_name) ~= nil
		or table.find(CONVERTER_DEFS, def_name) ~= nil
	then
		return "store"
	end
	return "economy"
end

return table.freeze({
	PLAIN_EXTRACTOR = PLAIN_EXTRACTOR,
	ADVANCED_EXTRACTOR = ADVANCED_EXTRACTOR,
	LINES = LINES,
	LABS = LABS,
	ENERGY_DEFS = ENERGY_DEFS,
	ENERGY_TIERS = ENERGY_TIERS,
	CONVERTER_DEFS = CONVERTER_DEFS,
	ENERGY_STORES = ENERGY_STORES,
	TURRET_DEFS = TURRET_DEFS,
	GROUND_DEFENSES = GROUND_DEFENSES,
	AIR_DEFENSES = AIR_DEFENSES,
	role_of = role_of,
	constructor_of = constructor_of,
	block_of = block_of,
})
