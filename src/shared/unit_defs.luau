local ReplicatedStorage = game:GetService "ReplicatedStorage"

local types = require(ReplicatedStorage.Shared.types)
local config = require(ReplicatedStorage.Shared.config)
local heightmap = require(ReplicatedStorage.Shared.heightmap)

type EntityDef = types.EntityDef

-- Gameplay numbers are Beyond All Reason's, copied as they appear in its unit files so each one can
-- be checked against the source: units/CorBots/corak.lua (grunt), units/ArmBots/armck.lua
-- (constructor), units/ArmBuildings/LandFactories/armlab.lua (bot lab) and
-- units/ArmBuildings/LandEconomy/armsolar.lua (solar collector) and
-- units/ArmBuildings/LandEconomy/armmex.lua (metal extractor), units/armcom.lua (commander),
-- units/ArmBuildings/LandUtil/armnanotc.lua (construction turret),
-- units/ArmBuildings/LandDefenceOffence/armllt.lua (guard) and
-- units/ArmBuildings/LandEconomy/armestor.lua and armmstor.lua (the stores), and from Cortex
-- units/CorBuildings/LandFactories/corvp.lua (vehicle lab), units/CorVehicles/corgator.lua (incisor),
-- units/CorBuildings/LandDefenceOffence/corllt.lua (guard) and corhllt.lua (twin guard),
-- units/CorBots/corstorm.lua (aggravator), units/CorVehicles/corcv.lua (construction vehicle),
-- units/CorBots/cornecro.lua (graverobber), units/ArmBots/armwar.lua (centurion),
-- units/CorVehicles/cormist.lua (lasher), units/CorVehicles/corfav.lua (rascal),
-- units/CorVehicles/corwolv.lua (wolverine), units/CorVehicles/T2/cormart.lua (quaker),
-- units/CorBuildings/LandDefenceOffence/corpun.lua (agitator), units/ArmBots/armflea.lua (tick) and
-- units/CorBuildings/LandDefenceOffence/corhlt.lua (warden), units/CorBuildings/SeaFactories/corsy.lua (shipyard),
-- units/CorShips/coresupp.lua (supporter), units/CorShips/corcs.lua (construction ship) and
-- units/CorBuildings/LandDefenceOffence/corrl.lua (thistle), units/CorBots/corcrash.lua (trasher) and
-- units/CorBuildings/LandEconomy/cormakr.lua
-- and cormmkr.lua (the energy converters), whose blasts are in weapons/Unit_Explosions.lua, and
-- units/Scavengers/Buildings/Economy/corafust3.lua (epic fusion reactor) and cormmkrt3.lua (epic energy converter)
-- and units/CorBuildings/LandUtil/cornanotct2.lua (advanced construction turret) and, from Legion,
-- units/Legion/Ships/legnavydestro.lua (Syracusia) and units/CorBuildings/LandDefenceOffence/corbuzz.lua (Calamity) and
-- units/CorBuildings/LandUtil/corgate.lua (Overseer) and units/ArmBots/T2/armsnipe.lua (Sharpshooter) and
-- units/CorBots/T2/corhrk.lua (Arbiter) and units/CorBuildings/LandFactories/corgant.lua (Experimental Gantry).
--
-- BAR measures distance in elmos and acceleration per frame at 30 frames a second. One stud is 11
-- elmos because the Peewee's 22 elmo wide collision cylinder is a 2 stud wide capsule;
-- every length, speed and acceleration below goes through that one number.
local ELMOS_PER_STUD = 11
local FRAMES_PER_SECOND = 30

-- Buildings are sized in cells of the building grid, not in studs, so every one is a whole number of
-- cells across and fills the cells it stands on exactly.
local function cells(count: number): number
	return count * config.CELL_STUDS
end

local function studs(elmos: number): number
	return elmos / ELMOS_PER_STUD
end

-- BAR's blasts come out oversized here, so every weapon's area of effect is this fraction of its BAR radius.
local AOE_SCALE = 1 / 5

local function aoe(radius: number): number
	return radius * AOE_SCALE
end

-- A unit's collider, from its BAR collision volume in elmos: a capsule as tall as the volume and as wide
-- as its longer horizontal side, converted like everything else rather than rounded to whole studs.
local function capsule(width: number, height: number, length: number): types.CapsuleCollider
	return { shape = "capsule", radius = studs(math.max(width, length) / 2), height = studs(height) }
end

-- BAR's acceleration is elmos per frame per frame; this is studs per second per second.
local function studs_per_second_squared(elmos_per_frame_squared: number): number
	return studs(elmos_per_frame_squared * FRAMES_PER_SECOND * FRAMES_PER_SECOND)
end

-- Spring's map gravity, in elmos per second squared: what a weapon with no gravity of its own falls under.
local MAP_GRAVITY = 130

-- BAR's `accuracy` as the half angle, in radians, of the cone a shot may stray within: Spring reads it
-- as a fraction of 0xafff of a half turn.
local function accuracy(value: number): number
	return value * math.pi / 0xafff
end

