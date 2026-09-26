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

type EntityDef = types.EntityDef
type Weapon = types.Weapon

-- Not from BAR: the scavengers' beacon, called `name`, standing on `stands`. Nobody builds it; it only ever appears
-- through the scavengers gamemode, so it is in no build list. It is not reclaimable, so the only way to be rid of it is
-- to destroy it, and what it leaves is worth half its metal to whoever does.
local function beacon(name: string, subtitle: string, stands: types.Footing): EntityDef
	return {
		name = name,
		role = "beacon",
		display_name = "Scavenger Beacon",
		subtitle = subtitle,
		kind = "building",
		category = "scavengers",
		collider = { shape = "box", width = cells(3), height = cells(4), length = cells(3) },
		metal_cost = 1500,
		energy_cost = 0,
		buildpower_cost = 30000,
		health = 2000,
		footing = stands,
		reclaim_while_standing = false,
		color = palette.VIOLET,
	}
end

-- What only the scavengers field: their boss and the beacons that summon them. Nothing builds these, so none is in
-- anyone's build options or in the roster the beacons make from (server/scavengers.luau).
local defs: { [string]: EntityDef } = {
	-- The end of a game against the scavengers: it comes when every beacon is down, or when the game's progress runs
	-- out, and killing it wins. Not from BAR. It is the Juggernaut grown half as big again, slower, and with twice the
	-- health before the difficulty multiplies it, and its weapons hit harder and reach further. It walks the sea floor as
	-- the Juggernaut does, so there is no island it cannot get to.
	-- bar: none (the scavengers' own)
	scavenger_boss = {
		name = "scavenger_boss",
		role = "boss",
		footing = footing.moves "VBOT6",
		display_name = "Scavenger Overlord",
		subtitle = "The scavengers' last stand",
		kind = "unit",
		category = "scavengers",
		collider = capsule(145, 240, 128),
		metal_cost = 60000,
		energy_cost = 1200000,
		buildpower_cost = 1500000,
		health = 1000000,
		acceleration = studs_per_second_squared(0.1),
		max_speed = studs(30),
		weapons = {
			-- the heat ray
			{
				kind = "heat_ray",
				damage = 8000,
				reload = 4,
				range = studs(1000),
				turret = { turn_rate = math.rad(90) },
				energy_per_shot = 0,
				offset = Vector3.new(0, 15, 4),
				delivery = {
					kind = "beam",
					time = 0.6,
					thickness = 3,
				},
			},
			-- the plasma cannon
			{
				kind = "plasma_cannon",
				damage = 220,
				reload = 1.4,
				burst_count = 14,
				burst_interval = 0.03,
				range = studs(700),
				energy_per_shot = 0,
				offset = Vector3.new(0, 12, 6),
				delivery = {
					kind = "lobbed",
					arc = "low",
					projectile = projectile({
						speed = shell_speed(studs(1000)),
						gravity = shell_gravity(studs(MAP_GRAVITY)),
						aoe_radius = aoe(130),
						edge_effectiveness = 0.65,
						inaccuracy = accuracy(2750),
					}),
				},
			},
			-- the rocket rack
			{
				kind = "missiles",
				damage = 1200,
				reload = 5,
				range = studs(1100),
				energy_per_shot = 0,
				target_layer = "ground",
				offset = Vector3.new(0, 18, -3),
				delivery = missile(
					"short",
					projectile({
						speed = studs(2600),
						aoe_radius = aoe(220),
						edge_effectiveness = 0.85,
					})
				),
			},
		} :: { Weapon },
		color = Color3.fromRGB(160, 84, 214),
	},

	-- bar: none (the scavengers' own)
	scavenger_beacon = beacon("scavenger_beacon", "Summons scavengers", footing.LAND),

	-- The same beacon for the sea: it floats, in water deep enough for the ships it makes, and it is the one that
	-- appears where there is water, as the land one appears where there is not.
	-- bar: none (the scavengers' own)
	scavenger_sea_beacon = beacon("scavenger_sea_beacon", "Summons scavenger ships", footing.afloat(studs(12))),
}

return table.freeze(defs)
