--!strict
local ReplicatedStorage = game:GetService "ReplicatedStorage"

local types = require(ReplicatedStorage.Shared.types)

local conversions = require(script.Parent.conversions)
local palette = require(script.Parent.palette)
local footing = require(script.Parent.footing)

local studs = conversions.studs
local aoe = conversions.aoe
local capsule = conversions.capsule
local studs_per_second_squared = conversions.studs_per_second_squared
local MAP_GRAVITY = conversions.MAP_GRAVITY
local run_out = conversions.run_out
local projectile = conversions.projectile
local altitude = conversions.altitude
local accuracy = conversions.accuracy
local shell_speed = conversions.shell_speed
local shell_gravity = conversions.shell_gravity

type EntityDef = types.EntityDef
type Weapon = types.Weapon

-- The first tier of aircraft, the ones the Air Lab makes.
local defs: { [string]: EntityDef } = {
	-- a builder that flies: it goes where it is sent over anything in the way, so it reaches sites that a
	-- vehicle or a bot cannot, and stays up while it has work to do. It builds what the Construction Vehicle does.
	-- bar: corca
	construction_aircraft = {
		name = "construction_aircraft",
		display_name = "Construction Aircraft",
		kind = "unit",
		category = "aircraft",
		tech_level = 1,
		-- 34 x 18 x 46 elmos
		collider = capsule(34, 18, 46),
		-- not bar's: its costs, health, buildpower, acceleration and speed; corca's are metalcost 115, energycost 2200,
		-- buildtime 5200, health 161, workertime 55, maxacc 0.06 and speed 131
		metal_cost = 100,
		energy_cost = 1700,
		buildpower_cost = 3980,
		health = 340,
		builder = {
			buildpower = 80,
			assists = true,
			repairs = true,
			reclaims = true,
			options = {
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
		},
		acceleration = studs_per_second_squared(0.2),
		max_speed = studs(250),
		footing = footing.ANYWHERE,
		-- corca's `cruisealtitude` 75
		air = { altitude = altitude(75), climb_speed = 10 }, -- not bar's: climb_speed
		color = palette.AMBER,
	},

	-- a fighter: quick, fragile, and dedicated anti air, so it hurts aircraft as much as anything does and
	-- cannot shoot at anything else
	-- bar: corveng
	valiant = {
		name = "valiant",
		display_name = "Valiant",
		subtitle = "Fighter",
		kind = "unit",
		category = "aircraft",
		tech_level = 1,
		-- 36 x 30 x 40 elmos
		collider = capsule(36, 30, 40),
		metal_cost = 73,
		energy_cost = 2800,
		buildpower_cost = 3330,
		health = 156,
		acceleration = studs_per_second_squared(0.1825),
		max_speed = studs(297.6),
		footing = footing.ANYWHERE,
		-- BAR's corveng: `cruisealtitude` 125 and `turnradius` 64. BAR has no turn rate, which comes out of its flight
		-- model; this is that model's steady turn at full bank, elevator and rudder (`maxbank` 0.8, `maxelevator`
		-- 0.01065, `maxrudder` 0.00615, `speedtofront` 0.063), a circle of about 23 studs.
		air = {
			altitude = altitude(125),
			climb_speed = 14, -- not bar's
			wings = { turn_rate = 1.18, run_out = run_out(64, 297.6) }, -- derived: turn_rate
		},
		weapons = {
			{
				kind = "aa_missiles",
				damage = 125,
				reload = 0.9,
				range = studs(680),
				energy_per_shot = 0,
				target_layer = "air",
				airborne_only = true,
				delivery = {
					kind = "straight",
					guidance = "homes",
					projectile = projectile({
						speed = studs(500),
						acceleration = studs(350),
						thrust_time = 1.9,
						aoe_radius = aoe(10),
						line_thickness = 0.2,
					}),
				},
			},
		} :: { Weapon },
		color = palette.ROSE,
	},

	-- a bomber: it flies over what it attacks and drops bombs as it goes, then comes round again. A bomb
	-- keeps the bomber's speed as it falls, so it is let go some way short of its target, and it can only hit
	-- what is on the ground. A burst of five is one shot: they are laid in a line along its path with the target
	-- in the middle, the first coming down short of it and the last past it.
	-- bar: corshad
	whirlwind = {
		name = "whirlwind",
		display_name = "Whirlwind",
		subtitle = "Bomber",
		kind = "unit",
		category = "aircraft",
		tech_level = 1,
		-- 44 x 26 x 48 elmos
		collider = capsule(44, 26, 48),
		metal_cost = 150,
		energy_cost = 4600,
		buildpower_cost = 5050,
		health = 680,
		acceleration = studs_per_second_squared(0.0575),
		max_speed = studs(234),
		footing = footing.ANYWHERE,
		-- BAR's corshad: `cruisealtitude` 165 and `turnradius` 64. The turn rate is its flight model's steady turn,
		-- as for the Valiant (`maxelevator` 0.01046, `maxrudder` 0.00596, `speedtofront` 0.06183), a circle of about
		-- 23 studs.
		air = {
			altitude = altitude(165),
			climb_speed = 12, -- not bar's
			bombing_runs = true,
			wings = { turn_rate = 0.92, run_out = run_out(64, 234) }, -- derived: turn_rate
		},
		-- BAR's corbomb
		weapons = {
			{
				kind = "bombs",
				damage = 112,
				reload = 6,
				burst_count = 5,
				burst_interval = 0.26667,
				-- divergence from bar. Bar is 1280 range which makes no sense for the bomber
				range = studs(100),
				energy_per_shot = 0,
				target_layer = "ground",
				delivery = {
					kind = "bomb",
					projectile = projectile({
						speed = 0,
						gravity = studs(MAP_GRAVITY),
						aoe_radius = aoe(168),
						edge_effectiveness = 0.4,
					}),
				},
			},
		} :: { Weapon },
		color = palette.RUST,
	},

	-- a light gunship: it hovers over what it attacks and circles it (server/orbits.luau), spraying it with quick bursts
	-- of plasma, and hits only what is on the ground and the water. Armada's, from units/ArmAircraft/armkam.lua.
	-- bar: armkam
	banshee = {
		name = "banshee",
		display_name = "Banshee",
		subtitle = "Light gunship",
		kind = "unit",
		category = "aircraft",
		tech_level = 1,
		-- no collision volume of its own, so its 2 x 2 footprint, 32 elmos a side
		collider = capsule(32, 32, 32),
		metal_cost = 135,
		energy_cost = 2300,
		buildpower_cost = 5050,
		health = 560,
		acceleration = studs_per_second_squared(0.15),
		max_speed = studs(184.8),
		footing = footing.ANYWHERE,
		-- `cruisealtitude` 70
		air = { altitude = altitude(70), climb_speed = 10 }, -- not bar's: climb_speed
		-- emg: a cannon, bursts of three strewn about their aim (`accuracy` 13 and `sprayangle` 1024). BAR's fires only
		-- ahead (`tolerance` 5000); it fires whichever way here, as the other gunships do.
		weapons = {
			{
				kind = "plasma_cannon",
				damage = 9,
				reload = 0.7,
				burst_count = 3,
				burst_interval = 0.1,
				range = studs(350),
				energy_per_shot = 0,
				target_layer = "ground",
				delivery = {
					kind = "lobbed",
					arc = "low",
					projectile = projectile({
						speed = shell_speed(studs(1000)),
						gravity = shell_gravity(studs(MAP_GRAVITY)),
						aoe_radius = aoe(40),
						edge_effectiveness = 0.5,
						inaccuracy = accuracy(13 + 1024),
					}),
				},
			},
		} :: { Weapon },
		color = palette.OLIVE,
	},

	-- a light transport: it lifts light units only, which is every T1 ground unit and nothing heavier
	-- bar: corvalk
	hercules = {
		name = "hercules",
		display_name = "Hercules",
		subtitle = "Light transport",
		kind = "unit",
		category = "aircraft",
		tech_level = 1,
		-- 40 x 20 x 56 elmos
		collider = capsule(40, 20, 56),
		-- not bar's: its costs, health, acceleration, speed and capacity; corvalk's are metalcost 74, energycost 1450,
		-- buildtime 4120, health 280, maxacc 0.09, speed 198 and transportcapacity 1
		metal_cost = 90,
		energy_cost = 1400,
		buildpower_cost = 2600,
		health = 560,
		acceleration = studs_per_second_squared(0.4),
		max_speed = studs(230),
		footing = footing.ANYWHERE,
		-- armatlas's and corvalk's `paralyzemultiplier` 0
		emp_resistance = 1,
		-- corvalk's `cruisealtitude` 100
		air = { altitude = altitude(100), climb_speed = 10 }, -- not bar's: climb_speed
		transport = { capacity = 2, carries = "light" },
		color = palette.AMBER,
	},

	-- a heavy transport: slow, tough and unarmed. It carries light and heavy things, in as many slots as they take.
	-- bar: corhvytrans
	hephaestus = {
		name = "hephaestus",
		display_name = "Hephaestus",
		subtitle = "Heavy transport",
		kind = "unit",
		category = "aircraft",
		tech_level = 1,
		-- 64 x 40 x 84 elmos
		collider = capsule(64, 40, 84),
		metal_cost = 190,
		energy_cost = 4000,
		buildpower_cost = 8500,
		health = 800,
		acceleration = studs_per_second_squared(0.09),
		max_speed = studs(100),
		footing = footing.ANYWHERE,
		-- armhvytrans's and corhvytrans's `paralyzemultiplier` 0
		emp_resistance = 1,
		-- corhvytrans's `cruisealtitude` 100
		air = { altitude = altitude(100), climb_speed = 8 }, -- not bar's: climb_speed
		transport = { capacity = 1, carries = "heavy" },
		color = palette.AMBER,
	},
}

return table.freeze(defs)
