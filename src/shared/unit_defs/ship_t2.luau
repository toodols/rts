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
local shell_speed = conversions.shell_speed
local shell_gravity = conversions.shell_gravity
local projectile = conversions.projectile
local missile_aoe = conversions.missile_aoe
local accuracy = conversions.accuracy

type EntityDef = types.EntityDef
type Weapon = types.Weapon

-- Cortex's second tier of warships, from the Advanced Shipyard (the Buccaneer and the Sea Dragon are in ship_t1.luau).
-- A turret's turn rate is its aim speed in the unit's script (scripts/Units/<name>.bos); BAR's per-category damages
-- (commanders, subs) are left out, as they are for every other def, and anti-air weapons use BAR's `vtol` damage.

-- cor_bats (units/CorShips/T2/corbats.lua)
local function despot_cannon(): Weapon
	return {
		kind = "plasma_cannon",
		damage = 450,
		reload = 4,
		range = studs(950),
		-- corbats.bos: MAX_AIMY1_VELOCITY, 2.2 degrees a frame
		turret = { turn_rate = math.rad(2.2 * 30) },
		energy_per_shot = 0,
		target_layer = "ground",
		delivery = {
			kind = "lobbed",
			arc = "low",
			projectile = projectile({
				speed = shell_speed(studs(422)),
				gravity = shell_gravity(studs(MAP_GRAVITY)),
				aoe_radius = aoe(140),
				edge_effectiveness = 0.15,
				inaccuracy = accuracy(400),
			}),
		},
	}
end

-- corblackhy's heavylaser (units/CorShips/T2/corblackhy.lua)
local function hydra_laser(): Weapon
	return {
		kind = "laser",
		damage = 270,
		reload = 0.95,
		range = studs(830),
		-- corblackhy.bos: 150 degrees a second
		turret = { turn_rate = math.rad(150) },
		energy_per_shot = 80,
		target_layer = "ground",
		delivery = {
			kind = "beam",
			time = 0.2,
			thickness = 0.4,
			color = Color3.new(0, 1, 0),
		},
	}
end

-- corblackhy's ferret_missile
local function hydra_ferret(): Weapon
	return {
		kind = "aa_missiles",
		damage = 150,
		reload = 1.7,
		burst_count = 2,
		burst_interval = 0.2,
		range = studs(840),
		-- corblackhy.bos: 200 degrees a second
		turret = { turn_rate = math.rad(200) },
		energy_per_shot = 0,
		target_layer = "air",
		delivery = {
			kind = "straight",
			guidance = "homes",
			guidance_time = 2.5,
			projectile = projectile({
				speed = studs(1),
				acceleration = studs(1500),
				thrust_time = (1200 - 1) / 1500,
				aoe_radius = missile_aoe(16),
				edge_effectiveness = 0.15,
				line_thickness = 0.3,
			}),
		},
	}
end

