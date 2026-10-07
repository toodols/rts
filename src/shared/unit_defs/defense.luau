--!strict
local ReplicatedStorage = game:GetService "ReplicatedStorage"

local types = require(ReplicatedStorage.Shared.types)

local conversions = require(script.Parent.conversions)
local palette = require(script.Parent.palette)
local footing = require(script.Parent.footing)

local cells = conversions.cells
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
local missile_aoe = conversions.missile_aoe
local ROCKET_GRAVITY = conversions.ROCKET_GRAVITY
local ROCKET_DRAG = conversions.ROCKET_DRAG
local altitude = conversions.altitude

type EntityDef = types.EntityDef
type Weapon = types.Weapon

-- BAR's fmd_rocket, the anti-nuke interceptor the Prevailer and the Rampart both fire, out to their `coverage` of
-- `coverage` elmos, and each stockpiled at BAR's price.
local function interceptor(coverage: number): Weapon
	return {
		kind = "anti_nuke",
		damage = 1500,
		reload = 2,
		range = studs(coverage),
		energy_per_shot = 0,
		stockpile = { limit = 20, build_time = 90, metal = 150, energy = 7500 },
		delivery = {
			kind = "straight",
			guidance = "homes",
			projectile = projectile({
				speed = studs(6000),
				aoe_radius = aoe(420),
				edge_effectiveness = 0.15,
				-- not bar's: fmd_rocket's turnrate is 10000, conversions.turn_rate(10000)
				turn_rate = 8,
				-- a slim white missile on a blue-white flame, gone in a blink at this speed, so what shows is the
				-- contrail and smoke it leaves hanging along the way it flew up to the nuke
				look = {
					size = Vector3.new(0.8, 0.8, 4),
					color = Color3.fromRGB(235, 238, 242),
					material = Enum.Material.Metal,
					trail = { color = Color3.fromRGB(225, 240, 255), width = 1.6, lifetime = 3 },
					flame = { color = Color3.fromRGB(150, 210, 255), size = 1.8, rate = 240, lifetime = 0.15 },
					smoke = { color = Color3.fromRGB(215, 218, 222), size = 1.6, rate = 160, lifetime = 2.5 },
					light = { color = Color3.fromRGB(160, 215, 255), range = 24, brightness = 4 },
				},
			}),
		},
	}
end

