--!strict
export type EntityId = number
export type TeamId = number

-- A `reclaimable` is a piece of the map, a rock or a tree, that belongs to nobody and is there to be reclaimed for
-- what it holds. It is reclaimed exactly as a wreck is, but it was never anything, so it cannot be raised, and no
-- weapon harms it.
export type EntityKind = "unit" | "building" | "wreck" | "reclaimable"

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
	-- BAR's footprint of the capsule, its collision volume's two horizontal sides, which the art pipeline stretches
	-- models to; the sim uses `radius`
	width: number,
	length: number,
}

export type Collider = BoxCollider | CapsuleCollider

-- `guard` follows a friendly entity, its own team's or an ally's, and a builder guarding one works on whatever it
-- is working on.
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
	| "area_reclaim"
	| "area_repair"
	| "area_resurrect"
	| "area_attack"

export type Order = {
	kind: OrderKind,
	position: Vector3?,
	target_id: EntityId?,
	def_name: string?,
	facing: number?,
	radius: number?,
	-- for an attack or a ground attack, that it is a launch (D): it fires the manual-fire weapons
	-- (`Weapon.manual_fire`), which nothing else fires, and leaves the rest to pick their own targets
	launch: boolean?,
}

-- How a projectile flies once it is launched, whatever its path (`Delivery`): it thrusts along its heading for
-- `thrust_time` seconds, speeding up by `acceleration`, then loses its momentum to drag and gravity and falls. It
-- explodes on whatever it touches, hurting everything within `aoe_radius` of the blast. A shell is a rocket with no
-- thrust and no drag: it leaves the barrel at `speed` and gravity does the rest. All of it is the weapon's, the same
-- for every shot; what differs from one shot to the next is worked out at launch (`projectile.Launch`).
export type ProjectileParams = {
	speed: number,
	acceleration: number,
	thrust_time: number,
	gravity: number,
	-- once its thrust is spent, how hard the air slows it, per stud: it loses `drag` times its speed squared a second
	drag: number,
	aoe_radius: number,
	-- what is left of the blast's damage at its very edge, as a fraction of the damage at its centre
	edge_effectiveness: number?,
	-- half the angle, in radians, of the cone a shot may stray within from its aim; a bomb or a homing projectile does
	-- not stray
	inaccuracy: number?,
	-- how fast a homing projectile turns, in radians a second; HOMING_TURN_RATE (shared/projectile.luau) if nil. BAR's
	-- `turnrate`.
	turn_rate: number?,
	-- how many seconds after it is fired a shell goes off where it is, in the air or not, if it has not struck anything
	-- first: BAR's `burnblow` on a shell with a `flighttime`, which Spring lets burst when its flight time runs out
	fuse: number?,
	-- a shell that goes off where it was aimed, in the air or not, once it has flown as long as it takes to get there:
	-- BAR's `burnblow` on a cannon's shell with no `flighttime`, which Spring gives just long enough to reach its
	-- target. What a flak cannon's shell does, bursting among the aircraft it is fired at.
	burst_at_aim: boolean?,
	-- drawn as a purple neon line this many studs thick, the way BAR draws its anti-air missiles, instead of as a
	-- casing; a heavier anti-air weapon's is thicker. Only how it looks.
	line_thickness: number?,
	-- how it is drawn, in flight and when it goes off; nil for the look its kind has by default. Only how it looks.
	look: ProjectileLook?,
}

-- How a projectile that flies level or straight is steered onto what it is fired at: not at all, fired at where its
-- target is; by leading, fired ahead of a moving target at where it will be by the time the shot gets there (rockets
-- do not home, so one that has to hit something quick needs this); or by homing, tracking its target in flight and
-- steering a little ahead of it (projectile.home), as anti-air missiles and anti-nuke interceptors do.
export type Guidance = "none" | "leads" | "homes"

-- Which arc a lobbed shell is aimed along. At full speed only two reach a target, the high one and the low one; the
-- medium one is the angle halfway between them, launched slower so that it still lands on the target; and "auto"
-- takes the lowest of the low, medium and high ones that has a clear path.
export type Arc = "high" | "medium" | "low" | "auto"

