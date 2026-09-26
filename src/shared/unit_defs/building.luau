--!strict
local ReplicatedStorage = game:GetService "ReplicatedStorage"

local types = require(ReplicatedStorage.Shared.types)

local conversions = require(script.Parent.conversions)
local palette = require(script.Parent.palette)
local footing = require(script.Parent.footing)

local cells = conversions.cells
local studs = conversions.studs

type EntityDef = types.EntityDef

-- The unarmed buildings: economy, storage, construction turrets and the scavenger beacons.
local defs: { [string]: EntityDef } = {
	-- bar: armsolar
	solar_collector = {
		name = "solar_collector",
		display_name = "Solar Collector",
		kind = "building",
		category = "economy",
		-- armsolar's 50 x 76 x 50 elmo collision volume, in whole grid cells
		collider = { shape = "box", width = cells(2), height = cells(2), length = cells(2) },
		metal_cost = 155,
		energy_cost = 0,
		buildpower_cost = 2600,
		health = 340,
		footing = footing.LAND,
		energy_storage = 50,
		energy_income = 20,
		color = palette.GOLD,
	},

	-- bar: coradvsol
	advanced_solar_collector = {
		name = "advanced_solar_collector",
		display_name = "Advanced Solar Collector",
		subtitle = "Produces 80 energy",
		kind = "building",
		category = "economy",
		collider = { shape = "box", width = cells(2), height = cells(2), length = cells(2) },
		metal_cost = 370,
		energy_cost = 4000,
		energy_storage = 100,
		buildpower_cost = 8150,
		health = 1200,
		footing = footing.LAND,
		energy_income = 80,
		color = palette.GOLD,
	},

	-- cormakr: turns 70 energy a second into a metal a second, and goes up with a bang when destroyed
	-- bar: cormakr
	energy_converter = {
		name = "energy_converter",
		display_name = "Energy Converter",
		subtitle = "Converts energy to metal",
		kind = "building",
		category = "economy",
		-- 32 x 25 x 32 elmos
		collider = { shape = "box", width = cells(1), height = cells(1), length = cells(1) },
		metal_cost = 1,
		energy_cost = 1250,
		buildpower_cost = 2680,
		health = 167,
		footing = footing.LAND,
		energy_conversion = { energy_per_second = 70, metal_per_second = 70 * 0.01429 },
		death_explosion = { radius = studs(50), damage = 400 },
		color = palette.SILVER,
	},

	-- cormmkr: converts 600 energy a second to about ten metal, with a much bigger bang
	-- bar: cormmkr
	advanced_energy_converter = {
		name = "advanced_energy_converter",
		display_name = "Advanced Energy Converter",
		subtitle = "Converts 600 energy to 10 metal",
		kind = "building",
		category = "economy",
		-- 61 x 54 x 61 elmos
		collider = { shape = "box", width = cells(2), height = cells(2), length = cells(2) },
		metal_cost = 370,
		energy_cost = 21000,
		buildpower_cost = 31300,
		health = 560,
		footing = footing.LAND,
		energy_conversion = { energy_per_second = 600, metal_per_second = 600 * 0.01724 },
		death_explosion = { radius = studs(320), damage = 1220 },
		color = palette.SILVER,
	},

	-- bar: corfus
	fusion_reactor = {
		name = "fusion_reactor",
		display_name = "Fusion Reactor",
		subtitle = "Produces 850 energy",
		kind = "building",
		category = "economy",
		collider = { shape = "box", width = cells(3), height = cells(3), length = cells(3) },
		metal_cost = 3600,
		energy_cost = 22000,
		buildpower_cost = 59000,
		health = 4300,
		footing = footing.LAND,
		energy_storage = 2500,
		energy_income = 850,
		color = palette.GOLD,
		-- not bar's: corfus's fusionExplosion is 480 elmos across and 2650 damage
		death_explosion = { radius = 12, damage = 2000 },
	},

	-- bar: corafus
	advanced_fusion_reactor = {
		name = "advanced_fusion_reactor",
		display_name = "Advanced Fusion Reactor",
		subtitle = "just one more afus bro",
		kind = "building",
		category = "economy",
		collider = { shape = "box", width = cells(4), height = cells(4), length = cells(4) },
		metal_cost = 9700,
		energy_cost = 48000,
		buildpower_cost = 329200,
		-- not bar's: corafus's customfusionexplo is 1280 elmos across and 10600 damage
		death_explosion = { radius = 36, damage = 4000 },
		health = 9800,
		energy_income = 3000,
		energy_storage = 9000,
		footing = footing.LAND,
		color = palette.GOLD,
	},

	-- corafust3: the scavengers' fusion reactor. Its blast is ScavComBossExplo's, which is far wider than anything else's.
	-- bar: corafust3
	epic_fusion_reactor = {
		name = "epic_fusion_reactor",
		display_name = "Epic Fusion Reactor",
		kind = "building",
		subtitle = "just one more efus bro. one more efus and then i'll help front",
		category = "economy",
		-- 188 x 192 x 188 elmos, in whole grid cells
		collider = { shape = "box", width = cells(5), height = cells(5), length = cells(5) },
		metal_cost = 90000,
		energy_cost = 550000,
		buildpower_cost = 2500000,
		death_explosion = { radius = studs(3000), damage = 16700 },
		health = 9400,
		energy_income = 30000,
		energy_storage = 90000,
		footing = footing.LAND,
		color = palette.GOLD,
	},

	-- cormmkrt3: converts 6000 energy a second to 120 metal, and goes up like a fusion reactor
	-- bar: cormmkrt3
	epic_energy_converter = {
		name = "epic_energy_converter",
		display_name = "Epic Energy Converter",
		subtitle = "Produces 120 metal for 6000 energy",
		kind = "building",
		category = "economy",
		-- 122 x 107 x 121 elmos
		collider = { shape = "box", width = cells(3), height = cells(3), length = cells(3) },
		metal_cost = 9000,
		energy_cost = 550000,
		buildpower_cost = 350000,
		health = 1500,
		footing = footing.LAND,
		energy_conversion = { energy_per_second = 6000, metal_per_second = 6000 * 0.02 },
		death_explosion = { radius = studs(480), damage = 2650 },
		color = palette.SILVER,
	},

	-- bar: armmex
	metal_extractor = {
		name = "metal_extractor",
		display_name = "Metal Extractor",
		kind = "building",
		category = "economy",
		-- armmex has a 48 x 33 x 48 elmo collision volume, in whole grid cells
		collider = { shape = "box", width = cells(1), height = cells(1), length = cells(1) },
		metal_cost = 50,
		energy_cost = 500,
		buildpower_cost = 1800,
		health = 270,
		self_destruct_countdown = 1,
		-- the same extractor stands on dry land or on the sea floor, on whichever kind of spot it is built
		footing = footing.ANYWHERE,
		-- extraction in BAR depends on the spot; this is what a plain extractor makes on an
		-- ordinary one
		metal_income = 1,
		spot = "metal",
		color = palette.SILVER,
	},

	-- bar: cormoho
	advanced_metal_extractor = {
		name = "advanced_metal_extractor",
		display_name = "Advanced Metal Extractor",
		kind = "building",
		category = "economy",
		collider = { shape = "box", width = cells(1), height = cells(1), length = cells(1) },
		metal_cost = 620,
		energy_cost = 7700,
		buildpower_cost = 14900,
		health = 2800,
		footing = footing.LAND,
		metal_income = 7,
		spot = "metal",
		upgrades = { "metal_extractor" },
		color = palette.SILVER,
	},

	-- corgeo, Cortex's Geothermal Powerplant: energy from a geothermal vent, and only on one. Its collider is BAR's
	-- 5 x 5 footprint rather than its collision volume, so that the advanced plant and the Rampart, which share that
	-- footprint, stand on exactly the same place on a vent and can be built over it. It goes up like a small fusion.
	-- bar: corgeo
	geothermal_powerplant = {
		name = "geothermal_powerplant",
		display_name = "Geothermal Powerplant",
		subtitle = "Produces 300 energy",
		kind = "building",
		category = "economy",
		-- 63 x 45 x 63 elmos on a 5 x 5 footprint (80 elmos a side), in whole grid cells
		collider = { shape = "box", width = cells(2), height = cells(2), length = cells(2) },
		metal_cost = 540,
		energy_cost = 13000,
		buildpower_cost = 12900,
		health = 2050,
		footing = footing.LAND,
		energy_income = 300,
		energy_storage = 1000,
		spot = "geo",
		death_explosion = { radius = studs(520), damage = 1420 },
		color = palette.EMBER,
	},

	-- corageo, Cortex's Advanced Geothermal Powerplant. Built on a vent, or over a Geothermal Powerplant already on
	-- one, which is taken down and refunded when this is finished (BAR's unit_geo_upgrade_reclaimer). It goes up
	-- like a fusion reactor.
	-- bar: corageo
	advanced_geothermal_powerplant = {
		name = "advanced_geothermal_powerplant",
		display_name = "Advanced Geothermal Powerplant",
		subtitle = "Produces 1250 energy",
		kind = "building",
		category = "economy",
		-- 96 x 86 x 96 elmos on the same 5 x 5 footprint as the plain one
		collider = { shape = "box", width = cells(2), height = cells(2), length = cells(2) },
		metal_cost = 1500,
		energy_cost = 27000,
		buildpower_cost = 48000,
		health = 4150,
		footing = footing.LAND,
		energy_income = 1250,
		energy_storage = 12000,
		spot = "geo",
		upgrades = { "geothermal_powerplant" },
		death_explosion = { radius = studs(1280), damage = 10600 },
		color = palette.EMBER,
	},

	-- A builder that cannot move or make anything. It takes assist, reclaim and repair orders for whatever is
	-- within reach, and with nothing to do it puts its buildpower into the nearest friendly blueprint.
	-- bar: armnanotc
	construction_turret = {
		name = "construction_turret",
		display_name = "Construction Turret",
		weight_class = "light",
		kind = "building",
		category = "economy",
		collider = { shape = "box", width = cells(1), height = cells(1), length = cells(1) },
		metal_cost = 230,
		energy_cost = 3200,
		buildpower_cost = 5300,
		health = 560,
		builder = {
			buildpower = 200,
			range = studs(400),
			assists = true,
			repairs = true,
			reclaims = true,
		},
		footing = footing.LAND,
		color = palette.AMBER,
	},

	-- cornanotct2: the construction turret's advanced version
	-- bar: cornanotct2
	advanced_construction_turret = {
		name = "advanced_construction_turret",
		display_name = "Advanced Construction Turret",
		kind = "building",
		category = "economy",
		-- 46 x 80 x 46 elmos, in whole grid cells
		collider = { shape = "box", width = cells(1), height = cells(2), length = cells(1) },
		metal_cost = 840,
		energy_cost = 12800,
		buildpower_cost = 21000,
		health = 2200,
		builder = {
			buildpower = 600,
			range = studs(500),
			assists = true,
			repairs = true,
			reclaims = true,
		},
		footing = footing.LAND,
		color = palette.AMBER,
	},

	-- bar: armestor
	energy_storage = {
		name = "energy_storage",
		display_name = "Energy Storage",
		kind = "building",
		category = "economy",
		collider = { shape = "box", width = cells(1), height = cells(1), length = cells(1) },
		metal_cost = 170,
		energy_cost = 1700,
		buildpower_cost = 4110,
		health = 1890,
		footing = footing.LAND,
		energy_storage = 6000,
		color = palette.GOLD,
	},

	-- bar: armmstor
	metal_storage = {
		name = "metal_storage",
		display_name = "Metal Storage",
		kind = "building",
		category = "economy",
		collider = { shape = "box", width = cells(2), height = cells(2), length = cells(2) },
		metal_cost = 330,
		energy_cost = 570,
		buildpower_cost = 2920,
		health = 2100,
		footing = footing.LAND,
		metal_storage = 3000,
		color = palette.SILVER,
	},

	-- coruwadves, Cortex's Hardened Energy Storage, and it goes up like one
	-- bar: coruwadves
	hardened_energy_storage = {
		name = "hardened_energy_storage",
		display_name = "Hardened Energy Storage",
		kind = "building",
		category = "economy",
		-- 90 x 65 x 90 elmos, in whole grid cells
		collider = { shape = "box", width = cells(2), height = cells(2), length = cells(2) },
		metal_cost = 840,
		energy_cost = 11000,
		buildpower_cost = 20400,
		health = 12700,
		footing = footing.LAND,
		energy_storage = 40000,
		death_explosion = { radius = studs(480), damage = 2650 },
		color = palette.GOLD,
	},

	-- coruwadvms, Cortex's Hardened Metal Storage
	-- bar: coruwadvms
	hardened_metal_storage = {
		name = "hardened_metal_storage",
		display_name = "Hardened Metal Storage",
		kind = "building",
		category = "economy",
		-- 46 x 40 x 58 elmos, in whole grid cells
		collider = { shape = "box", width = cells(2), height = cells(1), length = cells(2) },
		metal_cost = 760,
		energy_cost = 11000,
		buildpower_cost = 20500,
		health = 11200,
		footing = footing.LAND,
		metal_storage = 10000,
		color = palette.SILVER,
	},

	-- armtide: it stands in the water and makes energy from the tide, as much a second as the map's tidal strength
	-- (`environment`), as BAR's does.
	-- bar: armtide
	tidal_generator = {
		name = "tidal_generator",
		display_name = "Tidal Generator",
		kind = "building",
		category = "economy",
		-- 37 x 26 x 39 elmos
		collider = { shape = "box", width = cells(1), height = studs(26), length = cells(1) },
		metal_cost = 90,
		energy_cost = 200,
		buildpower_cost = 2190,
		health = 400,
		footing = footing.afloat(studs(20)),
		energy_storage = 50,
		tidal_multiplier = 1,
		color = palette.SKY,
	},

	-- bar: corwin
	wind_turbine = {
		name = "wind_turbine",
		display_name = "Wind Turbine",
		kind = "building",
		category = "economy",
		collider = { shape = "box", width = cells(1), height = cells(2), length = cells(1) },
		metal_cost = 40,
		energy_cost = 175,
		buildpower_cost = 1600,
		health = 196,
		footing = footing.LAND,
		-- it makes as much energy a second as the wind speed, for now with nothing scaling it
		wind_multiplier = 1,
		color = palette.GUNMETAL,
	},
}

return table.freeze(defs)
