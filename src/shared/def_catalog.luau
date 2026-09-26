--!strict
-- Every def a player can have, filed the way a list of them reads: bots, vehicles, hovercraft, ships and aircraft by
-- tier, the experimentals, then the factories, the economy and the defences, each cheapest first. What is no one's to
-- build, the reclaimables, the campaign's props and the scavengers' own, is not in it, and a carrier's drone is only
-- reached through its carrier. With it go the links between defs the other way round from what a def says: what
-- builds each, what launches each drone, and which mission unlocks each. The lobby's encyclopedia lists it; anything
-- else that lists defs by what they are reads it here.

local ReplicatedStorage = game:GetService "ReplicatedStorage"

local campaign = require(ReplicatedStorage.Shared.campaign)
local types = require(ReplicatedStorage.Shared.types)
local unit_defs = require(ReplicatedStorage.Shared.unit_defs)

type EntityDef = types.EntityDef
type Category = types.Category

-- A heading and the defs under it, cheapest first.
export type Section = {
	key: string,
	category: Category,
	label: string,
	names: { string },
}

-- The headings, in order: the defs filed under each category (`EntityDef.category`), and under each tech level where
-- a heading names one.
local SECTION_GROUPS: { { key: string, category: Category, tech_level: number?, label: string } } = {
	{ key = "bot_t1", category = "bots", tech_level = 1, label = "BOTS · TIER 1" },
	{ key = "bot_t2", category = "bots", tech_level = 2, label = "BOTS · TIER 2" },
	{ key = "vehicle_t1", category = "vehicles", tech_level = 1, label = "VEHICLES · TIER 1" },
	{ key = "vehicle_t2", category = "vehicles", tech_level = 2, label = "VEHICLES · TIER 2" },
	{ key = "hover_t1", category = "hover", label = "HOVERCRAFT" },
	{ key = "ship_t1", category = "ships", label = "SHIPS" },
	{ key = "air_t1", category = "aircraft", tech_level = 1, label = "AIRCRAFT · TIER 1" },
	{ key = "air_t2", category = "aircraft", tech_level = 2, label = "AIRCRAFT · TIER 2" },
	{ key = "t3", category = "experimental", label = "EXPERIMENTAL" },
	{ key = "factory", category = "factories", label = "FACTORIES" },
	{ key = "building", category = "economy", label = "ECONOMY" },
	{ key = "defense", category = "defences", label = "DEFENCES" },
}

-- Whether `def` is listed: what can be built (and so locked), and a commander.
local function listed(def: EntityDef): boolean
	if def.kind ~= "unit" and def.kind ~= "building" then
		return false
	end
	return campaign.is_lockable(def.name) or unit_defs.is_commander(def)
end

-- Cheapest first, the way a build menu goes from the first things built to the last.
local function by_cost(a: EntityDef, b: EntityDef): boolean
	if a.metal_cost ~= b.metal_cost then
		return a.metal_cost < b.metal_cost
	end
	return a.display_name < b.display_name
end

local SECTIONS: { Section } = {}
for _, group in SECTION_GROUPS do
	local defs: { EntityDef } = {}
	for _, def in unit_defs.defs do
		local filed = def.category == group.category and (group.tech_level == nil or def.tech_level == group.tech_level)
		if filed and listed(def) then
			table.insert(defs, def)
		end
	end
	table.sort(defs, by_cost)
	local names: { string } = {}
	for _, def in defs do
		table.insert(names, def.name)
	end
	if #names > 0 then
		table.insert(
			SECTIONS,
			table.freeze({
				key = group.key,
				category = group.category,
				label = group.label,
				names = table.freeze(names),
			})
		)
	end
end
table.freeze(SECTIONS)

-- Every def with an entry, and how many are listed. A drone has an entry but is in no section.
local HAS_ENTRY: { [string]: boolean } = {}
local LISTED_COUNT = 0
for _, section in SECTIONS do
	for _, name in section.names do
		HAS_ENTRY[name] = true
		LISTED_COUNT += 1
	end
end
for name, def in unit_defs.defs do
	if unit_defs.is_drone(def) then
		HAS_ENTRY[name] = true
	end
end

-- What builds each def, and what launches each drone, both cheapest first.
local BUILT_BY: { [string]: { string } } = {}
local LAUNCHED_BY: { [string]: { string } } = {}
do
	local all: { EntityDef } = {}
	for name in HAS_ENTRY do
		table.insert(all, unit_defs.defs[name])
	end
	table.sort(all, by_cost)
	for _, def in all do
		for _, option in unit_defs.build_options(def) do
			BUILT_BY[option] = BUILT_BY[option] or {}
			table.insert(BUILT_BY[option], def.name)
		end
		if def.carrier ~= nil then
			LAUNCHED_BY[def.carrier.drone] = LAUNCHED_BY[def.carrier.drone] or {}
			table.insert(LAUNCHED_BY[def.carrier.drone], def.name)
		end
	end
end

-- The label of the mission whose finish unlocks each def, "(Hard)" after it for its hard mode's.
local UNLOCKED_BY: { [string]: string } = {}
for _, mission in campaign.MISSIONS do
	for _, name in mission.unlocks do
		UNLOCKED_BY[name] = mission.label
	end
	local hard_unlocks: { string } = mission.hard_mode_unlocks or {}
	for _, name in hard_unlocks do
		UNLOCKED_BY[name] = UNLOCKED_BY[name] or `{mission.label} (Hard)`
	end
end

local NONE: { string } = table.freeze({})

-- Whether `def_name` has an entry of its own.
local function has_entry(def_name: string): boolean
	return HAS_ENTRY[def_name] == true
end

-- What builds `def_name`, cheapest first; empty for what nothing listed builds.
local function built_by(def_name: string): { string }
	return BUILT_BY[def_name] or NONE
end

-- What launches the drone `def_name`, cheapest first; empty for anything else.
local function launched_by(def_name: string): { string }
	return LAUNCHED_BY[def_name] or NONE
end

-- The label of the mission that unlocks `def_name`, if one does.
local function unlocked_by(def_name: string): string?
	return UNLOCKED_BY[def_name]
end

return table.freeze({
	SECTIONS = SECTIONS,
	LISTED_COUNT = LISTED_COUNT,
	has_entry = has_entry,
	built_by = built_by,
	launched_by = launched_by,
	unlocked_by = unlocked_by,
})
