--!strict
local ReplicatedStorage = game:GetService "ReplicatedStorage"

local types = require(ReplicatedStorage.Shared.types)
local ground_levels = require(ReplicatedStorage.Shared.ground_levels)
local world_scale = require(ReplicatedStorage.Shared.world_scale)
local skins = require(ReplicatedStorage.Shared.skins)
local move_classes = require(ReplicatedStorage.Shared.move_classes)
local weapon_kinds = require(ReplicatedStorage.Shared.weapon_kinds)
local entity_attrs = require(ReplicatedStorage.Shared.entity_attrs)
local deep_freeze = require(ReplicatedStorage.Shared.deep_freeze).deep_freeze

local factory = require(script.factory)
local building = require(script.building)
local defense = require(script.defense)
local bot_t1 = require(script.bot_t1)
local vehicle_t1 = require(script.vehicle_t1)
local air_t1 = require(script.air_t1)
local air_t2 = require(script.air_t2)
local seaplane = require(script.seaplane)
local ship_t1 = require(script.ship_t1)
local ship_t2 = require(script.ship_t2)
local hover_t1 = require(script.hover_t1)
local bot_t2 = require(script.bot_t2)
local t3 = require(script.t3)
local vehicle_t2 = require(script.vehicle_t2)
local reclaimable = require(script.reclaimable)
local scavenger = require(script.scavenger)
local campaign = require(script.campaign)
local turret_mounts = require(script.turret_mounts)

type EntityDef = types.EntityDef
type Weapon = types.Weapon
type ProjectileParams = types.ProjectileParams
type EntityState = types.EntityState

-- The jobs a builder can do with its buildpower besides building (`types.Builder`).
export type Job = "assist" | "repair" | "reclaim" | "resurrect"
-- What a weapon can be turned on is decided by the layer its target is on (`layer_of`, `reaches_layer`).
export type Layer = "air" | "ground" | "water" | "under"

-- Gameplay numbers are Beyond All Reason's, copied as they appear in its unit files so each one can be checked against
-- the source: every def names the unit it is written from on a `-- bar:` line, and marks what is not that unit's (see
-- conversions.luau). The reclaimables are BAR's map features; see reclaimable.luau.
--
-- The defs themselves are split by what they are, one module each, and all written in BAR's own numbers through
-- `conversions`. Each says what it is filed under itself (`category`, `tech_level`), so nothing reads that off which
-- module it is in.

-- BAR's `buildtime` is the buildpower a thing costs, and a builder's `workertime` is the buildpower
-- it applies each second, so buildpower_cost / buildpower is the build time in seconds.

local GROUPS: { [string]: { [string]: EntityDef } } = {
	factory = factory,
	building = building,
	defense = defense,
	bot_t1 = bot_t1,
	vehicle_t1 = vehicle_t1,
	air_t1 = air_t1,
	air_t2 = air_t2,
	seaplane = seaplane,
	ship_t1 = ship_t1,
	ship_t2 = ship_t2,
	hover_t1 = hover_t1,
	bot_t2 = bot_t2,
	t3 = t3,
	vehicle_t2 = vehicle_t2,
	reclaimable = reclaimable,
	scavenger = scavenger,
	campaign = campaign,
}

-- The gap between the shots of a burst, for a burst weapon that does not say its own (`Weapon.burst_interval`): short
-- enough to read as one rapid burst rather than a weapon that simply reloads fast.
local DEFAULT_BURST_INTERVAL = 0.1
-- Shots leave from this far above the middle of the shooter, as a fraction of its height (`muzzle_of`).
local MUZZLE_FRACTION = 0.25
-- Fraction of a dead entity's metal that survives into its wreck, the fraction of its buildpower_cost that reclaiming
-- the wreck has to chew through, and how much damage a wreck takes before it is gone, as a fraction of what the thing
-- it was had in health.
local WRECK_METAL_FRACTION = 0.5
local WRECK_BUILDPOWER_FRACTION = 0.2
local WRECK_HEALTH_FRACTION = 0.5