-- Water depths follow BAR's movement classes, from gamedata/movedefs.lua, except that land units do not
-- wade at all here: they and buildings stand only on dry ground, commanders and other amphibious things
-- go anywhere (BAR's 5000 elmos), and a ship has a minimum depth from its own file and no maximum.

-- BAR's `buildtime` is the buildpower a thing costs, and a builder's `workertime` is the buildpower
-- it applies each second, so buildpower_cost / buildpower is the build time in seconds.

local defs: { [string]: EntityDef } = {
	bot_lab = {
		name = "bot_lab",
		display_name = "Bot Lab",
		kind = "building",
		collider = { shape = "box", width = cells(3), height = cells(2), length = cells(3) },
		metal_cost = 500,
		energy_cost = 950,
		buildpower_cost = 5000,
		health = 2900,
		buildpower = 150,
		acceleration = nil,
		max_speed = nil,
		reclaiming = false,
		repairing = false,
		resurrecting = false,
		assisting = false,
		max_water_depth = 0,
		build_options = { "constructor", "grunt", "tick", "aggravator", "graverobber", "centurion", "trasher" },
		weapon = nil,
		color = Color3.fromRGB(122, 134, 148),
	},
	advanced_bot_lab = {
		name = "advanced_bot_lab",
		display_name = "Advanced Bot Lab",
		kind = "building",
		collider = { shape = "box", width = cells(3), height = cells(2), length = cells(3) },
		metal_cost = 2600,
		energy_cost = 16000,
		buildpower_cost = 26000,
		health = 4500,
		buildpower = 600,
		acceleration = nil,
		max_speed = nil,
		reclaiming = false,
		repairing = false,
		resurrecting = false,
		assisting = false,
		max_water_depth = 0,
		build_options = { "advanced_constructor", "arbiter", "gunslinger", "sharpshooter", "sumo", "fatboy", "mammoth", "anti_nuke_prevailer" },
		weapon = nil,
		color = Color3.fromRGB(122, 134, 148),
	},
	advanced_vehicle_lab = {
		name = "advanced_vehicle_lab",
		display_name = "Advanced Vehicle Lab",
		kind = "building",
		collider = { shape = "box", width = cells(3), height = cells(2), length = cells(3) },
		metal_cost = 2600,
		energy_cost = 16000,
		buildpower_cost = 28000,
		health = 5100,
		buildpower = 600,
		metal_storage = 200,
		energy_storage = 200,
		acceleration = nil,
		max_speed = nil,
		reclaiming = false,
		repairing = false,
		resurrecting = false,
		assisting = false,
		max_water_depth = 0,
		weapon = nil,
		build_options = { "advanced_construction_vehicle", "quaker", "mantis" },
		color = Color3.fromRGB(122, 134, 148),
	},

	-- corgant, Cortex's Experimental Gantry: the lab for the third tier. Nothing of that tier exists here yet, so it has
	-- nothing to build until something is added to its list.
	experimental_gantry = {
		name = "experimental_gantry",
		display_name = "Experimental Gantry",
		kind = "building",
		-- 196 x 110 x 196 elmos, in whole grid cells
		collider = { shape = "box", width = cells(4), height = cells(3), length = cells(4) },
		metal_cost = 8400,
		energy_cost = 62000,
		buildpower_cost = 68000,
		health = 17800,
		buildpower = 1800,
		metal_storage = 800,
		energy_storage = 1400,
		acceleration = nil,
		max_speed = nil,
		reclaiming = false,
		repairing = false,
		resurrecting = false,
		assisting = false,
		max_water_depth = 0,
		build_options = {},
		weapon = nil,
		color = Color3.fromRGB(122, 134, 148),
	},

	solar_collector = {
		name = "solar_collector",
		display_name = "Solar Collector",
		kind = "building",
		-- armsolar's 50 x 76 x 50 elmo collision volume, in whole grid cells
		collider = { shape = "box", width = cells(2), height = cells(2), length = cells(2) },
		metal_cost = 155,
		energy_cost = 0,
		buildpower_cost = 2600,
		health = 340,
		buildpower = nil,
		acceleration = nil,
		max_speed = nil,
		reclaiming = false,
		repairing = false,
		resurrecting = false,
		assisting = false,
		max_water_depth = 0,
		build_options = nil,
		weapon = nil,
		energy_storage = 50,
		energy_income = 20,
		color = Color3.fromRGB(232, 200, 92),
	},
	advanced_solar_collector = {
		name = "advanced_solar_collector",
		display_name = "Advanced Solar Collector",
		kind = "building",
		collider = { shape = "box", width = cells(2), height = cells(2), length = cells(2) },
		metal_cost = 370,
		energy_cost = 4000,
		energy_storage = 100,
		buildpower_cost = 8150,
		health = 1200,
		buildpower = nil,
		acceleration = nil,
		max_speed = nil,
		reclaiming = false,
		repairing = false,
		resurrecting = false,
		assisting = false,
		max_water_depth = 0,
		build_options = nil,
		weapon = nil,
		energy_income = 80,
		color = Color3.fromRGB(232, 200, 92),
	},
	-- cormakr: turns 70 energy a second into a metal a second, and goes up with a bang when destroyed
	energy_converter = {
		name = "energy_converter",
		display_name = "Energy Converter",
		kind = "building",
		-- 32 x 25 x 32 elmos
		collider = { shape = "box", width = cells(1), height = cells(1), length = cells(1) },
		metal_cost = 1,
		energy_cost = 1250,
		buildpower_cost = 2680,
		health = 167,
		buildpower = nil,
		acceleration = nil,
		max_speed = nil,
		reclaiming = false,
		repairing = false,
		resurrecting = false,
		assisting = false,
		max_water_depth = 0,
		build_options = nil,
		weapon = nil,
		energy_conversion = { energy_per_second = 70, metal_per_second = 70 * 0.01429 },
		death_explosion = { radius = studs(50), damage = 400 },
		color = Color3.fromRGB(150, 160, 176),
	},
	-- cormmkr: converts 600 energy a second to about ten metal, with a much bigger bang
	advanced_energy_converter = {
		name = "advanced_energy_converter",
		display_name = "Advanced Energy Converter",
		kind = "building",
		-- 61 x 54 x 61 elmos
		collider = { shape = "box", width = cells(2), height = cells(2), length = cells(2) },
		metal_cost = 370,
		energy_cost = 21000,
		buildpower_cost = 31300,
		health = 560,
		buildpower = nil,
		acceleration = nil,
		max_speed = nil,
		reclaiming = false,
		repairing = false,
		resurrecting = false,
		assisting = false,
		max_water_depth = 0,
		build_options = nil,
		weapon = nil,
		energy_conversion = { energy_per_second = 600, metal_per_second = 600 * 0.01724 },
		death_explosion = { radius = studs(320), damage = 1220 },
		color = Color3.fromRGB(150, 160, 176),
	},
	fusion_reactor = {
		name = "fusion_reactor",
		display_name = "Fusion Reactor",
		kind = "building",
		collider = { shape = "box", width = cells(3), height = cells(3), length = cells(3) },
		metal_cost = 3600,
		energy_cost = 22000,
		buildpower_cost = 59000,
		health = 4300,
		buildpower = nil,
		acceleration = nil,
		max_speed = nil,
		reclaiming = false,
		repairing = false,
		resurrecting = false,
		assisting = false,
		max_water_depth = 0,
		build_options = nil,
		weapon = nil,
		energy_storage = 2500,
		energy_income = 850,
		color = Color3.fromRGB(232, 200, 92),
		death_explosion = { radius = 12, damage = 2000 },
	},
	advanced_fusion_reactor = {
		name = "advanced_fusion_reactor",
		display_name = "Advanced Fusion Reactor",
		kind = "building",
		collider = { shape = "box", width = cells(4), height = cells(4), length = cells(4) },
		metal_cost = 9700,
		energy_cost = 48000,
		buildpower_cost = 329200,
		death_explosion = { radius = 36, damage = 4000 },
		health = 9800,
		energy_income = 3000,
		energy_storage = 9000,
		buildpower = nil,
		acceleration = nil,
		max_speed = nil,
		reclaiming = false,
		repairing = false,
		resurrecting = false,
		assisting = false,
		max_water_depth = 0,
		build_options = nil,
		weapon = nil,
		color = Color3.fromRGB(232, 200, 92),
	},
	-- corafust3: the scavengers' fusion reactor. Its blast is ScavComBossExplo's, which is far wider than anything else's.
	epic_fusion_reactor = {
		name = "epic_fusion_reactor",
		display_name = "Epic Fusion Reactor",
		kind = "building",
		-- 188 x 192 x 188 elmos, in whole grid cells
		collider = { shape = "box", width = cells(5), height = cells(5), length = cells(5) },
		metal_cost = 90000,
		energy_cost = 550000,
		buildpower_cost = 2500000,
		death_explosion = { radius = studs(3000), damage = 16700 },
		health = 9400,
		energy_income = 30000,
		energy_storage = 90000,
		buildpower = nil,
		acceleration = nil,
		max_speed = nil,
		reclaiming = false,
		repairing = false,
		resurrecting = false,
		assisting = false,
		max_water_depth = 0,
		build_options = nil,
		weapon = nil,
		color = Color3.fromRGB(232, 200, 92),
	},
	-- cormmkrt3: converts 6000 energy a second to 120 metal, and goes up like a fusion reactor
	epic_energy_converter = {
		name = "epic_energy_converter",
		display_name = "Epic Energy Converter",
		kind = "building",
		-- 122 x 107 x 121 elmos
		collider = { shape = "box", width = cells(3), height = cells(3), length = cells(3) },
		metal_cost = 9000,
		energy_cost = 550000,
		buildpower_cost = 350000,
		health = 1500,
		buildpower = nil,
		acceleration = nil,
		max_speed = nil,
		reclaiming = false,
		repairing = false,
		resurrecting = false,
		assisting = false,
		max_water_depth = 0,
		build_options = nil,
		weapon = nil,
		energy_conversion = { energy_per_second = 6000, metal_per_second = 6000 * 0.02 },
		death_explosion = { radius = studs(480), damage = 2650 },
		color = Color3.fromRGB(150, 160, 176),
	},

	metal_extractor = {
		name = "metal_extractor",
		display_name = "Metal Extractor",
		kind = "building",
		-- armmex has a 48 x 33 x 48 elmo collision volume, in whole grid cells
		collider = { shape = "box", width = cells(1), height = cells(1), length = cells(1) },
		metal_cost = 50,
		energy_cost = 500,
		buildpower_cost = 1800,
		health = 270,
		buildpower = nil,
		acceleration = nil,
		max_speed = nil,
		reclaiming = false,
		repairing = false,
		resurrecting = false,
		assisting = false,
		-- the same extractor stands on dry land or on the sea floor, on whichever kind of spot it is built
		max_water_depth = studs(9999),
		build_options = nil,
		weapon = nil,
		-- extraction in BAR depends on the spot; this is what a plain extractor makes on an
		-- ordinary one
		metal_income = 1,
		requires_metal_spot = true,
		color = Color3.fromRGB(150, 160, 176),
	},
	advanced_metal_extractor = {
		name = "advanced_metal_extractor",
		display_name = "Advanced Metal Extractor",
		kind = "building",
		collider = { shape = "box", width = cells(1), height = cells(1), length = cells(1) },
		metal_cost = 620,
		energy_cost = 7700,
		buildpower_cost = 14900,
		health = 2800,
		buildpower = nil,
		acceleration = nil,
		max_speed = nil,
		reclaiming = false,
		repairing = false,
		resurrecting = false,
		assisting = false,
		max_water_depth = 0,
		build_options = nil,
		weapon = nil,
		metal_income = 7,
		requires_metal_spot = true,
		color = Color3.fromRGB(150, 160, 176),
	},

	commander = {
		name = "commander",
		slope_class = "COMMANDERBOT",
		weight_class = "heavy",
		display_name = "Commander",
		kind = "unit",
		-- 28 x 52 x 28 elmos
		collider = capsule(28, 52, 28),
		metal_cost = 2700,
		energy_cost = 26000,
		buildpower_cost = 75000,
		health = 3700,
		buildpower = 300,
		acceleration = studs_per_second_squared(0.18),
		max_speed = studs(37.5),
		reclaiming = true,
		repairing = true,
		resurrecting = false,
		assisting = true,
		max_water_depth = studs(5000),
		build_options = {
			"bot_lab",
			"vehicle_lab",
			"air_lab",
			"shipyard",
			"solar_collector",
			"metal_extractor",
			"energy_storage",
			"metal_storage",
			"energy_converter",
			"wind_turbine",
			"tidal_generator",
			"guard",
			"thistle",
		},
		-- armcomlaser
		weapon = {
			damage = 75,
			reload = 0.4,
			range = studs(300),
			energy_per_shot = 0,
			beam_time = 0.1,
		},
		-- the disintegrator: BAR gives it 99999 damage in a 36 elmo area, which kills anything it
		-- touches. Here it is a rectangle as long as its range, and that area is its half width.
		manual_weapon = {
			range = studs(250),
			reload = 0.9,
			energy_per_shot = 500,
			radius = studs(36),
		},
		-- armcom's own income and storage; a team with no commander has neither
		metal_income = 2,
		energy_income = 30,
		metal_storage = 500,
		energy_storage = 500,
		nametag = true,
		-- BAR's commander blast is defined in a weapon file this was not taken from, so these are chosen
		-- to be big: wide enough to take out a cluster of buildings and most of what stands near it
		death_explosion = { radius = 24, damage = 4000 },
		color = Color3.fromRGB(244, 226, 160),
	},

	-- A builder that cannot move or make anything. It takes assist, reclaim and repair orders for whatever is
	-- within reach, and with nothing to do it puts its buildpower into the nearest friendly blueprint.
	construction_turret = {
		name = "construction_turret",
		display_name = "Construction Turret",
		weight_class = "light",
		kind = "building",
		collider = { shape = "box", width = cells(1), height = cells(1), length = cells(1) },
		metal_cost = 230,
		energy_cost = 3200,
		buildpower_cost = 5300,
		health = 560,
		buildpower = 200,
		acceleration = nil,
		max_speed = nil,
		reclaiming = true,
		repairing = true,
		resurrecting = false,
		assisting = true,
		max_water_depth = 0,
		build_options = nil,
		weapon = nil,
		build_range = studs(400),
		color = Color3.fromRGB(226, 178, 74),
	},

	-- cornanotct2: the construction turret's advanced version
	advanced_construction_turret = {
		name = "advanced_construction_turret",
		display_name = "Advanced Construction Turret",
		kind = "building",
		-- 46 x 80 x 46 elmos, in whole grid cells
		collider = { shape = "box", width = cells(1), height = cells(2), length = cells(1) },
		metal_cost = 840,
		energy_cost = 12800,
		buildpower_cost = 21000,
		health = 2200,
		buildpower = 600,
		acceleration = nil,
		max_speed = nil,
		reclaiming = true,
		repairing = true,
		resurrecting = false,
		assisting = true,
		max_water_depth = 0,
		build_options = nil,
		weapon = nil,
		build_range = studs(500),
		color = Color3.fromRGB(226, 178, 74),
	},

	-- Not from BAR: the scavengers' beacon. Nobody builds it; it only ever appears through the scavengers
	-- gamemode, so it is in no build list. It is not reclaimable, so the only way to be rid of it is to
	-- destroy it, and what it leaves is worth half its metal to whoever does.
	scavenger_beacon = {
		name = "scavenger_beacon",
		display_name = "Scavenger Beacon",
		subtitle = "Summons scavengers",
		kind = "building",
		collider = { shape = "box", width = cells(3), height = cells(4), length = cells(3) },
		metal_cost = 1500,
		energy_cost = 0,
		buildpower_cost = 30000,
		health = 20000,
		buildpower = nil,
		acceleration = nil,
		max_speed = nil,
		reclaiming = false,
		repairing = false,
		resurrecting = false,
		assisting = false,
		max_water_depth = 0,
		build_options = nil,
		weapon = nil,
		reclaimable = false,
		color = Color3.fromRGB(150, 70, 200),
	},

	-- The same beacon for the sea: it floats, in water deep enough for the ships it makes, and it is the one that
	-- appears where there is water, as the land one appears where there is not.
	scavenger_sea_beacon = {
		name = "scavenger_sea_beacon",
		display_name = "Scavenger Beacon",
		subtitle = "Summons scavenger ships",
		kind = "building",
		collider = { shape = "box", width = cells(3), height = cells(4), length = cells(3) },
		metal_cost = 1500,
		energy_cost = 0,
		buildpower_cost = 30000,
		health = 20000,
		buildpower = nil,
		acceleration = nil,
		max_speed = nil,
		reclaiming = false,
		repairing = false,
		resurrecting = false,
		assisting = false,
		max_water_depth = studs(9999),
		min_water_depth = studs(12),
		build_options = nil,
		weapon = nil,
		reclaimable = false,
		color = Color3.fromRGB(150, 70, 200),
	},

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
		weapon = {
			damage = 75,
			reload = 0.46667,
			range = studs(435),
			energy_per_shot = 20,
			beam_time = 0.12,
		},
		color = Color3.fromRGB(198, 86, 72),
	},

	energy_storage = {
		name = "energy_storage",
		display_name = "Energy Storage",
		kind = "building",
		collider = { shape = "box", width = cells(1), height = cells(1), length = cells(1) },
		metal_cost = 170,
		energy_cost = 1700,
		buildpower_cost = 4110,
		health = 1890,
		buildpower = nil,
		acceleration = nil,
		max_speed = nil,
		reclaiming = false,
		repairing = false,
		resurrecting = false,
		assisting = false,
		max_water_depth = 0,
		build_options = nil,
		weapon = nil,
		energy_storage = 6000,
		color = Color3.fromRGB(232, 200, 92),
	},

	metal_storage = {
		name = "metal_storage",
		display_name = "Metal Storage",
		kind = "building",
		collider = { shape = "box", width = cells(2), height = cells(2), length = cells(2) },
		metal_cost = 330,
		energy_cost = 570,
		buildpower_cost = 2920,
		health = 2100,
		buildpower = nil,
		acceleration = nil,
		max_speed = nil,
		reclaiming = false,
		repairing = false,
		resurrecting = false,
		assisting = false,
		max_water_depth = 0,
		build_options = nil,
		weapon = nil,
		metal_storage = 3000,
		color = Color3.fromRGB(150, 160, 176),
	},

	-- corvp
	vehicle_lab = {
		name = "vehicle_lab",
		display_name = "Vehicle Lab",
		kind = "building",
		-- 96 x 40 x 96 elmos, in whole grid cells
		collider = { shape = "box", width = cells(3), height = cells(1), length = cells(3) },
		metal_cost = 570,
		energy_cost = 1550,
		buildpower_cost = 5650,
		health = 3000,
		buildpower = 150,
		acceleration = nil,
		max_speed = nil,
		reclaiming = false,
		repairing = false,
		resurrecting = false,
		assisting = false,
		max_water_depth = 0,
		build_options = { "incisor", "construction_vehicle", "lasher", "rascal", "wolverine" },
		weapon = nil,
		color = Color3.fromRGB(122, 134, 148),
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
		weapon = nil,
		turrets = {
			{
				weapon = { damage = 75, reload = 0.46667, range = studs(490), energy_per_shot = 15, beam_time = 0.12 },
				offset = Vector3.new(0, 3, 0),
			},
			{
				weapon = { damage = 75, reload = 0.46667, range = studs(400), energy_per_shot = 15, beam_time = 0.12 },
				offset = Vector3.new(0, 1, 0),
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
		weapon = {
			damage = 261,
			reload = 1.2,
			range = studs(620),
			energy_per_shot = 50,
			beam_time = 0.15,
			beam_thickness = 0.5,
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
		weapon = {
			damage = 115,
			reload = 1.7,
			range = studs(765),
			energy_per_shot = 0,
			anti_air = true,
			target_layer = "air",
			projectile = {
				speed = studs(400),
				acceleration = studs(150),
				thrust_time = 1.9,
				gravity = 12,
				drag = 1.5,
				aoe_radius = aoe(studs(48) / 3),
				leads = true,
			},
		},
		color = Color3.fromRGB(198, 86, 72),
	},

	-- corstorm, Cortex's rocket bot. Its rocket thrusts for two seconds, at a launch speed and
	-- acceleration taken from BAR, and after that falls; the drag and gravity are chosen, and its blast
	-- is a third of the area BAR gives it.
	aggravator = {
		name = "aggravator",
		slope_class = "BOT2",
		weight_class = "light",
		display_name = "Aggravator",
		subtitle = "Rocket bot",
		kind = "unit",
		-- 22 x 28 x 22 elmos
		collider = capsule(22, 28, 22),
		metal_cost = 110,
		energy_cost = 1150,
		buildpower_cost = 1950,
		health = 740,
		buildpower = nil,
		acceleration = studs_per_second_squared(0.1242),
		max_speed = studs(47.7),
		reclaiming = false,
		repairing = false,
		resurrecting = false,
		assisting = false,
		max_water_depth = 0,
		build_options = nil,
		weapon = {
			damage = 157,
			reload = 3.8,
			range = studs(475),
			energy_per_shot = 0,
			projectile = {
				speed = studs(190),
				acceleration = studs(120),
				thrust_time = 2,
				gravity = 12,
				drag = 1.5,
				aoe_radius = aoe(studs(48) / 3),
			},
		},
		color = Color3.fromRGB(196, 140, 84),
	},

	-- corcrash, Cortex's Trasher: a bot with a missile for aircraft and for nothing else, the same missile as the
	-- thistle's with its own numbers. BAR gives it a second weapon that does no damage and only helps it aim, which
	-- is left out. Its movement class is BAR's ABOT3, the amphibious bot: it climbs what the other bots do, and
	-- wades as the commander does.
	trasher = {
		name = "trasher",
		slope_class = "ABOT3",
		weight_class = "light",
		display_name = "Trasher",
		subtitle = "Anti air bot",
		kind = "unit",
		-- 30 x 32 x 30 elmos
		collider = capsule(30, 32, 30),
		metal_cost = 125,
		energy_cost = 1100,
		buildpower_cost = 1900,
		health = 640,
		buildpower = nil,
		acceleration = studs_per_second_squared(0.138),
		max_speed = studs(53.49),
		reclaiming = false,
		repairing = false,
		resurrecting = false,
		assisting = false,
		max_water_depth = studs(5000),
		build_options = nil,
		weapon = {
			damage = 110,
			reload = 2,
			range = studs(760),
			energy_per_shot = 0,
			anti_air = true,
			target_layer = "air",
			projectile = {
				speed = studs(650),
				acceleration = studs(141),
				thrust_time = 1.75,
				gravity = 12,
				drag = 1.5,
				aoe_radius = aoe(studs(48) / 3),
				leads = true,
			},
		},
		color = Color3.fromRGB(196, 140, 84),
	},

	-- cornecro. It can repair and reclaim and nothing else: it neither builds nor assists.
	graverobber = {
		name = "graverobber",
		slope_class = "BOT2",
		weight_class = "light",
		display_name = "Graverobber",
		subtitle = "Rezbot",
		kind = "unit",
		-- 28 x 34 x 28 elmos
		collider = capsule(28, 34, 28),
		metal_cost = 130,
		energy_cost = 1400,
		buildpower_cost = 2800,
		health = 220,
		buildpower = 200,
		acceleration = studs_per_second_squared(0.23),
		max_speed = studs(78),
		reclaiming = true,
		repairing = true,
		resurrecting = true,
		assisting = false,
		max_water_depth = 0,
		build_options = nil,
		weapon = nil,
		color = Color3.fromRGB(150, 176, 120),
	},

	-- armwar: a bot with a pair of short-range lasers, one on each side, that aim on their own
	centurion = {
		name = "centurion",
		slope_class = "BOT3",
		weight_class = "light",
		display_name = "Centurion",
		subtitle = "Anti swarm bot",
		kind = "unit",
		-- 30 x 32 x 30 elmos
		collider = capsule(30, 32, 30),
		metal_cost = 270,
		energy_cost = 3100,
		buildpower_cost = 4200,
		health = 1590,
		buildpower = nil,
		acceleration = studs_per_second_squared(0.0828),
		max_speed = studs(45),
		reclaiming = false,
		repairing = false,
		resurrecting = false,
		assisting = false,
		max_water_depth = 0,
		build_options = nil,
		weapon = nil,
		turrets = {
			{
				weapon = { damage = 55, reload = 0.3, range = studs(325), energy_per_shot = 0, beam_time = 0.12 },
				offset = Vector3.new(-0.7, 1, 0),
			},
			{
				weapon = { damage = 55, reload = 0.3, range = studs(325), energy_per_shot = 0, beam_time = 0.12 },
				offset = Vector3.new(0.7, 1, 0),
			},
		},
		color = Color3.fromRGB(120, 150, 196),
	},

	-- cormist: a truck that throws missiles, which fly the way the aggravator's rockets do
	-- it can also target aircraft
	lasher = {
		name = "lasher",
		slope_class = "TANK3",
		vehicle = true,
		weight_class = "light",
		display_name = "Lasher",
		subtitle = "Missile truck",
		kind = "unit",
		-- 32 x 31 x 43 elmos
		collider = capsule(32, 31, 43),
		metal_cost = 155,
		energy_cost = 2400,
		buildpower_cost = 3440,
		health = 860,
		buildpower = nil,
		acceleration = studs_per_second_squared(0.02208),
		max_speed = studs(52),
		reclaiming = false,
		repairing = false,
		resurrecting = false,
		assisting = false,
		max_water_depth = 0,
		build_options = nil,
		weapon = {
			damage = 63,
			reload = 2.5,
			range = studs(575),
			energy_per_shot = 0,
			anti_air = true,
			projectile = {
				speed = studs(350),
				acceleration = studs(110),
				thrust_time = 1.7,
				gravity = 12,
				drag = 1.5,
				aoe_radius = aoe(studs(48) / 3),
				leads = true,
			},
		},
		color = Color3.fromRGB(176, 122, 88),
	},

	-- corfav: a fast, fragile scout with a light laser
	rascal = {
		name = "rascal",
		slope_class = "TANK2",
		vehicle = true,
		weight_class = "light",
		display_name = "Rascal",
		subtitle = "Scout vehicle",
		kind = "unit",
		-- 16 x 16 x 26 elmos
		collider = capsule(16, 16, 26),
		metal_cost = 26,
		energy_cost = 270,
		buildpower_cost = 1150,
		health = 90,
		buildpower = nil,
		acceleration = studs_per_second_squared(0.2),
		max_speed = studs(153),
		reclaiming = false,
		repairing = false,
		resurrecting = false,
		assisting = false,
		max_water_depth = 0,
		build_options = nil,
		weapon = {
			damage = 35,
			reload = 1.1,
			range = studs(180),
			energy_per_shot = 0,
			beam_time = 0.18,
		},
		color = Color3.fromRGB(196, 96, 80),
	},

	-- corcv
	construction_vehicle = {
		name = "construction_vehicle",
		slope_class = "TANK3",
		vehicle = true,
		weight_class = "light",
		display_name = "Construction Vehicle",
		subtitle = "Builder vehicle",
		kind = "unit",
		-- 35 x 32 x 49 elmos
		collider = capsule(35, 32, 49),
		metal_cost = 145,
		energy_cost = 2100,
		buildpower_cost = 4160,
		health = 1430,
		buildpower = 95,
		acceleration = studs_per_second_squared(0.03049),
		max_speed = studs(51),
		reclaiming = true,
		repairing = true,
		resurrecting = false,
		assisting = true,
		max_water_depth = 0,
		build_options = {
			"bot_lab",
			"vehicle_lab",
			"advanced_vehicle_lab",
			"air_lab",
			"shipyard",
			"solar_collector",
			"advanced_solar_collector",
			"metal_extractor",
			"energy_storage",
			"metal_storage",
			"energy_converter",
			"wind_turbine",
			"tidal_generator",
			"construction_turret",
			"guard",
			"thistle",
			"twin_guard",
			"warden",
			"agitator",
		},
		weapon = nil,
		color = Color3.fromRGB(226, 178, 74),
	},

	-- corgator, Cortex's light laser tank
	incisor = {
		name = "incisor",
		slope_class = "TANK2",
		vehicle = true,
		weight_class = "light",
		display_name = "Incisor",
		subtitle = "Laser tank",
		kind = "unit",
		-- 23 x 24 x 33 elmos
		collider = capsule(23, 24, 33),
		metal_cost = 120,
		energy_cost = 1100,
		buildpower_cost = 2300,
		health = 820,
		buildpower = nil,
		acceleration = studs_per_second_squared(0.04631),
		max_speed = studs(85),
		reclaiming = false,
		repairing = false,
		resurrecting = false,
		assisting = false,
		max_water_depth = 0,
		build_options = nil,
		weapon = {
			damage = 75,
			reload = 0.8,
			range = studs(230),
			energy_per_shot = 0,
			beam_time = 0.1,
		},
		color = Color3.fromRGB(176, 122, 88),
	},

	constructor = {
		name = "constructor",
		slope_class = "BOT2",
		weight_class = "light",
		display_name = "Constructor",
		subtitle = "Builder bot",
		kind = "unit",
		-- armck: 27 x 30 x 27 elmos
		collider = capsule(27, 30, 27),
		metal_cost = 110,
		energy_cost = 1600,
		buildpower_cost = 3450,
		health = 760,
		buildpower = 80,
		acceleration = studs_per_second_squared(0.552),
		max_speed = studs(36),
		reclaiming = true,
		repairing = true,
		resurrecting = false,
		assisting = true,
		max_water_depth = 0,
		build_options = {
			"bot_lab",
			"advanced_bot_lab",
			"vehicle_lab",
			"air_lab",
			"shipyard",
			"solar_collector",
			"advanced_solar_collector",
			"metal_extractor",
			"energy_storage",
			"metal_storage",
			"energy_converter",
			"wind_turbine",
			"tidal_generator",
			"construction_turret",
			"guard",
			"thistle",
			"twin_guard",
			"warden",
			"agitator",
		},
		weapon = nil,
		color = Color3.fromRGB(226, 178, 74),
	},
	advanced_constructor = {
		name = "advanced_constructor",
		slope_class = "BOT2",
		display_name = "Advanced Constructor",
		weight_class = "light",
		kind = "unit",
		collider = capsule(28, 42, 30),
		metal_cost = 470,
		energy_cost = 6900,
		energy_make = 14,
		energy_storage = 100,
		buildpower_cost = 12500,
		health = 1000,
		buildpower = 220,
		acceleration = studs_per_second_squared(0.4692),
		max_speed = studs(33),
		reclaiming = true,
		repairing = true,
		resurrecting = false,
		assisting = true,
		max_water_depth = 0,
		build_options = {
			"bot_lab",
			"advanced_bot_lab",
			"advanced_metal_extractor",
			"advanced_energy_converter",
			"scorpion",
			"pulsar",
			"persecutor",
			"catalyst",
			"apocalypse",
			"overseer",
			"calamity",
			"fusion_reactor",
			"advanced_fusion_reactor",
			"epic_fusion_reactor",
			"experimental_gantry",
			"epic_energy_converter",
			"advanced_construction_turret",
		},
		color = Color3.fromRGB(226, 178, 74),
	},
	advanced_construction_vehicle = {
		name = "advanced_construction_vehicle",
		slope_class = "TANK3",
		vehicle = true,
		display_name = "Advanced Construction Vehicle",
		kind = "unit",
		collider = capsule(36, 36, 47),
		metal_cost = 580,
		energy_cost = 7000,
		buildpower_cost = 17000,
		health = 2150,
		buildpower = 310,
		acceleration = studs_per_second_squared(0.02547),
		max_speed = studs(49.5),
		reclaiming = true,
		repairing = true,
		resurrecting = false,
		assisting = true,
		max_water_depth = 0,
		build_options = {
			"vehicle_lab",
			"advanced_vehicle_lab",
			"advanced_metal_extractor",
			"advanced_energy_converter",
			"scorpion",
			"pulsar",
			"persecutor",
			"catalyst",
			"apocalypse",
			"overseer",
			"calamity",
			"fusion_reactor",
			"advanced_fusion_reactor",
			"epic_fusion_reactor",
			"experimental_gantry",
			"epic_energy_converter",
			"advanced_construction_turret",
		},
		color = Color3.fromRGB(226, 178, 74),
	},
	-- corwolv: a light artillery tank. It lobs a shell high over anything in the way at targets it cannot
	-- see, and the shell is slow enough that a fast target may be gone from where it lands.
	wolverine = {
		name = "wolverine",
		slope_class = "TANK3",
		vehicle = true,
		display_name = "Wolverine",
		subtitle = "Light artillery tank",
		kind = "unit",
		-- 28 x 22 x 38 elmos
		collider = capsule(28, 22, 38),
		metal_cost = 170,
		energy_cost = 2500,
		buildpower_cost = 3550,
		health = 750,
		buildpower = nil,
		acceleration = studs_per_second_squared(0.02293),
		max_speed = studs(48),
		reclaiming = false,
		repairing = false,
		resurrecting = false,
		assisting = false,
		max_water_depth = 0,
		build_options = nil,
		weapon = {
			damage = 300,
			reload = 7.1,
			range = studs(710),
			energy_per_shot = 0,
			projectile = {
				speed = studs(580),
				acceleration = 0,
				thrust_time = 0,
				gravity = studs_per_second_squared(0.276),
				drag = 0,
				aoe_radius = aoe(studs(113)),
				edge_effectiveness = 0.15,
				arc = "high",
				plasma = true,
				inaccuracy = accuracy(275),
			},
		},
		color = Color3.fromRGB(196, 96, 80),
	},
	-- cormart: a heavier artillery tank whose shells hit harder and burst wider than the Wolverine's. BAR
	-- has it fire along the low arc; it is set to the high one here.
	-- legvcarry: a drone carrier. It has no gun of its own; it keeps two drones on its back and sends them at
	-- whatever comes within a thousand elmos. Its movement class is BAR's HTANK4.
	mantis = {
		name = "mantis",
		slope_class = "HTANK4",
		vehicle = true,
		display_name = "Mantis",
		subtitle = "Drone carrier",
		kind = "unit",
		-- 55 x 37 x 67 elmos
		collider = capsule(55, 37, 67),
		metal_cost = 450,
		energy_cost = 9000,
		buildpower_cost = 11550,
		health = 1400,
		buildpower = nil,
		acceleration = studs_per_second_squared(0.02),
		max_speed = studs(45),
		reclaiming = false,
		repairing = false,
		resurrecting = false,
		assisting = false,
		max_water_depth = studs(12),
		build_options = nil,
		weapon = nil,
		carrier = {
			drone = "drone",
			count = 2,
			engage_range = studs(1000),
			respawn_seconds = 10,
			repair_per_second = 30,
		},
		color = Color3.fromRGB(120, 150, 196),
	},
	-- legdrone: what a Mantis carries. It is quick and hard to hit, and its laser is weak but not nothing. A Mantis
	-- keeps only two, so each has three times BAR's health and one and a half times its damage: the pair is as
	-- tough as BAR's six but does half the damage, which is what it takes to keep them from being too much. Nothing
	-- builds it: its carrier makes it. BAR's two-shot burst is one shot of twice the damage there.
	drone = {
		name = "drone",
		display_name = "Drone",
		subtitle = "Combat drone",
		kind = "unit",
		drone = true,
		-- 20 x 20 x 20 elmos, its footprint being one
		collider = capsule(20, 20, 20),
		metal_cost = 15,
		energy_cost = 500,
		buildpower_cost = 1000,
		health = 500,
		buildpower = nil,
		acceleration = studs_per_second_squared(0.35),
		max_speed = studs(280.5),
		reclaiming = false,
		repairing = false,
		resurrecting = false,
		assisting = false,
		max_water_depth = studs(9999),
		build_options = nil,
		air = { altitude = 7, climb_speed = 20 },
		weapon = {
			damage = 36,
			reload = 0.9,
			range = studs(300),
			energy_per_shot = 0,
			beam_time = 0.1,
		},
		color = Color3.fromRGB(226, 226, 120),
	},
	quaker = {
		name = "quaker",
		slope_class = "TANK3",
		vehicle = true,
		display_name = "Quaker",
		subtitle = "Mobile artillery",
		kind = "unit",
		-- 38 x 24 x 41 elmos
		collider = capsule(38, 24, 41),
		metal_cost = 400,
		energy_cost = 4400,
		buildpower_cost = 9000,
		health = 1200,
		buildpower = nil,
		acceleration = studs_per_second_squared(0.03),
		max_speed = studs(58),
		reclaiming = false,
		repairing = false,
		resurrecting = false,
		assisting = false,
		max_water_depth = 0,
		build_options = nil,
		weapon = {
			damage = 420,
			reload = 5,
			range = studs(800),
			energy_per_shot = 0,
			projectile = {
				speed = studs(349),
				acceleration = 0,
				thrust_time = 0,
				gravity = studs(MAP_GRAVITY),
				drag = 0,
				aoe_radius = aoe(studs(144)),
				edge_effectiveness = 0.65,
				arc = "high",
				plasma = true,
				inaccuracy = accuracy(640),
			},
		},
		color = Color3.fromRGB(120, 150, 196),
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
		weapon = {
			damage = 350,
			reload = 3.16667,
			range = studs(1245),
			energy_per_shot = 0,
			projectile = {
				speed = studs(600),
				acceleration = 0,
				thrust_time = 0,
				gravity = studs_per_second_squared(0.289),
				drag = 0,
				aoe_radius = aoe(studs(120)),
				edge_effectiveness = 0.4,
				arc = "auto",
				plasma = true,
				inaccuracy = accuracy(75),
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
		weapon = {
			damage = 420,
			reload = 2.1,
			range = studs(1390),
			energy_per_shot = 0,
			projectile = {
				speed = studs(450),
				acceleration = 0,
				thrust_time = 0,
				gravity = studs(MAP_GRAVITY),
				drag = 0,
				aoe_radius = aoe(studs(164)),
				edge_effectiveness = 0.4,
				arc = "auto",
				plasma = true,
				inaccuracy = accuracy(450),
			},
		},
		color = Color3.fromRGB(198, 86, 72),
	},
	-- corhrk, Cortex's Arbiter: a heavy rocket bot. BAR's rocket climbs steeply and comes down on its target from
	-- above; here it flies as the missile launchers' do, straight up, over to the target and down onto it, so nothing
	-- in the way stops it. The climb and dive are chosen: BAR does not give them.
	arbiter = {
		name = "arbiter",
		slope_class = "BOT3",
		weight_class = "light",
		display_name = "Arbiter",
		subtitle = "Heavy rocket bot",
		kind = "unit",
		-- 26 x 31 x 33 elmos
		collider = capsule(26, 31, 33),
		metal_cost = 600,
		energy_cost = 5800,
		buildpower_cost = 9500,
		health = 610,
		buildpower = nil,
		acceleration = studs_per_second_squared(0.1265),
		max_speed = studs(54),
		reclaiming = false,
		repairing = false,
		resurrecting = false,
		assisting = false,
		max_water_depth = 0,
		build_options = nil,
		weapon = {
			damage = 800,
			reload = 8,
			range = studs(1210),
			energy_per_shot = 0,
			projectile = {
				speed = studs(800),
				acceleration = 0,
				thrust_time = 0,
				gravity = 0,
				drag = 0,
				aoe_radius = aoe(studs(70)),
				edge_effectiveness = 0.61,
				missile = { climb = 40, dive_angle = math.rad(60) },
			},
		},
		color = Color3.fromRGB(196, 140, 84),
	},
	-- armsnipe, Armada's Sharpshooter: a sniper bot. BAR fires a cannon shell at 3000 elmos a second, which at the
	-- range it shoots from is over in a fraction of a second, so it is a beam here, striking the first solid thing
	-- on its line the instant it fires. It hits very hard, reloads very slowly and pays energy for every shot. BAR
	-- also lets it cloak, which is left out.
	sharpshooter = {
		name = "sharpshooter",
		slope_class = "BOT2",
		weight_class = "light",
		display_name = "Sharpshooter",
		subtitle = "Sniper bot",
		kind = "unit",
		-- 30 x 44 x 30 elmos
		collider = capsule(30, 44, 30),
		metal_cost = 680,
		energy_cost = 20000,
		buildpower_cost = 24000,
		health = 580,
		buildpower = nil,
		acceleration = studs_per_second_squared(0.138),
		max_speed = studs(33),
		reclaiming = false,
		repairing = false,
		resurrecting = false,
		assisting = false,
		max_water_depth = 0,
		build_options = nil,
		weapon = {
			damage = 2500,
			reload = 10,
			range = studs(900),
			energy_per_shot = 500,
			beam_time = 0.2,
			beam_thickness = 0.12,
			beam_color = Color3.fromRGB(255, 255, 0),
		},
		color = Color3.fromRGB(120, 150, 196),
	},
	-- armmav: a bot with a rifle whose shells fly fast and flat, and which mends itself. Everything here is BAR's. The
	-- shell falls under gravity and is aimed along the low arc that lands it on its target, so like any low
	-- shot it needs a clear line, and a friend in the way stops it.
	gunslinger = {
		name = "gunslinger",
		slope_class = "BOT3",
		display_name = "Gunslinger",
		subtitle = "Solo leveling bot",
		kind = "unit",
		-- 36 x 48 x 36 elmos
		collider = capsule(36, 48, 36),
		metal_cost = 650,
		energy_cost = 11000,
		buildpower_cost = 17000,
		health = 1800,
		autoheal = 50,
		buildpower = nil,
		acceleration = studs_per_second_squared(0.138),
		max_speed = studs(50),
		reclaiming = false,
		repairing = false,
		resurrecting = false,
		assisting = false,
		max_water_depth = 0,
		build_options = nil,
		weapon = {
			damage = 265,
			reload = 1,
			range = studs(365),
			energy_per_shot = 0,
			projectile = {
				plasma = true,
				speed = studs(600),
				acceleration = 0,
				thrust_time = 0,
				gravity = studs(MAP_GRAVITY),
				drag = 0,
				aoe_radius = aoe(studs(24)),
				edge_effectiveness = 0.15,
				arc = "low",
			},
		},
		color = Color3.fromRGB(120, 150, 196),
	},
	sumo = {
		name = "sumo",
		slope_class = "HBOT4",
		display_name = "Sumo",
		subtitle = "Armored assault bot",
		kind = "unit",
		collider = capsule(32, 34, 30),
		metal_cost = 560,
		energy_cost = 9300,
		buildpower_cost = 12000,
		health = 6000,
		buildpower = nil,
		acceleration = studs_per_second_squared(0.138),
		max_speed = studs(38),
		reclaiming = false,
		repairing = false,
		resurrecting = false,
		assisting = false,
		max_water_depth = 0,
		build_options = nil,
		weapon = {
			damage = 275,
			reload = 0.8,
			range = studs(275),
			energy_per_shot = 45,
			beam_time = 0.3,
			beam_thickness = 0.7,
		},
		color = Color3.fromRGB(226, 178, 74),
	},
	-- corsumo: the heaviest bot there is, with a laser that is the Sumo's and then some. Everything here is BAR's.
	mammoth = {
		name = "mammoth",
		slope_class = "HBOT4",
		display_name = "Mammoth",
		subtitle = "Heavy assault bot",
		weight_class = "heavy",
		kind = "unit",
		-- 38 x 34 x 36 elmos
		collider = capsule(60, 60, 60),
		metal_cost = 2200,
		energy_cost = 35000,
		buildpower_cost = 65000,
		health = 15600,
		buildpower = nil,
		acceleration = studs_per_second_squared(0.0552),
		max_speed = studs(23),
		reclaiming = false,
		repairing = false,
		resurrecting = false,
		assisting = false,
		max_water_depth = 0,
		build_options = nil,
		weapon = {
			damage = 302,
			reload = 0.6,
			range = studs(650),
			energy_per_shot = 75,
			beam_time = 0.19,
			beam_thickness = 0.8,
		},
		color = Color3.fromRGB(226, 178, 74),
	},
	fatboy = {
		name = "fatboy",
		slope_class = "HBOT4",
		display_name = "Fatboy",
		subtitle = "Heavy Plasma Bot",
		weight_class = "heavy",
		kind = "unit",
		collider = capsule(60, 60, 60),
		metal_cost = 1400,
		energy_cost = 20000,
		buildpower_cost = 32000,
		health = 7800,
		buildpower = nil,
		acceleration = studs_per_second_squared(0.0138),
		max_speed = studs(30),
		reclaiming = false,
		repairing = false,
		resurrecting = false,
		assisting = false,
		max_water_depth = 0,
		build_options = nil,
		weapon = {
			damage = 800,
			reload = 7,
			range = studs(700),
			energy_per_shot = 0,
			projectile = {
				plasma = true,
				speed = studs(600),
				acceleration = 0,
				thrust_time = 0,
				gravity = studs(MAP_GRAVITY),
				drag = 0,
				aoe_radius = aoe(studs(300)),
				edge_effectiveness = 0.15,
				arc = "medium",
			},
		},
		color = Color3.fromRGB(226, 178, 74),
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
		weapon = {
			damage = 825,
			reload = 2,
			range = studs(730),
			energy_per_shot = 0,
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
		weapon = {
			damage = 10800,
			reload = 9.9,
			range = studs(1400),
			energy_per_shot = 0,
			beam_time = 1.5,
			beam_thickness = 2,
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
		weapon = {
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
		weapon = {
			damage = 15000,
			reload = 30,
			-- as far as anything on the map, the whole of it
			range = studs(20000),
			energy_per_shot = 0,
			-- same here, each missile costs 2x metal than BAR
			stockpile = { limit = 10, build_time = 180, metal = 3000, energy = 187500 },
			projectile = {
				speed = studs(500),
				acceleration = 0,
				thrust_time = 0,
				gravity = 0,
				drag = 0,
				aoe_radius = aoe(studs(1920)),
				edge_effectiveness = 0.1,
				missile = { climb = 300, dive_angle = math.rad(80) },
			},
		},
		color = Color3.fromRGB(198, 86, 72),
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
		weapon = {
			damage = 2000,
			reload = 0.75,
			range = studs(6100),
			energy_per_shot = 18000,
			projectile = {
				speed = studs(950),
				acceleration = 0,
				thrust_time = 0,
				gravity = studs(MAP_GRAVITY),
				drag = 0,
				aoe_radius = aoe(studs(157)),
				edge_effectiveness = 0.15,
				arc = "auto",
				plasma = true,
				inaccuracy = accuracy(750),
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
		weapon = nil,
		shield = {
			radius = studs(550),
			power = 6175,
			regen = 130,
			regen_energy = 562.5,
			starting_power = 2090,
		},
		color = Color3.fromRGB(96, 170, 214),
	},

	grunt = {
		name = "grunt",
		slope_class = "BOT2",
		weight_class = "light",
		display_name = "Grunt",
		subtitle = "Fast infantry bot",
		kind = "unit",
		-- corak: 24 x 32 x 24 elmos
		collider = capsule(24, 32, 24),
		metal_cost = 43,
		energy_cost = 820,
		buildpower_cost = 1250,
		health = 280,
		buildpower = nil,
		acceleration = studs_per_second_squared(0.4),
		max_speed = studs(81),
		reclaiming = false,
		repairing = false,
		resurrecting = false,
		assisting = false,
		max_water_depth = 0,
		build_options = nil,
		weapon = {
			damage = 37,
			reload = 0.5,
			range = studs(215),
			energy_per_shot = 0,
			beam_time = 0.1,
		},
		color = Color3.fromRGB(198, 86, 72),
	},
	-- armflea: a tiny, quick scout bot with a short-range laser
	tick = {
		name = "tick",
		slope_class = "SBOT2",
		weight_class = "light",
		display_name = "Tick",
		subtitle = "Scout bot",
		kind = "unit",
		-- 20 x 12 x 20 elmos
		collider = capsule(20, 12, 20),
		metal_cost = 21,
		energy_cost = 300,
		buildpower_cost = 800,
		health = 60,
		buildpower = nil,
		acceleration = studs_per_second_squared(0.575),
		max_speed = studs(132),
		reclaiming = false,
		repairing = false,
		resurrecting = false,
		assisting = false,
		max_water_depth = 0,
		build_options = nil,
		weapon = {
			damage = 24,
			reload = 0.6,
			range = studs(140),
			energy_per_shot = 0,
			beam_time = 0.1,
		},
		color = Color3.fromRGB(150, 176, 120),
	},
	-- corsy: a factory that has to stand in water deep enough for its ships to float out of it
	shipyard = {
		name = "shipyard",
		display_name = "Shipyard",
		subtitle = "Ship factory",
		kind = "building",
		-- 96 x 59 x 96 elmos
		collider = { shape = "box", width = cells(2), height = cells(2), length = cells(2) },
		metal_cost = 450,
		energy_cost = 950,
		buildpower_cost = 5100,
		health = 4300,
		buildpower = 150,
		acceleration = nil,
		max_speed = nil,
		reclaiming = false,
		repairing = false,
		resurrecting = false,
		assisting = false,
		max_water_depth = studs(9999),
		min_water_depth = studs(30),
		build_options = { "construction_ship", "supporter", "riptide", "syracusia" },
		weapon = nil,
		color = Color3.fromRGB(122, 134, 148),
	},
	-- coresupp: a light gunboat with a laser at each end, each aiming on its own
	supporter = {
		name = "supporter",
		display_name = "Supporter",
		subtitle = "Light gun boat",
		kind = "unit",
		-- 20 x 16 x 40 elmos
		collider = capsule(20, 16, 40),
		metal_cost = 100,
		energy_cost = 1000,
		buildpower_cost = 1400,
		health = 480,
		buildpower = nil,
		acceleration = studs_per_second_squared(0.11054),
		max_speed = studs(109.8),
		reclaiming = false,
		repairing = false,
		resurrecting = false,
		assisting = false,
		max_water_depth = studs(9999),
		min_water_depth = studs(4),
		build_options = nil,
		weapon = nil,
		turrets = {
			{
				weapon = { damage = 41, reload = 0.93, range = studs(280), energy_per_shot = 0, beam_time = 0.16 },
				offset = Vector3.new(0, 1, 1.4),
			},
			{
				weapon = { damage = 41, reload = 0.93, range = studs(280), energy_per_shot = 0, beam_time = 0.16 },
				offset = Vector3.new(0, 1, -1.4),
			},
		},
		color = Color3.fromRGB(198, 86, 72),
	},
	-- corpship: a gunboat with a single light cannon. Its shell falls under gravity and is aimed along the low arc,
	-- so it needs a clear line to its target, and a friend in the way stops it. Everything here is BAR's.
	riptide = {
		name = "riptide",
		display_name = "Riptide",
		subtitle = "Gun ship",
		kind = "unit",
		-- 25 x 24 x 71 elmos
		collider = capsule(25, 24, 71),
		metal_cost = 420,
		energy_cost = 2800,
		buildpower_cost = 4550,
		health = 2350,
		buildpower = nil,
		acceleration = studs_per_second_squared(0.04391),
		max_speed = studs(82.5),
		reclaiming = false,
		repairing = false,
		resurrecting = false,
		assisting = false,
		max_water_depth = studs(9999),
		min_water_depth = studs(6),
		build_options = nil,
		weapon = {
			damage = 96,
			reload = 0.8,
			range = studs(480),
			energy_per_shot = 0,
			projectile = {
				speed = studs(340),
				acceleration = 0,
				thrust_time = 0,
				gravity = studs(MAP_GRAVITY),
				drag = 0,
				aoe_radius = aoe(studs(48)),
				edge_effectiveness = 0.15,
				arc = "low",
				plasma = true,
			},
		},
		color = Color3.fromRGB(120, 150, 196),
	},
	-- legnavydestro, Legion's Syracusia: a destroyer with an orange heat ray, which needs energy to fire, and a drone
	-- carrier. BAR gives it two drones; this game gives it one, to keep the count of things down, and makes up for it
	-- by making that one drone tougher and harder hitting than either of BAR's. The heat ray's area of effect is left
	-- out, as a beam has none here.
	syracusia = {
		name = "syracusia",
		display_name = "Syracusia",
		subtitle = "Destroyer with drones",
		kind = "unit",
		-- 35 x 50 x 86 elmos
		collider = capsule(35, 50, 86),
		metal_cost = 875,
		energy_cost = 9500,
		buildpower_cost = 11500,
		health = 3800,
		buildpower = nil,
		acceleration = studs_per_second_squared(0.02757),
		max_speed = studs(58),
		reclaiming = false,
		repairing = false,
		resurrecting = false,
		assisting = false,
		max_water_depth = studs(9999),
		min_water_depth = studs(12),
		build_options = nil,
		weapon = {
			damage = 410,
			reload = 2.4,
			range = studs(700),
			energy_per_shot = 17,
			beam_time = 0.8,
			beam_thickness = 0.35,
			beam_color = Color3.fromRGB(255, 128, 0),
		},
		carrier = {
			drone = "drone",
			count = 1,
			engage_range = studs(1000),
			respawn_seconds = 8,
			repair_per_second = 30,
		},
		color = Color3.fromRGB(196, 140, 84),
	},

	-- corcs: builds on the water. It makes a shipyard, and a metal extractor on the sea floor.
	construction_ship = {
		name = "construction_ship",
		display_name = "Construction Ship",
		subtitle = "Builder ship",
		kind = "unit",
		-- 30 x 26 x 47 elmos
		collider = capsule(30, 26, 47),
		metal_cost = 200,
		energy_cost = 2000,
		buildpower_cost = 3700,
		health = 1080,
		buildpower = 125,
		acceleration = studs_per_second_squared(0.03567),
		max_speed = studs(60),
		reclaiming = true,
		repairing = true,
		resurrecting = false,
		assisting = true,
		max_water_depth = studs(9999),
		min_water_depth = studs(15),
		build_options = { "shipyard", "metal_extractor", "tidal_generator" },
		weapon = nil,
		color = Color3.fromRGB(226, 178, 74),
	},
	-- armtide: it stands in the water and makes energy from the tide. BAR gives it 25 a second; here it is a
	-- flat 15 for now.
	tidal_generator = {
		name = "tidal_generator",
		display_name = "Tidal Generator",
		kind = "building",
		-- 37 x 26 x 39 elmos
		collider = { shape = "box", width = cells(1), height = studs(26), length = cells(1) },
		metal_cost = 90,
		energy_cost = 200,
		buildpower_cost = 2190,
		health = 400,
		buildpower = nil,
		acceleration = nil,
		max_speed = nil,
		reclaiming = false,
		repairing = false,
		resurrecting = false,
		assisting = false,
		max_water_depth = studs(9999),
		min_water_depth = studs(20),
		build_options = nil,
		weapon = nil,
		energy_storage = 50,
		energy_income = 15,
		color = Color3.fromRGB(96, 170, 214),
	},
	wind_turbine = {
		name = "wind_turbine",
		display_name = "Wind Turbine",
		kind = "building",
		collider = { shape = "box", width = cells(1), height = cells(2), length = cells(1) },
		metal_cost = 40,
		energy_cost = 175,
		buildpower_cost = 1600,
		health = 196,
		buildpower = nil,
		acceleration = nil,
		max_speed = nil,
		reclaiming = false,
		repairing = false,
		resurrecting = false,
		assisting = false,
		max_water_depth = 0,
		build_options = nil,
		weapon = nil,
		-- it makes as much energy a second as the wind speed, for now with nothing scaling it
		wind_multiplier = 1,
		color = Color3.fromRGB(122, 134, 148),
	},

	-- Aircraft. Unlike everything above, none of these numbers is copied from a BAR unit file: they are
	-- chosen, in BAR's units and with BAR's proportions, so that a fighter outruns a bomber and a bomber
	-- outruns a transport, and are the ones to replace when the real ones are looked up.
	air_lab = {
		name = "air_lab",
		display_name = "Air Lab",
		subtitle = "Aircraft factory",
		kind = "building",
		collider = { shape = "box", width = cells(3), height = cells(1), length = cells(3) },
		metal_cost = 630,
		energy_cost = 1100,
		buildpower_cost = 5380,
		health = 2150,
		buildpower = 150,
		acceleration = nil,
		max_speed = nil,
		reclaiming = false,
		repairing = false,
		resurrecting = false,
		assisting = false,
		max_water_depth = 0,
		build_options = { "construction_aircraft", "valiant", "whirlwind", "hercules", "hephaestus" },
		weapon = nil,
		color = Color3.fromRGB(122, 134, 148),
	},
	-- a builder that flies: it goes where it is sent over anything in the way, so it reaches sites that a
	-- vehicle or a bot cannot, and stays up while it has work to do. It builds what the Construction Vehicle does.
	construction_aircraft = {
		name = "construction_aircraft",
		display_name = "Construction Aircraft",
		subtitle = "Builder aircraft",
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
			"shipyard",
			"solar_collector",
			"advanced_solar_collector",
			"metal_extractor",
			"energy_storage",
			"metal_storage",
			"energy_converter",
			"wind_turbine",
			"tidal_generator",
			"construction_turret",
			"guard",
			"thistle",
			"twin_guard",
			"warden",
			"agitator",
		},
		weapon = nil,
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
		air = { altitude = 26, climb_speed = 14 },
		weapon = {
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
				gravity = 12,
				drag = 1.5,
				aoe_radius = aoe(studs(10)),
				leads = true,
			},
		},
		color = Color3.fromRGB(196, 96, 80),
	},
	-- a bomber: it flies over what it attacks and drops bombs as it goes, then comes round again. A bomb
	-- falls where it is let go, so it has to be over its target, and it can only hit what is on the ground.
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
		air = { altitude = 24, climb_speed = 12, bombing_runs = true },
		-- divergence from BAR - bomber drops 1 bomb only, but has more radius and damage
		weapon = {
			damage = 350,
			reload = 2,
			burst_count = 2,
			range = 4,
			energy_per_shot = 0,
			target_layer = "ground",
			projectile = {
				speed = 0,
				acceleration = 0,
				thrust_time = 0,
				gravity = 40,
				drag = 0,
				aoe_radius = aoe(studs(350)),
				edge_effectiveness = 0.4,
				dropped = true,
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
		weapon = nil,
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
		weapon = nil,
		air = { altitude = 22, climb_speed = 8 },
		transport = { capacity = 1, carries = "heavy" },
		color = Color3.fromRGB(226, 178, 74),
	},
	-- anti-missile defense bot with homing projectiles to intercept nuclear strikes
	anti_nuke_prevailer = {
		name = "anti_nuke_prevailer",
		display_name = "Anti-Nuke Prevailer",
		subtitle = "Anti-missile defense bot",
		kind = "unit",
		-- 32 x 42 x 32 elmos
		collider = capsule(32, 42, 32),
		metal_cost = 1200,
		energy_cost = 8500,
		buildpower_cost = 12000,
		health = 1500,
		buildpower = nil,
		acceleration = studs_per_second_squared(0.15),
		max_speed = studs(65),
		reclaiming = false,
		repairing = false,
		resurrecting = false,
		assisting = false,
		max_water_depth = 0,
		build_options = nil,
		weapon = {
			damage = 800,
			reload = 1.5,
			range = studs(1200),
			energy_per_shot = 50,
			anti_air = true,
			target_layer = "air",
			projectile = {
				speed = studs(900),
				acceleration = studs(300),
				thrust_time = 3,
				gravity = 0,
				drag = 0,
				aoe_radius = aoe(studs(100)),
				homing = true,
			},
		},
		color = Color3.fromRGB(255, 215, 0),
	},
}

-- A carrier that is missing something only fails once its drones are up and running, with an error about a nil
-- somewhere else, so every one is checked here, when the defs load, and the error names the unit and the field.
local CARRIER_FIELDS = { "count", "engage_range", "respawn_seconds", "repair_per_second" }

for def_name, def in defs do
	local carrier = def.carrier
	if carrier == nil then
		continue
	end
	local drone_def = defs[carrier.drone]
	assert(drone_def ~= nil, `"{def_name}" carries "{carrier.drone}", which is not a def`)
	assert(drone_def.drone == true, `"{def_name}" carries "{carrier.drone}", which is not marked drone = true`)
	for _, field in CARRIER_FIELDS do
		assert(
			typeof((carrier :: any)[field]) == "number",
			`"{def_name}".carrier.{field} must be a number, but it is {typeof((carrier :: any)[field])}`
		)
	end
end

local function get(def_name: string): EntityDef
	local def = defs[def_name]
	assert(def ~= nil, `unknown entity def "{def_name}"`)
	return def
end

-- The footprint a collider occupies on the ground, as a half-extent on each axis. Capsules are
-- treated as their bounding square so that occupancy tests can share one code path with boxes.
-- A building occupies whole cells of the building grid, so its footprint is its collider rounded up
-- to a multiple of the cell size, and neighbours pack edge to edge with no slivers between them.
local function grid_span(length: number): number
	return math.ceil(length / config.CELL_STUDS) * config.CELL_STUDS
end

-- The longest range anything on `def` can shoot, or nil if it cannot shoot at all.
local function attack_range(def: EntityDef): number?
	local longest: number? = nil
	if def.weapon ~= nil then
		longest = def.weapon.range
	end
	if def.turrets ~= nil then
		for _, turret in def.turrets do
			if longest == nil or turret.weapon.range > longest then
				longest = turret.weapon.range
			end
		end
	end
	return longest
end

-- The range to draw round something: how far it shoots, or for a drone carrier how far out its drones go to
-- fight, which is a range like a weapon's. Unlike `attack_range` it does not make the carrier armed: it has
-- nothing to aim, so it cannot be ordered to attack.
local function display_range(def: EntityDef): number?
	local range = attack_range(def)
	if range == nil and def.carrier ~= nil then
		return def.carrier.engage_range
	end
	return range
end

-- Whether something can be given orders at all: every unit can, and so can a building that works,
-- like a construction turret, which just cannot move, or one with a weapon, which can be told what to shoot.
local function takes_orders(def: EntityDef): boolean
	if def.kind == "unit" then
		return true
	end
	if attack_range(def) ~= nil then
		return true
	end
	return def.buildpower ~= nil and (def.assisting or def.reclaiming or def.repairing)
end

-- Whether `def` is a building that makes units, a lab or a shipyard. It cannot be given orders, but it
-- takes move orders as a rally point for what it makes.
local function is_factory(def: EntityDef): boolean
	if def.kind ~= "building" or def.build_options == nil then
		return false
	end
	for _, name in def.build_options do
		local option = defs[name]
		if option ~= nil and option.kind == "unit" then
			return true
		end
	end
	return false
end

-- Whether `def` may stand where the water is between `shallowest` and `deepest` studs deep, which is
-- how it is under a footprint: a unit needs the deepest ground it touches to be within its limit, and a
-- ship needs even the shallowest to be deep enough.
local function tolerates_water(def: EntityDef, shallowest: number, deepest: number): boolean
	return deepest <= def.max_water_depth and shallowest >= (def.min_water_depth or 0)
end

-- Whether it floats on the water's surface rather than standing on the ground under it.
local function floats(def: EntityDef): boolean
	return def.min_water_depth ~= nil
end

-- The height its underside rests at at (x, z): the ground under it, or for something that floats, the
-- water's surface where that is higher, so a ship or a shipyard sits on the sea while a building
-- that is built underwater stands on the sea floor.
local function surface_height(def: EntityDef, x: number, z: number): number
	local ground = heightmap.height_at(x, z)
	if floats(def) then
		return math.max(ground, config.WATER_LEVEL)
	end
	return ground
end

-- The point at (x, z) that something of this def rests at: `surface_height` there. Waypoints for a ship
-- lie on the water and not on the sea floor beneath it.
local function surface_position(def: EntityDef, x: number, z: number): Vector3
	return Vector3.new(x, surface_height(def, x, z), z)
end

local function is_air(def: EntityDef): boolean
	return def.air ~= nil
end

-- What `amount` of a weapon's damage comes to against something of `target`. An aircraft shrugs off
-- anything that is not a dedicated anti air weapon, taking only a fraction of the damage.
local function damage_against(anti_air: boolean, target: EntityDef, amount: number): number
	if is_air(target) and anti_air == false then
		return amount * config.NON_AA_AIR_DAMAGE_FRACTION
	end
	return amount
end

-- Whether a transport of `carrier` can pick up something of `cargo`, unit or static defence: the cargo has a
-- weight class, and a light transport takes only light cargo while a heavy one takes light and heavy.
local function can_carry(carrier: EntityDef, cargo: EntityDef): boolean
	local carrying = carrier.transport
	local weight = cargo.weight_class
	if carrying == nil or weight == nil then
		return false
	end
	return weight == "light" or carrying.carries == "heavy"
end

local function footprint_half_extents(def: EntityDef): Vector2
	local collider = def.collider
	if collider.shape == "box" then
		return Vector2.new(grid_span(collider.width) / 2, grid_span(collider.length) / 2)
	end
	return Vector2.new(collider.radius, collider.radius)
end

local function collider_height(def: EntityDef): number
	local collider = def.collider
	if collider.shape == "box" then
		return collider.height
	end
	return collider.height
end

-- Horizontal radius used for separation, range checks and click picking.
local function collider_radius(def: EntityDef): number
	local collider = def.collider
	if collider.shape == "box" then
		return math.max(collider.width, collider.length) / 2
	end
	return collider.radius
end

-- How many of a transport's slots something takes up
local function transport_slots(def: EntityDef): number
	-- return math.max(1, math.ceil(collider_radius(def) / config.TRANSPORT_SLOT_RADIUS))
	return 1
end

return table.freeze({
	defs = defs,
	get = get,
	footprint_half_extents = footprint_half_extents,
	takes_orders = takes_orders,
	is_factory = is_factory,
	tolerates_water = tolerates_water,
	floats = floats,
	surface_height = surface_height,
	surface_position = surface_position,
	is_air = is_air,
	damage_against = damage_against,
	can_carry = can_carry,
	transport_slots = transport_slots,
	attack_range = attack_range,
	display_range = display_range,
	collider_height = collider_height,
	collider_radius = collider_radius,
})
