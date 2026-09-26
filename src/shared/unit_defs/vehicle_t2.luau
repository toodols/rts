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
local accuracy = conversions.accuracy
local shell_speed = conversions.shell_speed
local shell_gravity = conversions.shell_gravity
local projectile = conversions.projectile
local missile = conversions.missile
local altitude = conversions.altitude

type EntityDef = types.EntityDef
type Weapon = types.Weapon

-- The second tier of vehicles, the ones the Advanced Vehicle Lab makes, and the Mantis's drone.
local defs: { [string]: EntityDef } = {
	-- bar: coracv
	advanced_construction_vehicle = {
		name = "advanced_construction_vehicle",
		footing = footing.moves "TANK3",
		builder = {
			buildpower = 310,
			range = studs(136),
			assists = true,
			repairs = true,
			reclaims = true,
			options = {
				"vehicle_lab",
				"advanced_vehicle_lab",
				"advanced_metal_extractor",
				"advanced_geothermal_powerplant",
				"rampart",
				"advanced_energy_converter",
				"scorpion",
				"pulsar",
				"persecutor",
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
		},
		display_name = "Advanced Construction Vehicle",
		kind = "unit",
		category = "vehicles",
		tech_level = 2,
		collider = capsule(36, 36, 47),
		metal_cost = 580,
		energy_cost = 7000,
		buildpower_cost = 17000,
		health = 2150,
		acceleration = studs_per_second_squared(0.02547),
		max_speed = studs(49.5),
		color = palette.AMBER,
	},

	-- cormart: a heavier artillery tank whose shells hit harder and burst wider than the Wolverine's. BAR
	-- has it fire along the low arc; it is set to the high one here.
	-- legvcarry: a drone carrier. It has no gun of its own; it keeps two drones on its back and sends them at
	-- whatever comes within a thousand elmos. Its movement class is BAR's HTANK4.
	-- bar: legvcarry
	mantis = {
		name = "mantis",
		footing = footing.moves("HTANK4", studs(12)),
		display_name = "Mantis",
		subtitle = "Drone carrier",
		kind = "unit",
		category = "vehicles",
		tech_level = 2,
		-- 55 x 37 x 67 elmos
		collider = capsule(55, 37, 67),
		metal_cost = 450,
		energy_cost = 9000,
		buildpower_cost = 11550,
		health = 1400,
		acceleration = studs_per_second_squared(0.02),
		max_speed = studs(45),
		-- BAR's keeps six and starts with three; this one keeps one, much tougher (see the drone). Each is built, and
		-- paid for, as BAR's are: 15 metal and 500 energy over ten seconds.
		carrier = {
			drone = "drone",
			count = 1,
			starting = 1,
			stockpile = { limit = 1, build_time = 10, metal = 15, energy = 500 },
			engage_range = studs(1000),
			repair_per_second = 30,
		},
		color = palette.STEEL_BLUE,
	},

	-- legdrone: what a Mantis carries. It is quick and hard to hit, and its laser is weak but not nothing. A Mantis
	-- keeps only two, so each has three times BAR's health and one and a half times its damage: the pair is as
	-- tough as BAR's six but does half the damage, which is what it takes to keep them from being too much. Nothing
	-- builds it: its carrier makes it. BAR's two-shot burst is one shot of twice the damage there.
	-- bar: legdrone
	drone = {
		name = "drone",
		display_name = "Drone",
		subtitle = "Combat drone",
		kind = "unit",
		category = "vehicles",
		tech_level = 2,
		role = "drone",
		-- 20 x 20 x 20 elmos, its footprint being one
		collider = capsule(20, 20, 20),
		metal_cost = 15,
		energy_cost = 500,
		buildpower_cost = 1000,
		health = 300,
		acceleration = studs_per_second_squared(0.35),
		max_speed = studs(280.5),
		footing = footing.ANYWHERE,
		-- legdrone's `cruisealtitude` 78
		air = { altitude = altitude(78), climb_speed = 20 }, -- not bar's: climb_speed
		weapons = {
			{
				kind = "laser",
				damage = 24,
				reload = 0.9,
				range = studs(300),
				energy_per_shot = 0,
				delivery = {
					kind = "beam",
					time = 0.1,
				},
			},
		} :: { Weapon },
		color = Color3.fromRGB(226, 226, 120),
	},

	-- bar: cormart
	quaker = {
		name = "quaker",
		footing = footing.moves "TANK3",
		display_name = "Quaker",
		subtitle = "Mobile artillery",
		kind = "unit",
		category = "vehicles",
		tech_level = 2,
		-- 38 x 24 x 41 elmos
		collider = capsule(38, 24, 41),
		metal_cost = 400,
		energy_cost = 4400,
		buildpower_cost = 9000,
		health = 1200,
		acceleration = studs_per_second_squared(0.03),
		max_speed = studs(58),
		weapons = {
			{
				kind = "plasma_cannon",
				damage = 420,
				reload = 5,
				range = studs(800),
				turret = { turn_rate = math.rad(120) },
				energy_per_shot = 0,
				delivery = {
					kind = "lobbed",
					arc = "high",
					projectile = projectile({
						speed = shell_speed(studs(349)),
						gravity = shell_gravity(studs(MAP_GRAVITY)),
						aoe_radius = aoe(144),
						edge_effectiveness = 0.65,
						inaccuracy = accuracy(640),
					}),
				},
			},
		} :: { Weapon },
		color = palette.STEEL_BLUE,
	},

	-- corvroc, Cortex's Negotiator: the Arbiter's rocket on a truck, heavier and slower to reload. It flies the way the
	-- Arbiter's does, straight up, over and down, with the same chosen climb and dive.
	-- bar: corvroc
	negotiator = {
		name = "negotiator",
		footing = footing.moves "HTANK4",
		weight_class = "heavy",
		display_name = "Negotiator",
		subtitle = "Rocket launcher",
		kind = "unit",
		category = "vehicles",
		tech_level = 2,
		-- 40 x 40 x 44 elmos
		collider = capsule(40, 40, 44),
		metal_cost = 880,
		energy_cost = 6700,
		buildpower_cost = 20000,
		health = 1390,
		acceleration = studs_per_second_squared(0.02489),
		max_speed = studs(33),
		weapons = {
			{
				kind = "missiles",
				damage = 1700,
				reload = 16,
				range = studs(1310),
				turret = { turn_rate = math.rad(90) },
				energy_per_shot = 0,
				delivery = missile(
					"short",
					projectile({
						speed = studs(415),
						aoe_radius = aoe(150),
						edge_effectiveness = 0.65,
					})
				),
			},
		} :: { Weapon },
		color = palette.COPPER,
	},

	-- correap, Cortex's Tiger: a quick, tough heavy tank with a fast-firing cannon, good at most jobs. Everything here
	-- is BAR's.
	-- bar: correap
	tiger = {
		name = "tiger",
		footing = footing.moves "MTANK3",
		weight_class = "heavy",
		display_name = "Tiger",
		subtitle = "Heavy assault tank",
		kind = "unit",
		category = "vehicles",
		tech_level = 2,
		-- 34 x 34 x 38 elmos
		collider = capsule(34, 34, 38),
		metal_cost = 690,
		energy_cost = 10000,
		buildpower_cost = 16000,
		health = 5300,
		acceleration = studs_per_second_squared(0.0362),
		max_speed = studs(69),
		weapons = {
			{
				kind = "plasma_cannon",
				damage = 109,
				reload = 0.7,
				range = studs(410),
				turret = { turn_rate = math.rad(130) },
				energy_per_shot = 0,
				delivery = {
					kind = "lobbed",
					arc = "low",
					projectile = projectile({
						speed = shell_speed(studs(380)),
						gravity = shell_gravity(studs(MAP_GRAVITY)),
						aoe_radius = aoe(64),
						edge_effectiveness = 0.15,
					}),
				},
			},
		} :: { Weapon },
		color = palette.RUST,
	},

	-- corparrow, Cortex's Poison Arrow: an amphibious heavy tank that drives along the sea floor as readily as on land,
	-- with a slow, hard-hitting cannon. Its movement class is BAR's ATANK3. Everything here is BAR's.
	-- bar: corparrow
	poison_arrow = {
		name = "poison_arrow",
		footing = footing.moves "ATANK3",
		weight_class = "heavy",
		display_name = "Poison Arrow",
		subtitle = "Amphibious heavy tank",
		kind = "unit",
		category = "vehicles",
		tech_level = 2,
		-- 44 x 35 x 53 elmos
		collider = capsule(44, 35, 53),
		metal_cost = 1050,
		energy_cost = 21000,
		buildpower_cost = 26000,
		health = 6300,
		acceleration = studs_per_second_squared(0.0266),
		max_speed = studs(51),
		-- corparrow's `paralyzemultiplier` 0.2
		emp_resistance = 0.8,
		weapons = {
			{
				kind = "plasma_cannon",
				damage = 370,
				reload = 1.8,
				range = studs(575),
				turret = { turn_rate = math.rad(130) },
				energy_per_shot = 0,
				delivery = {
					kind = "lobbed",
					arc = "low",
					projectile = projectile({
						speed = shell_speed(studs(300)),
						gravity = shell_gravity(studs(MAP_GRAVITY)),
						aoe_radius = aoe(160),
						edge_effectiveness = 0.15,
					}),
				},
			},
		} :: { Weapon },
		color = palette.OLIVE,
	},

	-- armmanni, Armada's Starlight: a slow tank carrying a long-range tachyon beam that hits very hard and costs a
	-- thousand energy a shot. Its gun fires only into the half ahead of it (BAR's maxangledif 180 about maindir
	-- 0 0 1), and it goes up in BAR's "penetrator" blast when it dies. BAR's 1000 damage to commanders is not
	-- modelled: every target takes the default 2500. Everything else here is BAR's.
	-- bar: armmanni
	starlight = {
		name = "starlight",
		footing = footing.moves "HTANK4",
		weight_class = "heavy",
		display_name = "Starlight",
		subtitle = "Mobile tachyon weapon",
		kind = "unit",
		category = "vehicles",
		tech_level = 2,
		-- 39 x 49 x 39 elmos
		collider = capsule(39, 49, 39),
		metal_cost = 1200,
		energy_cost = 18500,
		buildpower_cost = 33000,
		health = 2800,
		acceleration = studs_per_second_squared(0.00715),
		max_speed = studs(42),
		weapons = {
			{
				kind = "laser",
				damage = 2500,
				reload = 4.7,
				range = studs(950),
				energy_per_shot = 1000,
				turret = { turn_rate = math.rad(50) },
				-- the forward half: BAR's maxangledif is the whole cone, this is half of it
				fire_arc = math.rad(90),
				target_layer = "ground",
				delivery = {
					kind = "beam",
					time = 0.3,
					thickness = 1,
					color = Color3.fromRGB(0, 0, 255),
					charged = true,
				},
			},
		} :: { Weapon },
		death_explosion = { radius = studs(420), damage = 980 },
		color = palette.STEEL_BLUE,
	},
}

return table.freeze(defs)
