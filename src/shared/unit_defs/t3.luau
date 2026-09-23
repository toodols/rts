local ReplicatedStorage = game:GetService "ReplicatedStorage"

local types = require(ReplicatedStorage.Shared.types)

local conversions = require(script.Parent.conversions)

local studs = conversions.studs
local aoe = conversions.aoe
local capsule = conversions.capsule
local studs_per_second_squared = conversions.studs_per_second_squared
local MAP_GRAVITY = conversions.MAP_GRAVITY
local accuracy = conversions.accuracy
local shell_speed = conversions.shell_speed
local shell_gravity = conversions.shell_gravity

type EntityDef = types.EntityDef

-- The third tier, the units the Experimental Gantry makes.
local defs: { [string]: EntityDef } = {
	-- corkorg, Cortex's Juggernaut: an enormous walker with three weapons, a heat ray that burns through anything, a
	-- gauss cannon and a rocket rack, and a reactor of its own. It walks along the sea floor as the commander does, as
	-- BAR's VBOT6 lets it. BAR's cannon throws ten shells at once in a spread; here they go out as a burst so quick it
	-- is nearly the same thing, each strayed within BAR's spray. Its kicks and stomps are left out. The rocket's climb
	-- and dive are the Arbiter's.
	juggernaut = {
		name = "juggernaut",
		slope_class = "VBOT6",
		display_name = "Juggernaut",
		subtitle = "Experimental assault bot",
		kind = "unit",
		-- 97 x 160 x 85 elmos
		collider = capsule(97, 160, 85),
		metal_cost = 29000,
		energy_cost = 615000,
		buildpower_cost = 730000,
		health = 149000,
		energy_income = 300,
		energy_storage = 5000,
		buildpower = nil,
		acceleration = studs_per_second_squared(0.1242),
		max_speed = studs(37),
		reclaiming = false,
		repairing = false,
		resurrecting = false,
		assisting = false,
		max_water_depth = studs(5000),
		build_options = nil,
		weapons = {
			{
				damage = 5500,
				reload = 4,
				range = studs(900),
				turret = { turn_rate = math.rad(90) },
				energy_per_shot = 1200,
				offset = Vector3.new(0, 10, 3),
				beam_time = 0.6,
				beam_thickness = 2,
			},
			{
				damage = 165,
				reload = 1.4,
				burst_count = 10,
				burst_interval = 0.03,
				range = studs(590),
				energy_per_shot = 0,
				offset = Vector3.new(0, 8, 4),
				projectile = {
					speed = shell_speed(studs(900)),
					acceleration = 0,
					thrust_time = 0,
					gravity = shell_gravity(studs(MAP_GRAVITY)),
					drag = 0,
					aoe_radius = aoe(studs(112)),
					edge_effectiveness = 0.65,
					arc = "low",
					plasma = true,
					inaccuracy = accuracy(2750),
				},
			},
			{
				damage = 800,
				reload = 6,
				range = studs(950),
				energy_per_shot = 0,
				target_layer = "ground",
				offset = Vector3.new(0, 12, -2),
				projectile = {
					speed = studs(2600),
					acceleration = 0,
					thrust_time = 0,
					gravity = 0,
					drag = 0,
					aoe_radius = aoe(studs(200)),
					edge_effectiveness = 0.85,
					missile = { climb = 40, dive_angle = math.rad(60) },
				},
			},
		},
		color = Color3.fromRGB(198, 86, 72),
	},

	-- armvang, Armada's Vanguard: a slow all-terrain walker that climbs any slope, though it keeps out of water, and
	-- lobs heavy plasma shells from very far. BAR has it choose between a low and a high trajectory; here it picks for
	-- itself each shot, as the Agitator does. Everything here is BAR's.
	vanguard = {
		name = "vanguard",
		slope_class = "HTBOT6",
		display_name = "Vanguard",
		subtitle = "All-terrain heavy plasma cannon",
		kind = "unit",
		-- 65 x 60 x 65 elmos
		collider = capsule(65, 60, 65),
		metal_cost = 3300,
		energy_cost = 71000,
		buildpower_cost = 120000,
		health = 8500,
		buildpower = nil,
		acceleration = studs_per_second_squared(0.02645),
		max_speed = studs(33),
		reclaiming = false,
		repairing = false,
		resurrecting = false,
		assisting = false,
		max_water_depth = 0,
		build_options = nil,
		weapons = {
			{
				damage = 1265,
				reload = 8,
				range = studs(1450),
				turret = { turn_rate = math.rad(90) },
				energy_per_shot = 0,
				projectile = {
					speed = shell_speed(studs(500)),
					acceleration = 0,
					thrust_time = 0,
					gravity = shell_gravity(studs(MAP_GRAVITY)),
					drag = 0,
					aoe_radius = aoe(studs(192)),
					edge_effectiveness = 0.65,
					arc = "auto",
					plasma = true,
				},
			},
		},
		color = Color3.fromRGB(120, 150, 196),
	},

	-- corshiva, Cortex's Shiva: an amphibious siege walker that wades along the sea floor as the commander does, as
	-- BAR's HABOT5 lets it. It has a heavy plasma cannon and one rocket launcher, whose rocket flies as the Arbiter's
	-- does, straight up, over and down, with the Arbiter's climb and dive. Everything else here is BAR's.
	shiva = {
		name = "shiva",
		slope_class = "HABOT5",
		display_name = "Shiva",
		subtitle = "Amphibious siege mech",
		kind = "unit",
		-- 61 x 60 x 61 elmos
		collider = capsule(61, 60, 61),
		metal_cost = 1600,
		energy_cost = 23000,
		buildpower_cost = 40000,
		health = 9400,
		buildpower = nil,
		acceleration = studs_per_second_squared(0.069),
		max_speed = studs(48),
		reclaiming = false,
		repairing = false,
		resurrecting = false,
		assisting = false,
		max_water_depth = studs(5000),
		build_options = nil,
		weapons = {
			{
				damage = 600,
				reload = 2,
				range = studs(650),
				turret = { turn_rate = math.rad(90) },
				energy_per_shot = 0,
				offset = Vector3.new(0, 3, 2),
				projectile = {
					speed = shell_speed(studs(310)),
					acceleration = 0,
					thrust_time = 0,
					gravity = shell_gravity(studs(MAP_GRAVITY)),
					drag = 0,
					aoe_radius = aoe(studs(176)),
					edge_effectiveness = 0.15,
					arc = "low",
					plasma = true,
				},
			},
			{
				damage = 750,
				reload = 7,
				range = studs(800),
				energy_per_shot = 0,
				target_layer = "ground",
				offset = Vector3.new(0, 4, -1),
				projectile = {
					speed = studs(800),
					acceleration = 0,
					thrust_time = 0,
					gravity = 0,
					drag = 0,
					aoe_radius = aoe(studs(60)),
					edge_effectiveness = 0.65,
					missile = { climb = 40, dive_angle = math.rad(60) },
				},
			},
		},
		color = Color3.fromRGB(150, 176, 120),
	},
}

return table.freeze(defs)