-- How a weapon's shot gets to what it is fired at, which is what everything that flies, aims or draws a shot switches
-- on. Every weapon has exactly one.
--
-- `beam`: a laser or a lightning gun. It strikes the first solid thing on the line to its target at once.
-- `straight`: a rocket, a bolt or a homing missile, fired along a line and steered as its `guidance` says.
-- `lobbed`: a shell aimed along its `arc` so that it comes down on its target. The high, medium and automatic arcs
--   are fired without a line of sight, because the arc carries the shell over whatever is in between.
-- `missile`: goes straight up from its launcher to `climb` studs above it, over to its target at that height, and then
--   down onto it, along a line at least `dive_angle` radians steep. It is stopped by nothing on the way up or across,
--   and only strikes what is in its path once it has turned to come down. It flies at its `speed` throughout, and is
--   aimed at where its target was when it was launched.
-- `bomb`: let go rather than fired, so it leaves its launcher with no launch speed of its own, carried on by the
--   launcher's velocity, and gravity does the rest.
-- `torpedo`: a torpedo or a depth charge, which BAR makes the same weapon: it runs under the water's surface, level, at
--   `speed` gaining `acceleration` for `thrust_time`, and nothing slows it or pulls it down. It is the only weapon
--   that can be aimed at something wholly under the water, and it can be aimed at nothing that is not in the water
--   (`unit_defs.in_water`). Land in its way stops it.
export type Beam = {
	kind: "beam",
	-- how many seconds its beam stays up; it deals its damage over that time (server/beams.luau). Nil for one that deals
	-- it all at once, drawn for the client's usual moment.
	time: number?,
	-- how wide its beam is drawn, in studs, and what colour; without a colour it is its team's
	thickness: number?,
	color: Color3?,
	-- drawn as a heavy charged beam: its muzzle glows brighter as it reloads, and its shot has a hot core, a throbbing
	-- sheath, rings and flashes (client/charged_beam.luau). Only how it looks.
	charged: boolean?,
	-- a lightning gun's sparks, which jump from where it strikes to what is around it
	lightning: Lightning?,
}
-- A homing one is guided for `guidance_time` seconds, after which it stops steering and falls, as BAR's does at the
-- end of its `flighttime`; nil to have that worked out from its range at launch (projectiles.launch). It may be lofted
-- (`loft`), as BAR's `trajectoryheight` lofts a missile: it steers at first for a point above its target, `loft` times
-- the distance to it at launch, and that point sinks onto the target, evenly, over the time the flight takes
-- (`projectile.Shot`'s `loft_height` and `loft_time`). It is launched toward that point too, so it goes up and over
-- and comes down on what it was fired at, over what is in the way.
export type StraightDelivery = {
	kind: "straight",
	guidance: Guidance,
	projectile: ProjectileParams,
	guidance_time: number?,
	loft: number?,
}
export type LobbedDelivery = { kind: "lobbed", arc: Arc, projectile: ProjectileParams }
export type MissileDelivery = { kind: "missile", climb: number, dive_angle: number, projectile: ProjectileParams }
export type BombDelivery = { kind: "bomb", projectile: ProjectileParams }
-- A homing one may be guided for no longer than `guidance_time` seconds, as a straight one may.
export type TorpedoDelivery = {
	kind: "torpedo",
	guidance: Guidance,
	projectile: ProjectileParams,
	guidance_time: number?,
}
-- Every delivery that launches a projectile.
export type ProjectileDelivery = StraightDelivery | LobbedDelivery | MissileDelivery | BombDelivery | TorpedoDelivery
export type Delivery = Beam | ProjectileDelivery

-- How a projectile looks (`ProjectileParams.look`). Every field is optional, and one left out keeps the default for
-- the projectile's kind: a grey casing, glowing plasma, or an anti-air streak, going off in a plain fireball.
export type ProjectileLook = {
	-- its body: how big it is, in studs, lying along the way it flies, and what it is made of
	size: Vector3?,
	color: Color3?,
	material: Enum.Material?,
	-- a ribbon left hanging in the air behind it, which fades over `lifetime` seconds, as wide as `width` where it
	-- leaves the projectile and nothing at its far end
	trail: { color: Color3, width: number, lifetime: number }?,
	-- fire from its tail: `rate` puffs a second, each `size` studs across when it starts, that live `lifetime` seconds
	flame: { color: Color3, size: number, rate: number, lifetime: number }?,
	-- smoke it leaves behind, puffs of `size` that swell as they go and hang in the air for `lifetime` seconds
	smoke: { color: Color3, size: number, rate: number, lifetime: number }?,
	-- a light it casts on what it flies over
	light: { color: Color3, range: number, brightness: number }?,
	-- how it goes off: "fireball", the default, or "nuclear", a blinding flash, a fireball, a mushroom cloud rising
	-- over it and shockwaves racing out along the ground, lighting up the whole view for a moment, or "emp", a pale
	-- turquoise pulse thrown through with lightning
	explosion: ("fireball" | "nuclear" | "emp")?,
}

-- A weapon's turret: it turns about its owner's up axis at `turn_rate` radians a second toward whatever the weapon
-- means to shoot, keeping on it through the reload, and the weapon fires only once it points within `TURRET_TOLERANCE`
-- (server/turrets.luau) radians of it. With nothing to shoot for `TURRET_REST_DELAY` seconds it turns back to face
-- ahead. Its aim is `Entity.weapon_aims`, relative to the way its owner faces.
export type Turret = {
	turn_rate: number,
}

-- Where a weapon on a turret piece of its owner's model fires from (`Weapon.turret_mount`): the point `pivot` the piece
-- turns about, from the model's origin (the ground under the middle of its collider), and the `muzzle`, from the pivot
-- with the turret at rest facing ahead; x to the right, y up, z ahead. Its generator in tools/model_pipeline declares
-- them (unit_defs/turret_mounts.luau), and its art is built to agree.
export type TurretMount = {
	pivot: Vector3,
	muzzle: Vector3,
}

-- Which of the two layers of the world a weapon can shoot at. Aircraft are in the air and everything else
-- is on the ground.
export type TargetLayer = "ground" | "air"

-- What a weapon is: what the HUD calls it and the icon it shows, and what goes with being one of its kind that no
-- other field says, like doing full damage to aircraft or being stopped by a plasma deflector (shared/weapon_kinds).
export type WeaponKind =
	"laser"
	| "heat_ray"
	| "emp_laser"
	| "lightning"
	| "sniper"
	| "flamethrower"
	| "plasma_cannon"
	| "cannon"
	| "gauss"
	| "shotgun"
	| "machine_gun"
	| "flak"
	| "rockets"
	| "missiles"
	| "aa_missiles"
	| "emp_missile"
	| "nuke"
	| "anti_nuke"
	| "torpedo"
	| "depth_charge"
	| "bombs"
	| "emp_bombs"

export type Weapon = {
	kind: WeaponKind,
	damage: number,
	reload: number,
	range: number,
	energy_per_shot: number,
	-- how its shots get to what it fires at
	delivery: Delivery,
	-- where its shots come from, in the entity's own frame: x to its right, y up, z ahead. Nil for a weapon that fires
	-- from its `turret_mount`, or else from the usual spot just above an entity's middle (server/muzzles.luau).
	offset: Vector3?,
	-- where it fires from when it is on a turret piece of its owner's model, which unit_defs gives it from
	-- unit_defs/turret_mounts.luau; never alongside an `offset`
	turret_mount: TurretMount?,
	-- weapons that share a non-nil group share one reload between them: firing either one starts both
	-- reloading, so only one of a group ever fires at a time. BAR's Lasher is this: one ground rocket,
	-- one anti-air missile, one cooldown between them, whichever finds a target first.
	weapon_group: string?,
	-- what it can shoot at: nil for both layers, and a weapon that names one never fires at the other
	target_layer: TargetLayer?,
	-- a weapon that fires from a stockpile of missiles that it builds up over time, rather than from a
	-- reload alone
	stockpile: Stockpile?,
	-- a weapon that fires only at what a launch order (D, `Order.launch`) names, never at what happens to come within
	-- its range nor at what a plain attack order names, like the nuclear silo's
	manual_fire: boolean?,
	-- a weapon that can be fired from under the water, as a submarine's missile is (BAR's `waterweapon` on something
	-- that is not a torpedo); nil for one that, like almost every weapon, cannot
	launches_underwater: boolean?,
	-- a weapon on an aircraft that fires only while it is in the air, never while it sits on the ground
	airborne_only: boolean?,
	-- a weapon on a turret of its own, which has to turn to face what it shoots before it can fire; nil for one
	-- that fires wherever its target is, whichever way its owner faces
	turret: Turret?,
	-- for a weapon fixed facing forward, like a submarine's torpedo tubes: half the angle, in radians, of the cone
	-- ahead of its owner that it fires into. Nothing outside it is shot at; the owner has to turn onto it first. Nil
	-- for one that fires whichever way its target is.
	fire_arc: number?,
	-- where the middle of that cone points, in radians off straight ahead, measured the way `Entity.facing` is: a
	-- weapon mounted on its owner's flank, like the Thor's EMP lasers. Nil for straight ahead.
	fire_direction: number?,
	-- a weapon that fires multiple shots in quick succession before reloading: `burst_count` shots, each
	-- `burst_interval` seconds apart (`unit_defs.burst_interval`), and only once the whole burst is out does the full
	-- `reload` apply before the next one starts. A bomb weapon takes its burst as one shot, as BAR's bombers do: it
	-- starts it once the target is within half the length of the line of bombs it lays of where the first would come
	-- down, so the target is in the middle of the line, and the rest follow the first whatever they will come down on.
	burst_count: number?,
	burst_interval: number?,
	-- an EMP weapon, BAR's `paralyzer`: its damage, from a hit or a blast, goes into the EMP of what it reaches
	-- instead of its health (server/emp.luau), and it stuns for no longer than this many seconds (BAR's
	-- `paralyzetime`). Nil for a weapon that does real damage.
	paralyze_time: number?,
	-- a shell that splits in the air (`Split`), as BAR's `split` special effect has it; nil for one that stays whole
	split: Split?,
}

