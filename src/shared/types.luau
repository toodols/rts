export type EntityId = number
export type TeamId = number

export type EntityKind = "unit" | "building" | "wreck"

-- Everything buildable exists first as a `blueprint` that accumulates buildpower, metal and
-- energy, and flips to `active` once its buildpower_cost has been fully applied.
export type EntityState = "blueprint" | "active"

-- Buildings are cuboids measured in whole cells of the building grid. Units are capsules sized from BAR's
-- collision volumes, converted from elmos to studs.
export type BoxCollider = {
	shape: "box",
	width: number,
	height: number,
	length: number,
}

export type CapsuleCollider = {
	shape: "capsule",
	radius: number,
	height: number,
}

export type Collider = BoxCollider | CapsuleCollider

-- `guard` follows a friendly entity, and a builder guarding one works on whatever it is working on.
-- `build` walks to a spot and starts a blueprint there when it arrives, which is why it carries the
-- def, position and facing it will build with instead of a blueprint to help. `attack_ground` keeps shooting
-- at a point on the ground, with no target, until it is given something else to do. A transport's `load`
-- goes to a friendly unit and takes it aboard; its `unload` goes to a point and sets everything it carries
-- down there. `fight` is a move that stops to shoot at whatever comes within reach on the way, and carries
-- on once there is nothing left to shoot at. `dgun` fires a manual weapon, the commander's disintegrator, along
-- the line to a point: it closes in until the point is in range, waits for the weapon to be ready, fires once, and
-- is done.
export type OrderKind =
	"move"
	| "fight"
	| "dgun"
	| "attack"
	| "attack_ground"
	| "reclaim"
	| "assist"
	| "guard"
	| "build"
	| "repair"
	| "resurrect"
	| "load"
	| "unload"

export type Order = {
	kind: OrderKind,
	position: Vector3?,
	target_id: EntityId?,
	def_name: string?,
	facing: number?,
}

-- How a rocket flies: it thrusts along its heading for `thrust_time` seconds, speeding up, then loses
-- its momentum to drag and gravity and falls. It explodes on whatever it touches, hurting everything
-- within `aoe_radius` of the blast.
--
-- A shell is a rocket with no thrust and no drag: it leaves the barrel at `speed` and gravity does the
-- rest. Setting `arc` makes it one that is lobbed: it is aimed at an angle chosen so that it lands on
-- its target, the high one or the low one of the two that do, or the one halfway between them (launched slower, so that it still lands on the target), or, for "auto", the lowest of the low, medium and high ones that has a clear path, and is fired without a line of sight,
-- because the arc carries it over whatever is in between.
export type ProjectileParams = {
	speed: number,
	acceleration: number,
	thrust_time: number,
	gravity: number,
	drag: number,
	aoe_radius: number,
	-- what is left of the blast's damage at its very edge, as a fraction of the damage at its centre
	edge_effectiveness: number?,
	arc: ("high" | "medium" | "low" | "auto")?,
	-- half the angle, in radians, of the cone a lobbed shell may stray within from its aim
	inaccuracy: number?,
	-- a bomb: it is let go rather than fired, so it leaves its launcher heading straight down, with no
	-- launch speed, and gravity does the rest
	dropped: boolean?,
	-- fired ahead of a moving target, at where it will be by the time the rocket gets there, and not at where it
	-- is. Rockets do not home, so a missile that has to hit something quick, like an aircraft, needs it.
	leads: boolean?,
	-- a missile that goes up and comes down on its target rather than flying at it
	missile: Missile?,
	-- a plasma shell: one that a plasma deflector stops. Rockets, missiles and beams are not.
	plasma: boolean?,
}

-- How a missile flies: straight up from its launcher to `climb` studs above it, over to its target at that
-- height, and then down onto it, along a line at least `dive_angle` radians steep. It is stopped by nothing
-- on the way up or across, and only strikes what is in its path once it has turned to come down. It flies at
-- the rocket's `speed` throughout, and is aimed at where its target was when it was launched.
export type Missile = {
	climb: number,
	dive_angle: number,
}

-- Which of the two layers of the world a weapon can shoot at. Aircraft are in the air and everything else
-- is on the ground.
export type TargetLayer = "ground" | "air"

