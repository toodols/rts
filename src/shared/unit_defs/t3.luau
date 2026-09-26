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

type EntityDef = types.EntityDef
type Weapon = types.Weapon

-- The third tier, the units the Experimental Gantry makes.
local defs: { [string]: EntityDef } = {
	-- corkorg, Cortex's Juggernaut: an enormous walker with three weapons, a heat ray that burns through anything, a
	-- gauss cannon and a rocket rack, and a reactor of its own. It walks along the sea floor as the commander does, as
	-- BAR's VBOT6 lets it. BAR's cannon throws ten shells at once in a spread; here they go out as a burst so quick it
	-- is nearly the same thing, each strayed within BAR's spray. Its kicks and stomps are left out. The rocket's climb
	-- and dive are the Arbiter's.
	-- bar: corkorg
	juggernaut = {
		name = "juggernaut",
		footing = footing.moves "VBOT6",
		display_name = "Juggernaut",
		subtitle = "Experimental assault bot",
		kind = "unit",
		category = "experimental",
		tech_level = 3,
		-- 97 x 160 x 85 elmos
		collider = capsule(97, 160, 85),
		metal_cost = 29000,
		energy_cost = 615000,
		buildpower_cost = 730000,
		health = 149000,
		self_destruct_countdown = 10,
		energy_income = 300,
		energy_storage = 5000,
		acceleration = studs_per_second_squared(0.1242),
		max_speed = studs(37),
		-- corkorg's `paralyzemultiplier` 0
		emp_resistance = 1,
		weapons = {
			{
				kind = "heat_ray",
				damage = 5500,
				reload = 4,
				range = studs(900),
				turret = { turn_rate = math.rad(90) },
				energy_per_shot = 1200,
				delivery = {
					kind = "beam",
					time = 0.6,
					thickness = 2,
				},
			},
			{
				kind = "plasma_cannon",
				damage = 165,
				reload = 1.4,
				burst_count = 10,
				burst_interval = 0.03,
				range = studs(590),
				energy_per_shot = 0,
				offset = Vector3.new(0, 8, 4),
				delivery = {
					kind = "lobbed",
					arc = "low",
					projectile = projectile({
						speed = shell_speed(studs(900)),
						gravity = shell_gravity(studs(MAP_GRAVITY)),
						aoe_radius = aoe(112),
						edge_effectiveness = 0.65,
						inaccuracy = accuracy(2750),
					}),
				},
			},
			{
				kind = "missiles",
				damage = 800,
				reload = 6,
				range = studs(950),
				energy_per_shot = 0,
				target_layer = "ground",
				offset = Vector3.new(0, 12, -2),
				delivery = missile(
					"short",
					projectile({
						speed = studs(2600),
						aoe_radius = aoe(200),
						edge_effectiveness = 0.85,
					})
				),
			},
		} :: { Weapon },
		color = palette.BRICK,
	},

	-- armvang, Armada's Vanguard: a slow all-terrain walker that climbs any slope, though it keeps out of water, and
	-- lobs heavy plasma shells from very far. BAR has it choose between a low and a high trajectory; here it picks for
	-- itself each shot, as the Agitator does. Everything here is BAR's.
	-- bar: armvang
	vanguard = {
		name = "vanguard",
		footing = footing.moves "HTBOT6",
		display_name = "Vanguard",
		subtitle = "All-terrain heavy plasma cannon",
		kind = "unit",
		category = "experimental",
		tech_level = 3,
		-- 65 x 60 x 65 elmos
		collider = capsule(65, 60, 65),
		metal_cost = 3300,
		energy_cost = 71000,
		buildpower_cost = 120000,
		health = 8500,
		acceleration = studs_per_second_squared(0.02645),
		max_speed = studs(33),
		weapons = {
			{
				kind = "plasma_cannon",
				damage = 1265,
				reload = 8,
				range = studs(1450),
				turret = { turn_rate = math.rad(90) },
				energy_per_shot = 0,
				delivery = {
					kind = "lobbed",
					arc = "auto",
					projectile = projectile({
						speed = shell_speed(studs(500)),
						gravity = shell_gravity(studs(MAP_GRAVITY)),
						aoe_radius = aoe(192),
						edge_effectiveness = 0.65,
					}),
				},
			},
		} :: { Weapon },
		color = palette.STEEL_BLUE,
	},

	-- corshiva, Cortex's Shiva: an amphibious siege walker that wades along the sea floor as the commander does, as
	-- BAR's HABOT5 lets it. It has a heavy plasma cannon and one rocket launcher, whose rocket flies as the Arbiter's
	-- does, straight up, over and down, with the Arbiter's climb and dive. Everything else here is BAR's.
	-- bar: corshiva
	shiva = {
		name = "shiva",
		footing = footing.moves "HABOT5",
		display_name = "Shiva",
		subtitle = "Amphibious siege mech",
		kind = "unit",
		category = "experimental",
		tech_level = 3,
		-- 61 x 60 x 61 elmos
		collider = capsule(61, 60, 61),
		metal_cost = 1600,
		energy_cost = 23000,
		buildpower_cost = 40000,
		health = 9400,
		acceleration = studs_per_second_squared(0.069),
		max_speed = studs(48),
		weapons = {
			{
				kind = "plasma_cannon",
				damage = 600,
				reload = 2,
				range = studs(650),
				turret = { turn_rate = math.rad(90) },
				energy_per_shot = 0,
				delivery = {
					kind = "lobbed",
					arc = "low",
					projectile = projectile({
						speed = shell_speed(studs(310)),
						gravity = shell_gravity(studs(MAP_GRAVITY)),
						aoe_radius = aoe(176),
						edge_effectiveness = 0.15,
					}),
				},
			},
			{
				kind = "missiles",
				damage = 750,
				reload = 7,
				range = studs(800),
				energy_per_shot = 0,
				target_layer = "ground",
				offset = Vector3.new(0, 4, -1),
				delivery = missile(
					"short",
					projectile({
						speed = studs(800),
						aoe_radius = aoe(60),
						edge_effectiveness = 0.65,
					})
				),
			},
		} :: { Weapon },
		color = palette.OLIVE,
	},

	-- armthor, Armada's Thor: an enormous tank with a lightning cannon, two EMP lasers and an EMP missile.
	-- - The cannon throws ten bolts in a burst, charged once for the burst as Spring charges a salvo. Each bolt's sparks
	--   jump to up to five things within 125 elmos for a quarter of its damage, as BAR's lightning gadget has them. The
	--   spark reach is left at its size in studs and is not shrunk as blasts are.
	-- - The EMP lasers sit one on either flank. BAR aims each along one side (`maindir` -1 0 0 and 1 0 0) within 90
	--   degrees of it (`maxangledif` 180).
	-- - The missile is BAR's `commandfire` stockpile of two, one every 65 seconds for its 100 metal and 5000 energy. It is
	--   launched only at what a launch order (D) names, as the nuclear silo's is. It flies as the Arbiter's does, with the
	--   Arbiter's climb and dive.
	-- - The turret turns at kinematic_turret_1.h's 3 degrees a frame.
	-- Everything else here is BAR's.
	-- bar: armthor
	thor = {
		name = "thor",
		footing = footing.moves "HTANK7",
		display_name = "Thor",
		subtitle = "Experimental lightning tank",
		kind = "unit",
		category = "experimental",
		tech_level = 3,
		-- 58 x 34 x 58 elmos
		collider = capsule(58, 34, 58),
		metal_cost = 9000,
		energy_cost = 240000,
		buildpower_cost = 320000,
		health = 56000,
		acceleration = studs_per_second_squared(0.015),
		max_speed = studs(54),
		-- armthor's `paralyzemultiplier` 0
		emp_resistance = 1,
		weapons = {
			-- thunder
			{
				kind = "lightning",
				damage = 300,
				reload = 3.1,
				burst_count = 10,
				burst_interval = 0.03333,
				range = studs(540),
				turret = { turn_rate = math.rad(90) },
				energy_per_shot = 350,
				target_layer = "ground",
				delivery = {
					kind = "beam",
					lightning = { forks = 5, range = studs(125), fork_damage = 0.25 },
				},
			},
			-- empmissile
			{
				kind = "emp_missile",
				damage = 80000,
				reload = 3,
				range = studs(1050),
				energy_per_shot = 0,
				target_layer = "ground",
				paralyze_time = 12,
				stockpile = { limit = 2, build_time = 65, metal = 100, energy = 5000 },
				manual_fire = true,
				offset = Vector3.new(0, 0, -1.5),
				delivery = missile(
					"short",
					projectile({
						speed = studs(500),
						aoe_radius = aoe(196),
						edge_effectiveness = 1,
						look = { explosion = "emp" },
					})
				),
			},
			-- emp, on each flank
			{
				kind = "emp_laser",
				damage = 300,
				reload = 0.25,
				range = studs(350),
				energy_per_shot = 15,
				paralyze_time = 8,
				fire_arc = math.rad(90),
				fire_direction = math.rad(-90),
				offset = Vector3.new(-1.6, -0.55, 0),
				delivery = {
					kind = "beam",
					time = 0.25,
					color = Color3.new(0.7, 0.7, 1),
				},
			},
			{
				kind = "emp_laser",
				damage = 300,
				reload = 0.25,
				range = studs(350),
				energy_per_shot = 15,
				paralyze_time = 8,
				fire_arc = math.rad(90),
				fire_direction = math.rad(90),
				offset = Vector3.new(1.6, -0.55, 0),
				delivery = {
					kind = "beam",
					time = 0.25,
					color = Color3.new(0.7, 0.7, 1),
				},
			},
		} :: { Weapon },
		color = Color3.fromRGB(110, 140, 210),
	},

	-- corjugg, Cortex's Behemoth: a four-legged walking fortress, slow, with more health than anything else that moves.
	-- - Its gauss cannon is BAR's DGun weapon. The ball is `noexplode`, so it goes through whatever it strikes, going off
	--   inside it every frame it spends there, and flies on until it comes down. Nothing close in survives it for long.
	--   BAR has it fall under the map's gravity, so here it is fired on the low arc a shell takes.
	-- - Two lasers low on its front each fire within 45 degrees of their own line (`maindir` -1 0 4 and 1 0 4,
	--   `maxangledif` 90), and one on its back fires all round.
	-- - Its footsteps are a weapon in BAR that does no damage, and are left out.
	-- - The turret turns at BAR's 90 degrees a second.
	-- Everything else here is BAR's.
	-- bar: corjugg
	behemoth = {
		name = "behemoth",
		footing = footing.moves "HBOT7",
		display_name = "Behemoth",
		subtitle = "Experimental heavy assault bot",
		kind = "unit",
		category = "experimental",
		tech_level = 3,
		-- 90 x 80 x 90 elmos
		collider = capsule(90, 80, 90),
		metal_cost = 20000,
		energy_cost = 513000,
		buildpower_cost = 780000,
		health = 335000,
		acceleration = studs_per_second_squared(0.0552),
		max_speed = studs(16.5),
		-- corjugg's `paralyzemultiplier` 0
		emp_resistance = 1,
		weapons = {
			-- juggernaut_fire
			{
				kind = "gauss",
				damage = 1200,
				reload = 4,
				range = studs(590),
				turret = { turn_rate = math.rad(90) },
				energy_per_shot = 0,
				delivery = {
					kind = "lobbed",
					arc = "low",
					projectile = projectile({
						speed = shell_speed(studs(520)),
						gravity = shell_gravity(studs(MAP_GRAVITY)),
						aoe_radius = aoe(65),
						edge_effectiveness = 0.15,
						look = {
							size = Vector3.new(1.2, 1.2, 1.2),
							color = Color3.new(1, 0.8, 0.17),
							material = Enum.Material.Neon,
							light = { color = Color3.new(1, 0.8, 0.17), range = 12, brightness = 2 },
						},
					}),
				},
			},
			-- juggernaut_bottom, left and right
			{
				kind = "laser",
				damage = 75,
				reload = 0.3,
				range = studs(435),
				energy_per_shot = 15,
				target_layer = "ground",
				fire_arc = math.rad(45),
				fire_direction = -math.atan2(1, 4),
				offset = Vector3.new(-1.1, -0.7, 3.2),
				delivery = {
					kind = "beam",
					time = 0.08,
					color = Color3.new(1, 0, 0),
				},
			},
			{
				kind = "laser",
				damage = 75,
				reload = 0.3,
				range = studs(435),
				energy_per_shot = 15,
				target_layer = "ground",
				fire_arc = math.rad(45),
				fire_direction = math.atan2(1, 4),
				offset = Vector3.new(1.1, -0.7, 3.2),
				delivery = {
					kind = "beam",
					time = 0.08,
					color = Color3.new(1, 0, 0),
				},
			},
			-- juggernaut_top
			{
				kind = "laser",
				damage = 150,
				reload = 0.46667,
				range = studs(550),
				energy_per_shot = 30,
				offset = Vector3.new(0, 3.2, -0.3),
				delivery = {
					kind = "beam",
					time = 0.15,
					color = Color3.new(1, 0, 0),
				},
			},
		} :: { Weapon },
		color = Color3.fromRGB(186, 110, 64),
	},
}

return table.freeze(defs)