local defs: { [string]: EntityDef } = {
	-- corbats (units/CorShips/T2/corbats.lua), Cortex's Despot: a battleship. Its one big turret carries three cannons,
	-- which BAR slaves to the first (`slaveto`) and its script fires one after another as a salvo; here they are three
	-- weapons of their own, the first on the turret and the other two aiming alongside it. A green heavy laser, which
	-- needs energy to fire, sits on a turret of its own. Everything here is BAR's.
	-- bar: corbats
	despot = {
		name = "despot",
		display_name = "Despot",
		subtitle = "Battleship",
		kind = "unit",
		category = "ships",
		tech_level = 2,
		-- 62 x 62 x 148 elmos
		collider = capsule(62, 62, 148),
		metal_cost = 3400,
		energy_cost = 23000,
		buildpower_cost = 51000,
		health = 12000,
		acceleration = studs_per_second_squared(0.01427),
		max_speed = studs(53.1),
		footing = footing.ship("BOAT9", studs(15)),
		weapons = {
			despot_cannon(),
			despot_cannon(),
			despot_cannon(),
			-- cor_batslaser
			{
				kind = "laser",
				damage = 300,
				reload = 0.95,
				range = studs(700),
				-- corbats.bos: 200 degrees a second
				turret = { turn_rate = math.rad(200) },
				energy_per_shot = 80,
				target_layer = "ground",
				delivery = {
					kind = "beam",
					time = 0.2,
					thickness = 0.4,
					color = Color3.new(0, 1, 0),
				},
			},
		} :: { Weapon },
		color = palette.STEEL_BLUE,
	},

	-- corshark (units/CorShips/T2/corshark.lua), Cortex's Predator: a fast attack submarine. It runs under the surface,
	-- where nothing but a torpedo can be aimed at it, and fires quick homing torpedoes (`tracks`) from fixed tubes, at
	-- what is within BAR's `tolerance` of ahead (9000 of a 65536th turn either side). The torpedo leaves at BAR's launch
	-- speed and gains its acceleration until it is at BAR's top speed. Everything here is BAR's.
	-- bar: corshark
	predator = {
		name = "predator",
		display_name = "Predator",
		subtitle = "Attack submarine",
		kind = "unit",
		category = "ships",
		tech_level = 2,
		-- 30 x 30 x 64 elmos
		collider = capsule(30, 30, 64),
		metal_cost = 730,
		energy_cost = 14000,
		buildpower_cost = 23000,
		health = 1610,
		acceleration = studs_per_second_squared(0.05),
		max_speed = studs(84),
		footing = footing.ship("UBOAT4", studs(15), studs(40)),
		weapons = {
			-- armsmart_torpedo
			{
				kind = "torpedo",
				damage = 350,
				reload = 2.2,
				range = studs(400),
				energy_per_shot = 0,
				fire_arc = math.rad(9000 * 360 / 65536),
				delivery = {
					kind = "torpedo",
					guidance = "homes",
					projectile = projectile({
						speed = studs(150),
						acceleration = studs(10),
						thrust_time = (200 - 150) / 10,
						aoe_radius = aoe(16),
						edge_effectiveness = 0.15,
					}),
				},
			},
		} :: { Weapon },
		color = palette.STEEL_BLUE,
	},

	-- corssub (units/CorShips/T2/corssub.lua), Cortex's Kraken: a long-range battle submarine, stealthy and slow, with
	-- one heavy homing torpedo that hits hard and reaches far. BAR fires it within 80 degrees of ahead (`maxangledif`).
	-- The torpedo leaves at BAR's launch speed and gains its acceleration until it is at BAR's top speed. Everything
	-- here is BAR's.
	-- bar: corssub
	kraken = {
		name = "kraken",
		display_name = "Kraken",
		subtitle = "Battle submarine",
		kind = "unit",
		category = "ships",
		tech_level = 2,
		-- 52 x 25 x 60 elmos
		collider = capsule(52, 25, 60),
		metal_cost = 1900,
		energy_cost = 29000,
		buildpower_cost = 35000,
		health = 3900,
		acceleration = studs_per_second_squared(0.018),
		max_speed = studs(39),
		footing = footing.ship("UBOAT4", studs(20), studs(80)),
		weapons = {
			-- armserp_weapon
			{
				kind = "torpedo",
				damage = 1650,
				reload = 8,
				range = studs(850),
				energy_per_shot = 0,
				fire_arc = math.rad(80) / 2,
				delivery = {
					kind = "torpedo",
					guidance = "homes",
					projectile = projectile({
						speed = studs(150),
						acceleration = studs(25),
						thrust_time = (220 - 150) / 25,
						aoe_radius = aoe(160),
						edge_effectiveness = 0.15,
					}),
				},
			},
		} :: { Weapon },
		color = palette.COPPER,
	},

	-- cormship (units/CorShips/T2/cormship.lua), Cortex's Messenger: a cruise missile ship. Its launcher, which only
	-- pitches (cormship.bos), throws a heavy rocket high over whatever is in the way, at what is within 60 degrees of
	-- ahead (`maxangledif`); once it starts to come down it splits (BAR's `split` special effect) into eight smaller
	-- rockets, BAR's `rocket_split`, which rain down around its target. A missile turret on its deck shoots at
	-- aircraft. BAR's radar is left out, as there is none here. Everything else here is BAR's.
	-- bar: cormship
	messenger = {
		name = "messenger",
		display_name = "Messenger",
		subtitle = "Cruise missile ship",
		kind = "unit",
		category = "ships",
		tech_level = 2,
		-- 43 x 43 x 101 elmos
		collider = capsule(43, 43, 101),
		metal_cost = 2000,
		energy_cost = 10000,
		buildpower_cost = 24000,
		health = 3350,
		acceleration = studs_per_second_squared(0.02799),
		max_speed = studs(61.44),
		footing = footing.ship("BOAT5", studs(12)),
		weapons = {
			-- rocket
			{
				kind = "rockets",
				damage = 1100,
				reload = 8,
				range = studs(1550),
				energy_per_shot = 0,
				fire_arc = math.rad(60) / 2,
				target_layer = "ground",
				delivery = {
					kind = "lobbed",
					arc = "high",
					projectile = projectile({
						speed = shell_speed(studs(450)),
						gravity = shell_gravity(studs(MAP_GRAVITY)),
						aoe_radius = aoe(300),
						edge_effectiveness = 0.15,
					}),
				},
				-- rocket_split
				split = {
					count = 8,
					weapon = {
						kind = "rockets",
						damage = 350,
						reload = 8,
						range = studs(1550),
						energy_per_shot = 0,
						target_layer = "ground",
						delivery = {
							kind = "lobbed",
							arc = "high",
							projectile = projectile({
								speed = shell_speed(studs(480)),
								gravity = shell_gravity(studs(MAP_GRAVITY)),
								aoe_radius = aoe(68),
								edge_effectiveness = 0.15,
							}),
						},
					},
				},
			},
			-- missile
			{
				kind = "aa_missiles",
				damage = 138,
				reload = 2,
				range = studs(710),
				-- cormship.bos: 170 degrees a second
				turret = { turn_rate = math.rad(170) },
				energy_per_shot = 0,
				target_layer = "air",
				delivery = {
					kind = "straight",
					guidance = "homes",
					guidance_time = 1.75,
					projectile = projectile({
						speed = studs(430),
						acceleration = studs(90),
						thrust_time = (450 - 430) / 90,
						aoe_radius = missile_aoe(48),
						edge_effectiveness = 0.15,
						line_thickness = 0.3,
					}),
				},
			},
		} :: { Weapon },
		color = palette.BRICK,
	},

	-- corarch (units/CorShips/T2/corarch.lua), Cortex's Arrow Storm: an anti-air ship, with a pair of missile racks
	-- that fire two at a time, and a flak cannon whose shells burst where they were aimed (`burnblow`), among the
	-- aircraft they were fired at. BAR's `bogus_missile`, which does no damage, is left out. Everything else here is
	-- BAR's.
	-- bar: corarch
	arrow_storm = {
		name = "arrow_storm",
		display_name = "Arrow Storm",
		subtitle = "Anti-air ship",
		kind = "unit",
		category = "ships",
		tech_level = 2,
		-- 37 x 37 x 74 elmos
		collider = capsule(37, 37, 74),
		metal_cost = 1000,
		energy_cost = 12000,
		buildpower_cost = 21000,
		health = 3900,
		acceleration = studs_per_second_squared(0.03127),
		max_speed = studs(60.48),
		footing = footing.ship("BOAT4", studs(30)),
		weapons = {
			-- ga2
			{
				kind = "aa_missiles",
				damage = 125,
				reload = 1.6,
				burst_count = 2,
				burst_interval = 0.4,
				range = studs(870),
				-- corarch.bos: 455 degrees a second
				turret = { turn_rate = math.rad(455) },
				energy_per_shot = 0,
				target_layer = "air",
				delivery = {
					kind = "straight",
					guidance = "homes",
					guidance_time = 1.75,
					projectile = projectile({
						speed = studs(1),
						acceleration = studs(1200),
						thrust_time = (1000 - 1) / 1200,
						aoe_radius = missile_aoe(64),
						edge_effectiveness = 0.15,
						line_thickness = 0.3,
					}),
				},
			},
			-- mobileflak
			{
				kind = "flak",
				damage = 200,
				reload = 0.73333,
				range = studs(775),
				-- corarch.bos: 755 degrees a second
				turret = { turn_rate = math.rad(755) },
				energy_per_shot = 0,
				target_layer = "air",
				delivery = {
					kind = "lobbed",
					arc = "low",
					projectile = projectile({
						speed = shell_speed(studs(1550)),
						gravity = shell_gravity(studs(MAP_GRAVITY)),
						aoe_radius = aoe(140),
						edge_effectiveness = 1,
						inaccuracy = accuracy(1000),
						burst_at_aim = true,
					}),
				},
			},
		} :: { Weapon },
		color = palette.SKY,
	},

	-- corblackhy (units/CorShips/T2/corblackhy.lua), Cortex's Black Hydra: the flagship. A great turret of heavy plasma
	-- cannon fires bursts of four shells that reach across much of the map, three green heavy lasers, which need energy
	-- to fire, cover it close in, and two pop-up missile launchers shoot at aircraft. EMP does nothing to it
	-- (`paralyzemultiplier` 0), and it goes up as BAR's `flagshipExplosion` when it dies. BAR's `aamissile`, which none
	-- of its weapons use, and its radar, as there is none here, are left out. Everything else here is BAR's.
	-- bar: corblackhy
	black_hydra = {
		name = "black_hydra",
		display_name = "Black Hydra",
		subtitle = "Flagship",
		kind = "unit",
		category = "ships",
		tech_level = 2,
		-- 80 x 80 x 186 elmos
		collider = capsule(80, 80, 186),
		metal_cost = 21000,
		energy_cost = 190000,
		buildpower_cost = 310000,
		health = 53000,
		acceleration = studs_per_second_squared(0.00809),
		max_speed = studs(49.5),
		footing = footing.ship("BOAT9", studs(15)),
		emp_resistance = 1,
		weapons = {
			-- heavyplasma
			{
				kind = "plasma_cannon",
				damage = 600,
				reload = 5.5,
				burst_count = 4,
				burst_interval = 0.8,
				range = studs(2550),
				-- corblackhy.bos: CATT1_MAX_VELOCITY, 3 degrees a frame
				turret = { turn_rate = math.rad(3 * 30) },
				energy_per_shot = 0,
				target_layer = "ground",
				delivery = {
					kind = "lobbed",
					arc = "low",
					projectile = projectile({
						speed = shell_speed(studs(600)),
						gravity = shell_gravity(studs(MAP_GRAVITY)),
						aoe_radius = aoe(240),
						edge_effectiveness = 0.15,
						-- its accuracy and its sprayangle
						inaccuracy = accuracy(500 + 600),
					}),
				},
			},
			hydra_laser(),
			hydra_ferret(),
			hydra_laser(),
			hydra_laser(),
			hydra_ferret(),
		} :: { Weapon },
		death_explosion = { radius = studs(480), damage = 2650 },
		color = palette.GOLD,
	},
}

return table.freeze(defs)