export type Weapon = {
	damage: number,
	reload: number,
	range: number,
	energy_per_shot: number,
	-- a dedicated anti air weapon does its full damage to aircraft; any other does only a fraction of it
	-- (`config.NON_AA_AIR_DAMAGE_FRACTION`)
	anti_air: boolean?,
	-- what it can shoot at: nil for both layers, and a weapon that names one never fires at the other
	target_layer: TargetLayer?,
	-- set for a weapon that throws a rocket rather than hitting its target instantly
	projectile: ProjectileParams?,
	-- for a laser, how many seconds its beam stays up. It is only what is drawn: the damage lands at the
	-- instant it fires, and does not wait for the beam to go.
	beam_time: number?,
	-- for a laser, how wide its beam is drawn, in studs, and what colour; without a colour it is its team's
	beam_thickness: number?,
	beam_color: Color3?,
	-- a weapon that fires from a stockpile of missiles that it builds up over time, rather than from a
	-- reload alone. It shoots only when it is told to, never at what happens to come within its range.
	stockpile: Stockpile?,
	-- for a weapon that fires multiple times per reload cycle; nil if weapon fires once per reload
	burst_count: number?,
}

-- What building up missiles takes: every `build_time` seconds one more is finished, at the price of `metal` and
-- `energy`, until `limit` are held. A missile that cannot be paid for yet waits until it can be.
export type Stockpile = {
	limit: number,
	build_time: number,
	metal: number,
	energy: number,
}

-- One of several weapons an entity carries, each with its own reload and its own target. `offset` is
-- where its shots come from, in the entity's own frame: x to its right, y up, z ahead.
export type Turret = {
	weapon: Weapon,
	offset: Vector3,
}

-- What happens when something finished is destroyed: everything within `radius` takes `damage` at the
-- centre, falling off toward the edge.
export type DeathExplosion = {
	radius: number,
	damage: number,
}

-- What a converter does at full tilt: it eats `energy_per_second` and makes `metal_per_second` from it.
export type EnergyConversion = {
	energy_per_second: number,
	metal_per_second: number,
}

-- A weapon that only fires when told to, in a direction rather than at a target. It sweeps a
-- rectangle from its owner out to `range`, `radius` to either side of the line, and destroys everything
-- inside it: friend, foe and building alike.
export type ManualWeapon = {
	range: number,
	reload: number,
	energy_per_shot: number,
	radius: number,
}

-- What makes something an aircraft. It takes off and lands straight up and down, so it needs no runway: it
-- climbs to `altitude` above the ground when it has somewhere to go, and settles back onto the ground once
-- it has been idle a while. Nothing on the ground gets in its way, and it is in the way of nothing while
-- it is up.
export type Aircraft = {
	-- how far above the ground it flies, in studs
	altitude: number,
	-- how fast it climbs and descends, in studs a second
	climb_speed: number,
	-- flies over what it attacks and on past it, then turns back for another pass, rather than stopping
	-- to hover over it; what a bomber does
	bombing_runs: boolean?,
}

-- A plasma deflector's shield: a sphere of `radius` studs round the building that stops enemy plasma shells, each
-- costing it the shell's damage in `power`. It starts with `starting_power`, and grows back `regen` a second for
-- `regen_energy` energy a second, when the energy is there.
export type Shield = {
	radius: number,
	power: number,
	regen: number,
	regen_energy: number,
	starting_power: number,
}

-- What a carrier keeps: `count` drones of `drone`, parked on it. While an enemy is within `engage_range` they
-- launch and fight it; when nothing is, or it goes out of range, they fly back and park. A drone that is shot
-- down is replaced `respawn_seconds` later. A drone parked on its carrier is mended by it, `repair_per_second`
-- health a second, for nothing.
export type Carrier = {
	drone: string,
	count: number,
	engage_range: number,
	respawn_seconds: number,
	repair_per_second: number,
}

-- How heavy a unit is to a transport. A unit with no weight class cannot be carried at all.
export type WeightClass = "light" | "heavy"

-- What a transport can carry: `capacity` is in slots, and a unit takes as many as
-- `unit_defs.transport_slots` says. A transport that carries "light" takes light units only, and one that
-- carries "heavy" takes light and heavy ones.
export type Transport = {
	capacity: number,
	carries: WeightClass,
}

