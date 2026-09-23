local ReplicatedStorage = game:GetService "ReplicatedStorage"

local types = require(ReplicatedStorage.Shared.types)

local conversions = require(script.Parent.conversions)

local cells = conversions.cells
local studs = conversions.studs

type EntityDef = types.EntityDef

-- The labs, the shipyard and the gantry: the buildings that make units.
local defs: { [string]: EntityDef } = {
	bot_lab = {
		name = "bot_lab",
		display_name = "Bot Lab",
		kind = "building",
		collider = { shape = "box", width = cells(3), height = cells(2), length = cells(3) },
		metal_cost = 500,
		energy_cost = 950,
		buildpower_cost = 5000,
		health = 2900,
		buildpower = 150,
		acceleration = nil,
		max_speed = nil,
		reclaiming = false,
		repairing = false,
		resurrecting = false,
		assisting = false,
		max_water_depth = 0,
		build_options = {
			"construction_bot",
			"grunt",
			"tick",
			"thug",
			"aggravator",
			"graverobber",
			"centurion",
			"trasher",
		},
		weapons = nil,
		color = Color3.fromRGB(122, 134, 148),
	},

	advanced_bot_lab = {
		name = "advanced_bot_lab",
		display_name = "Advanced Bot Lab",
		kind = "building",
		collider = { shape = "box", width = cells(3), height = cells(2), length = cells(3) },
		metal_cost = 2600,
		energy_cost = 16000,
		buildpower_cost = 26000,
		health = 4500,
		buildpower = 600,
		acceleration = nil,
		max_speed = nil,
		reclaiming = false,
		repairing = false,
		resurrecting = false,
		assisting = false,
		max_water_depth = 0,
		build_options = {
			"advanced_construction_bot",
			"arbiter",
			"gunslinger",
			"sharpshooter",
			"sumo",
			"fatboy",
			"mammoth",
			"recluse",
		},
		weapons = nil,
		color = Color3.fromRGB(122, 134, 148),
	},

	-- corvp
	vehicle_lab = {
		name = "vehicle_lab",
		display_name = "Vehicle Lab",
		kind = "building",
		-- 96 x 40 x 96 elmos, in whole grid cells
		collider = { shape = "box", width = cells(3), height = cells(1), length = cells(3) },
		metal_cost = 570,
		energy_cost = 1550,
		buildpower_cost = 5650,
		health = 3000,
		buildpower = 150,
		acceleration = nil,
		max_speed = nil,
		reclaiming = false,
		repairing = false,
		resurrecting = false,
		assisting = false,
		max_water_depth = 0,
		build_options = { "incisor", "construction_vehicle", "lasher", "rascal", "wolverine", "brute" },
		weapons = nil,
		color = Color3.fromRGB(122, 134, 148),
	},

	advanced_vehicle_lab = {
		name = "advanced_vehicle_lab",
		display_name = "Advanced Vehicle Lab",
		kind = "building",
		collider = { shape = "box", width = cells(3), height = cells(2), length = cells(3) },
		metal_cost = 2600,
		energy_cost = 16000,
		buildpower_cost = 28000,
		health = 5100,
		buildpower = 600,
		metal_storage = 200,
		energy_storage = 200,
		acceleration = nil,
		max_speed = nil,
		reclaiming = false,
		repairing = false,
		resurrecting = false,
		assisting = false,
		max_water_depth = 0,
		weapons = nil,
		build_options = { "advanced_construction_vehicle", "quaker", "mantis", "tiger", "poison_arrow", "negotiator" },
		color = Color3.fromRGB(122, 134, 148),
	},

	-- corgant, Cortex's Experimental Gantry: the lab for the third tier.
	experimental_gantry = {
		name = "experimental_gantry",
		display_name = "Experimental Gantry",
		kind = "building",
		-- 196 x 110 x 196 elmos, in whole grid cells
		collider = { shape = "box", width = cells(4), height = cells(3), length = cells(4) },
		metal_cost = 8400,
		energy_cost = 62000,
		buildpower_cost = 68000,
		health = 17800,
		buildpower = 1800,
		metal_storage = 800,
		energy_storage = 1400,
		acceleration = nil,
		max_speed = nil,
		reclaiming = false,
		repairing = false,
		resurrecting = false,
		assisting = false,
		max_water_depth = 0,
		build_options = { "juggernaut", "vanguard", "shiva" },
		weapons = nil,
		color = Color3.fromRGB(122, 134, 148),
	},

	-- corsy: a factory that has to stand in water deep enough for its ships to float out of it
	shipyard = {
		name = "shipyard",
		display_name = "Shipyard",
		subtitle = "Ship factory",
		kind = "building",
		-- 96 x 59 x 96 elmos
		collider = { shape = "box", width = cells(2), height = cells(2), length = cells(2) },
		metal_cost = 450,
		energy_cost = 950,
		buildpower_cost = 5100,
		health = 4300,
		buildpower = 150,
		acceleration = nil,
		max_speed = nil,
		reclaiming = false,
		repairing = false,
		resurrecting = false,
		assisting = false,
		max_water_depth = studs(9999),
		min_water_depth = studs(30),
		build_options = { "construction_ship", "supporter", "riptide", "syracusia", "herring", "orca", "buccaneer" },
		weapons = nil,
		color = Color3.fromRGB(122, 134, 148),
	},

	-- Aircraft. The fighter and the bomber are BAR's corveng and corshad. The rest of these numbers are not copied
	-- from a BAR unit file: they are chosen, in BAR's units and with BAR's proportions, so that a fighter outruns a
	-- bomber and a bomber outruns a transport, and are the ones to replace when the real ones are looked up.
	air_lab = {
		name = "air_lab",
		display_name = "Air Lab",
		subtitle = "Aircraft factory",
		kind = "building",
		collider = { shape = "box", width = cells(3), height = cells(1), length = cells(3) },
		metal_cost = 630,
		energy_cost = 1100,
		buildpower_cost = 5380,
		health = 2150,
		buildpower = 150,
		acceleration = nil,
		max_speed = nil,
		reclaiming = false,
		repairing = false,
		resurrecting = false,
		assisting = false,
		max_water_depth = 0,
		build_options = { "construction_aircraft", "valiant", "whirlwind", "hercules", "hephaestus" },
		weapons = nil,
		color = Color3.fromRGB(122, 134, 148),
	},
}

return table.freeze(defs)
