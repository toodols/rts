--!strict
-- The buildings the build keys pick, as data. Buildings are grouped into categories, each with an action of its own
-- that Shared.keybinds binds to a key (in the BAR profile Z economy, X combat, C utility, V production). A category's
-- action places its main building, and while anything in the category is being placed, the actions of its picks choose
-- the rest of it instead of whatever their keys mean otherwise (A the energy converter among the economy buildings, not
-- attack mode). A pick with several buildings places whichever of them the selection can build, the first it can. A
-- category's first pick is its main building, best first.
--
-- The build menu shows the categories a tab each, in this order, every building against its key (ui/build_menu.luau),
-- and a key and the menu's first page always agree on what a category's key places (`entry`).
--
-- A pick is in a key slot, as BAR's build grid has them: the slots are named after the keys BAR puts them on, and each is
-- one action whatever category it is used in (`build_key_<slot>`), so a player rebinds a slot once, not every building
-- in it. No two picks of a category share a slot. A category's action is `build_<its name, lower case>`. A lab's units
-- are in the same slots (`LAB_SLOTS`), and while a lab is selected they come before anything else a key means.

export type Pick = { slot: string, action: string, defs: { string } }

export type Category = {
	name: string,
	-- what starts it
	action: string,
	picks: { Pick },
	-- every building in it, in the order of its picks
	defs: { string },
	-- the action that picks each building
	action_of: { [string]: string },
}

-- The key slots as BAR's build grid lays them out, row by row, T beside the top row: how the settings show them.
local SLOT_ROWS: { { string } } = table.freeze({
	table.freeze({ "Q", "W", "E", "R", "T" }),
	table.freeze({ "A", "S", "D", "F" }),
	table.freeze({ "Z", "X", "C", "V" }),
})

-- Every key slot, row by row.
local SLOTS: { string } = {}
for _, row in SLOT_ROWS do
	for _, slot in row do
		table.insert(SLOTS, slot)
	end
end
table.freeze(SLOTS)

-- The action of the key slot `slot`.
local function slot_action(slot: string): string
	return `build_key_{string.lower(slot)}`
end

local function category(name: string, pick_defs: { { slot: string, defs: { string } } }): Category
	local picks: { Pick } = {}
	local defs: { string } = {}
	local action_of: { [string]: string } = {}
	for _, each in pick_defs do
		assert(table.find(SLOTS, each.slot) ~= nil, `{name}: "{each.slot}" is no key slot`)
		local pick: Pick =
			table.freeze({ slot = each.slot, action = slot_action(each.slot), defs = table.freeze(each.defs) })
		table.insert(picks, pick)
		for _, def_name in each.defs do
			if action_of[def_name] == nil then
				table.insert(defs, def_name)
				action_of[def_name] = pick.action
			end
		end
	end
	for index, pick in picks do
		for other = index + 1, #picks do
			assert(picks[other].slot ~= pick.slot, `{name}: two picks in the key slot "{pick.slot}"`)
		end
	end
	return table.freeze({
		name = name,
		action = `build_{string.lower(name)}`,
		picks = table.freeze(picks),
		defs = table.freeze(defs),
		action_of = table.freeze(action_of),
	})
end

local CATEGORIES: { Category } = table.freeze({
	category("Economy", {
		{ slot = "Z", defs = { "advanced_metal_extractor", "metal_extractor" } },
		{ slot = "X", defs = { "fusion_reactor", "solar_collector" } },
		{ slot = "Q", defs = { "hardened_energy_storage", "energy_storage" } },
		{ slot = "W", defs = { "hardened_metal_storage", "metal_storage" } },
		{ slot = "A", defs = { "advanced_energy_converter", "energy_converter" } },
		{ slot = "C", defs = { "advanced_fusion_reactor", "wind_turbine" } },
		{ slot = "E", defs = { "epic_fusion_reactor" } },
		{ slot = "T", defs = { "epic_energy_converter" } },
		{ slot = "V", defs = { "advanced_solar_collector" } },
		-- the geothermal plants, on a vent: the advanced one for whoever can build it, and its sidegrade
		{ slot = "S", defs = { "tidal_generator", "advanced_geothermal_powerplant", "geothermal_powerplant" } },
		{ slot = "F", defs = { "rampart" } },
	}),
	category("Combat", {
		{ slot = "Z", defs = { "scorpion", "guard" } },
		-- the floating ones where BAR's commander has them, beside the land ones it cannot build
		{ slot = "X", defs = { "pulsar", "twin_guard", "urchin" } },
		{ slot = "C", defs = { "warden", "persecutor" } },
		{ slot = "W", defs = { "agitator", "calamity" } },
		{ slot = "D", defs = { "eradicator", "prevailer" } },
		{ slot = "A", defs = { "thistle" } },
		{ slot = "S", defs = { "screamer", "slingshot" } },
		{ slot = "V", defs = { "catalyst" } },
		{ slot = "E", defs = { "apocalypse" } },
		{ slot = "R", defs = { "coral" } },
	}),
	category("Utility", {
		{ slot = "Z", defs = { "wall" } },
		{ slot = "Q", defs = { "overseer" } },
	}),
	category("Production", {
		{ slot = "Z", defs = { "bot_lab" } },
		{ slot = "X", defs = { "vehicle_lab" } },
		-- construction turret is A while advanced construction turret is C, with the air lab. This is intentional,
		-- copied from BAR.
		{ slot = "A", defs = { "construction_turret", "experimental_gantry" } },
		{ slot = "S", defs = { "advanced_bot_lab", "advanced_vehicle_lab", "advanced_air_lab", "advanced_shipyard" } },
		{ slot = "V", defs = { "shipyard" } },
		{ slot = "C", defs = { "air_lab", "advanced_construction_turret" } },
		{ slot = "Q", defs = { "hovercraft_platform" } },
		{ slot = "W", defs = { "seaplane_platform" } },
	}),
})

