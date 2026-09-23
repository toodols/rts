local ReplicatedStorage = game:GetService "ReplicatedStorage"

local types = require(ReplicatedStorage.Shared.types)
local config = require(ReplicatedStorage.Shared.config)
local heightmap = require(ReplicatedStorage.Shared.heightmap)

local factory = require(script.factory)
local building = require(script.building)
local defense = require(script.defense)
local bot_t1 = require(script.bot_t1)
local vehicle_t1 = require(script.vehicle_t1)
local air_t1 = require(script.air_t1)
local ship_t1 = require(script.ship_t1)
local bot_t2 = require(script.bot_t2)
local t3 = require(script.t3)
local vehicle_t2 = require(script.vehicle_t2)
local reclaimable = require(script.reclaimable)

type EntityDef = types.EntityDef

-- Gameplay numbers are Beyond All Reason's, copied as they appear in its unit files so each one can
-- be checked against the source: units/CorBots/corak.lua (grunt), units/ArmBots/armck.lua
-- (construction_bot), units/ArmBuildings/LandFactories/armlab.lua (bot lab) and
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
-- units/CorBots/T2/corhrk.lua (Arbiter) and units/CorBuildings/LandFactories/corgant.lua (Experimental Gantry) and
-- units/CorBuildings/SeaEconomy/coruwadves.lua and coruwadvms.lua (the hardened stores) and
-- units/CorBuildings/LandDefenceOffence/corscreamer.lua (Screamer) and units/CorBots/corthud.lua (Thug),
-- units/CorVehicles/corraid.lua (Brute), units/CorVehicles/T2/correap.lua (Tiger), corparrow.lua (Poison Arrow)
-- and corvroc.lua (Negotiator), units/ArmBots/T2/armsptk.lua (Recluse), units/CorGantry/corkorg.lua (Juggernaut),
-- units/ArmGantry/armvang.lua (Vanguard), units/CorBuildings/LandDefenceOffence/corerad.lua (Eradicator) and
-- units/CorShips/corpt.lua (Herring), units/CorGantry/corshiva.lua (Shiva), units/CorShips/corsub.lua (Orca) and
-- units/CorShips/T2/corcrus.lua (Buccaneer), units/CorBuildings/LandEconomy/corgeo.lua and corageo.lua (the
-- geothermal powerplants) and, from Legion, units/Legion/Economy/legrampart.lua (Rampart) and
-- units/Legion/Air/T2 Air/legheavydrone.lua (its heavy drone). The reclaimables are BAR's map features; see reclaimable.luau.
--
-- The defs themselves are split by what they are, one module each, and all written in BAR's own numbers through
-- `conversions`.

