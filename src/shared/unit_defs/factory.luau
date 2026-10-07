--!strict
local ReplicatedStorage = game:GetService "ReplicatedStorage"

local types = require(ReplicatedStorage.Shared.types)

local conversions = require(script.Parent.conversions)
local palette = require(script.Parent.palette)
local footing = require(script.Parent.footing)

local cells = conversions.cells
local studs = conversions.studs

type EntityDef = types.EntityDef

-- The labs, the shipyard and the gantry: the buildings that make units.
local defs: { [string]: EntityDef } = {
	-- bar: armlab
	bot_lab = {
		name = "bot_lab",
		display_name = "Bot Lab",
		kind = "building",
		category = "factories",
		collider = { shape = "box", width = cells(3), height = cells(2), length = cells(3) },
		metal_cost = 500,
		energy_cost = 950,
		buildpower_cost = 5000,
		health = 2900,
		builder = {
			buildpower = 150,
			options = {
				"construction_bot",
				"grunt",
				"tick",
				"thug",
				"aggravator",
				"graverobber",
				"centurion",
				"trasher",
			},
		},
		footing = footing.LAND,
		color = palette.GUNMETAL,
	},

	-- bar: coralab
	advanced_bot_lab = {
		name = "advanced_bot_lab",
		display_name = "Advanced Bot Lab",
		kind = "building",
		category = "factories",
		collider = { shape = "box", width = cells(3), height = cells(2), length = cells(3) },
		metal_cost = 2600,
		energy_cost = 16000,
		buildpower_cost = 26000,
		health = 4500,
		builder = {
			buildpower = 600,
			options = {
				"advanced_construction_bot",
				"arbiter",
				"gunslinger",
				"sharpshooter",
				"sumo",
				"fatboy",
				"mammoth",
				"recluse",
			},
		},
		footing = footing.LAND,
		color = palette.GUNMETAL,
	},

	-- corvp
	-- bar: corvp
	vehicle_lab = {
		name = "vehicle_lab",
		display_name = "Vehicle Lab",
		kind = "building",
		category = "factories",
		-- 96 x 40 x 96 elmos, in whole grid cells
		collider = { shape = "box", width = cells(3), height = cells(1), length = cells(3) },
		metal_cost = 570,
		energy_cost = 1550,
		buildpower_cost = 5650,
		health = 3000,
		builder = {
			buildpower = 150,
			options = {
				"incisor",
				"construction_vehicle",
				"lasher",
				"rascal",
				"wolverine",
				"brute",
				"janus",
				"pounder",
				"garpike",
			},
		},
		footing = footing.LAND,
		color = palette.GUNMETAL,
	},

	-- corhp, Cortex's Hovercraft Platform: the lab for hovercraft. It stands on dry land, as BAR's does.
	-- bar: corhp
	hovercraft_platform = {
		name = "hovercraft_platform",
		display_name = "Hovercraft Platform",
		kind = "building",
		category = "factories",
		-- 96 x 32 x 96 elmos, in whole grid cells
		collider = { shape = "box", width = cells(3), height = cells(1), length = cells(3) },
		metal_cost = 670,
		energy_cost = 2000,
		buildpower_cost = 8700,
		health = 3750,
		builder = {
			buildpower = 150,
			options = { "construction_hovercraft", "goon", "birdeater", "halberd" },
		},
		metal_storage = 200,
		energy_storage = 200,
		footing = footing.LAND,
		color = palette.GUNMETAL,
	},

	-- bar: coravp
	advanced_vehicle_lab = {
		name = "advanced_vehicle_lab",
		display_name = "Advanced Vehicle Lab",
		kind = "building",
		category = "factories",
		collider = { shape = "box", width = cells(3), height = cells(2), length = cells(3) },
		metal_cost = 2600,
		energy_cost = 16000,
		buildpower_cost = 28000,
		health = 5100,
		builder = {
			buildpower = 600,
			options = {
				"advanced_construction_vehicle",
				"quaker",
				"mantis",
				"tiger",
				"poison_arrow",
				"negotiator",
				"starlight",
			},
		},
		metal_storage = 200,
		energy_storage = 200,
		footing = footing.LAND,
		color = palette.GUNMETAL,
	},

	-- corgant, Cortex's Experimental Gantry: the lab for the third tier.
	-- bar: corgant
	experimental_gantry = {
		name = "experimental_gantry",
		display_name = "Experimental Gantry",
		kind = "building",
		category = "factories",
		-- 196 x 110 x 196 elmos, in whole grid cells
		collider = { shape = "box", width = cells(4), height = cells(3), length = cells(4) },
		metal_cost = 8400,
		energy_cost = 62000,
		buildpower_cost = 68000,
		health = 17800,
		builder = {
			buildpower = 1800,
			options = { "juggernaut", "vanguard", "shiva", "thor", "behemoth" },
		},
		metal_storage = 800,
		energy_storage = 1400,
		footing = footing.LAND,
		color = palette.GUNMETAL,
	},

	-- corsy: a factory that has to stand in water deep enough for its ships to float out of it
	-- bar: corsy
	shipyard = {
		name = "shipyard",
		display_name = "Shipyard",
		kind = "building",
		category = "factories",
		-- 96 x 59 x 96 elmos
		collider = { shape = "box", width = cells(2), height = cells(2), length = cells(2) },
		metal_cost = 450,
		energy_cost = 950,
		buildpower_cost = 5100,
		health = 4300,
		builder = {
			buildpower = 150,
			options = {
				"construction_ship",
				"supporter",
				"riptide",
				"oppressor",
				"syracusia",
				"argonaut",
				"herring",
				"orca",
			},
		},
		footing = footing.afloat(studs(5)),
		color = palette.GUNMETAL,
	},

	-- corasy, Cortex's Advanced Shipyard: the shipyard for the second tier, which the Construction Ship builds. Its
	-- numbers are BAR's. It makes what there is of BAR's second tier of ships, in BAR's order.
	-- bar: corasy
	advanced_shipyard = {
		name = "advanced_shipyard",
		display_name = "Advanced Shipyard",
		kind = "building",
		category = "factories",
		-- 186 x 78 x 183 elmos
		collider = { shape = "box", width = cells(4), height = cells(2), length = cells(4) },
		metal_cost = 2800,
		energy_cost = 10000,
		buildpower_cost = 24000,
		health = 5900,
		builder = {
			buildpower = 600,
			options = {
				"construction_ship",
				"buccaneer",
				"predator",
				"kraken",
				"arrow_storm",
				"despot",
				"messenger",
				"black_hydra",
				"sea_dragon",
			},
		},
		metal_storage = 200,
		energy_storage = 200,
		footing = footing.afloat(studs(30)),
		color = palette.GUNMETAL,
	},

	-- corplat: the lab for seaplanes, which floats on water deep enough for it. Only the Construction Ship and the
	-- Construction Hovercraft build it.
	-- bar: corplat
	seaplane_platform = {
		name = "seaplane_platform",
		display_name = "Seaplane Platform",
		kind = "building",
		category = "factories",
		-- no collision volume of its own; its wreck's is 117.5 x 41.25 x 112.5 elmos, in whole grid cells
		collider = { shape = "box", width = cells(3), height = cells(1), length = cells(3) },
		metal_cost = 1400,
		energy_cost = 5500,
		buildpower_cost = 11800,
		health = 2200,
		builder = {
			buildpower = 300,
			options = { "construction_seaplane", "cutlass", "dam_buster", "monsoon", "bat" },
		},
		energy_storage = 200,
		footing = footing.afloat(studs(30)),
		color = palette.GUNMETAL,
	},

	-- The lab for aircraft.
	-- bar: corap
	air_lab = {
		name = "air_lab",
		display_name = "Air Lab",
		kind = "building",
		category = "factories",
		collider = { shape = "box", width = cells(3), height = cells(1), length = cells(3) },
		metal_cost = 630,
		energy_cost = 1100,
		buildpower_cost = 5380,
		health = 2150,
		builder = {
			buildpower = 150,
			options = { "construction_aircraft", "valiant", "whirlwind", "banshee", "hercules", "hephaestus" },
		},
		footing = footing.LAND,
		color = palette.GUNMETAL,
	},

	-- The lab for the second tier of aircraft, which the first tier's Construction Aircraft builds. Its costs are the
	-- Advanced Vehicle Lab's.
	-- bar: coraap
	advanced_air_lab = {
		name = "advanced_air_lab",
		display_name = "Advanced Air Lab",
		kind = "building",
		category = "factories",
		collider = { shape = "box", width = cells(3), height = cells(2), length = cells(3) },
		-- not bar's: coraap's metalcost is 2900, energycost 28000 and buildtime 32000
		metal_cost = 2600,
		energy_cost = 15000,
		buildpower_cost = 26000,
		health = 3900,
		builder = {
			buildpower = 600,
			options = {
				"advanced_construction_aircraft",
				"nighthawk",
				"hailstorm",
				"stiletto",
				"liche",
				"angler",
				"tyrannus",
				"stronghold",
			},
		},
		metal_storage = 200,
		energy_storage = 200,
		footing = footing.LAND,
		color = palette.GUNMETAL,
	},
}

return table.freeze(defs)
