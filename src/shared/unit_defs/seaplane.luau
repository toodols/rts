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
local shell_speed = conversions.shell_speed
local shell_gravity = conversions.shell_gravity
local projectile = conversions.projectile
local altitude = conversions.altitude

type EntityDef = types.EntityDef
type Weapon = types.Weapon

-- Cortex's seaplanes, the ones the Seaplane Platform makes, in BAR's numbers from its unit files:
-- units/CorSeaplanes/corcsa.lua (Construction Seaplane), corcut.lua (Cutlass), corsb.lua (Dam Buster), corseap.lua
-- (Monsoon) and corsfig.lua (Bat). BAR files them between its first and second tiers (the platform's `techlevel` 1.5),
-- and so are they here.
--
-- None of them has a collision volume of its own, so each gets a collider the size of its footprint. BAR has no turn
-- rate for a plane, which comes out of its flight model; each winged one's is that model's steady turn at full bank,
-- elevator and rudder, worked out as the Valiant's is: a circle of 3.06 / (0.6 `maxrudder` + 0.8 `maxelevator`) elmos,
-- flown at `speed`. The gunships, which hover, circle what they attack (server/orbits.luau) side on, and fire whichever
-- way it is from them.
local TECH_LEVEL = 1.5

local defs: { [string]: EntityDef } = {
	-- corcsa: a builder that flies, off the Seaplane Platform. It builds on the land and on the sea alike.
	-- bar: corcsa
	construction_seaplane = {
		name = "construction_seaplane",
		display_name = "Construction Seaplane",
		kind = "unit",
		category = "aircraft",
		tech_level = TECH_LEVEL,
		-- no collision volume of its own, so its 2 x 2 footprint, 32 elmos a side
		collider = capsule(32, 32, 32),
		metal_cost = 140,
		energy_cost = 5300,
		buildpower_cost = 9500,
		health = 435,
		energy_income = 20,
		energy_storage = 75,
		builder = {
			buildpower = 75,
			range = studs(136),
			assists = true,
			repairs = true,
			reclaims = true,
			-- corcsa's own list, less what this game does not have
			options = {
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
				"wall",
				"guard",
				"twin_guard",
				"warden",
				"agitator",
				"thistle",
				"eradicator",
				"shipyard",
				"seaplane_platform",
				"advanced_air_lab",
				"tidal_generator",
			},
		},
		acceleration = studs_per_second_squared(0.072),
		max_speed = studs(140),
		footing = footing.ANYWHERE,
		-- `cruisealtitude` 55
		air = { altitude = altitude(55), climb_speed = 10 }, -- not bar's: climb_speed
		color = palette.AMBER,
	},

	-- corcut: a gunship with a quick pair of cannon shots, for what is on the ground and the water
	-- bar: corcut
	cutlass = {
		name = "cutlass",
		display_name = "Cutlass",
		subtitle = "Seaplane gunship",
		kind = "unit",
		category = "aircraft",
		tech_level = TECH_LEVEL,
		-- no collision volume of its own, so its 3 x 3 footprint, 48 elmos a side
		collider = capsule(48, 48, 48),
		metal_cost = 230,
		energy_cost = 5400,
		buildpower_cost = 11500,
		health = 1010,
		acceleration = studs_per_second_squared(0.18),
		max_speed = studs(152.39999),
		footing = footing.ANYWHERE,
		-- `cruisealtitude` 85
		air = { altitude = altitude(85), climb_speed = 10 }, -- not bar's: climb_speed
		-- vtol_rocket2, which is a cannon for all its name
		weapons = {
			{
				kind = "plasma_cannon",
				damage = 47,
				reload = 1.3,
				burst_count = 2,
				burst_interval = 0.1,
				range = studs(430),
				energy_per_shot = 0,
				target_layer = "ground",
				delivery = {
					kind = "lobbed",
					arc = "low",
					projectile = projectile({
						speed = shell_speed(studs(600)),
						gravity = shell_gravity(studs(MAP_GRAVITY)),
						aoe_radius = aoe(18),
						edge_effectiveness = 0.15,
					}),
				},
			},
		} :: { Weapon },
		color = palette.EMBER,
	},

	-- corsb: a bomber. It lays a wide carpet of bombs on a pass, three salvos of eight, and comes round again.
	-- bar: corsb
	dam_buster = {
		name = "dam_buster",
		display_name = "Dam Buster",
		subtitle = "Seaplane bomber",
		kind = "unit",
		category = "aircraft",
		tech_level = TECH_LEVEL,
		-- no collision volume of its own, so its 3 x 3 footprint, 48 elmos a side
		collider = capsule(48, 48, 48),
		metal_cost = 200,
		energy_cost = 8200,
		buildpower_cost = 9000,
		health = 940,
		acceleration = studs_per_second_squared(0.06),
		max_speed = studs(240),
		footing = footing.ANYWHERE,
		-- `cruisealtitude` 150 and `turnradius` 64; `maxelevator` 0.00972 and `maxrudder` 0.00522, a circle of about
		-- 26 studs
		air = {
			altitude = altitude(150),
			climb_speed = 11, -- not bar's
			bombing_runs = true,
			wings = { turn_rate = 0.86, run_out = run_out(64, 240) }, -- derived: turn_rate
		},
		-- cor_seaadvbomb: three salvos (`burst` 3, `burstrate` 0.13333) of eight bombs each (`projectiles` 8), strewn
		-- about their line (`sprayangle` 6000). BAR's bombs skip off the water; these do not.
		weapons = {
			{
				kind = "bombs",
				damage = 50,
				reload = 8,
				-- derived: the 24 bombs as one burst, let go evenly over the time BAR's three salvos take, so they are
				-- laid in a line as long as BAR's
				burst_count = 3 * 8,
				burst_interval = 2 * 0.13333 / (3 * 8 - 1),
				-- divergence from bar, as the Whirlwind's. Bar is 1280 range which makes no sense for the bomber
				range = studs(100),
				energy_per_shot = 0,
				target_layer = "ground",
				delivery = {
					kind = "bomb",
					projectile = projectile({
						speed = 0,
						-- `mygravity` 0.4
						gravity = studs_per_second_squared(0.4),
						aoe_radius = aoe(100),
						edge_effectiveness = 0.65,
					}),
				},
			},
		} :: { Weapon },
		color = palette.COPPER,
	},

	-- corseap: a torpedo gunship. It hovers over the sea and drops homing torpedoes on what is in the water, ships and
	-- submarines alike, and on nothing else.
	-- bar: corseap
	monsoon = {
		name = "monsoon",
		display_name = "Monsoon",
		subtitle = "Torpedo gunship",
		kind = "unit",
		category = "aircraft",
		tech_level = TECH_LEVEL,
		-- no collision volume of its own, so its 3 x 3 footprint, 48 elmos a side
		collider = capsule(48, 48, 48),
		metal_cost = 230,
		energy_cost = 5500,
		buildpower_cost = 11000,
		health = 1000,
		acceleration = studs_per_second_squared(0.22),
		max_speed = studs(200),
		footing = footing.ANYWHERE,
		-- `cruisealtitude` 100
		air = { altitude = altitude(100), climb_speed = 10 }, -- not bar's: climb_speed
		-- armseap_weapon1. BAR's hits what is on land too, for a fifth of its damage (`land_damage_mult` 0.2); a torpedo
		-- here is aimed at nothing out of the water.
		weapons = {
			{
				kind = "torpedo",
				damage = 342,
				reload = 4,
				range = studs(600),
				energy_per_shot = 0,
				-- not bar's: BAR's fires into a 40 degree cone ahead (`maxangledif` 40), which a gunship circling side on
				-- here would hardly ever have its target in, so it fires whichever way its target is
				delivery = {
					kind = "torpedo",
					guidance = "homes",
					projectile = projectile({
						speed = studs(130),
						acceleration = studs(15),
						thrust_time = (200 - 130) / 15,
						-- derived: let go in the air, it falls under Spring's map gravity until it meets the water, as a
						-- torpedo does in Spring (it has no `mygravity` of its own)
						gravity = studs(MAP_GRAVITY),
						aoe_radius = aoe(16),
						edge_effectiveness = 0.35,
					}),
				},
			},
		} :: { Weapon },
		color = palette.SKY,
	},

	-- corsfig: a fighter, cheap and fragile, whose missiles hit only aircraft
	-- bar: corsfig
	bat = {
		name = "bat",
		display_name = "Bat",
		subtitle = "Seaplane fighter",
		kind = "unit",
		category = "aircraft",
		tech_level = TECH_LEVEL,
		-- no collision volume of its own, so its 2 x 2 footprint, 32 elmos a side
		collider = capsule(32, 32, 32),
		metal_cost = 90,
		energy_cost = 4600,
		buildpower_cost = 6500,
		health = 220,
		acceleration = studs_per_second_squared(0.2175),
		max_speed = studs(315.60001),
		footing = footing.ANYWHERE,
		-- `cruisealtitude` 140 and `turnradius` 64; `maxelevator` 0.01002 and `maxrudder` 0.00552, a circle of about
		-- 25 studs
		air = {
			altitude = altitude(140),
			climb_speed = 14, -- not bar's
			wings = { turn_rate = 1.17, run_out = run_out(64, 315.60001) }, -- derived: turn_rate
		},
		-- corsfig_weapon, whose damage to aircraft (`vtol`) is 200
		weapons = {
			{
				kind = "aa_missiles",
				damage = 200,
				reload = 0.83333,
				range = studs(710),
				energy_per_shot = 0,
				target_layer = "air",
				airborne_only = true,
				delivery = {
					kind = "straight",
					guidance = "homes",
					projectile = projectile({
						speed = studs(480),
						acceleration = studs(425),
						thrust_time = (900 - 480) / 425,
						aoe_radius = aoe(8),
						edge_effectiveness = 0.15,
						line_thickness = 0.2,
					}),
				},
			},
		} :: { Weapon },
		color = palette.VIOLET,
	},
}

return table.freeze(defs)