-- What a shell that splits does (BAR's `speceffect = "split"`, luarules/gadgets/unit_custom_weapons_behaviours.lua):
-- once it starts to come down, it bursts, harmlessly, into `count` shots of `weapon`, each flying on from where it
-- burst with the shell's velocity and a random push of its own, which rain down around what it was fired at. Only
-- `weapon`'s kind, damage and delivery matter: it is never fired on its own.
export type Split = {
	count: number,
	weapon: Weapon,
}

-- What a lightning gun's sparks do, as BAR's lightning splash gadget has them (unit_lightning_splash_dmg.lua): where
-- the bolt ends, up to `forks` other things within `range` studs, nearest first, each take `fork_damage` times the
-- bolt's damage, friend or foe. What the bolt struck is left out, and so is anything armed with a lightning gun of its
-- own, and anything under the water.
export type Lightning = {
	forks: number,
	range: number,
	fork_damage: number,
}

-- What building up missiles takes: every `build_time` seconds one more is finished, at the price of `metal` and
-- `energy`, until `limit` are held. A missile that cannot be paid for yet waits until it can be.
export type Stockpile = {
	limit: number,
	build_time: number,
	metal: number,
	energy: number,
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
	-- how far above the ground it flies, in studs (unit_defs/conversions.altitude)
	altitude: number,
	-- how fast it climbs and descends, in studs a second
	climb_speed: number,
	-- flies over what it attacks and on past it, then turns back for another pass, rather than stopping
	-- to hover over it; what a bomber does
	bombing_runs: boolean?,
	-- flies on wings, as a fighter or a bomber does, and cannot hover
	wings: Wings?,
}

-- What flying on wings is like. Such an aircraft still takes off and lands straight up and down, but in the air it
-- holds its height only by moving forward: while it has something to do it flies flat out, as BAR's planes do, and
-- it turns no faster than `turn_rate`, in radians a second, so where it has nowhere in particular to be it circles.
-- When where it is going is behind it and nearer than `run_out` studs, it holds its heading until it is not, and
-- only then turns back, which is what makes an attack a pass and not a tight circle round the target. Once it has
-- nothing to do it slows to a stop as it comes down.
export type Wings = {
	turn_rate: number,
	run_out: number,
}

-- A shield (server/shields.luau): a sphere of `radius` studs round what carries it that stops enemy shots, plasma shells
-- only for a plasma deflector's (`blocks` "plasma"), or every weapon's (`blocks` "all"), each costing it the shot's
-- damage in `power`. It starts with `starting_power`, and grows back `regen` a second for `regen_energy` energy a
-- second, when the energy is there. One with an `upkeep` is switched on and off, costs that much energy a second
-- while it is up, and grows back only while it is off.
export type Shield = {
	radius: number,
	power: number,
	regen: number,
	regen_energy: number,
	starting_power: number,
	blocks: "plasma" | "all",
	upkeep: { moving: number, standing: number }?,
}

-- What a carrier keeps: up to `count` drones of `drone` out at once, parked on it or flying (BAR's maxunits). While
-- an enemy is within `engage_range` they launch and fight it; when nothing is, or it goes out of range, they fly back
-- and park. It comes with `starting` of them for nothing (BAR's startingdronecount), and builds the rest into a
-- `stockpile`, as a silo builds missiles, each paid for as it is built: with fewer than `count` out, the next is
-- taken from the stockpile, and a drone that is shot down is gone along with what it cost. The stockpile goes on
-- filling while the drones are out, so a carrier can hold a full set in reserve behind a full set out, as BAR's
-- stockpiling carriers do. A drone parked on its carrier is mended by it, `repair_per_second` health a second, for
-- nothing.
export type Carrier = {
	drone: string,
	count: number,
	starting: number,
	stockpile: Stockpile,
	engage_range: number,
	repair_per_second: number,
}

-- How heavy a unit is to a transport. A unit with no weight class cannot be carried at all.
export type WeightClass = "light" | "heavy"

-- What a transport can carry: up to `capacity` things at once. A transport that carries "light" takes light things
-- only, and one that carries "heavy" takes light and heavy ones.
export type Transport = {
	capacity: number,
	carries: WeightClass,
}
--  What something that builds does with its buildpower, `buildpower` of it a second, applied within `range` studs
-- (`order_kinds.BUILD_RANGE` and its like if nil). `options` is what it can build, and it is its own list: the
-- buildings a builder can place, or the units a factory can queue. Nothing shares one, so a unit that is alike another
-- today can change tomorrow. Of the other jobs it does only those it says: help build what another is building or
-- making (`assists`), mend what is hurt (`repairs`), take things apart for what they are worth (`reclaims`), and raise
-- a
-- unit's wreck, putting its metal back and then its buildpower into bringing it back (`resurrects`).
export type Builder = {
	buildpower: number,
	range: number?,
	options: { string }?,
	assists: boolean?,
	repairs: boolean?,
	reclaims: boolean?,
	resurrects: boolean?,
}

-- BAR's movement classes (gamedata/movedefs.lua) that something here moves by; `shared/move_classes` has what each is.
export type MoveClassName =
	"COMMANDERBOT"
	| "BOT2"
	| "BOT3"
	| "ABOT3"
	| "SBOT2"
	| "HBOT4"
	| "HBOT7"
	| "VBOT6"
	| "HABOT5"
	| "TBOT3"
	| "HTBOT6"
	| "TANK2"
	| "TANK3"
	| "HTANK4"
	| "HTANK7"
	| "MTANK3"
	| "ATANK3"
	| "HOVER2"
	| "HOVER3"
	| "BOAT3"
	| "BOAT4"
	| "BOAT5"
	| "BOAT9"
	| "UBOAT4"

-- How something meets the water. "ground": it stands on the ground, under water no deeper than its footing allows.
-- "float": it floats on the surface, a ship or a building built on the sea, and needs water at least so deep. "hover":
-- a hovercraft, which rides the surface over water of any depth and the ground where there is none, and is never in
-- the water, so no torpedo is aimed at it.
export type WaterMode = "ground" | "float" | "hover"

-- How a movement class slows in the water, BAR's `depthModParams`, in elmos as BAR has them: in water at least
-- `min_depth` deep (`minHeight`) it goes 1 / (`quadratic` * depth² + `linear` * depth + `constant`) as fast, that
-- divisor held to at most `max_scale` (`maxScale`). See move_classes.speed_in_water.
export type DepthMod = {
	min_depth: number,
	constant: number,
	linear: number,
	quadratic: number,
	max_scale: number,
}

-- A movement class: the steepest ground it can stand on, in degrees (BAR's `maxslope`; nil for one held to no slope,
-- a ship's), how it meets the water, the deepest water it goes into (nil for no limit), whether it runs on tracks
-- or wheels, and so is drawn as a car rather than a bot, and how it slows in the water (nil for not at all).
export type MoveClass = {
	max_slope: number?,
	water: WaterMode,
	max_water_depth: number?,
	vehicle: boolean,
	depth_mod: DepthMod?,
}

-- Where something can be and how it rests there, what placement, movement, drowning and the pathfinder all read.
-- `class` is the movement class of anything that moves over the ground or the water (nil for buildings, aircraft and
-- reclaimables). `max_depth` is the deepest water it may stand in and `min_depth` the shallowest it may float on, in
-- studs; `waterline` is how far below the surface a submarine's underside rides (BAR's `waterline`), 0 for everything
-- else. Built by unit_defs/footing.luau from the class and what the unit's own file says.
export type Footing = {
	class: MoveClassName?,
	water: WaterMode,
	max_depth: number,
	min_depth: number,
	waterline: number,
}

-- What a def is filed under, for the lobby's encyclopedia and anything else that lists defs by what they are.
export type Category =
	"bots"
	| "vehicles"
	| "hover"
	| "ships"
	| "aircraft"
	| "experimental"
	| "factories"
	| "economy"
	| "defences"
	| "scavengers"
	| "campaign"
	| "scenery"

-- What a unit is to its side, where that decides how the game treats it. A commander is what a side stands or falls
-- by: losing every one loses the game, it always leaves its wreck, an enemy's blocks a disintegrator, and its team's
-- name is shown over it. A drone is a part of its carrier: it cannot be selected or ordered, is not built by a factory,
-- leaves no wreck and is no loss. A boss is what the scavengers end with (server/scavengers): destroying it wins the
-- game against them, it is never taken away for getting nowhere, and its wreck never stands up again as theirs. A beacon
-- is what the scavengers come from: it makes their units and defences round itself, and their boss comes once the last
-- falls.
export type Role = "commander" | "drone" | "boss" | "beacon"

-- The spots a building can be bound to: a metal spot, for an extractor, or a geothermal vent.
export type SpotKind = "metal" | "geo"

-- What harms it: nothing but a manual weapon, no weapon, blast or death explosion, hurts the one; nothing at all, the
-- manual weapon included, hurts the other.
export type DamageImmunity = "all_but_manual_weapon" | "all"

-- How a reclaimable is drawn and where a generated map lays it. `art` is its art in Shared.reclaimable_art, stretched
-- to its collider (and the shape drawn instead while that loads); `shadowless` art casts no shadow, since thousands of
-- low rocks and shrubs cost far more in shadows than they show; and `ground` is the ground it is laid on, soil for
-- what grows and any dry ground for the rest.
export type Feature = {
	art: "rock" | "tree" | "shrub",
	shadowless: boolean?,
	ground: "soil" | "any",
}

-- A def lists only what it has: every optional field below is nil for something that has none of it.
export type EntityDef = {
	name: string,
	display_name: string,
	-- what it is in plain words, shown under its name
	subtitle: string?,
	kind: EntityKind,
	category: Category,
	-- the tech level of what makes it, for a unit, 1 for the first labs, 2 for the advanced ones and 3 for the gantry,
	-- and 1.5, between the two, for the Seaplane Platform, as BAR has it; nil for buildings and scenery, which are not
	-- filed by one
	tech_level: number?,
	role: Role?,
	collider: Collider,
	footing: Footing,
	metal_cost: number,
	energy_cost: number,
	buildpower_cost: number,
	-- nil for what no weapon wears down (`damage_immunity`): it has no health to lose (`unit_defs.max_health`)
	health: number?,
	builder: Builder?,
	-- how fast it gets going and how fast it goes; nil for what never moves
	acceleration: number?,
	max_speed: number?,
	-- every weapon this entity carries, each independently targeted, reloaded and fired, save that
	-- weapons sharing a `weapon_group` reload together
	weapons: { Weapon }?,
	manual_weapon: ManualWeapon?,
	air: Aircraft?,
	-- set for something that carries units
	transport: Transport?,
	-- set for something that keeps drones on it and sends them out to fight
	carrier: Carrier?,
	-- set for a plasma deflector
	shield: Shield?,
	-- how heavy it is to a transport; nil for something that cannot be carried
	weight_class: WeightClass?,
	-- hard to pick out: an enemy weapon only picks it to shoot at from within `STEALTH_DETECTION_RANGE`
	-- (server/targeting.luau), however far it reaches, though one ordered to attack it still can
	stealth: boolean?,
	-- health it mends by itself every second, whatever it is doing, without a builder or any cost
	autoheal: number?,
	-- how much of the EMP that reaches it it shrugs off, from 0 to 1: 1 is never stunned, and no EMP weapon aims at it.
	-- BAR's `paralyzemultiplier` is 1 minus this. Nil for 0.
	emp_resistance: number?,
	death_explosion: DeathExplosion?,
	-- BAR's selfdestructcountdown: how long it counts down once told to destroy itself (see server/self_destruct.luau);
	-- nil for BAR's usual 5
	self_destruct_countdown: number?,
	-- turns energy into metal while it is standing and finished
	energy_conversion: EnergyConversion?,
	-- energy this generates every second while it is standing and finished
	energy_income: number?,
	-- makes this many times the wind speed in energy a second
	wind_multiplier: number?,
	-- for a tidal generator: the energy it makes a second is the tidal strength (`environment`) times this
	tidal_multiplier: number?,
	-- metal this makes every second while it is standing and finished
	metal_income: number?,
	-- storage this adds to its team while it is standing and finished
	metal_storage: number?,
	energy_storage: number?,
	-- the kind of spot it can only be built on, and is snapped onto
	spot: SpotKind?,
	-- the def this is built over in place, on the same spot, as an advanced extractor is over a plain one: that one
	-- does not block it, and is taken down and its metal refunded when this is finished
	upgrades: { string }?,
	-- false for something that cannot be reclaimed while it stands, and can only be destroyed; its wreck can still be
	-- reclaimed. Nil means it can.
	reclaim_while_standing: boolean?,
	damage_immunity: DamageImmunity?,
	-- BAR's `objectify`: put down to be in the way, like a wall, and so treated as a piece of the map rather than
	-- something of the enemy's to go and destroy
	objectify: boolean?,
	-- set for a reclaimable
	feature: Feature?,
	color: Color3,
}

-- What a wreck was, for raising it again: the def of what died (its own def is its wreck's, `unit_defs.wreck_of`), and
-- the buildpower put into raising it so far, out of that def's buildpower_cost.
export type Wreck = {
	source_def_name: string,
	resurrect_progress: number,
}

-- What remains hold (a wreck or a reclaimable) and what is left of it. Reclaiming them applies buildpower out of the
-- buildpower total, and pays out the metal and energy totals in proportion. The totals are the def's metal_cost,
-- energy_cost and buildpower_cost (a wreck's own def's: half the metal of what died, over a fifth of its buildpower),
-- unless the map says otherwise for a reclaimable, as a BAR map does for each of its features.
export type Yield = {
	metal_total: number,
	energy_total: number,
	buildpower_total: number,
	metal_left: number,
	energy_left: number,
	buildpower_left: number,
}

-- What a reclaimable holds, when it is not what its def says.
export type Holds = {
	metal: number,
	energy: number,
	buildpower: number,
}

-- What a stockpile (`Stockpile`) holds: how many are finished and held ready, and seconds spent on the next one.
export type Stocked = {
	held: number,
	progress: number,
}

-- Everything an entity is and has that lasts, and that more than one part of the game reads: what it is, where, how
-- whole, its orders, what its weapons have ready. What one part of the game keeps about what it is doing with an
-- entity, like a lab's blueprint in progress or a builder's wait at its site, is that part's own, by entity id, and
-- forgotten when the entity is (server/bootstrap.luau's FORGETTERS).
export type Entity = {
	id: EntityId,
	team: TeamId,
	-- the name of what it is, which is what it is drawn as: for a wreck, what died
	def_name: string,
	-- the skin it wears (shared/skins), from its team's when it was made; nil for a wreck or a reclaimable, which
	-- wear none
	skin: string?,
	-- its def, as it has it: `def_name`'s through its skin (`unit_defs.skinned`), or a wreck's own
	-- (`unit_defs.wreck_of`). Everything the sim reads of what an entity is reads it here.
	def: EntityDef,
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
	-- production queue, def names, only meaningful for entities whose builder has `options`
	queue: { string },
	-- seconds until a manual weapon can fire again, if the entity has one
	manual_reload_remaining: number,
	-- seconds until each of its weapons can fire again, by weapon: a weapon sharing a `weapon_group`
	-- with an earlier one in the list reads and writes that one's slot instead of its own
	weapon_reloads: { number },
	-- tracks burst fire state for each weapon, by weapon, if it has a burst
	weapon_burst_remaining: { number },
	-- what each weapon that stockpiles its missiles holds (`Weapon.stockpile`), by weapon
	weapon_stockpiles: { [number]: Stocked },
	-- for a carrier, the drones it holds ready to launch (`Carrier.stockpile`)
	drone_stockpile: Stocked?,
	-- where each weapon with a turret points, by weapon, in radians about the up axis from the way the entity faces
	weapon_aims: { number },
	-- seconds a blueprint has gone without anyone building it; it starts to decay past a limit
	unfed_time: number,
	-- set for a wreck
	wreck: Wreck?,
	-- set for remains, a wreck or a reclaimable
	yield: Yield?,
	-- what it has done to enemies: how many it has killed, the damage it has dealt them (not counting what went past
	-- their last hit point), that damage weighed as the targeting weighs it, in power (`unit_defs.power`) taken off
	-- them, and the experience all that has earned it (see server/credit.luau)
	kills: number,
	damage_dealt: number,
	score_dealt: number,
	experience: number,
	-- EMP it has taken, BAR's paralyze damage, in health points: it is stunned while this is at least its max health,
	-- and it drains away steadily (server/emp.luau)
	emp: number,
	alive: boolean,
}

export type Team = {
	id: TeamId,
	-- what the team is called, taken from its player's name
	name: string,
	-- the skin everything it makes from now on wears (shared/skins)
	skin: string,
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

-- A resource a team banks, and can give an ally (ShareResources).
export type Resource = "metal" | "energy"

-- Whose team a team in the player list is, to the player it is sent to (RosterUpdated): their own, an ally's, an
-- enemy's, or, to a spectator, one being watched.
export type RosterRelation = "self" | "ally" | "enemy" | "watched"

-- What the player list is told of a team's bank: only ever for the player's own team and their allies.
export type Bank = {
	metal: number,
	energy: number,
	metal_capacity: number,
	energy_capacity: number,
}

-- A team in the player list (RosterUpdated, server/sharing.luau).
export type RosterEntry = {
	team_id: TeamId,
	name: string,
	-- the UserId of the team's player for their headshot, or 0 for a team with nobody on it
	user_id: number,
	color: Color3,
	relation: RosterRelation,
	bank: Bank?,
}

-- What a notice a player is sent is about (Notify, server/notifications.luau), which is what the toast says
-- (client/ui/notifications.luau): an ally asks for metal or sent some, your base or commander is under attack, an enemy
-- has aircraft or an atomic bomber, an enemy has launched a nuke, and, in the third campaign mission
-- (server/missions/counterattack.luau), a building put where the enemy will land and a wave on its way.
export type NoticeKind =
	"metal_request"
	| "metal_sent"
	| "base_attacked"
	| "commander_attacked"
	| "air_detected"
	| "atomic_bomber_detected"
	| "nuke_launched"
	| "enemy_zone"
	| "wave"
	| "final_wave"

-- A value for each NoticeKind, so that a table of them does not check unless it has every one.
export type PerNoticeKind<T> = {
	metal_request: T,
	metal_sent: T,
	base_attacked: T,
	commander_attacked: T,
	air_detected: T,
	atomic_bomber_detected: T,
	nuke_launched: T,
	enemy_zone: T,
	wave: T,
	final_wave: T,
}

-- A notice as it is sent (Notify).
export type Notice = {
	kind: NoticeKind,
	-- the team it is about, for an ally's request or gift: its name and colour
	from: string?,
	color: Color3?,
	-- how much metal, for an ally's request or gift, and which wave
	amount: number?,
	-- where it is happening, for a base or commander under attack, a building in the enemy's way, or a wave
	at: Vector3?,
}

-- What a player is told of their own team's resources a few times a second (TeamUpdated): `Team`'s numbers.
export type TeamResources = {
	metal: number,
	energy: number,
	metal_capacity: number,
	energy_capacity: number,
	metal_income: number,
	energy_income: number,
	metal_revenue: number,
	metal_expense: number,
	energy_revenue: number,
	energy_expense: number,
}

-- One team's resources in the list of every team's a spectator is told (TeamsUpdated): a list, since a remote garbles
-- a table keyed by scattered numbers.
export type TeamsEntry = {
	team: number,
	resources: TeamResources,
}

return table.freeze({})
