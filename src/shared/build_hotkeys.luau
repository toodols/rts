--!strict
-- The keys that pick buildings, as data. Buildings are grouped into categories, each with a key of its own: Z economy,
-- X combat, C utility, V production. A category's key places its main building, and while anything in the category is
-- being placed, the keys of its picks choose the rest of it instead of whatever they mean otherwise (A the energy
-- converter among the economy buildings, not attack mode). A pick with several buildings places whichever of them the
-- selection can build, the first it can. A category's first pick is its main building, best first, and its key there
-- is Z, as it is the economy's own: Z places the main building of whichever category is being placed from.
--
-- The build menu shows the categories a tab each, in this order, every building against its key (ui/build_menu.luau),
-- and a key and the menu's first page always agree on what a category's key places (`entry`).

-- A key is its KeyCode's name.
export type Pick = { key: string, defs: { string } }

export type Category = {
	name: string,
	-- what starts it
	key: string,
	picks: { Pick },
	-- every building in it, in the order of its picks
	defs: { string },
	-- the key that picks each building
	key_of: { [string]: string },
}

local function category(name: string, key: string, picks: { Pick }): Category
	local defs: { string } = {}
	local key_of: { [string]: string } = {}
	for _, pick in picks do
		table.freeze(pick.defs)
		table.freeze(pick)
		for _, def_name in pick.defs do
			if key_of[def_name] == nil then
				table.insert(defs, def_name)
				key_of[def_name] = pick.key
			end
		end
	end
	return table.freeze({
		name = name,
		key = key,
		picks = table.freeze(picks),
		defs = table.freeze(defs),
		key_of = table.freeze(key_of),
	})
end

local CATEGORIES: { Category } = table.freeze({
	category("Economy", "Z", {
		{ key = "Z", defs = { "advanced_metal_extractor", "metal_extractor" } },
		{ key = "X", defs = { "fusion_reactor", "solar_collector" } },
		{ key = "Q", defs = { "hardened_energy_storage", "energy_storage" } },
		{ key = "W", defs = { "hardened_metal_storage", "metal_storage" } },
		{ key = "A", defs = { "advanced_energy_converter", "energy_converter" } },
		{ key = "C", defs = { "advanced_fusion_reactor", "wind_turbine" } },
		{ key = "E", defs = { "epic_fusion_reactor" } },
		{ key = "T", defs = { "epic_energy_converter" } },
		{ key = "V", defs = { "advanced_solar_collector" } },
		-- the geothermal plants, on a vent: the advanced one for whoever can build it, and its sidegrade
		{ key = "S", defs = { "tidal_generator", "advanced_geothermal_powerplant", "geothermal_powerplant" } },
		{ key = "F", defs = { "rampart" } },
	}),
	category("Combat", "X", {
		{ key = "Z", defs = { "scorpion", "guard" } },
		{ key = "X", defs = { "pulsar", "twin_guard" } },
		{ key = "C", defs = { "warden", "persecutor" } },
		{ key = "W", defs = { "agitator", "calamity" } },
		{ key = "D", defs = { "eradicator", "prevailer" } },
		{ key = "A", defs = { "thistle" } },
		{ key = "S", defs = { "screamer" } },
		{ key = "V", defs = { "catalyst" } },
		{ key = "E", defs = { "apocalypse" } },
	}),
	category("Utility", "C", {
		{ key = "Z", defs = { "wall" } },
		{ key = "Q", defs = { "overseer" } },
	}),
	category("Production", "V", {
		{ key = "Z", defs = { "bot_lab" } },
		-- construction turret is A while advanced construction turret is C. This is intentional, copied from BAR.
		{ key = "X", defs = { "vehicle_lab" } },
		{ key = "A", defs = { "construction_turret", "experimental_gantry" } },
		{ key = "S", defs = { "advanced_bot_lab", "advanced_vehicle_lab", "advanced_air_lab", "advanced_shipyard" } },
		{ key = "V", defs = { "shipyard" } },
		{ key = "C", defs = { "air_lab", "advanced_construction_turret" } },
		{ key = "Q", defs = { "hovercraft_platform" } },
	}),
})

-- The category a building belongs to, if any.
local function category_of(def_name: string): Category?
	for _, each in CATEGORIES do
		if each.key_of[def_name] ~= nil then
			return each
		end
	end
	return nil
end

-- The category key `key` starts, if it starts one.
local function started_by(key: string): Category?
	for _, each in CATEGORIES do
		if each.key == key then
			return each
		end
	end
	return nil
end

-- The buildings `key` picks within `from`, if it picks any there.
local function pick(from: Category, key: string): { string }?
	for _, each in from.picks do
		if each.key == key then
			return each.defs
		end
	end
	return nil
end

-- Whether `def_name` is what `from`'s own key places when the selection can build it: one of its main buildings.
local function is_main(from: Category, def_name: string): boolean
	return table.find(from.picks[1].defs, def_name) ~= nil
end

-- What `from`'s own key places, out of `builds` (what the selection can build): its main building, best first, that is
-- unlocked, or failing one the first unlocked building in it. The second result is what the build menu shows for a
-- category with nothing unlocked, locked: the first of its main buildings in `builds`, or failing one the first of
-- anything in it. Both nil when `builds` holds nothing of it.
local function entry(from: Category, builds: { string }, is_unlocked: (def_name: string) -> boolean): (string?, string?)
	local shown: string? = nil
	for _, def_name in from.picks[1].defs do
		if table.find(builds, def_name) ~= nil then
			if is_unlocked(def_name) then
				return def_name, def_name
			end
			shown = shown or def_name
		end
	end
	for _, def_name in from.defs do
		if table.find(builds, def_name) ~= nil then
			if is_unlocked(def_name) then
				return def_name, def_name
			end
			shown = shown or def_name
		end
	end
	return nil, shown
end

return table.freeze({
	categories = CATEGORIES,
	category_of = category_of,
	started_by = started_by,
	pick = pick,
	is_main = is_main,
	entry = entry,
})