-- Each lab's units in the key slots, as BAR's build grid has them (luaui/configs/gridmenu_layouts.lua's labGrids, cell
-- by cell Z X C V, A S D F, Q W E R). Our labs mix BAR's factions, so where two of a lab's units have the same cell in
-- BAR the one listed first in the lab keeps it and the other takes the nearest free cell in its row, or failing one
-- the first free cell; so does a unit BAR's grids do not have.
local LAB_SLOTS: { [string]: { [string]: string } } = {
	advanced_air_lab = {
		advanced_construction_aircraft = "Z",
		nighthawk = "X",
		hailstorm = "V",
		stiletto = "E",
		liche = "Q",
		angler = "D",
		tyrannus = "W",
		stronghold = "S",
	},
	advanced_bot_lab = {
		advanced_construction_bot = "Z",
		arbiter = "F",
		gunslinger = "A",
		sharpshooter = "W",
		sumo = "D",
		fatboy = "R",
		mammoth = "Q",
		recluse = "X",
	},
	advanced_shipyard = {
		construction_ship = "Z",
		buccaneer = "C",
		predator = "Q",
		kraken = "W",
		arrow_storm = "E",
		despot = "D",
		messenger = "V",
		black_hydra = "F",
		sea_dragon = "X",
	},
	advanced_vehicle_lab = {
		advanced_construction_vehicle = "Z",
		quaker = "V",
		mantis = "X",
		tiger = "C",
		poison_arrow = "W",
		negotiator = "R",
		starlight = "D",
	},
	air_lab = {
		construction_aircraft = "Z",
		valiant = "X",
		whirlwind = "V",
		banshee = "C",
		hercules = "S",
		hephaestus = "D",
	},
	bot_lab = {
		construction_bot = "Z",
		grunt = "C",
		tick = "V",
		thug = "S",
		aggravator = "A",
		graverobber = "X",
		centurion = "D",
		trasher = "E",
	},
	experimental_gantry = { juggernaut = "V", vanguard = "C", shiva = "Z", thor = "X", behemoth = "A" },
	hovercraft_platform = { construction_hovercraft = "Z", goon = "C", birdeater = "E", halberd = "D" },
	seaplane_platform = { construction_seaplane = "Z", cutlass = "C", dam_buster = "V", monsoon = "S", bat = "X" },
	shipyard = {
		construction_ship = "Z",
		supporter = "C",
		riptide = "A",
		oppressor = "S",
		syracusia = "D",
		argonaut = "F",
		herring = "E",
		orca = "Q",
	},
	vehicle_lab = {
		incisor = "C",
		construction_vehicle = "Z",
		lasher = "E",
		rascal = "V",
		wolverine = "D",
		brute = "A",
		janus = "S",
		pounder = "F",
		garpike = "W",
	},
}
for lab, units in LAB_SLOTS do
	local used: { [string]: string } = {}
	for unit, slot in units do
		assert(table.find(SLOTS, slot) ~= nil, `{lab}: "{slot}" is no key slot`)
		assert(used[slot] == nil, `{lab}: {used[slot]} and {unit} share the key slot "{slot}"`)
		used[slot] = unit
	end
	table.freeze(units)
end
table.freeze(LAB_SLOTS)

-- The action that queues `unit` in the lab `lab`, if it has one.
local function lab_action(lab: string, unit: string): string?
	local units = LAB_SLOTS[lab]
	local slot = if units ~= nil then units[unit] else nil
	return if slot ~= nil then slot_action(slot) else nil
end

-- The unit of the lab `lab` in the key slot `action` is the action of, if any.
local function lab_unit(lab: string, action: string): string?
	local units = LAB_SLOTS[lab]
	if units == nil then
		return nil
	end
	for unit, slot in units do
		if slot_action(slot) == action then
			return unit
		end
	end
	return nil
end

-- The category a building belongs to, if any.
local function category_of(def_name: string): Category?
	for _, each in CATEGORIES do
		if each.action_of[def_name] ~= nil then
			return each
		end
	end
	return nil
end

-- The category the action `action` starts, if it starts one.
local function started_by(action: string): Category?
	for _, each in CATEGORIES do
		if each.action == action then
			return each
		end
	end
	return nil
end

-- The buildings the action `action` picks within `from`, if it picks any there.
local function pick(from: Category, action: string): { string }?
	for _, each in from.picks do
		if each.action == action then
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
	slots = SLOTS,
	slot_rows = SLOT_ROWS,
	slot_action = slot_action,
	labs = LAB_SLOTS,
	lab_action = lab_action,
	lab_unit = lab_unit,
	categories = CATEGORIES,
	category_of = category_of,
	started_by = started_by,
	pick = pick,
	is_main = is_main,
	entry = entry,
})