-- Water depths follow BAR's movement classes, from gamedata/movedefs.lua, except that land units do not
-- wade at all here: they and buildings stand only on dry ground, commanders and other amphibious things
-- go anywhere (BAR's 5000 elmos), and a ship has a minimum depth from its own file and no maximum.

-- BAR's `buildtime` is the buildpower a thing costs, and a builder's `workertime` is the buildpower
-- it applies each second, so buildpower_cost / buildpower is the build time in seconds.

local GROUPS: { [string]: { [string]: EntityDef } } = {
	factory = factory,
	building = building,
	defense = defense,
	bot_t1 = bot_t1,
	vehicle_t1 = vehicle_t1,
	air_t1 = air_t1,
	ship_t1 = ship_t1,
	bot_t2 = bot_t2,
	t3 = t3,
	vehicle_t2 = vehicle_t2,
	reclaimable = reclaimable,
}

-- Every def of every group in one table, by name. Two groups that both define a name would have one silently
-- win, so that is an error here, and so is a def filed under a name other than its own.
local defs: { [string]: EntityDef } = {}

for group_name, group in GROUPS do
	for def_name, def in group do
		assert(defs[def_name] == nil, `"{def_name}" is defined twice, the second time in {group_name}`)
		assert(def.name == def_name, `"{def_name}" in {group_name} is named "{def.name}"`)
		defs[def_name] = def
	end
end

-- A carrier that is missing something only fails once its drones are up and running, with an error about a nil
-- somewhere else, so every one is checked here, when the defs load, and the error names the unit and the field.
local CARRIER_FIELDS = { "count", "starting", "engage_range", "repair_per_second" }
local STOCKPILE_FIELDS = { "limit", "build_time", "metal", "energy" }

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
	local stockpile = (carrier :: any).stockpile
	assert(typeof(stockpile) == "table", `"{def_name}".carrier.stockpile is missing`)
	for _, field in STOCKPILE_FIELDS do
		assert(
			typeof(stockpile[field]) == "number",
			`"{def_name}".carrier.stockpile.{field} must be a number, but it is {typeof(stockpile[field])}`
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
	if def.weapons ~= nil then
		for _, weapon in def.weapons do
			if longest == nil or weapon.range > longest then
				longest = weapon.range
			end
		end
	end
	return longest
end

-- Units close in to a little inside a range, not right up to it, the way `orders` does (its RANGE_MARGIN).
local RANGE_MARGIN = 0.85

-- How close something of `def` has to get to what an order of `kind` is aimed at to carry it out: within reach for
-- what is done from a distance, and all the way for anything else. Where a route laid for the order (`commands`) can
-- stop, and where the client draws a queue as ending.
local function order_reach(def: EntityDef, kind: string): number
	if kind == "dgun" then
		return if def.manual_weapon ~= nil then def.manual_weapon.range * RANGE_MARGIN else 0
	end
	if kind == "attack" or kind == "attack_ground" then
		local range = attack_range(def)
		return if range ~= nil then range * RANGE_MARGIN else 0
	end
	if kind == "build" or kind == "assist" or kind == "repair" then
		return (def.build_range or config.BUILD_RANGE) * RANGE_MARGIN
	end
	if kind == "reclaim" then
		return (def.build_range or config.RECLAIM_RANGE) * RANGE_MARGIN
	end
	if kind == "resurrect" then
		return (def.build_range or config.RESURRECT_RANGE) * RANGE_MARGIN
	end
	return 0
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
-- that is built underwater stands on the sea floor. A submarine rides its `waterline` under the surface
-- instead, and on the sea floor where the water is not that deep.
local function surface_height(def: EntityDef, x: number, z: number): number
	local ground = heightmap.height_at(x, z)
	if floats(def) then
		return math.max(ground, config.WATER_LEVEL - (def.waterline or 0))
	end
	return ground
end

-- How far under the surface something's underside has to be for it to count as in the water, so that one
-- standing on a beach a hair below the waterline does not.
local IN_WATER_MARGIN = 0.1

-- Whether something of `def` centred at `position` is in the water: a ship, whose hull sits in it, or a
-- submarine, or anything whose underside is under the surface, like an amphibious unit walking the sea floor or
-- a building built on it. It is what a torpedo can be aimed at, and nothing else. Being over the water is not
-- being in it: an aircraft never is, and nor is a hovercraft riding on top, so that is how to tell one apart when
-- there are hovercraft.
local function in_water(def: EntityDef, position: Vector3): boolean
	if def.air ~= nil then
		return false
	end
	if floats(def) then
		return true
	end
	return position.Y - def.collider.height / 2 < config.WATER_LEVEL - IN_WATER_MARGIN
end

-- Whether something of `def` centred at `position` is wholly under the water, its top included: a submarine
-- that has dived, or anything on the sea floor with the water over it. Only a torpedo can be aimed at it, and
-- a laser does not reach it; what it takes from anything else is the blast of what goes off near it.
local function submerged(def: EntityDef, position: Vector3): boolean
	return def.air == nil and position.Y + def.collider.height / 2 <= config.WATER_LEVEL
end

-- The point at (x, z) that something of this def rests at: `surface_height` there. Waypoints for a ship
-- lie on the water and not on the sea floor beneath it.
local function surface_position(def: EntityDef, x: number, z: number): Vector3
	return Vector3.new(x, surface_height(def, x, z), z)
end

local function is_air(def: EntityDef): boolean
	return def.air ~= nil
end

-- How tight a circle `def` flies at full speed if it flies on wings, and 0 if it does not. It cannot stop on a
-- point it is making for, so this is about as close to it as it can be counted on to come.
local function turn_radius(def: EntityDef): number
	local wings = if def.air ~= nil then def.air.wings else nil
	if wings == nil or def.max_speed == nil then
		return 0
	end
	return def.max_speed / wings.turn_rate
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
	in_water = in_water,
	submerged = submerged,
	is_air = is_air,
	turn_radius = turn_radius,
	damage_against = damage_against,
	can_carry = can_carry,
	transport_slots = transport_slots,
	attack_range = attack_range,
	order_reach = order_reach,
	display_range = display_range,
	collider_height = collider_height,
	collider_radius = collider_radius,
})
