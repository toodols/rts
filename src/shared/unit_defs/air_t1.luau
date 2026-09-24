local ReplicatedStorage = game:GetService "ReplicatedStorage"

local types = require(ReplicatedStorage.Shared.types)

local conversions = require(script.Parent.conversions)

local studs = conversions.studs
local aoe = conversions.aoe
local capsule = conversions.capsule
local studs_per_second_squared = conversions.studs_per_second_squared
local MAP_GRAVITY = conversions.MAP_GRAVITY
local run_out = conversions.run_out

type EntityDef = types.EntityDef

-- The first tier of aircraft, the ones the Air Lab makes.
local defs: { [string]: EntityDef } = {
	-- a builder that flies: it goes where it is sent over anything in the way, so it reaches sites that a
	-- vehicle or a bot cannot, and stays up while it has work to do. It builds what the Construction Vehicle does.
	construction_aircraft = {
		name = "construction_aircraft",
		display_name = "Construction Aircraft",
		kind = "unit",
		-- 34 x 18 x 46 elmos
		collider = capsule(34, 18, 46),
		metal_cost = 100,
		energy_cost = 1700,
		buildpower_cost = 3980,
		health = 340,
		buildpower = 80,
		acceleration = studs_per_second_squared(0.2),
		max_speed = studs(250),
		reclaiming = true,
		repairing = true,
		resurrecting = false,
		assisting = true,
		max_water_depth = studs(9999),
		build_options = {
			"bot_lab",
			"vehicle_lab",
			"air_lab",
			"advanced_air_lab",
			"hovercraft_platform",
			"shipyard",
			"solar_collector",
			"advanced_solar_collector",
			"metal_extractor",
			"geothermal_powerplant",
			"energy_storage",
			"metal_storage",
			"energy_converter",
			"wind_turbine",
			"tidal_generator",
			"construction_turret",
			"guard",
			"wall",
			"thistle",
			"twin_guard",
			"warden",
			"agitator",
		},
		weapons = nil,
		air = { altitude = 18, climb_speed = 10 },
		color = Color3.fromRGB(226, 178, 74),
	},

	-- a fighter: quick, fragile, and dedicated anti air, so it hurts aircraft as much as anything does and
	-- cannot shoot at anything else
	valiant = {
		name = "valiant",
		display_name = "Valiant",
		subtitle = "Fighter",
		kind = "unit",
		-- 36 x 30 x 40 elmos
		collider = capsule(36, 30, 40),
		metal_cost = 73,
		energy_cost = 2800,
		buildpower_cost = 3330,
		health = 156,
		buildpower = nil,
		acceleration = studs_per_second_squared(0.1825),
		max_speed = studs(297.6),
		reclaiming = false,
		repairing = false,
		resurrecting = false,
		assisting = false,
		max_water_depth = studs(9999),
		build_options = nil,
		-- BAR's corveng: `cruisealtitude` 125 and `turnradius` 64. BAR has no turn rate, which comes out of its flight
		-- model; this is that model's steady turn at full bank, elevator and rudder (`maxbank` 0.8, `maxelevator`
		-- 0.01065, `maxrudder` 0.00615, `speedtofront` 0.063), a circle of about 23 studs.
		air = {
			altitude = studs(125),
			climb_speed = 14,
			wings = { turn_rate = 1.18, run_out = run_out(64, 297.6) },
		},
		weapons = {
			{
				damage = 125,
				reload = 0.9,
				range = studs(680),
				energy_per_shot = 0,
				anti_air = true,
				target_layer = "air",
				projectile = {
					speed = studs(500),
					acceleration = studs(350),
					thrust_time = 1.9,
					gravity = 0,
					drag = 0,
					aoe_radius = aoe(studs(10)),
					line_thickness = 0.2,
					homing = true,
				},
			},
		},
		color = Color3.fromRGB(196, 96, 80),
	},

	-- a bomber: it flies over what it attacks and drops bombs as it goes, then comes round again. A bomb
	-- keeps the bomber's speed as it falls, so it is let go some way short of its target, and it can only hit
	-- what is on the ground. A burst of five is one shot: they are laid in a line along its path with the target
	-- in the middle, the first coming down short of it and the last past it.
	whirlwind = {
		name = "whirlwind",
		display_name = "Whirlwind",
		subtitle = "Bomber",
		kind = "unit",
		-- 44 x 26 x 48 elmos
		collider = capsule(44, 26, 48),
		metal_cost = 150,
		energy_cost = 4600,
		buildpower_cost = 5050,
		health = 680,
		buildpower = nil,
		acceleration = studs_per_second_squared(0.0575),
		max_speed = studs(234),
		reclaiming = false,
		repairing = false,
		resurrecting = false,
		assisting = false,
		max_water_depth = studs(9999),
		build_options = nil,
		-- BAR's corshad: `cruisealtitude` 165 and `turnradius` 64. The turn rate is its flight model's steady turn,
		-- as for the Valiant (`maxelevator` 0.01046, `maxrudder` 0.00596, `speedtofront` 0.06183), a circle of about
		-- 23 studs.
		air = {
			altitude = studs(165),
			climb_speed = 12,
			bombing_runs = true,
			wings = { turn_rate = 0.92, run_out = run_out(64, 234) },
		},
		-- BAR's corbomb
		weapons = {
			{
				damage = 112,
				reload = 6,
				burst_count = 5,
				burst_interval = 0.26667,
				-- divergence from bar. Bar is 1280 range which makes no sense for the bomber
				range = studs(100),
				energy_per_shot = 0,
				target_layer = "ground",
				projectile = {
					speed = 0,
					acceleration = 0,
					thrust_time = 0,
					gravity = studs(MAP_GRAVITY),
					drag = 0,
					aoe_radius = aoe(studs(168)),
					edge_effectiveness = 0.4,
					dropped = true,
				},
			},
		},
		color = Color3.fromRGB(176, 122, 88),
	},

	-- a light transport: it lifts light units only, which is every T1 ground unit and nothing heavier
	hercules = {
		name = "hercules",
		display_name = "Hercules",
		subtitle = "Light transport",
		kind = "unit",
		-- 40 x 20 x 56 elmos
		collider = capsule(40, 20, 56),
		metal_cost = 90,
		energy_cost = 1400,
		buildpower_cost = 2600,
		health = 560,
		buildpower = nil,
		acceleration = studs_per_second_squared(0.4),
		max_speed = studs(230),
		reclaiming = false,
		repairing = false,
		resurrecting = false,
		assisting = false,
		max_water_depth = studs(9999),
		build_options = nil,
		weapons = nil,
		air = { altitude = 22, climb_speed = 10 },
		transport = { capacity = 2, carries = "light" },
		color = Color3.fromRGB(226, 178, 74),
	},

	-- a heavy transport: slow, tough and unarmed. It carries light and heavy things, in as many slots as they take.
	hephaestus = {
		name = "hephaestus",
		display_name = "Hephaestus",
		subtitle = "Heavy transport",
		kind = "unit",
		-- 64 x 40 x 84 elmos
		collider = capsule(64, 40, 84),
		metal_cost = 190,
		energy_cost = 4000,
		buildpower_cost = 8500,
		health = 800,
		buildpower = nil,
		acceleration = studs_per_second_squared(0.09),
		max_speed = studs(100),
		reclaiming = false,
		repairing = false,
		resurrecting = false,
		assisting = false,
		max_water_depth = studs(9999),
		build_options = nil,
		weapons = nil,
		air = { altitude = 22, climb_speed = 8 },
		transport = { capacity = 1, carries = "heavy" },
		color = Color3.fromRGB(226, 178, 74),
	},
}

return table.freeze(defs)