export type EntityDef = {
	name: string,
	display_name: string,
	-- what it is in plain words, shown under its name
	subtitle: string?,
	kind: EntityKind,
	-- a tank, truck or other wheeled or tracked ground unit, drawn as a car rather than a bot; nil for
	-- everything else
	vehicle: boolean?,
	-- BAR's movement class, which decides the steepest ground it can stand on (`passability.max_slope`); nil
	-- for anything that is not held to the ground's slope: buildings, aircraft and ships
	slope_class: string?,
	collider: Collider,
	metal_cost: number,
	energy_cost: number,
	buildpower_cost: number,
	health: number,
	-- nil for things that cannot build, assist or reclaim at all
	buildpower: number?,
	-- nil for buildings, which never move
	acceleration: number?,
	max_speed: number?,
	reclaiming: boolean,
	repairing: boolean,
	-- can raise a unit's wreck: puts its metal back and then its buildpower into bringing it back
	resurrecting: boolean,
	assisting: boolean,
	-- how deep the water may be where it stands, in studs. A land unit wades a little, a commander goes
	-- almost anywhere, and a ship is limited only by `min_water_depth`
	max_water_depth: number,
	-- how deep the water has to be for it to stand there; nil for anything that lives on land. Having one
	-- is what makes a unit a ship: it floats on the surface rather than resting on the ground below it.
	min_water_depth: number?,
	-- what this entity can build, and it is its own list: the buildings a builder can place, or the units a
	-- factory can queue. Nothing shares one, so a unit that is alike another today can change tomorrow.
	build_options: { string }?,
	weapon: Weapon?,
	manual_weapon: ManualWeapon?,
	-- independently targetable weapons, for something like the twin guard that has more than one
	turrets: { Turret }?,
	-- set for an aircraft
	air: Aircraft?,
	-- set for something that carries units
	transport: Transport?,
	-- set for something that keeps drones on it and sends them out to fight
	carrier: Carrier?,
	-- set for a plasma deflector
	shield: Shield?,
	-- true for a drone: a unit that belongs to its carrier. It cannot be selected or ordered, is not built
	-- by a factory and leaves no wreck.
	drone: boolean?,
	-- how heavy it is to a transport; nil for something that cannot be carried
	weight_class: WeightClass?,
	-- health it mends by itself every second, whatever it is doing, without a builder or any cost; nil if it does not
	autoheal: number?,
	death_explosion: DeathExplosion?,
	-- turns energy into metal while it is standing and finished; nil if it converts none
	energy_conversion: EnergyConversion?,
	-- energy this generates every second while it is standing and finished; nil if it makes none
	energy_income: number?,
	-- makes this many times the wind speed in energy a second; nil if it does not run on wind
	wind_multiplier: number?,
	-- metal this makes every second while it is standing and finished; nil if it makes none
	metal_income: number?,
	-- shows its team's name over it; only the commander does
	nametag: boolean?,
	-- how far it reaches to build, for something that builds on its own; nil for everything else
	build_range: number?,
	-- storage this adds to its team while it is standing and finished; nil if it adds none
	metal_storage: number?,
	energy_storage: number?,
	-- true for things that can only be built on a metal spot, and are snapped onto it
	requires_metal_spot: boolean?,
	-- false for something that cannot be reclaimed while it stands, and can only be destroyed; its wreck can
	-- still be reclaimed. nil means it can.
	reclaimable: boolean?,
	color: Color3,
}

-- What is left behind when something dies. Reclaiming it applies buildpower exactly the way
-- construction does, paying out metal at metal_total / buildpower_total per unit of buildpower.
export type Wreck = {
	source_def_name: string,
	metal_total: number,
	metal_left: number,
	buildpower_total: number,
	buildpower_left: number,
	-- buildpower put into raising it so far, out of the source def's buildpower_cost
	resurrect_progress: number,
}

export type Entity = {
	id: EntityId,
	team: TeamId,
	def_name: string,
	kind: EntityKind,
	state: EntityState,
	position: Vector3,
	facing: number,
	velocity: Vector3,
	health: number,
	max_health: number,
	-- blueprint accounting; build_progress is measured in buildpower and completes at buildpower_cost
	build_progress: number,
	metal_paid: number,
	energy_paid: number,
	orders: { Order },
	-- production queue, def names, only meaningful for entities with `build_options`
	queue: { string },
	reload_remaining: number,
	-- seconds until a manual weapon can fire again, if the entity has one
	manual_reload_remaining: number,
	-- seconds until each of its turrets can fire again, by turret
	turret_reloads: { number },
	-- missiles held ready, and seconds spent on the next one, if its weapon stockpiles them
	stockpile: number,
	stockpile_progress: number,
	-- tracks burst fire state: how many shots fired in current burst and how many remain
	burst_state: { fired: number, burst_remaining: number }?,
	-- seconds a blueprint has gone without anyone building it; it starts to decay past a limit
	unfed_time: number,
	wreck: Wreck?,
	alive: boolean,
}

export type Team = {
	id: TeamId,
	-- what the team is called, taken from its player's name
	name: string,
	metal: number,
	energy: number,
	metal_income: number,
	energy_income: number,
	metal_capacity: number,
	energy_capacity: number,
	-- what actually came in and went out each second lately, smoothed: every way of gaining the resource, reclaim
	-- included, and every way of spending it. Unlike `*_income` this is what really happened, not what is set up to.
	metal_revenue: number,
	metal_expense: number,
	energy_revenue: number,
	energy_expense: number,
}

-- One entity's claim on the shared resource pool for this tick, gathered before anything is
-- actually spent so that a stall can be spread proportionally across every drain.
export type Drain = {
	entity_id: EntityId,
	team: TeamId,
	target_id: EntityId,
	buildpower: number,
	metal_per_buildpower: number,
	energy_per_buildpower: number,
}

return table.freeze({})
