local ReplicatedStorage = game:GetService "ReplicatedStorage"

local types = require(ReplicatedStorage.Shared.types)

local conversions = require(script.Parent.conversions)

local studs = conversions.studs
local aoe = conversions.aoe
local capsule = conversions.capsule
local studs_per_second_squared = conversions.studs_per_second_squared
local MAP_GRAVITY = conversions.MAP_GRAVITY
local run_out = conversions.run_out
local accuracy = conversions.accuracy
local shell_speed = conversions.shell_speed
local shell_gravity = conversions.shell_gravity

type EntityDef = types.EntityDef

-- How BAR's `LaserCannon` is drawn: not a beam but a bolt of light that flies at the weapon's speed, as BAR's does, in
-- the yellow of its `rgbcolor`. Its damage lands where the bolt hits, not when it is fired.
local LASER_BOLT: types.ProjectileLook = {
	size = Vector3.new(0.2, 0.2, 1.6),
	color = Color3.new(1, 0.95, 0.4),
	material = Enum.Material.Neon,
}

-- divergence from bar: the drag on a bolt that has flown its weapon's range, where BAR's would fly on forever. Fired
-- level from a plane's height, it arcs down about as far again as its range, and falls no faster than 34 studs a second.
local BOLT_SPENT_DRAG = 0.02

