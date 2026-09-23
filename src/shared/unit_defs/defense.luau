local ReplicatedStorage = game:GetService "ReplicatedStorage"

local types = require(ReplicatedStorage.Shared.types)

local conversions = require(script.Parent.conversions)

local cells = conversions.cells
local studs = conversions.studs
local aoe = conversions.aoe
local capsule = conversions.capsule
local studs_per_second_squared = conversions.studs_per_second_squared
local MAP_GRAVITY = conversions.MAP_GRAVITY
local accuracy = conversions.accuracy
local shell_speed = conversions.shell_speed
local shell_gravity = conversions.shell_gravity

type EntityDef = types.EntityDef

-- The buildings that fight: towers, artillery, missile silos, the anti-nuke and the plasma deflector.
local defs: { [string]: EntityDef } = {
	-- corllt, BAR's Guard: a light laser turret
	guard = {
		name = "guard",
		weight_class = "heavy",
		display_name = "Guard",
		subtitle = "Laser tower",
		kind = "building",
		collider = { shape = "box", width = cells(1), height = cells(2), length = cells(1) },
		metal_cost = 90,
		energy_cost = 700,
		buildpower_cost = 2500,
		health = 650,
		buildpower = nil,
		acceleration = nil,
		max_speed = nil,
		reclaiming = false,
		repairing = false,
		resurrecting = false,
		assisting = false,
		max_water_depth = 0,
		build_options = nil,
		weapons = {
			{
				damage = 75,
				reload = 0.46667,
				range = studs(435),
				energy_per_shot = 20,
				beam_time = 0.12,
				turret = { turn_rate = math.rad(240) },
			},
		},
		color = Color3.fromRGB(198, 86, 72),
	},

	-- corhllt: a stronger guard with two turrets, a long one on top and a shorter one below, each aimed
	-- at a target of its own
	twin_guard = {
		name = "twin_guard",
		weight_class = "heavy",
		display_name = "Twin Guard",
		subtitle = "Twin laser tower",
		kind = "building",
		collider = { shape = "box", width = cells(1), height = cells(2), length = cells(1) },
		metal_cost = 195,
		energy_cost = 1750,
		buildpower_cost = 4900,
		health = 1670,
		buildpower = nil,
		acceleration = nil,
		max_speed = nil,
		reclaiming = false,
		repairing = false,
		resurrecting = false,
		assisting = false,
		max_water_depth = 0,
		build_options = nil,
		weapons = {
			{
				damage = 75,
				reload = 0.46667,
				range = studs(490),
				energy_per_shot = 15,
				beam_time = 0.12,
				offset = Vector3.new(0, 3, 0),
				turret = { turn_rate = math.rad(220) },
			},
			{
				damage = 75,
				reload = 0.46667,
				range = studs(400),
				energy_per_shot = 15,
				beam_time = 0.12,
				offset = Vector3.new(0, 1, 0),
				turret = { turn_rate = math.rad(180) },
			},
		},
		color = Color3.fromRGB(198, 86, 72),
	},

	-- corhlt: a tower with one heavy laser that reaches far and hits hard, at a heavy cost in energy
	warden = {
		name = "warden",
		display_name = "Warden",
		subtitle = "Heavy laser tower",
		kind = "building",
		-- 38 x 90 x 38 elmos
		collider = { shape = "box", width = cells(1), height = cells(2), length = cells(1) },
		metal_cost = 480,
		energy_cost = 4700,
		buildpower_cost = 11400,
		health = 2750,
		buildpower = nil,
		acceleration = nil,
		max_speed = nil,
		reclaiming = false,
		repairing = false,
		resurrecting = false,
		assisting = false,
		max_water_depth = 0,
		build_options = nil,
		weapons = {
			{
				damage = 261,
				reload = 1.2,
				range = studs(620),
				energy_per_shot = 50,
				beam_time = 0.15,
				beam_thickness = 0.5,
				-- a heavy turret, slower to come round than a guard's
				turret = { turn_rate = math.rad(120) },
			},
		},
		color = Color3.fromRGB(198, 86, 72),
	},

	-- corrl, Cortex's Thistle: a tower that throws a missile at aircraft and at nothing else. The missile flies
	-- the way the aggravator's rocket does, at BAR's launch speed, acceleration and flight time. BAR's homes in on
	-- its target and this game's rockets do not, so it is aimed ahead of one that is moving.
	thistle = {
		name = "thistle",
		display_name = "Thistle",
		subtitle = "Anti air tower",
		kind = "building",
		-- 32 x 70 x 32 elmos, in whole grid cells
		collider = { shape = "box", width = cells(1), height = cells(2), length = cells(1) },
		metal_cost = 80,
		energy_cost = 850,
		buildpower_cost = 1750,
		health = 335,
		buildpower = nil,
		acceleration = nil,
		max_speed = nil,
		reclaiming = false,
		repairing = false,
		resurrecting = false,
		assisting = false,
		max_water_depth = 0,
		build_options = nil,
		weapons = {
			{
				damage = 115,
				reload = 1.7,
				range = studs(765),
				energy_per_shot = 0,
				turret = { turn_rate = math.rad(200) },
				anti_air = true,
				target_layer = "air",
				projectile = {
					speed = studs(400),
					acceleration = studs(150),
					thrust_time = 1.9,
					gravity = 0,
					drag = 0,
					aoe_radius = aoe(studs(48) / 3),
					line_thickness = 0.3,
					homing = true,
				},
			},
		},
		color = Color3.fromRGB(198, 86, 72),
	},

	-- corscreamer, Cortex's Screamer: a long range anti air missile tower. Like BAR's it builds its missiles up in a
	-- stockpile of five, one every 14 seconds for the 1800 energy BAR charges a shot, and fires them only at
	-- aircraft. The missile is launched and thrusts at BAR's speeds for its flight time, and homes on its target.
	screamer = {
		name = "screamer",
		display_name = "Screamer",
		subtitle = "Long range anti air tower",
		kind = "building",
		-- 63 x 57 x 63 elmos, in whole grid cells
		collider = { shape = "box", width = cells(2), height = cells(2), length = cells(2) },
		metal_cost = 1650,
		energy_cost = 32000,
		buildpower_cost = 28000,
		health = 1670,
		buildpower = nil,
		acceleration = nil,
		max_speed = nil,
		reclaiming = false,
		repairing = false,
		resurrecting = false,
		assisting = false,
		max_water_depth = 0,
		build_options = nil,
		weapons = {
			{
				damage = 750,
				reload = 1.8,
				range = studs(2400),
				energy_per_shot = 0,
				turret = { turn_rate = math.rad(90) },
				anti_air = true,
				target_layer = "air",
				stockpile = { limit = 5, build_time = 14, metal = 0, energy = 1800 },
				projectile = {
					speed = studs(1400),
					acceleration = studs(1000),
					thrust_time = 2.2,
					gravity = 0,
					drag = 0,
					aoe_radius = aoe(studs(425) / 3),
					edge_effectiveness = 0.75,
					line_thickness = 0.6,
					homing = true,
				},
			},
		},
		color = Color3.fromRGB(198, 86, 72),
	},

	-- corpun: a plasma battery with a long reach that lobs its shells over the front line. BAR lets it
	-- switch between a flat and a high trajectory; here it picks for itself each shot, the flat one when nothing is
	-- in the way of it and the high one when something is.
	agitator = {
		name = "agitator",
		display_name = "Agitator",
		subtitle = "Plasma artillery",
		kind = "building",
		-- 52 x 60 x 52 elmos
		collider = { shape = "box", width = cells(2), height = cells(2), length = cells(2) },
		metal_cost = 1300,
		energy_cost = 13500,
		buildpower_cost = 17400,
		health = 3250,
		buildpower = nil,
		acceleration = nil,
		max_speed = nil,
		reclaiming = false,
		repairing = false,
		resurrecting = false,
		assisting = false,
		max_water_depth = 0,
		build_options = nil,
		weapons = {
			{
				damage = 350,
				reload = 3.16667,
				range = studs(1245),
				energy_per_shot = 0,
				turret = { turn_rate = math.rad(70) },
				projectile = {
					speed = shell_speed(studs(600)),
					acceleration = 0,
					thrust_time = 0,
					gravity = shell_gravity(studs_per_second_squared(0.289)),
					drag = 0,
					aoe_radius = aoe(studs(120)),
					edge_effectiveness = 0.4,
					arc = "auto",
					plasma = true,
					inaccuracy = accuracy(75),
				},
			},
		},
		color = Color3.fromRGB(198, 86, 72),
	},

	-- The Agitator's advanced version, built only by advanced construction units. It picks its arc the same
	-- way, but shoots farther, harder, wider and straighter. Unlike the rest, these numbers are not copied from a
	-- BAR unit file: they are chosen to sit between the Agitator and the Pulsar in cost and reach. Its
	-- shell is faster than the Agitator's so that the longer range is within what the same gravity lets
	-- it throw.
	persecutor = {
		name = "persecutor",
		display_name = "Persecutor",
		subtitle = "Advanced plasma artillery",
		kind = "building",
		collider = { shape = "box", width = cells(3), height = cells(3), length = cells(3) },
		metal_cost = 2500,
		energy_cost = 17000,
		buildpower_cost = 25700,
		health = 4250,
		buildpower = nil,
		acceleration = nil,
		max_speed = nil,
		reclaiming = false,
		repairing = false,
		resurrecting = false,
		assisting = false,
		max_water_depth = 0,
		build_options = nil,
		weapons = {
			{
				damage = 420,
				reload = 2.1,
				range = studs(1390),
				energy_per_shot = 0,
				turret = { turn_rate = math.rad(55) },
				projectile = {
					speed = shell_speed(studs(450)),
					acceleration = 0,
					thrust_time = 0,
					gravity = shell_gravity(studs(MAP_GRAVITY)),
					drag = 0,
					aoe_radius = aoe(studs(164)),
					edge_effectiveness = 0.4,
					arc = "auto",
					plasma = true,
					inaccuracy = accuracy(450),
				},
			},
		},
		color = Color3.fromRGB(198, 86, 72),
	},

	scorpion = {
		name = "scorpion",
		display_name = "Scorpion",
		subtitle = "Sabot Battery",
		kind = "building",
		collider = { shape = "box", width = cells(1), height = cells(2), length = cells(1) },
		metal_cost = 730,
		energy_cost = 14000,
		buildpower_cost = 15000,
		health = 3000,
		buildpower = nil,
		acceleration = nil,
		max_speed = nil,
		reclaiming = false,
		repairing = false,
		resurrecting = false,
		assisting = false,
		max_water_depth = 0,
		build_options = nil,
		weapons = {
			{
				damage = 825,
				reload = 2,
				range = studs(730),
				energy_per_shot = 0,
				turret = { turn_rate = math.rad(150) },
				projectile = {
					speed = studs(570),
					acceleration = studs(400),
					thrust_time = 1.05,
					gravity = 12,
					drag = 1.5,
					aoe_radius = aoe(studs(24)),
					edge_effectiveness = 0.15,
				},
			},
		},
		color = Color3.fromRGB(226, 178, 74),
	},

	pulsar = {
		name = "pulsar",
		display_name = "Pulsar",
		subtitle = "Tachyon Accelerator",
		kind = "building",
		health = 6100,
		metal_cost = 3500,
		energy_cost = 74000,
		buildpower_cost = 52000,
		collider = { shape = "box", width = cells(2), height = cells(3), length = cells(2) },
		buildpower = nil,
		acceleration = nil,
		max_speed = nil,
		reclaiming = false,
		repairing = false,
		resurrecting = false,
		assisting = false,
		max_water_depth = 0,
		build_options = nil,
		weapons = {
			{
				damage = 10800,
				reload = 9.9,
				range = studs(1400),
				energy_per_shot = 0,
				turret = { turn_rate = math.rad(45) },
				beam_time = 1.5,
				beam_thickness = 2,
			},
		},
		color = Color3.fromRGB(198, 86, 72),
	},

	-- cortron: a tactical missile launcher. It builds up missiles and holds them until it is told what to hit,
	-- then sends one straight up; it comes back down on the target from above, so nothing in the way stops it.
	-- Unlike most of the rest, its numbers are not copied from a BAR unit file: they are chosen to sit
	-- between the Persecutor and the Pulsar in cost.
	catalyst = {
		name = "catalyst",
		display_name = "Catalyst",
		subtitle = "Tactical missile launcher",
		kind = "building",
		collider = { shape = "box", width = cells(2), height = cells(2), length = cells(2) },
		metal_cost = 1200,
		energy_cost = 14000,
		buildpower_cost = 59000,
		health = 2400,
		buildpower = nil,
		acceleration = nil,
		max_speed = nil,
		reclaiming = false,
		repairing = false,
		resurrecting = false,
		assisting = false,
		max_water_depth = 0,
		build_options = nil,
		weapons = {
			{
				damage = 4000,
				reload = 2,
				range = studs(2250),
				energy_per_shot = 0,
				stockpile = { limit = 10, build_time = 75, metal = 550, energy = 17437 },
				projectile = {
					speed = studs(700),
					acceleration = 0,
					thrust_time = 0,
					gravity = 0,
					drag = 0,
					aoe_radius = aoe(studs(380)),
					edge_effectiveness = 0.3,
					missile = { climb = 40, dive_angle = math.rad(60) },
				},
			},
		},
		color = Color3.fromRGB(198, 86, 72),
	},

	-- corsilo: a nuclear missile silo. Its missiles take a long time and a great deal to build, climb very
	-- high, cross the whole map and come down almost vertically on the target with a blast that dwarfs
	-- anything else in the game. Its numbers are chosen, like the Catalyst's.
	apocalypse = {
		name = "apocalypse",
		display_name = "Apocalypse",
		subtitle = "Nuclear missile silo",
		kind = "building",
		collider = { shape = "box", width = cells(3), height = cells(2), length = cells(3) },
		-- divergence from BAR. the apocalypse is simply too useful on this game configuration, so the metal cost is increased 2x
		metal_cost = 15400,
		energy_cost = 82000,
		buildpower_cost = 181000,
		health = 4500,
		buildpower = nil,
		acceleration = nil,
		max_speed = nil,
		reclaiming = false,
		repairing = false,
		resurrecting = false,
		assisting = false,
		max_water_depth = 0,
		build_options = nil,
		weapons = {
			{
				damage = 15000,
				reload = 30,
				-- as far as anything on the map, the whole of it
				range = studs(20000),
				energy_per_shot = 0,
				-- same here, each missile costs 2x metal than BAR
				stockpile = { limit = 10, build_time = 180, metal = 3000, energy = 187500 },
				-- it launches only when told what at
				manual_fire = true,
				projectile = {
					speed = studs(500),
					acceleration = 0,
					thrust_time = 0,
					gravity = 0,
					drag = 0,
					aoe_radius = aoe(studs(1920)),
					edge_effectiveness = 0.1,
					missile = { climb = 300, dive_angle = math.rad(80) },
					nuclear = true,
					-- a big dark missile riding a column of fire, leaving a white contrail and a pillar of smoke across
					-- the sky, that goes off in a mushroom cloud
					look = {
						size = Vector3.new(1.6, 1.6, 7),
						color = Color3.fromRGB(62, 64, 70),
						material = Enum.Material.Metal,
						trail = { color = Color3.fromRGB(236, 236, 230), width = 3, lifetime = 8 },
						flame = { color = Color3.fromRGB(255, 150, 50), size = 2.6, rate = 80, lifetime = 0.4 },
						smoke = { color = Color3.fromRGB(196, 194, 190), size = 3.5, rate = 45, lifetime = 6 },
						light = { color = Color3.fromRGB(255, 170, 80), range = 30, brightness = 5 },
						explosion = "nuclear",
					},
				},
			},
		},
		color = Color3.fromRGB(198, 86, 72),
	},

	-- Anti-nuke interceptor: defends against incoming nuclear missiles by launching homing interceptors
	-- that track and collide with nukes before they detonate. Continuously searches for nuclear missiles
	-- and launches interceptors as long as energy is available.
	prevailer = {
		name = "prevailer",
		display_name = "Prevailer",
		subtitle = "Anti-nuke interceptor",
		kind = "building",
		-- Similar footprint to other missile defense structures
		collider = { shape = "box", width = cells(2), height = cells(3), length = cells(2) },
		metal_cost = 12000,
		energy_cost = 45000,
		buildpower_cost = 120000,
		health = 3200,
		buildpower = nil,
		acceleration = nil,
		max_speed = nil,
		reclaiming = false,
		repairing = false,
		resurrecting = false,
		assisting = false,
		max_water_depth = 0,
		build_options = nil,
		-- homing interceptor weapon that searches for nuclear missiles
		weapons = {
			{
				damage = 2000,
				reload = 2,
				-- range out to which it searches for nukes to intercept
				range = studs(5000),
				energy_per_shot = 4000,
				anti_nuke = true,
				projectile = {
					speed = studs(600),
					acceleration = 0,
					thrust_time = 0,
					gravity = 0,
					drag = 0,
					aoe_radius = aoe(studs(400)),
					edge_effectiveness = 0.2,
					homing = true,
				},
			},
		},
		color = Color3.fromRGB(100, 150, 200),
	},

	-- legrampart, Legion's Rampart: the advanced geothermal's sidegrade. It makes half the energy, but is an anti-nuke
	-- and a drone platform besides. Built on a vent, or over a Geothermal Powerplant already on one, as the advanced
	-- plant is. Its interceptor is BAR's fmd_rocket, whose `coverage` is how far out it defends and so is its range
	-- here, and each missile is stockpiled at BAR's price. Its drones are BAR's heavy drones, but two of them rather
	-- than BAR's three. BAR also gives it radar and a jammer, which there is nothing here to be.
	rampart = {
		name = "rampart",
		display_name = "Rampart",
		subtitle = "Geothermal powerplant, anti-nuke and drone platform",
		kind = "building",
		-- 96 x 86 x 96 elmos on the geothermals' 5 x 5 footprint
		collider = { shape = "box", width = cells(2), height = cells(2), length = cells(2) },
		metal_cost = 2600,
		energy_cost = 38000,
		buildpower_cost = 36000,
		health = 8600,
		buildpower = nil,
		acceleration = nil,
		max_speed = nil,
		reclaiming = false,
		repairing = false,
		resurrecting = false,
		assisting = false,
		max_water_depth = 0,
		build_options = nil,
		energy_income = 600,
		energy_storage = 4000,
		requires_geo_spot = true,
		upgrades = { "geothermal_powerplant" },
		weapons = {
			{
				damage = 1500,
				reload = 2,
				range = studs(1600),
				energy_per_shot = 0,
				anti_nuke = true,
				stockpile = { limit = 20, build_time = 90, metal = 150, energy = 7500 },
				projectile = {
					speed = studs(6000),
					acceleration = 0,
					thrust_time = 0,
					gravity = 0,
					drag = 0,
					aoe_radius = aoe(studs(420)),
					edge_effectiveness = 0.15,
					homing = true,
				},
			},
		},
		-- BAR builds a drone every `spawnrate` seconds at its own price, starting with one out
		carrier = {
			drone = "heavy_drone",
			count = 2,
			starting = 1,
			stockpile = { limit = 1, build_time = 8, metal = 90, energy = 1000 },
			engage_range = studs(1600),
			-- BAR's dockinghealrate, as it is
			repair_per_second = 256,
		},
		death_explosion = { radius = studs(480), damage = 2650 },
		color = Color3.fromRGB(214, 110, 62),
	},

	-- legheavydrone: what a Rampart carries. Its heat ray is a burst of ten 10-damage beams in BAR, one shot of
	-- 100 here, as the Mantis's drone's burst is one shot. Nothing builds it: its carrier makes it.
	heavy_drone = {
		name = "heavy_drone",
		display_name = "Heavy Drone",
		subtitle = "Combat drone",
		kind = "unit",
		drone = true,
		-- no collision volume of its own, so its 2 x 2 footprint, 32 elmos a side
		collider = capsule(32, 32, 32),
		metal_cost = 90,
		energy_cost = 1000,
		buildpower_cost = 5820,
		health = 1650,
		buildpower = nil,
		acceleration = studs_per_second_squared(0.15),
		max_speed = studs(180.5),
		reclaiming = false,
		repairing = false,
		resurrecting = false,
		assisting = false,
		max_water_depth = studs(9999),
		build_options = nil,
		air = { altitude = 7, climb_speed = 20 },
		weapons = {
			{
				damage = 100,
				reload = 0.8,
				range = studs(430),
				energy_per_shot = 0,
				beam_time = 0.1,
				beam_color = Color3.fromRGB(255, 140, 0),
			},
		},
		color = Color3.fromRGB(214, 110, 62),
	},

	-- corbuzz, Cortex's Calamity: a plasma cannon that fires shell after shell at a range nothing else reaches. A
	-- shot costs 18000 energy, so a team has to hold that much before it can fire at all. It picks its arc for every
	-- shot: the low one when that is clear, then the medium one, which goes well up into the air, and the high one
	-- when the ground is in the way of both.
	calamity = {
		name = "calamity",
		display_name = "Calamity",
		subtitle = "Rapid fire long range plasma cannon",
		kind = "building",
		-- 80 x 160 x 80 elmos, in whole grid cells
		collider = { shape = "box", width = cells(2), height = cells(4), length = cells(2) },
		metal_cost = 68000,
		energy_cost = 800000,
		buildpower_cost = 1400000,
		health = 33500,
		buildpower = nil,
		acceleration = nil,
		max_speed = nil,
		reclaiming = false,
		repairing = false,
		resurrecting = false,
		assisting = false,
		max_water_depth = 0,
		build_options = nil,
		weapons = {
			{
				damage = 2000,
				reload = 0.75,
				range = studs(6100),
				energy_per_shot = 18000,
				turret = { turn_rate = math.rad(35) },
				projectile = {
					speed = shell_speed(studs(950)),
					acceleration = 0,
					thrust_time = 0,
					gravity = shell_gravity(studs(MAP_GRAVITY)),
					drag = 0,
					aoe_radius = aoe(studs(157)),
					edge_effectiveness = 0.15,
					arc = "auto",
					plasma = true,
					inaccuracy = accuracy(750),
				},
			},
		},
		color = Color3.fromRGB(198, 86, 72),
	},

	-- corgate, Cortex's Overseer: a plasma deflector. It stands inside a bubble that swallows enemy plasma shells,
	-- the arced shots of artillery and cannons; rockets and beams pass through it.
	overseer = {
		name = "overseer",
		display_name = "Overseer",
		subtitle = "Plasma deflector",
		kind = "building",
		-- 57 x 38 x 57 elmos, in whole grid cells
		collider = { shape = "box", width = cells(1), height = cells(1), length = cells(1) },
		metal_cost = 3200,
		energy_cost = 55000,
		buildpower_cost = 55000,
		health = 3550,
		buildpower = nil,
		acceleration = nil,
		max_speed = nil,
		reclaiming = false,
		repairing = false,
		resurrecting = false,
		assisting = false,
		max_water_depth = 0,
		build_options = nil,
		weapons = nil,
		shield = {
			radius = studs(550),
			power = 6175,
			regen = 130,
			regen_energy = 562.5,
			starting_power = 2090,
		},
		color = Color3.fromRGB(96, 170, 214),
	},

	-- corerad, Cortex's Eradicator: a heavy anti-air battery that fires bursts of four fast homing missiles far out, so
	-- bombers come down before they are over what they came for. It shoots at aircraft and nothing else. The missile
	-- flies the way the Thistle's does, at BAR's launch speed, acceleration and flight time.
	eradicator = {
		name = "eradicator",
		display_name = "Eradicator",
		subtitle = "Heavy anti air battery",
		kind = "building",
		-- 55 x 36 x 48 elmos, in whole grid cells
		collider = { shape = "box", width = cells(2), height = cells(2), length = cells(2) },
		metal_cost = 800,
		energy_cost = 7900,
		buildpower_cost = 12000,
		health = 4450,
		buildpower = nil,
		acceleration = nil,
		max_speed = nil,
		reclaiming = false,
		repairing = false,
		resurrecting = false,
		assisting = false,
		max_water_depth = 0,
		build_options = nil,
		weapons = {
			{
				damage = 250,
				reload = 1.6,
				burst_count = 4,
				burst_interval = 0.23333,
				range = studs(1200),
				energy_per_shot = 0,
				turret = { turn_rate = math.rad(110) },
				anti_air = true,
				target_layer = "air",
				projectile = {
					speed = studs(540),
					acceleration = studs(300),
					thrust_time = 2.3,
					gravity = 0,
					drag = 0,
					aoe_radius = aoe(studs(48) / 3),
					line_thickness = 0.4,
					homing = true,
				},
			},
		},
		color = Color3.fromRGB(198, 86, 72),
	},
}

return table.freeze(defs)
