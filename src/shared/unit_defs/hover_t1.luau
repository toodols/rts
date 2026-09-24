local ReplicatedStorage = game:GetService "ReplicatedStorage"

local types = require(ReplicatedStorage.Shared.types)

local conversions = require(script.Parent.conversions)

local studs = conversions.studs
local aoe = conversions.aoe
local capsule = conversions.capsule
local studs_per_second_squared = conversions.studs_per_second_squared

type EntityDef = types.EntityDef

-- Cortex's hovercraft, the ones the Hovercraft Platform makes, from units/CorHovercraft/ (corsh, corah, corch and
-- corhal). A hovercraft rides on a cushion of air over land and water alike: it goes anywhere the ground is not too
-- steep, and over water of any depth, whose surface it rides flat whatever the sea floor under it is doing. It is
-- never in the water, so a torpedo cannot be aimed at it (`unit_defs.in_water`). Its slope class is BAR's HOVER2 or
-- HOVER3 by its size, as gamedata/movedefs.lua gives them.
local defs: { [string]: EntityDef } = {
	-- corch: builds on land and on the water, and is quicker about it than the Construction Vehicle
	construction_hovercraft = {
		name = "construction_hovercraft",
		build_range = studs(150),
		slope_class = "HOVER3",
		hover = true,
		weight_class = "light",
		display_name = "Construction Hovercraft",
		kind = "unit",
		-- 27 x 26 x 40 elmos
		collider = capsule(27, 26, 40),
		metal_cost = 190,
		energy_cost = 3000,
		buildpower_cost = 4580,
		health = 1490,
		buildpower = 115,
		energy_income = 11,
		energy_storage = 75,
		acceleration = studs_per_second_squared(0.03792),
		max_speed = studs(60.899),
		reclaiming = true,
		repairing = true,
		resurrecting = false,
		assisting = true,
		max_water_depth = studs(9999),
		-- corch's own list, less what this game does not have
		build_options = {
			"solar_collector",
			"advanced_solar_collector",
			"wind_turbine",
			"geothermal_powerplant",
			"metal_storage",
			"energy_storage",
			"metal_extractor",
			"energy_converter",
			"bot_lab",
			"vehicle_lab",
			"air_lab",
			"hovercraft_platform",
			"construction_turret",
			"guard",
			"wall",
			"twin_guard",
			"warden",
			"agitator",
			"thistle",
			"eradicator",
			"shipyard",
			"tidal_generator",
			"advanced_vehicle_lab",
		},
		weapons = nil,
		color = Color3.fromRGB(226, 178, 74),
	},

	-- corsh, Cortex's Goon: a fast, flimsy raider with a quick-firing yellow laser
	goon = {
		name = "goon",
		slope_class = "HOVER2",
		hover = true,
		weight_class = "light",
		display_name = "Goon",
		subtitle = "Fast attack hovercraft",
		kind = "unit",
		-- 18 x 15 x 30 elmos
		collider = capsule(18, 15, 30),
		metal_cost = 75,
		energy_cost = 1500,
		buildpower_cost = 1500,
		health = 255,
		buildpower = nil,
		acceleration = studs_per_second_squared(0.10226),
		max_speed = studs(109.5),
		reclaiming = false,
		repairing = false,
		resurrecting = false,
		assisting = false,
		max_water_depth = studs(9999),
		build_options = nil,
		weapons = {
			{
				damage = 36,
				reload = 0.6,
				range = studs(230),
				turret = { turn_rate = math.rad(300) },
				energy_per_shot = 0,
				beam_time = 0.1,
				beam_color = Color3.new(1, 1, 0.3),
			},
		},
		color = Color3.fromRGB(176, 122, 88),
	},

	-- corah, Cortex's Birdeater: anti air, three homing missiles at a time and nothing for the ground. BAR's
	-- zero-damage "bogus" missile, which is only there to make it turn its turret early, is left out.
	birdeater = {
		name = "birdeater",
		slope_class = "HOVER3",
		hover = true,
		weight_class = "light",
		display_name = "Birdeater",
		subtitle = "Anti air hovercraft",
		kind = "unit",
		-- 28 x 16 x 35 elmos
		collider = capsule(28, 16, 35),
		metal_cost = 250,
		energy_cost = 4700,
		buildpower_cost = 3650,
		health = 1120,
		buildpower = nil,
		acceleration = studs_per_second_squared(0.06316),
		max_speed = studs(88.5),
		reclaiming = false,
		repairing = false,
		resurrecting = false,
		assisting = false,
		max_water_depth = studs(9999),
		build_options = nil,
		weapons = {
			{
				damage = 62,
				reload = 2.2,
				burst_count = 3,
				burst_interval = 0.2,
				range = studs(700),
				turret = { turn_rate = math.rad(300) },
				energy_per_shot = 0,
				anti_air = true,
				target_layer = "air",
				projectile = {
					speed = studs(450),
					acceleration = studs(164),
					thrust_time = (670 - 450) / 164,
					gravity = 0,
					drag = 0,
					aoe_radius = aoe(studs(48) / 3),
					edge_effectiveness = 0.15,
					line_thickness = 0.3,
					homing = true,
				},
			},
		},
		color = Color3.fromRGB(198, 86, 72),
	},

	-- corhal, Cortex's Halberd: a slow, heavily armoured assault hovercraft with a green high energy laser, which
	-- draws energy with every shot
	halberd = {
		name = "halberd",
		slope_class = "HOVER3",
		hover = true,
		weight_class = "heavy",
		display_name = "Halberd",
		subtitle = "Assault hovercraft",
		kind = "unit",
		-- 42 x 12 x 42 elmos
		collider = capsule(42, 12, 42),
		metal_cost = 640,
		energy_cost = 13000,
		buildpower_cost = 12900,
		health = 4350,
		buildpower = nil,
		acceleration = studs_per_second_squared(0.02428),
		max_speed = studs(45.3),
		reclaiming = false,
		repairing = false,
		resurrecting = false,
		assisting = false,
		max_water_depth = studs(9999),
		build_options = nil,
		weapons = {
			{
				damage = 275,
				reload = 0.8,
				range = studs(300),
				turret = { turn_rate = math.rad(150) },
				energy_per_shot = 45,
				beam_time = 0.15,
				beam_thickness = 0.4,
				beam_color = Color3.new(0, 1, 0),
			},
		},
		color = Color3.fromRGB(120, 150, 196),
	},
}

return table.freeze(defs)