-- The second tier of aircraft, the ones the Advanced Air Lab makes, in BAR's numbers from its unit files:
-- units/CorAircraft/T2/coraca.lua (Advanced Construction Aircraft), corvamp.lua (Nighthawk) and corhurc.lua
-- (Hailstorm), units/ArmAircraft/T2/armliche.lua (Liche) and armstil.lua (Stiletto), and
-- units/Legion/Air/T2 Air/legfort.lua (Tyrannus) and legstronghold.lua (Stronghold).
--
-- A unit file with no collision volume of its own gets a collider the size of its footprint, as the heavy drone does.
-- BAR has no turn rate for a plane, which comes out of its flight model; each one here is that model's steady turn at
-- full bank, elevator and rudder, worked out as the Valiant's and the Whirlwind's are: a circle of
-- 3.06 / (0.6 `maxrudder` + 0.8 `maxelevator`) elmos, flown at `speed`.
local defs: { [string]: EntityDef } = {
	-- coraca: the advanced builder that flies. It builds what the Advanced Construction Vehicle does, from anywhere.
	advanced_construction_aircraft = {
		name = "advanced_construction_aircraft",
		display_name = "Advanced Construction Aircraft",
		subtitle = "Advanced builder aircraft",
		kind = "unit",
		-- no collision volume of its own, so its 2 x 2 footprint, 32 elmos a side
		collider = capsule(32, 32, 32),
		metal_cost = 360,
		energy_cost = 11000,
		buildpower_cost = 22000,
		health = 205,
		buildpower = 130,
		build_range = studs(136),
		acceleration = studs_per_second_squared(0.065),
		max_speed = studs(181.5),
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
		-- `cruisealtitude` 70
		air = { altitude = studs(70), climb_speed = 10 },
		color = Color3.fromRGB(226, 178, 74),
	},

	-- corvamp: the stealth fighter. An enemy only picks it out to shoot at from close by (`stealth`), so it can slip
	-- past anti air that would reach it from far off.
	nighthawk = {
		name = "nighthawk",
		display_name = "Nighthawk",
		subtitle = "Stealth fighter",
		kind = "unit",
		-- no collision volume of its own, so its 2 x 2 footprint, 32 elmos a side
		collider = capsule(32, 32, 32),
		metal_cost = 145,
		energy_cost = 5100,
		buildpower_cost = 10500,
		health = 290,
		buildpower = nil,
		acceleration = studs_per_second_squared(0.2075),
		max_speed = studs(379),
		reclaiming = false,
		repairing = false,
		resurrecting = false,
		assisting = false,
		max_water_depth = studs(9999),
		build_options = nil,
		stealth = true,
		-- `cruisealtitude` 160 and `turnradius` 64; `maxelevator` 0.01113 and `maxrudder` 0.00663, a circle of about
		-- 22 studs
		air = {
			altitude = studs(160),
			climb_speed = 15,
			wings = { turn_rate = 1.59, run_out = run_out(64, 379) },
		},
		-- corvtol_advmissile
		weapons = {
			{
				damage = 500,
				reload = 1,
				range = studs(690),
				energy_per_shot = 0,
				anti_air = true,
				target_layer = "air",
				projectile = {
					speed = studs(515),
					acceleration = studs(450),
					thrust_time = (935 - 515) / 450,
					gravity = 0,
					drag = 0,
					aoe_radius = aoe(studs(8)),
					edge_effectiveness = 0.15,
					line_thickness = 0.25,
					homing = true,
				},
			},
		},
		color = Color3.fromRGB(70, 74, 92),
	},

	-- corhurc: the heavy bomber. A Whirlwind's run with heavier bombs over a wider blast, and the armour to live
	-- through the anti air on the way in.
	hailstorm = {
		name = "hailstorm",
		display_name = "Hailstorm",
		subtitle = "Heavy bomber",
		kind = "unit",
		-- no collision volume of its own, so its 4 x 4 footprint, 64 elmos a side
		collider = capsule(64, 64, 64),
		metal_cost = 310,
		energy_cost = 18500,
		buildpower_cost = 36000,
		health = 1520,
		buildpower = nil,
		acceleration = studs_per_second_squared(0.0525),
		max_speed = studs(248.399),
		reclaiming = false,
		repairing = false,
		resurrecting = false,
		assisting = false,
		max_water_depth = studs(9999),
		build_options = nil,
		-- `cruisealtitude` 220 and `turnradius` 64; `maxelevator` 0.00898 and `maxrudder` 0.00448, a circle of about
		-- 28 studs
		air = {
			altitude = studs(220),
			climb_speed = 11,
			bombing_runs = true,
			wings = { turn_rate = 0.8, run_out = run_out(64, 248.399) },
		},
		-- coradvbomb
		weapons = {
			{
				damage = 333,
				reload = 7,
				burst_count = 5,
				burst_interval = 0.2,
				-- divergence from bar, as the Whirlwind's. Bar is 1280 range which makes no sense for the bomber
				range = studs(100),
				energy_per_shot = 0,
				target_layer = "ground",
				projectile = {
					speed = 0,
					acceleration = 0,
					thrust_time = 0,
					-- `mygravity` 0.4
					gravity = studs_per_second_squared(0.4),
					drag = 0,
					aoe_radius = aoe(studs(180)),
					edge_effectiveness = 0.85,
					dropped = true,
				},
			},
		},
		color = Color3.fromRGB(150, 104, 78),
	},

	-- armstil: the EMP bomber. Its bombs stun what they land on rather than hurt it (server/emp.luau), and like the
	-- Nighthawk it is only picked out from close by (`stealth`).
	stiletto = {
		name = "stiletto",
		display_name = "Stiletto",
		subtitle = "EMP bomber",
		kind = "unit",
		-- 24 x 9 x 24 elmos
		collider = capsule(24, 9, 24),
		metal_cost = 460,
		energy_cost = 38000,
		buildpower_cost = 39000,
		health = 1880,
		buildpower = nil,
		acceleration = studs_per_second_squared(0.1575),
		max_speed = studs(300),
		reclaiming = false,
		repairing = false,
		resurrecting = false,
		assisting = false,
		max_water_depth = studs(9999),
		build_options = nil,
		stealth = true,
		-- `cruisealtitude` 120 and `turnradius` 64; `maxelevator` 0.00972 and `maxrudder` 0.00522, a circle of about
		-- 25 studs. BAR has no climb rate; this is the Hailstorm's.
		air = {
			altitude = studs(120),
			climb_speed = 11,
			bombing_runs = true,
			wings = { turn_rate = 1.07, run_out = run_out(64, 300) },
		},
		-- stiletto_bomb
		weapons = {
			{
				damage = 6000,
				reload = 7,
				burst_count = 3,
				burst_interval = 0.2333,
				-- divergence from bar, as the Whirlwind's. Bar is 1280 range which makes no sense for the bomber
				range = studs(100),
				energy_per_shot = 0,
				target_layer = "ground",
				paralyze_time = 20,
				projectile = {
					speed = 0,
					acceleration = 0,
					thrust_time = 0,
					-- `mygravity` 0.4
					gravity = studs_per_second_squared(0.4),
					drag = 0,
					aoe_radius = aoe(studs(200)),
					edge_effectiveness = 0.25,
					dropped = true,
					look = { explosion = "emp" },
				},
			},
		},
		color = Color3.fromRGB(96, 150, 190),
	},

	-- armliche: the atomic bomber. It comes in on a pass and fires one tactical nuclear missile from close by, slow to
	-- reload, so it wants an escort and a target worth it.
	liche = {
		name = "liche",
		display_name = "Liche",
		subtitle = "Atomic bomber",
		kind = "unit",
		-- no collision volume of its own, so its 3 x 3 footprint, 48 elmos a side
		collider = capsule(48, 48, 48),
		metal_cost = 2200,
		energy_cost = 46000,
		buildpower_cost = 73000,
		health = 2300,
		buildpower = nil,
		acceleration = studs_per_second_squared(0.1075),
		max_speed = studs(294.9),
		reclaiming = false,
		repairing = false,
		resurrecting = false,
		assisting = false,
		max_water_depth = studs(9999),
		build_options = nil,
		-- `cruisealtitude` 150 and `turnradius` 64; `maxelevator` 0.0095 and `maxrudder` 0.005, a circle of about
		-- 26 studs
		air = {
			altitude = studs(150),
			climb_speed = 10,
			bombing_runs = true,
			wings = { turn_rate = 1.02, run_out = run_out(64, 294.9) },
		},
		-- arm_pidr: a missile that does not track, fired at where its target is
		weapons = {
			{
				damage = 5625,
				reload = 9,
				range = studs(250),
				energy_per_shot = 0,
				target_layer = "ground",
				projectile = {
					speed = studs(140),
					acceleration = studs(40),
					thrust_time = (420 - 140) / 40,
					gravity = 0,
					drag = 0,
					aoe_radius = aoe(studs(256)),
					edge_effectiveness = 0.65,
					-- a fat dark missile that goes off in a mushroom cloud. BAR's anti-nukes do not target it.
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

	-- legfort: the flying fortress, a huge, slow gunship. It hovers, and like any gunship it keeps circling what it
	-- attacks while it fires (server/orbits.luau). Plasma cannons, burst-fire machine guns, and a rack of anti air
	-- missiles on top; the cannons and the guns are one weapon each here (see its weapons).
	tyrannus = {
		name = "tyrannus",
		display_name = "Tyrannus",
		subtitle = "Flying fortress",
		kind = "unit",
		-- 70 x 40 x 110 elmos
		collider = capsule(70, 40, 110),
		metal_cost = 5600,
		energy_cost = 79000,
		buildpower_cost = 119750,
		health = 16700,
		buildpower = nil,
		acceleration = studs_per_second_squared(0.09),
		max_speed = studs(93),
		reclaiming = false,
		repairing = false,
		resurrecting = false,
		assisting = false,
		max_water_depth = studs(9999),
		build_options = nil,
		-- `cruisealtitude` 100
		air = { altitude = studs(100), climb_speed = 6 },
		-- divergence from bar: BAR gives it two plasma cannons and three semiauto guns, alike but for where they sit.
		-- Here each alike set is one weapon, which fires all their shots as one burst, as often as they fired between
		-- them, so it hits as hard as often; only where the shots leave from is not quite the same.
		weapons = {
			-- plasma: BAR's two 166-damage cannons, 1.7 seconds apart each, as one firing both shells a tenth of a second
			-- apart and reloading for the rest of the 1.7 seconds
			{
				damage = 166,
				reload = 1.7 - 0.1,
				burst_count = 2,
				burst_interval = 0.1,
				range = studs(915),
				energy_per_shot = 0,
				target_layer = "ground",
				offset = Vector3.new(0, -0.6, 1.5),
				projectile = {
					speed = shell_speed(studs(400)),
					acceleration = 0,
					thrust_time = 0,
					gravity = shell_gravity(studs(MAP_GRAVITY)),
					drag = 0,
					aoe_radius = aoe(studs(160)),
					edge_effectiveness = 0.65,
					arc = "low",
					plasma = true,
					inaccuracy = accuracy(960),
				},
			},
			-- semiauto: BAR's three guns, each a 3-shot burst 0.066 seconds apart then 0.9 seconds' reload, as one gun
			-- firing all nine shots a third as far apart and reloading for the rest of the same 1.032 second cycle
			{
				damage = 36,
				reload = (2 * 0.066 + 0.9) - 8 * (0.066 / 3),
				burst_count = 9,
				burst_interval = 0.066 / 3,
				range = studs(650),
				energy_per_shot = 0,
				kind = "machine_gun",
				target_layer = "ground",
				offset = Vector3.new(0, -0.6, 1),
				-- divergence from bar: BAR's bolts fly on straight at full speed forever, off into the sky when they miss.
				-- Here each goes straight and level for as long as it takes to cross its range, so nothing within it is
				-- aimed any differently, and past that it slows and falls like a spent shell.
				projectile = {
					speed = studs(970),
					acceleration = 0,
					thrust_time = 650 / 970,
					gravity = shell_gravity(studs(MAP_GRAVITY)),
					drag = BOLT_SPENT_DRAG,
					aoe_radius = aoe(studs(16)),
					edge_effectiveness = 0.5,
					inaccuracy = accuracy(7 + 1024),
					look = LASER_BOLT,
				},
			},
			-- aa_missiles
			{
				damage = 76,
				reload = 0.8,
				range = studs(840),
				energy_per_shot = 0,
				anti_air = true,
				target_layer = "air",
				offset = Vector3.new(0, 1.2, 0),
				-- divergence from bar: drag as the other anti air missiles have, so that once its motor is spent one that
				-- missed slows and comes down rather than flying on at full speed
				projectile = {
					speed = studs(175),
					acceleration = studs(800),
					thrust_time = (1200 - 175) / 800,
					gravity = 0,
					drag = 0.02,
					aoe_radius = aoe(studs(16)),
					edge_effectiveness = 0.15,
					line_thickness = 0.3,
					homing = true,
				},
			},
		},
		color = Color3.fromRGB(150, 90, 80),
	},

	-- legstronghold: a heavy transport with a gun. It lifts light and heavy things, one at a time, as the Hephaestus
	-- does, and can cover what it drops off. As a gunship it circles what it attacks. BAR's shotgun throws eight
	-- 30-damage bolts at once in a spread; here they go out as a burst so quick it is nearly the same thing, as the
	-- Juggernaut's cannon does, each strayed within BAR's spray.
	stronghold = {
		name = "stronghold",
		display_name = "Stronghold",
		subtitle = "Heavy transport gunship",
		kind = "unit",
		-- 52 x 21 x 52 elmos
		collider = capsule(52, 21, 52),
		metal_cost = 550,
		energy_cost = 13000,
		buildpower_cost = 24200,
		health = 2600,
		buildpower = nil,
		acceleration = studs_per_second_squared(0.12),
		max_speed = studs(160),
		reclaiming = false,
		repairing = false,
		resurrecting = false,
		assisting = false,
		max_water_depth = studs(9999),
		-- legstronghold's `paralyzemultiplier` 0.025
		emp_resistance = 0.975,
		build_options = nil,
		-- `cruisealtitude` 135
		air = { altitude = studs(135), climb_speed = 8 },
		transport = { capacity = 1, carries = "heavy" },
		-- shotgun
		weapons = {
			{
				damage = 30,
				reload = 1.6,
				burst_count = 8,
				burst_interval = 0.01,
				range = studs(450),
				energy_per_shot = 0,
				kind = "shotgun",
				-- divergence from bar, as the Tyrannus's semiauto bolts: BAR's fly on straight at full speed forever, so
				-- one fired off into the distance could pick off something far out of range. Here each goes straight and
				-- level for as long as it takes to cross its range, and past that loses its speed fast and falls.
				projectile = {
					speed = studs(960),
					acceleration = 0,
					thrust_time = 450 / 960,
					gravity = shell_gravity(studs(MAP_GRAVITY)),
					drag = BOLT_SPENT_DRAG,
					aoe_radius = aoe(studs(16)),
					edge_effectiveness = 0.85,
					inaccuracy = accuracy(7 + 1000),
					look = LASER_BOLT,
				},
			},
		},
		color = Color3.fromRGB(226, 178, 74),
	},
}

return table.freeze(defs)
