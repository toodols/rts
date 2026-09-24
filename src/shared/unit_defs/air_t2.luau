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

-- The second tier of aircraft, the ones the Advanced Air Lab makes. Their names are BAR's, but like the first tier's
-- transports their numbers are not copied from BAR's unit files: they are chosen, in BAR's units and with BAR's
-- proportions against the first tier, and are the ones to replace when the real ones are looked up.
local defs: { [string]: EntityDef } = {
	-- the advanced builder that flies: it builds what the Advanced Construction Vehicle does, from anywhere
	advanced_construction_aircraft = {
		name = "advanced_construction_aircraft",
		display_name = "Advanced Construction Aircraft",
		subtitle = "Advanced builder aircraft",
		kind = "unit",
		-- 40 x 20 x 50 elmos
		collider = capsule(40, 20, 50),
		metal_cost = 340,
		energy_cost = 12000,
		buildpower_cost = 19000,
		health = 520,
		buildpower = 170,
		acceleration = studs_per_second_squared(0.16),
		max_speed = studs(225),
		reclaiming = true,
		repairing = true,
		resurrecting = false,
		assisting = true,
		max_water_depth = studs(9999),
		build_options = {
			"air_lab",
			"advanced_air_lab",
			"advanced_metal_extractor",
			"advanced_geothermal_powerplant",
			"rampart",
			"advanced_energy_converter",
			"scorpion",
			"pulsar",
			"persecutor",
			"eradicator",
			"catalyst",
			"prevailer",
			"apocalypse",
			"overseer",
			"wall",
			"calamity",
			"fusion_reactor",
			"advanced_fusion_reactor",
			"epic_fusion_reactor",
			"experimental_gantry",
			"epic_energy_converter",
			"advanced_construction_turret",
			"hardened_energy_storage",
			"hardened_metal_storage",
			"screamer",
		},
		weapons = nil,
		air = { altitude = 20, climb_speed = 10 },
		color = Color3.fromRGB(226, 178, 74),
	},

	-- the stealth fighter: a Valiant that is quicker, tougher and hits harder, and that an enemy only picks out to
	-- shoot at from close by (`stealth`), so it can slip past anti air that would reach it from far off
	nighthawk = {
		name = "nighthawk",
		display_name = "Nighthawk",
		subtitle = "Stealth fighter",
		kind = "unit",
		-- 36 x 22 x 44 elmos
		collider = capsule(36, 22, 44),
		metal_cost = 150,
		energy_cost = 5600,
		buildpower_cost = 7600,
		health = 300,
		buildpower = nil,
		acceleration = studs_per_second_squared(0.2),
		max_speed = studs(330),
		reclaiming = false,
		repairing = false,
		resurrecting = false,
		assisting = false,
		max_water_depth = studs(9999),
		build_options = nil,
		stealth = true,
		air = {
			altitude = studs(135),
			climb_speed = 15,
			wings = { turn_rate = 1.25, run_out = run_out(64, 330) },
		},
		weapons = {
			{
				damage = 170,
				reload = 0.9,
				range = studs(700),
				energy_per_shot = 0,
				anti_air = true,
				target_layer = "air",
				projectile = {
					speed = studs(560),
					acceleration = studs(380),
					thrust_time = 1.9,
					gravity = 0,
					drag = 0,
					aoe_radius = aoe(studs(12)),
					line_thickness = 0.25,
					homing = true,
				},
			},
		},
		color = Color3.fromRGB(70, 74, 92),
	},

	-- the heavy bomber: a Whirlwind's run with a longer line of heavier bombs, and the armour to live through the anti
	-- air on the way in
	hailstorm = {
		name = "hailstorm",
		display_name = "Hailstorm",
		subtitle = "Heavy bomber",
		kind = "unit",
		-- 56 x 30 x 64 elmos
		collider = capsule(56, 30, 64),
		metal_cost = 330,
		energy_cost = 11000,
		buildpower_cost = 17500,
		health = 1700,
		buildpower = nil,
		acceleration = studs_per_second_squared(0.05),
		max_speed = studs(220),
		reclaiming = false,
		repairing = false,
		resurrecting = false,
		assisting = false,
		max_water_depth = studs(9999),
		build_options = nil,
		air = {
			altitude = studs(180),
			climb_speed = 11,
			bombing_runs = true,
			wings = { turn_rate = 0.8, run_out = run_out(80, 220) },
		},
		weapons = {
			{
				damage = 190,
				reload = 7,
				burst_count = 8,
				burst_interval = 0.2,
				range = studs(100),
				energy_per_shot = 0,
				target_layer = "ground",
				projectile = {
					speed = 0,
					acceleration = 0,
					thrust_time = 0,
					gravity = studs(MAP_GRAVITY),
					drag = 0,
					aoe_radius = aoe(studs(200)),
					edge_effectiveness = 0.4,
					dropped = true,
				},
			},
		},
		color = Color3.fromRGB(150, 104, 78),
	},

	-- the atomic bomber: one bomb a run, and it goes off like a small nuke. Slow to come round and slow to reload,
	-- dear, and fragile for what it costs, so it wants an escort and a target worth it.
	liche = {
		name = "liche",
		display_name = "Liche",
		subtitle = "Atomic bomber",
		kind = "unit",
		-- 48 x 30 x 62 elmos
		collider = capsule(48, 30, 62),
		metal_cost = 1300,
		energy_cost = 42000,
		buildpower_cost = 60000,
		health = 2100,
		buildpower = nil,
		acceleration = studs_per_second_squared(0.045),
		max_speed = studs(250),
		reclaiming = false,
		repairing = false,
		resurrecting = false,
		assisting = false,
		max_water_depth = studs(9999),
		build_options = nil,
		air = {
			altitude = studs(220),
			climb_speed = 10,
			bombing_runs = true,
			wings = { turn_rate = 0.7, run_out = run_out(96, 250) },
		},
		weapons = {
			{
				damage = 5000,
				reload = 14,
				range = studs(100),
				energy_per_shot = 0,
				target_layer = "ground",
				projectile = {
					speed = 0,
					acceleration = 0,
					thrust_time = 0,
					gravity = studs(MAP_GRAVITY),
					drag = 0,
					-- a third of the Apocalypse's blast
					aoe_radius = aoe(studs(640)),
					edge_effectiveness = 0.15,
					dropped = true,
					-- a fat dark bomb that goes off in a mushroom cloud. It is a bomb and not a missile, so no
					-- anti-nuke shoots it down.
					look = {
						size = Vector3.new(0.9, 0.9, 2.2),
						color = Color3.fromRGB(62, 64, 70),
						material = Enum.Material.Metal,
						light = { color = Color3.fromRGB(255, 170, 80), range = 10, brightness = 2 },
						explosion = "nuclear",
					},
				},
			},
		},
		color = Color3.fromRGB(120, 108, 150),
	},

	-- the flying fortress: a huge, slow gunship bristling with guns. It hovers, and like any gunship it keeps circling
	-- what it attacks while it fires (server/orbits.luau). Two heavy lasers for the ground and a missile rack for
	-- aircraft.
	tyrannus = {
		name = "tyrannus",
		display_name = "Tyrannus",
		subtitle = "Flying fortress",
		kind = "unit",
		-- 90 x 50 x 110 elmos
		collider = capsule(90, 50, 110),
		metal_cost = 2600,
		energy_cost = 38000,
		buildpower_cost = 64000,
		health = 9500,
		buildpower = nil,
		acceleration = studs_per_second_squared(0.04),
		max_speed = studs(75),
		reclaiming = false,
		repairing = false,
		resurrecting = false,
		assisting = false,
		max_water_depth = studs(9999),
		build_options = nil,
		air = { altitude = 28, climb_speed = 6 },
		weapons = {
			{
				damage = 160,
				reload = 1.2,
				range = studs(560),
				energy_per_shot = 0,
				target_layer = "ground",
				offset = Vector3.new(-2.4, -0.6, 1.5),
				beam_time = 0.15,
				beam_thickness = 0.4,
			},
			{
				damage = 160,
				reload = 1.2,
				range = studs(560),
				energy_per_shot = 0,
				target_layer = "ground",
				offset = Vector3.new(2.4, -0.6, 1.5),
				beam_time = 0.15,
				beam_thickness = 0.4,
			},
			{
				damage = 200,
				reload = 2,
				range = studs(760),
				energy_per_shot = 0,
				anti_air = true,
				target_layer = "air",
				projectile = {
					speed = studs(520),
					acceleration = studs(350),
					thrust_time = 2,
					gravity = 0,
					drag = 0,
					aoe_radius = aoe(studs(14)),
					line_thickness = 0.3,
					homing = true,
				},
			},
		},
		color = Color3.fromRGB(150, 90, 80),
	},

	-- a heavy transport with guns: it lifts light and heavy things, one at a time, as the Hephaestus does, and it can
	-- fight its way in and cover what it drops off. As a gunship it circles what it attacks.
	stronghold = {
		name = "stronghold",
		display_name = "Stronghold",
		subtitle = "Heavy transport gunship",
		kind = "unit",
		-- 70 x 44 x 90 elmos
		collider = capsule(70, 44, 90),
		metal_cost = 620,
		energy_cost = 11000,
		buildpower_cost = 22000,
		health = 3200,
		buildpower = nil,
		acceleration = studs_per_second_squared(0.08),
		max_speed = studs(120),
		reclaiming = false,
		repairing = false,
		resurrecting = false,
		assisting = false,
		max_water_depth = studs(9999),
		build_options = nil,
		air = { altitude = 24, climb_speed = 8 },
		transport = { capacity = 1, carries = "heavy" },
		weapons = {
			{
				damage = 36,
				reload = 0.3,
				range = studs(440),
				energy_per_shot = 0,
				target_layer = "ground",
				beam_time = 0.08,
			},
			{
				damage = 90,
				reload = 2.5,
				range = studs(620),
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
		color = Color3.fromRGB(226, 178, 74),
	},
}

return table.freeze(defs)