-- `def` with each of its weapons that is on a turret piece of its model given where it fires from (`turret_mounts`,
-- which the model pipeline declares), each such weapon a copy, so that no table another def shares is changed. A mount
-- for a weapon the def does not have, or for one that gives an `offset` as well, is an error.
local function with_turret_mounts(def_name: string, def: EntityDef): EntityDef
	local mounts = turret_mounts[def_name]
	if mounts == nil then
		return def
	end
	local weapons = table.clone(def.weapons or {})
	for index, mount in mounts do
		local weapon = weapons[index]
		assert(weapon ~= nil, `"{def_name}" has a turret mount for weapon {index}, which it does not have`)
		assert(weapon.offset == nil, `"{def_name}"'s weapon {index} is on a turret and gives an offset as well`)
		local mounted = table.clone(weapon)
		mounted.turret_mount = mount
		weapons[index] = mounted
	end
	local mounted = table.clone(def)
	mounted.weapons = weapons
	return mounted
end

-- Every def of every group in one table, by name. Two groups that both define a name would have one silently
-- win, so that is an error here, and so is a def filed under a name other than its own, and one with more weapons than
-- an entity has attributes to show them by.
local defs: { [string]: EntityDef } = {}

for group_name, group in GROUPS do
	for def_name, def in group do
		assert(defs[def_name] == nil, `"{def_name}" is defined twice, the second time in {group_name}`)
		assert(def.name == def_name, `"{def_name}" in {group_name} is named "{def.name}"`)
		assert(
			def.weapons == nil or #def.weapons <= entity_attrs.MAX_WEAPONS,
			`"{def_name}" has more than {entity_attrs.MAX_WEAPONS} weapons`
		)
		assert(
			(def.health == nil) == (def.damage_immunity ~= nil),
			`"{def_name}" has to have health exactly when weapons can wear it down (no damage_immunity)`
		)
		defs[def_name] = deep_freeze(with_turret_mounts(def_name, def))
	end
end
table.freeze(defs)
for def_name in turret_mounts do
	assert(defs[def_name] ~= nil, `unit_defs/turret_mounts has mounts for "{def_name}", which is not a def`)
end

-- A carrier names its drone by name, which nothing but this can check: it has to be a def, and one that is a drone.
for def_name, def in defs do
	local carrier = def.carrier
	if carrier ~= nil then
		local drone_def = defs[carrier.drone]
		assert(drone_def ~= nil, `"{def_name}" carries "{carrier.drone}", which is not a def`)
		assert(drone_def.role == "drone", `"{def_name}" carries "{carrier.drone}", whose role is not "drone"`)
	end
end

local function get(def_name: string): EntityDef
	local def = defs[def_name]
	assert(def ~= nil, `unknown entity def "{def_name}"`)
	return def
end

-- Defs as a skin with `stats` makes them, by skin and def name, each made once, so that the same def is always the
-- same table.
local boosted: { [string]: { [string]: EntityDef } } = {}