-- The buildings that fight: towers, artillery, missile silos, the anti-nuke and the plasma deflector.
local defs: { [string]: EntityDef } = {
	-- corllt, BAR's Guard: a light laser turret
	-- bar: corllt
	guard = {
		name = "guard",
		weight_class = "heavy",
		display_name = "Guard",
		subtitle = "Laser tower",
		kind = "building",
		category = "defences",
		collider = { shape = "box", width = cells(1), height = cells(2), length = cells(1) },
		metal_cost = 90,
		energy_cost = 700,
		buildpower_cost = 2500,
		health = 650,
		footing = footing.LAND,
		weapons = {
			{
				kind = "laser",
				damage = 75,
				reload = 0.46667,
				range = studs(435),
				energy_per_shot = 20,
				delivery = {
					kind = "beam",
					time = 0.12,
				},
				turret = { turn_rate = math.rad(240) },
			},
		} :: { Weapon },
		color = palette.BRICK,
	},

	-- corhllt: a stronger guard with two turrets, a long one on top and a shorter one below, each aimed
	-- at a target of its own
	-- bar: corhllt
	twin_guard = {
		name = "twin_guard",
		weight_class = "heavy",
		display_name = "Twin Guard",
		subtitle = "Twin laser tower",
		kind = "building",
		category = "defences",
		collider = { shape = "box", width = cells(1), height = cells(2), length = cells(1) },
		metal_cost = 195,
		energy_cost = 1750,
		buildpower_cost = 4900,
		health = 1670,
		footing = footing.LAND,
		weapons = {
			{
				kind = "laser",
				damage = 75,
				reload = 0.46667,
				range = studs(490),
				energy_per_shot = 15,
				delivery = {
					kind = "beam",
					time = 0.12,
				},
				turret = { turn_rate = math.rad(220) },
			},
			{
				kind = "laser",
				damage = 75,
				reload = 0.46667,
				range = studs(400),
				energy_per_shot = 15,
				delivery = {
					kind = "beam",
					time = 0.12,
				},
				turret = { turn_rate = math.rad(180) },
			},
		} :: { Weapon },
		color = palette.BRICK,
	},

	-- corhlt: a tower with one heavy laser that reaches far and hits hard, at a heavy cost in energy
	-- bar: corhlt
	warden = {
		name = "warden",
		display_name = "Warden",
		subtitle = "Heavy laser tower",
		kind = "building",
		category = "defences",
		-- 38 x 90 x 38 elmos
		collider = { shape = "box", width = cells(1), height = cells(2), length = cells(1) },
		metal_cost = 480,
		energy_cost = 4700,
		buildpower_cost = 11400,
		health = 2750,
		footing = footing.LAND,
		weapons = {
			{
				kind = "laser",
				damage = 261,
				reload = 1.2,
				range = studs(620),
				energy_per_shot = 50,
				delivery = {
					kind = "beam",
					time = 0.15,
					thickness = 0.5,
				},
				-- a heavy turret, slower to come round than a guard's
				turret = { turn_rate = math.rad(120) },
			},
		} :: { Weapon },
		color = palette.BRICK,
	},

	-- corrl, Cortex's Thistle: a tower that throws a missile at aircraft and at nothing else. The missile flies
	-- the way the aggravator's rocket does, at BAR's launch speed, acceleration and flight time. BAR's homes in on
	-- its target and this game's rockets do not, so it is aimed ahead of one that is moving.
	-- bar: corrl
	thistle = {
		name = "thistle",
		display_name = "Thistle",
		subtitle = "Anti air tower",
		kind = "building",
		category = "defences",
		-- 32 x 70 x 32 elmos, in whole grid cells
		collider = { shape = "box", width = cells(1), height = cells(2), length = cells(1) },
		metal_cost = 80,
		energy_cost = 850,
		buildpower_cost = 1750,
		health = 335,
		footing = footing.LAND,
		weapons = {
			{
				kind = "aa_missiles",
				damage = 115,
				reload = 1.7,
				range = studs(765),
				energy_per_shot = 0,
				turret = { turn_rate = math.rad(200) },
				target_layer = "air",
				delivery = {
					kind = "straight",
					guidance = "homes",
					projectile = projectile({
						speed = studs(400),
						acceleration = studs(150),
						thrust_time = 1.9,
						aoe_radius = missile_aoe(48),
						line_thickness = 0.3,
					}),
				},
			},
		} :: { Weapon },
		color = palette.BRICK,
	},

	-- corscreamer, Cortex's Screamer: a long range anti air missile tower. Like BAR's it builds its missiles up in a
	-- stockpile of five, one every 14 seconds for the 1800 energy BAR charges a shot, and fires them only at
	-- aircraft. The missile is launched and thrusts at BAR's speeds for its flight time, and homes on its target.
	-- bar: corscreamer
	screamer = {
		name = "screamer",
		display_name = "Screamer",
		subtitle = "Long range anti air tower",
		kind = "building",
		category = "defences",
		-- 63 x 57 x 63 elmos, in whole grid cells
		collider = { shape = "box", width = cells(2), height = cells(2), length = cells(2) },
		metal_cost = 1650,
		energy_cost = 32000,
		buildpower_cost = 28000,
		health = 1670,
		footing = footing.LAND,
		weapons = {
			{
				kind = "aa_missiles",
				damage = 750,
				reload = 1.8,
				range = studs(2400),
				energy_per_shot = 0,
				turret = { turn_rate = math.rad(90) },
				target_layer = "air",
				stockpile = { limit = 5, build_time = 14, metal = 0, energy = 1800 },
				delivery = {
					kind = "straight",
					guidance = "homes",
					projectile = projectile({
						speed = studs(1400),
						acceleration = studs(1000),
						thrust_time = 2.2,
						aoe_radius = missile_aoe(425),
						edge_effectiveness = 0.75,
						line_thickness = 0.6,
					}),
				},
			},
		} :: { Weapon },
		color = palette.BRICK,
	},

	-- corpun: a plasma battery with a long reach that lobs its shells over the front line. BAR lets it
	-- switch between a flat and a high trajectory; here it picks for itself each shot, the flat one when nothing is
	-- in the way of it and the high one when something is.
	-- bar: corpun
	agitator = {
		name = "agitator",
		display_name = "Agitator",
		subtitle = "Plasma artillery",
		kind = "building",
		category = "defences",
		-- 52 x 60 x 52 elmos
		collider = { shape = "box", width = cells(2), height = cells(2), length = cells(2) },
		metal_cost = 1300,
		energy_cost = 13500,
		buildpower_cost = 17400,
		health = 3250,
		footing = footing.LAND,
		weapons = {
			{
				kind = "plasma_cannon",
				damage = 350,
				reload = 3.16667,
				range = studs(1245),
				energy_per_shot = 0,
				turret = { turn_rate = math.rad(70) },
				delivery = {
					kind = "lobbed",
					arc = "auto",
					projectile = projectile({
						speed = shell_speed(studs(600)),
						gravity = shell_gravity(studs_per_second_squared(0.289)),
						aoe_radius = aoe(120),
						edge_effectiveness = 0.4,
						inaccuracy = accuracy(75),
					}),
				},
			},
		} :: { Weapon },
		color = palette.BRICK,
	},

	-- cortoast, Cortex's Persecutor: the Agitator's advanced version, built only by advanced construction units. It
	-- picks its arc the same way, but shoots farther, harder and wider. It falls under the map's gravity rather than a
	-- gravity of its own, as the Agitator's shell does.
	-- bar: cortoast
	persecutor = {
		name = "persecutor",
		display_name = "Persecutor",
		subtitle = "Advanced plasma artillery",
		kind = "building",
		category = "defences",
		collider = { shape = "box", width = cells(3), height = cells(3), length = cells(3) },
		metal_cost = 2500,
		energy_cost = 17000,
		buildpower_cost = 25700,
		health = 4250,
		footing = footing.LAND,
		weapons = {
			{
				kind = "plasma_cannon",
				damage = 420,
				reload = 2.1,
				range = studs(1390),
				energy_per_shot = 0,
				turret = { turn_rate = math.rad(55) },
				delivery = {
					kind = "lobbed",
					arc = "auto",
					projectile = projectile({
						speed = shell_speed(studs(450)),
						gravity = shell_gravity(studs(MAP_GRAVITY)),
						aoe_radius = aoe(164),
						edge_effectiveness = 0.4,
						inaccuracy = accuracy(450),
					}),
				},
			},
		} :: { Weapon },
		color = palette.BRICK,
	},

	-- bar: corvipe
	scorpion = {
		name = "scorpion",
		display_name = "Scorpion",
		subtitle = "Sabot Battery",
		kind = "building",
		category = "defences",
		collider = { shape = "box", width = cells(1), height = cells(2), length = cells(1) },
		metal_cost = 730,
		energy_cost = 14000,
		buildpower_cost = 15000,
		health = 3000,
		footing = footing.LAND,
		weapons = {
			{
				kind = "rockets",
				damage = 825,
				reload = 2,
				range = studs(730),
				energy_per_shot = 0,
				turret = { turn_rate = math.rad(150) },
				delivery = {
					kind = "straight",
					guidance = "none",
					projectile = projectile({
						speed = studs(570),
						acceleration = studs(400),
						thrust_time = 1.05,
						gravity = ROCKET_GRAVITY,
						drag = ROCKET_DRAG,
						aoe_radius = aoe(24),
						edge_effectiveness = 0.15,
					}),
				},
			},
		} :: { Weapon },
		color = palette.AMBER,
	},

	-- bar: armanni
	pulsar = {
		name = "pulsar",
		display_name = "Pulsar",
		subtitle = "Tachyon Accelerator",
		kind = "building",
		category = "defences",
		health = 6100,
		metal_cost = 3500,
		energy_cost = 74000,
		buildpower_cost = 52000,
		collider = { shape = "box", width = cells(2), height = cells(3), length = cells(2) },
		footing = footing.LAND,
		weapons = {
			{
				kind = "laser",
				damage = 10800,
				reload = 9.9,
				range = studs(1400),
				-- not bar's: armanni's energypershot is 1500
				energy_per_shot = 0,
				turret = { turn_rate = math.rad(45) },
				delivery = {
					kind = "beam",
					time = 1.5,
					thickness = 2,
					charged = true,
				},
			},
		} :: { Weapon },
		color = palette.BRICK,
	},

	-- cortron: a tactical missile launcher. It builds up missiles and holds them until it is told what to hit (BAR's
	-- `commandfire`), then sends one straight up; it comes back down on the target from above, so nothing in the way
	-- stops it.
	-- bar: cortron
	catalyst = {
		name = "catalyst",
		display_name = "Catalyst",
		subtitle = "Tactical missile launcher",
		kind = "building",
		category = "defences",
		collider = { shape = "box", width = cells(2), height = cells(2), length = cells(2) },
		metal_cost = 1200,
		energy_cost = 14000,
		buildpower_cost = 59000,
		-- not bar's: cortron's health is 3550
		health = 2400,
		footing = footing.LAND,
		weapons = {
			{
				kind = "missiles",
				damage = 4000,
				reload = 2,
				range = studs(2250),
				energy_per_shot = 0,
				stockpile = { limit = 10, build_time = 75, metal = 550, energy = 17437 },
				manual_fire = true,
				delivery = missile(
					"short",
					projectile({
						-- not bar's: cortron_weapon's weaponvelocity is 1200 and its edgeeffectiveness 0.55
						speed = studs(700),
						aoe_radius = aoe(380),
						edge_effectiveness = 0.3,
					})
				),
			},
		} :: { Weapon },
		color = palette.BRICK,
	},

	-- corsilo: a nuclear missile silo. Its missiles take a long time and a great deal to build, climb very
	-- high, cross the whole map and come down almost vertically on the target with a blast that dwarfs
	-- anything else in the game.
	-- bar: corsilo
	apocalypse = {
		name = "apocalypse",
		display_name = "Apocalypse",
		subtitle = "Nuclear missile silo",
		kind = "building",
		category = "defences",
		collider = { shape = "box", width = cells(3), height = cells(2), length = cells(3) },
		-- divergence from BAR. the apocalypse is simply too useful on this game configuration, so the metal cost is increased 2x
		metal_cost = 15400,
		energy_cost = 82000,
		buildpower_cost = 181000,
		-- not bar's: corsilo's health is 6200
		health = 4500,
		footing = footing.LAND,
		weapons = {
			{
				kind = "nuke",
				damage = 15000,
				reload = 30,
				-- as far as anything on the map, the whole of it
				range = studs(20000),
				energy_per_shot = 0,
				-- same here, each missile costs 2x metal than BAR
				stockpile = { limit = 10, build_time = 180, metal = 3000, energy = 187500 },
				-- it launches only when told what at
				manual_fire = true,
				delivery = missile(
					"long",
					projectile({
						-- not bar's: crblmssl's weaponvelocity is 1600 and its edgeeffectiveness 0
						speed = studs(500),
						aoe_radius = aoe(1920),
						edge_effectiveness = 0.1,
						-- a big dark missile riding a column of fire, leaving a white contrail and a pillar of smoke
						-- across the sky, that goes off in a mushroom cloud
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
					})
				),
			},
		} :: { Weapon },
		color = palette.BRICK,
	},

	-- corfmd, Cortex's Prevailer: an anti-nuke. It stockpiles interceptors (BAR's fmd_rocket, twenty at most, one every
	-- 90 seconds, each at BAR's price) and launches one on its own at every enemy nuke that is coming down within its
	-- coverage, BAR's `coverage`, which is its range here. One interceptor is all a nuke takes: it goes off where they
	-- meet, harmlessly, and comes no further. Its collider is kept to the art's 2 x 2 cells; BAR's volume is
	-- 48 x 78 x 48 elmos on a 4 x 4 footprint.
	-- bar: corfmd
	prevailer = {
		name = "prevailer",
		display_name = "Prevailer",
		subtitle = "Anti-nuke interceptor",
		kind = "building",
		category = "defences",
		collider = { shape = "box", width = cells(2), height = cells(3), length = cells(2) },
		metal_cost = 1500,
		energy_cost = 40000,
		buildpower_cost = 60000,
		health = 3300,
		footing = footing.LAND,
		weapons = { interceptor(2000) },
		color = Color3.fromRGB(100, 150, 200),
	},

	-- legrampart, Legion's Rampart: the advanced geothermal's sidegrade. It makes half the energy, but is an anti-nuke
	-- and a drone platform besides. Built on a vent, or over a Geothermal Powerplant already on one, as the advanced
	-- plant is. Its interceptor is BAR's fmd_rocket, whose `coverage` is how far out it defends and so is its range
	-- here, and each missile is stockpiled at BAR's price. Its drones are BAR's heavy drones, but two of them rather
	-- than BAR's three. BAR also gives it radar and a jammer, which there is nothing here to be.
	-- bar: legrampart
	rampart = {
		name = "rampart",
		display_name = "Rampart",
		subtitle = "Geothermal fortress",
		kind = "building",
		category = "defences",
		-- 96 x 86 x 96 elmos on the geothermals' 5 x 5 footprint
		collider = { shape = "box", width = cells(2), height = cells(2), length = cells(2) },
		metal_cost = 2600,
		energy_cost = 38000,
		buildpower_cost = 36000,
		health = 8600,
		-- legrampart.lua's maxwaterdepth
		footing = footing.shallows(studs(5)),
		energy_income = 600,
		energy_storage = 4000,
		spot = "geo",
		upgrades = { "geothermal_powerplant" },
		weapons = { interceptor(1600) },
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
		color = palette.EMBER,
	},

	-- legheavydrone: what a Rampart carries. Its heat ray is a burst of ten 10-damage beams in BAR, one shot of
	-- 100 here, as the Mantis's drone's burst is one shot. Nothing builds it: its carrier makes it.
	-- bar: legheavydrone
	heavy_drone = {
		name = "heavy_drone",
		display_name = "Heavy Drone",
		subtitle = "Combat drone",
		kind = "unit",
		category = "defences",
		role = "drone",
		-- no collision volume of its own, so its 2 x 2 footprint, 32 elmos a side
		collider = capsule(32, 32, 32),
		metal_cost = 90,
		energy_cost = 1000,
		buildpower_cost = 5820,
		health = 1650,
		acceleration = studs_per_second_squared(0.15),
		max_speed = studs(180.5),
		footing = footing.ANYWHERE,
		-- legheavydrone's `cruisealtitude` 68
		air = { altitude = altitude(68), climb_speed = 20 }, -- not bar's: climb_speed
		weapons = {
			{
				kind = "heat_ray",
				damage = 100,
				reload = 0.8,
				range = studs(430),
				energy_per_shot = 0,
				delivery = {
					kind = "beam",
					time = 0.1,
					color = Color3.fromRGB(255, 140, 0),
				},
			},
		} :: { Weapon },
		color = palette.EMBER,
	},

	-- corbuzz, Cortex's Calamity: a plasma cannon that fires shell after shell at a range nothing else reaches. A
	-- shot costs 18000 energy, so a team has to hold that much before it can fire at all. It picks its arc for every
	-- shot: the low one when that is clear, then the medium one, which goes well up into the air, and the high one
	-- when the ground is in the way of both.
	-- bar: corbuzz
	calamity = {
		name = "calamity",
		display_name = "Calamity",
		subtitle = "Rapid fire long range plasma cannon",
		kind = "building",
		category = "defences",
		-- 80 x 160 x 80 elmos, in whole grid cells
		collider = { shape = "box", width = cells(2), height = cells(4), length = cells(2) },
		metal_cost = 68000,
		energy_cost = 800000,
		buildpower_cost = 1400000,
		health = 33500,
		footing = footing.LAND,
		weapons = {
			{
				kind = "plasma_cannon",
				damage = 2000,
				reload = 0.75,
				range = studs(6100),
				energy_per_shot = 18000,
				turret = { turn_rate = math.rad(35) },
				delivery = {
					kind = "lobbed",
					arc = "auto",
					projectile = projectile({
						speed = shell_speed(studs(950)),
						gravity = shell_gravity(studs(MAP_GRAVITY)),
						aoe_radius = aoe(157),
						edge_effectiveness = 0.15,
						inaccuracy = accuracy(750),
					}),
				},
			},
		} :: { Weapon },
		color = palette.BRICK,
	},

	-- corgate, Cortex's Overseer: a plasma deflector. It stands inside a bubble that swallows enemy plasma shells,
	-- the arced shots of artillery and cannons; rockets and beams pass through it.
	-- bar: corgate
	overseer = {
		name = "overseer",
		display_name = "Overseer",
		subtitle = "Plasma deflector",
		kind = "building",
		category = "defences",
		-- 57 x 38 x 57 elmos, in whole grid cells
		collider = { shape = "box", width = cells(1), height = cells(1), length = cells(1) },
		metal_cost = 3200,
		energy_cost = 55000,
		buildpower_cost = 55000,
		health = 3550,
		footing = footing.LAND,
		shield = {
			radius = studs(550),
			power = 6175,
			regen = 130,
			regen_energy = 562.5,
			starting_power = 2090,
			blocks = "plasma",
		},
		color = palette.SKY,
	},

	-- A wall section, after BAR's Dragon's Teeth (armdrag): cheap, tough and inert, put down in lines (shift-drag) to
	-- block a path or soak up fire. It is the utility category's own building.
	-- bar: armdrag
	wall = {
		name = "wall",
		display_name = "Wall",
		kind = "building",
		category = "defences",
		collider = { shape = "box", width = cells(2), height = cells(1), length = cells(2) },
		metal_cost = 10 * 4,
		energy_cost = 0,
		buildpower_cost = 1000 * 4,
		health = 2800 * 2,
		self_destruct_countdown = 1,
		footing = footing.LAND,
		-- armdrag's `paralyzemultiplier` 0
		emp_resistance = 1,
		-- armdrag's customparams
		objectify = true,
		color = Color3.fromRGB(128, 132, 138),
	},

	-- corerad, Cortex's Eradicator: a heavy anti-air battery that fires bursts of four fast homing missiles far out, so
	-- bombers come down before they are over what they came for. It shoots at aircraft and nothing else. The missile
	-- flies the way the Thistle's does, at BAR's launch speed, acceleration and flight time.
	-- bar: corerad
	eradicator = {
		name = "eradicator",
		display_name = "Eradicator",
		subtitle = "Heavy anti air battery",
		kind = "building",
		category = "defences",
		-- 55 x 36 x 48 elmos, in whole grid cells
		collider = { shape = "box", width = cells(2), height = cells(2), length = cells(2) },
		metal_cost = 800,
		energy_cost = 7900,
		buildpower_cost = 12000,
		health = 4450,
		footing = footing.LAND,
		weapons = {
			{
				kind = "aa_missiles",
				damage = 250,
				reload = 1.6,
				burst_count = 4,
				burst_interval = 0.23333,
				range = studs(1200),
				energy_per_shot = 0,
				turret = { turn_rate = math.rad(110) },
				target_layer = "air",
				delivery = {
					kind = "straight",
					guidance = "homes",
					projectile = projectile({
						speed = studs(540),
						acceleration = studs(300),
						thrust_time = 2.3,
						aoe_radius = missile_aoe(48),
						line_thickness = 0.4,
					}),
				},
			},
		} :: { Weapon },
		color = palette.BRICK,
	},

	-- The defences that float, which a construction ship builds.

	-- cortl, Cortex's Urchin: a torpedo launcher moored offshore. It fires at what is in the water and nothing else, as
	-- the Orca's torpedoes do; its torpedo leaves at BAR's launch speed and gains its acceleration until it is at BAR's
	-- top speed. BAR gives it no collision volume of its own, so its collider is its footprint, as tall as its wreck.
	-- bar: cortl
	urchin = {
		name = "urchin",
		display_name = "Urchin",
		subtitle = "Torpedo launcher",
		kind = "building",
		category = "defences",
		collider = { shape = "box", width = cells(1), height = studs(19), length = cells(1) },
		metal_cost = 170,
		energy_cost = 1800,
		buildpower_cost = 3750,
		health = 1440,
		footing = footing.afloat(studs(12)),
		weapons = {
			{
				kind = "torpedo",
				damage = 280,
				reload = 1.5,
				range = studs(500),
				energy_per_shot = 0,
				delivery = {
					kind = "torpedo",
					guidance = "leads",
					projectile = projectile({
						speed = studs(230),
						acceleration = studs(50),
						thrust_time = (280 - 230) / 50,
						aoe_radius = aoe(16),
						edge_effectiveness = 0.55,
					}),
				},
			},
		} :: { Weapon },
		color = palette.BRICK,
	},

	-- corfhlt, Cortex's Coral: the Warden afloat. Its laser is BAR's own for it, a little weaker and quicker than the
	-- Warden's and reaching a little further, on a broader, tougher hull that costs more energy.
	-- bar: corfhlt
	coral = {
		name = "coral",
		display_name = "Coral",
		subtitle = "Floating heavy laser tower",
		kind = "building",
		category = "defences",
		-- 73 x 67 x 73 elmos
		collider = { shape = "box", width = cells(2), height = studs(67), length = cells(2) },
		metal_cost = 480,
		energy_cost = 6200,
		buildpower_cost = 11400,
		health = 4350,
		footing = footing.afloat(studs(5)),
		weapons = {
			{
				kind = "laser",
				damage = 231,
				reload = 1,
				range = studs(630),
				energy_per_shot = 45,
				delivery = {
					kind = "beam",
					time = 0.225,
					thickness = 0.45,
				},
				-- the Warden's turret
				turret = { turn_rate = math.rad(120) },
			},
		} :: { Weapon },
		color = palette.BRICK,
	},

	-- corfrt, Cortex's Slingshot: the Thistle afloat, with the Thistle's missile, cost and health.
	-- bar: corfrt
	slingshot = {
		name = "slingshot",
		display_name = "Slingshot",
		subtitle = "Floating anti air tower",
		kind = "building",
		category = "defences",
		-- 40 x 64 x 40 elmos
		collider = { shape = "box", width = cells(1), height = studs(64), length = cells(1) },
		metal_cost = 80,
		energy_cost = 850,
		buildpower_cost = 1750,
		health = 335,
		footing = footing.afloat(studs(2)),
		weapons = {
			{
				kind = "aa_missiles",
				damage = 115,
				reload = 1.7,
				range = studs(765),
				energy_per_shot = 0,
				-- the Thistle's turret
				turret = { turn_rate = math.rad(200) },
				target_layer = "air",
				delivery = {
					kind = "straight",
					guidance = "homes",
					projectile = projectile({
						speed = studs(400),
						acceleration = studs(150),
						thrust_time = 1.9,
						aoe_radius = missile_aoe(48),
						line_thickness = 0.3,
					}),
				},
			},
		} :: { Weapon },
		color = palette.BRICK,
	},
}

return table.freeze(defs)
