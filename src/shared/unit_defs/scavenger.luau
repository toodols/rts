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

-- What only the scavengers field. Nothing builds these, so none is in anyone's build options or in the roster the
-- beacons make from (server/scavengers.luau); the beacons themselves are buildings, in building.luau.
local defs: { [string]: EntityDef } = {
	-- The end of a game against the scavengers: it comes when every beacon is down, or when the game's progress runs
	-- out, and killing it wins. Not from BAR. It is the Juggernaut grown half as big again, slower, and with twice the
	-- health before the difficulty multiplies it, and its weapons hit harder and reach further. It walks the sea floor as
	-- the Juggernaut does, so there is no island it cannot get to.
	scavenger_boss = {
		name = "scavenger_boss",
		slope_class = "VBOT6",
		display_name = "Scavenger Overlord",
		subtitle = "The scavengers' last stand",
		kind = "unit",
		collider = capsule(145, 240, 128),
		metal_cost = 60000,
		energy_cost = 1200000,
		buildpower_cost = 1500000,
		health = 300000,
		energy_income = nil,
		energy_storage = nil,
		buildpower = nil,
		acceleration = studs_per_second_squared(0.1),
		max_speed = studs(30),
		reclaiming = false,
		repairing = false,
		resurrecting = false,
		assisting = false,
		max_water_depth = studs(5000),
		build_options = nil,
		weapons = {
			-- the heat ray
			{
				damage = 8000,
				reload = 4,
				range = studs(1000),
				turret = { turn_rate = math.rad(90) },
				energy_per_shot = 0,
				offset = Vector3.new(0, 15, 4),
				beam_time = 0.6,
				beam_thickness = 3,
			},
			-- the plasma cannon
			{
				damage = 220,
				reload = 1.4,
				burst_count = 14,
				burst_interval = 0.03,
				range = studs(700),
				energy_per_shot = 0,
				offset = Vector3.new(0, 12, 6),
				projectile = {
					speed = shell_speed(studs(1000)),
					acceleration = 0,
					thrust_time = 0,
					gravity = shell_gravity(studs(MAP_GRAVITY)),
					drag = 0,
					aoe_radius = aoe(studs(130)),
					edge_effectiveness = 0.65,
					arc = "low",
					plasma = true,
					inaccuracy = accuracy(2750),
				},
			},
			-- the rocket rack
			{
				damage = 1200,
				reload = 5,
				range = studs(1100),
				energy_per_shot = 0,
				target_layer = "ground",
				offset = Vector3.new(0, 18, -3),
				projectile = {
					speed = studs(2600),
					acceleration = 0,
					thrust_time = 0,
					gravity = 0,
					drag = 0,
					aoe_radius = aoe(studs(220)),
					edge_effectiveness = 0.85,
					missile = { climb = 40, dive_angle = math.rad(60) },
				},
			},
		},
		color = Color3.fromRGB(160, 84, 214),
	},
}

return table.freeze(defs)