-- `def_name`'s def as something wearing the skin called `skin_name` has it. Most skins are only a look and leave the
-- def as it is, the very same table; one with `stats` (a developer's) gets a copy with its numbers changed.
local function skinned(def_name: string, skin_name: string?): EntityDef
	local def = get(def_name)
	if skin_name == nil then
		return def
	end
	local stats = skins.get(skin_name).stats
	if stats == nil then
		return def
	end
	local by_def = boosted[skin_name]
	if by_def == nil then
		by_def = {}
		boosted[skin_name] = by_def
	end
	local found = by_def[def_name]
	if found == nil then
		found = deep_freeze(skins.boost(def, stats))
		by_def[def_name] = found
	end
	return found
end

-- What something of `def` has in health when it is whole. What no weapon wears down has no health of its own
-- (`EntityDef.health`): it stands whole, one of one.
local function max_health(def: EntityDef): number
	return def.health or 1
end

-- What something of `def_name` leaves when it dies: its wreck, which is a def of its own. It lies where the thing fell,
-- the same shape, but it is nobody's and does nothing: it has none of the thing's weapons, speed, flight, work or blast,
-- only half its metal to be reclaimed out of a fifth of its buildpower, and half its health to be shot away with. No EMP
-- stuns it. What it was is kept by the entity (`Wreck.source_def_name`), for raising it again. Made once for each def.
local wrecks: { [string]: EntityDef } = {}
local function wreck_of(def_name: string): EntityDef
	local found = wrecks[def_name]
	if found == nil then
		local source = get(def_name)
		local wreck: EntityDef = {
			name = source.name,
			display_name = `{source.display_name} wreck`,
			kind = "wreck",
			category = source.category,
			collider = source.collider,
			footing = source.footing,
			metal_cost = source.metal_cost * WRECK_METAL_FRACTION,
			energy_cost = 0,
			buildpower_cost = source.buildpower_cost * WRECK_BUILDPOWER_FRACTION,
			health = math.max(1, max_health(source) * WRECK_HEALTH_FRACTION),
			emp_resistance = 1,
			color = source.color,
		}
		found = deep_freeze(wreck)
		wrecks[def_name] = found
	end
	return found
end

-- A def made so far, as it is asked for again: by name alone, by skin and name, or as a wreck.
export type Made = { kind: "def" | "skinned" | "wreck", name: string, skin: string?, def: EntityDef }

-- Every def made so far, in an order that is the same wherever the same defs were made: every def, then those a
-- skin boosted, then the wrecks, each by name. What keeps a def as a reference rather than a copy (server/snapshot)
-- finds its tables through this, and asks for each again the way `kind` says.
local function made(): { Made }
	local found: { Made } = {}
	local function sorted_names(of: { [string]: any }): { string }
		local names = {}
		for name in of do
			table.insert(names, name)
		end
		table.sort(names)
		return names
	end
	for _, name in sorted_names(defs) do
		table.insert(found, { kind = "def", name = name, def = defs[name] })
	end
	for _, skin_name in sorted_names(boosted) do
		local by_def = boosted[skin_name]
		for _, name in sorted_names(by_def) do
			table.insert(found, { kind = "skinned", name = name, skin = skin_name, def = by_def[name] })
		end
	end
	for _, name in sorted_names(wrecks) do
		table.insert(found, { kind = "wreck", name = name, def = wrecks[name] })
	end
	return found
end

-- What it is to its side ---------------------------------------------------------------------------------------

-- Whether `def` is a commander, what its side stands or falls by.
local function is_commander(def: EntityDef): boolean
	return def.role == "commander"
end

-- Whether `def` is a boss, what the scavengers end with.
local function is_boss(def: EntityDef): boolean
	return def.role == "boss"
end

-- Whether `def` is a beacon, what the scavengers come from.
local function is_beacon(def: EntityDef): boolean
	return def.role == "beacon"
end

-- Whether `def` is a drone, a part of its carrier: the carrier sends it out and calls it back, and nobody else
-- selects, orders or builds it.
local function is_drone(def: EntityDef): boolean
	return def.role == "drone"
end

-- Whether what is of `kind` is remains, lying about the map for the taking and belonging to nobody: a wreck, or a
-- reclaimable.
local function is_remains_kind(kind: types.EntityKind): boolean
	return kind == "wreck" or kind == "reclaimable"
end

-- Whether `def` is remains (`is_remains_kind`).
local function is_remains(def: EntityDef): boolean
	return is_remains_kind(def.kind)
end

-- Whether losing something finished of `def` counts as a loss to its side: a unit or a building, but not a drone, which
-- is only a part of its carrier.
local function counts_as_loss(def: EntityDef): boolean
	return is_remains(def) == false and def.role ~= "drone"
end

-- Whether something finished of `def` can leave a wreck when it dies: a unit or a building on the ground, but not an
-- aircraft, which comes down in pieces, nor a drone. A death violent enough leaves none anyway, except of what
-- `always_leaves_wreck`.
local function leaves_wreck(def: EntityDef): boolean
	return is_remains(def) == false and def.air == nil and def.role ~= "drone"
end

-- Whether something of `def` leaves its wreck however it dies, destroying itself included, as BAR's commanders do.
local function always_leaves_wreck(def: EntityDef): boolean
	return def.role == "commander"
end

-- Whether nothing but a manual weapon can harm something of `def` (`EntityDef.damage_immunity`). Such a thing that a
-- disintegrator takes is simply gone: no wreck, no pieces, no blast.
local function harmed_only_by_manual_weapon(def: EntityDef): boolean
	return def.damage_immunity == "all_but_manual_weapon"
end

-- Whether a weapon's damage or EMP harms something of `def` at all: anything but what is immune to it
-- (`EntityDef.damage_immunity`).
local function harmed_by_weapons(def: EntityDef): boolean
	return def.damage_immunity == nil
end

-- Its weapons ------------------------------------------------------------------------------------------------------

-- Whether `weapon` is dedicated anti-air, doing its full damage to aircraft.
local function is_anti_air(weapon: Weapon): boolean
	return weapon_kinds.get(weapon.kind).anti_air == true
end

-- Whether something of `def` has a weapon for aircraft: one made for shooting them down, or one that can only be turned
-- on them.
local function defends_against_air(def: EntityDef): boolean
	if def.weapons == nil then
		return false
	end
	for _, weapon in def.weapons do
		if is_anti_air(weapon) or weapon.target_layer == "air" then
			return true
		end
	end
	return false
end

-- Whether every weapon something of `def` has can only be turned on aircraft (and it has some).
local function is_anti_air_only(def: EntityDef): boolean
	if def.weapons == nil or #def.weapons == 0 then
		return false
	end
	for _, weapon in def.weapons do
		if weapon.target_layer ~= "air" then
			return false
		end
	end
	return true
end

-- Whether `weapon` is an anti-nuke's interceptor, which shoots at nuclear missiles and nothing else.
local function is_anti_nuke(weapon: Weapon): boolean
	return weapon_kinds.get(weapon.kind).anti_nuke == true
end

-- What a projectile of `weapon`'s flies like, or nil for a beam, which fires none.
local function projectile_of(weapon: Weapon): ProjectileParams?
	local delivery = weapon.delivery
	if delivery.kind == "beam" then
		return nil
	end
	return delivery.projectile
end

-- The gap between the shots of `weapon`'s burst.
local function burst_interval(weapon: Weapon): number
	return weapon.burst_interval or DEFAULT_BURST_INTERVAL
end

-- The longest range of `def`'s weapons that `counts` (every one of them, without it), or nil if it has none that do.
-- Every range asked of a def below is this, over the weapons it is about.
local function longest_range(def: EntityDef, counts: ((Weapon) -> boolean)?): number?
	local longest: number? = nil
	if def.weapons ~= nil then
		for _, weapon in def.weapons do
			if (counts == nil or counts(weapon)) and (longest == nil or weapon.range > longest) then
				longest = weapon.range
			end
		end
	end
	return longest
end

-- The longest range anything on `def` can shoot, or nil if it cannot shoot at all.
local function attack_range(def: EntityDef): number?
	return longest_range(def)
end

-- Whether `weapon` is what makes a place dangerous to be near: not one that fires only when told to, like a nuclear
-- silo's, which could reach anywhere, nor an anti-nuke.
local function threatens(weapon: Weapon): boolean
	return weapon.manual_fire ~= true and is_anti_nuke(weapon) == false
end

local function threatens_ground(weapon: Weapon): boolean
	return threatens(weapon) and weapon.target_layer ~= "air"
end

local function threatens_air(weapon: Weapon): boolean
	return threatens(weapon) and weapon.target_layer ~= "ground"
end

-- How far `def` reaches with the weapons that can be turned on the ground, and with those that can be turned on
-- aircraft; nil for a layer it cannot hit. Only the weapons that threaten (`threatens`) count. A carrier with nothing of
-- its own fights with its drones, as far out as it sends them.
local function reaches(def: EntityDef): (number?, number?)
	local ground = longest_range(def, threatens_ground)
	local air = longest_range(def, threatens_air)
	if def.carrier ~= nil then
		ground = math.max(ground or 0, def.carrier.engage_range)
	end
	return ground, air
end

-- Whether an attack order that is a launch or not (`launch`) fires `weapon`: a launch (the nuke or missile D fires)
-- fires the manual-fire weapons (`Weapon.manual_fire`), and any other attack every other one.
local function fired_by_order(weapon: Weapon, launch: boolean): boolean
	return (weapon.manual_fire == true) == launch
end

-- The longest range of the weapons of `def` that an attack order fires (`fired_by_order`), nil if it has none of them.
local function order_range(def: EntityDef, launch: boolean): number?
	return longest_range(def, function(weapon: Weapon): boolean
		return fired_by_order(weapon, launch)
	end)
end

-- The range to draw round something: how far it shoots, or for a drone carrier how far out its drones go to
-- fight, which is a range like a weapon's. Unlike `attack_range` it does not make the carrier armed: it has
-- nothing to aim, so it cannot be ordered to attack. An anti-nuke's interceptor is left out: what it covers
-- is drawn as a ring of its own (`intercept_range`).
local function display_range(def: EntityDef): number?
	local range = longest_range(def, function(weapon: Weapon): boolean
		return is_anti_nuke(weapon) == false
	end)
	if range == nil and def.carrier ~= nil then
		return def.carrier.engage_range
	end
	return range
end

-- How far out an anti-nuke shoots down nukes, or nil if it is not one.
local function intercept_range(def: EntityDef): number?
	return longest_range(def, is_anti_nuke)
end

-- What `amount` of a weapon's damage comes to against something of `target`. An aircraft shrugs off
-- anything that is not a dedicated anti air weapon, taking only a fraction of the damage.
local function damage_against(anti_air: boolean, target: EntityDef, amount: number): number
	if target.air ~= nil and anti_air == false then
		return amount * weapon_kinds.NON_AA_AIR_DAMAGE_FRACTION
	end
	return amount
end

-- What it does -----------------------------------------------------------------------------------------------------

-- Whether something of `def` does `job` with its buildpower.
local function does(def: EntityDef, job: Job): boolean
	local builder = def.builder
	if builder == nil then
		return false
	elseif job == "assist" then
		return builder.assists == true
	elseif job == "repair" then
		return builder.repairs == true
	elseif job == "reclaim" then
		return builder.reclaims == true
	end
	return builder.resurrects == true
end

-- How far something of `def` reaches to work, if it says (`Builder.range`); nil for the usual reach of its job.
local function build_range(def: EntityDef): number?
	return if def.builder ~= nil then def.builder.range else nil
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
	return does(def, "assist") or does(def, "reclaim") or does(def, "repair")
end

-- Whether `def` is a building that makes units, a lab or a shipyard. It cannot be given orders, but it
-- takes move orders as a rally point for what it makes.
local function is_factory(def: EntityDef): boolean
	local options = if def.kind == "building" and def.builder ~= nil then def.builder.options else nil
	if options == nil then
		return false
	end
	for _, name in options do
		local option = defs[name]
		if option ~= nil and option.kind == "unit" then
			return true
		end
	end
	return false
end

-- What something of `def` can build, or an empty list for something that builds nothing.
local EMPTY: { string } = table.freeze({})
local function build_options(def: EntityDef): { string }
	local options = if def.builder ~= nil then def.builder.options else nil
	return options or EMPTY
end

-- Whether something of `def` can be carried by a transport of `carrier`: the cargo has a weight class, and a light
-- transport takes only light cargo while a heavy one takes light and heavy.
local function can_carry(carrier: EntityDef, cargo: EntityDef): boolean
	local carrying = carrier.transport
	local weight = cargo.weight_class
	if carrying == nil or weight == nil then
		return false
	end
	return weight == "light" or carrying.carries == "heavy"
end

-- Whether a transport of `carrier` can pick up something of `cargo` in `cargo_state`, if it were in reach: something
-- finished that it can carry (`can_carry`), not in a hold already (`held`), and never a commander of a side not allied
-- with the transport's (`allied`).
local function can_load(
	carrier: EntityDef,
	cargo: EntityDef,
	cargo_state: EntityState,
	held: boolean,
	allied: boolean
): boolean
	return cargo_state == "active"
		and held == false
		and (allied or is_commander(cargo) == false)
		and can_carry(carrier, cargo)
end

-- What something of `def` is worth, as BAR reckons it: its metal cost plus a sixtieth of its energy cost. Targeting
-- shoots first at what is most of this for the health it has left, and experience is earned by taking it off enemies.
local function power(def: EntityDef): number
	return def.metal_cost + def.energy_cost / 60
end

-- Where it can be --------------------------------------------------------------------------------------------------

-- Whether `def` may stand where the water is between `shallowest` and `deepest` studs deep, which is
-- how it is under a footprint: a unit needs the deepest ground it touches to be within its limit, and a
-- ship needs even the shallowest to be deep enough.
local function tolerates_water(def: EntityDef, shallowest: number, deepest: number): boolean
	local footing = def.footing
	return deepest <= footing.max_depth and shallowest >= footing.min_depth
end

-- Whether it floats on the water's surface rather than standing on the ground under it: a ship, a submarine or a
-- building built on the sea.
local function floats(def: EntityDef): boolean
	return def.footing.water == "float"
end

-- Whether it rides the water's surface where there is water: something that floats, or a hovercraft, which rides over
-- it.
local function rides_surface(def: EntityDef): boolean
	return def.footing.water ~= "ground"
end

-- Whether it is a submarine: a ship that rides under the water's surface (`Footing.waterline`).
local function is_submarine(def: EntityDef): boolean
	return def.footing.waterline > 0
end

-- How far under the surface something's underside has to be for it to count as in the water, so that one
-- standing on a beach a hair below the waterline does not.
local IN_WATER_MARGIN = 0.1

-- Whether something of `def` centred at `position` is in the water: a ship, whose hull sits in it, or a
-- submarine, or anything whose underside is under the surface, like an amphibious unit walking the sea floor or
-- a building built on it. It is what a torpedo can be aimed at, and nothing else. Being over the water is not
-- being in it: an aircraft never is, and nor is a hovercraft riding on top.
local function in_water(def: EntityDef, position: Vector3): boolean
	local water = def.footing.water
	if def.air ~= nil or water == "hover" then
		return false
	end
	if water == "float" then
		return true
	end
	return position.Y - def.collider.height / 2 < ground_levels.WATER_LEVEL - IN_WATER_MARGIN
end

-- Whether something of `def` centred at `position` is wholly under the water, its top included: a submarine
-- that has dived, or anything on the sea floor with the water over it. Only a torpedo can be aimed at it, and
-- a laser does not reach it; what it takes from anything else is the blast of what goes off near it.
local function submerged(def: EntityDef, position: Vector3): boolean
	return def.air == nil
		and def.footing.water ~= "hover"
		and position.Y + def.collider.height / 2 <= ground_levels.WATER_LEVEL
end

-- Whether it runs on tracks or wheels, as its movement class says.
local function is_vehicle(def: EntityDef): boolean
	local class = move_classes.of(def.footing.class)
	return class ~= nil and class.vehicle
end

local function is_air(def: EntityDef): boolean
	return def.air ~= nil
end

-- Whether `weapon` lobs its shots: a shell on an arc, or a missile that climbs and comes down on where its target was.
local function is_lobbed(weapon: Weapon): boolean
	local kind = weapon.delivery.kind
	return kind == "lobbed" or kind == "missile"
end

local function is_torpedo(weapon: Weapon): boolean
	return weapon.delivery.kind == "torpedo"
end

-- The layer something of `def` at `position` is on.
local function layer_of(def: EntityDef, position: Vector3): Layer
	if is_air(def) then
		return "air"
	end
	if submerged(def, position) then
		return "under"
	end
	if in_water(def, position) then
		return "water"
	end
	return "ground"
end

-- Whether `weapon` can be turned on what is on `layer`: a torpedo on what is in the water or under it and nothing else,
-- and nothing else on what is under it; a weapon that names a layer on that one only (the ground's including the
-- water's); and a lobbed shell, which comes down where its target was, never on what flies. What the game's targeting
-- (server/shot_rules.luau), the AI's fight predictor and a pilot's reticle all go by.
local function reaches_layer(weapon: Weapon, layer: Layer): boolean
	if is_torpedo(weapon) then
		return layer == "water" or layer == "under"
	end
	if layer == "under" then
		return false
	end
	if weapon.target_layer == "air" then
		return layer == "air"
	end
	if weapon.target_layer == "ground" then
		return layer ~= "air"
	end
	return layer ~= "air" or is_lobbed(weapon) == false
end

-- Whether something of `def` moves about under its own power: a unit with a top speed and an acceleration. Everything
-- that asks whether something can go anywhere asks this.
local function moves(def: EntityDef): boolean
	return def.kind == "unit" and def.max_speed ~= nil and def.acceleration ~= nil
end

-- Whether something of `def` gets about on the ground or the water, and so has to find its way round what is in the
-- way (shared/pathfinder): something that moves (`moves`) and does not fly over it all.
local function walks(def: EntityDef): boolean
	return moves(def) and def.air == nil
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

-- Its size -----------------------------------------------------------------------------------------------------------

-- The footprint a collider occupies on the ground, as a half-extent on each axis. Capsules are
-- treated as their bounding square so that occupancy tests can share one code path with boxes.
-- A building occupies whole cells of the building grid, so its footprint is its collider rounded up
-- to a multiple of the cell size, and neighbours pack edge to edge with no slivers between them.
local function grid_span(length: number): number
	return math.ceil(length / world_scale.CELL_STUDS) * world_scale.CELL_STUDS
end

local function footprint_half_extents(def: EntityDef): Vector2
	local collider = def.collider
	if collider.shape == "box" then
		return Vector2.new(grid_span(collider.width) / 2, grid_span(collider.length) / 2)
	end
	return Vector2.new(collider.radius, collider.radius)
end

local function collider_height(def: EntityDef): number
	return def.collider.height
end

-- Where the shots of something of `def` with its middle at `position` leave from, for the line of sight a shot needs:
-- a little above its middle.
local function muzzle_of(def: EntityDef, position: Vector3): Vector3
	return position + Vector3.new(0, collider_height(def) * MUZZLE_FRACTION, 0)
end

-- Horizontal radius used for separation, range checks and click picking.
local function collider_radius(def: EntityDef): number
	local collider = def.collider
	if collider.shape == "box" then
		return math.max(collider.width, collider.length) / 2
	end
	return collider.radius
end

return table.freeze({
	defs = defs,
	get = get,
	skinned = skinned,
	max_health = max_health,
	wreck_of = wreck_of,
	made = made,
	is_commander = is_commander,
	is_drone = is_drone,
	is_remains_kind = is_remains_kind,
	is_remains = is_remains,
	is_boss = is_boss,
	is_beacon = is_beacon,
	counts_as_loss = counts_as_loss,
	leaves_wreck = leaves_wreck,
	always_leaves_wreck = always_leaves_wreck,
	harmed_only_by_manual_weapon = harmed_only_by_manual_weapon,
	harmed_by_weapons = harmed_by_weapons,
	is_anti_air = is_anti_air,
	defends_against_air = defends_against_air,
	is_anti_air_only = is_anti_air_only,
	is_anti_nuke = is_anti_nuke,
	is_lobbed = is_lobbed,
	is_torpedo = is_torpedo,
	layer_of = layer_of,
	reaches_layer = reaches_layer,
	projectile_of = projectile_of,
	burst_interval = burst_interval,
	longest_range = longest_range,
	attack_range = attack_range,
	reaches = reaches,
	fired_by_order = fired_by_order,
	order_range = order_range,
	display_range = display_range,
	intercept_range = intercept_range,
	damage_against = damage_against,
	takes_orders = takes_orders,
	is_factory = is_factory,
	does = does,
	build_range = build_range,
	build_options = build_options,
	can_carry = can_carry,
	can_load = can_load,
	power = power,
	tolerates_water = tolerates_water,
	floats = floats,
	rides_surface = rides_surface,
	is_submarine = is_submarine,
	in_water = in_water,
	submerged = submerged,
	is_vehicle = is_vehicle,
	is_air = is_air,
	moves = moves,
	walks = walks,
	turn_radius = turn_radius,
	footprint_half_extents = footprint_half_extents,
	collider_height = collider_height,
	muzzle_of = muzzle_of,
	collider_radius = collider_radius,
})
