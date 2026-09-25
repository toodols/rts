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
	-- once its thrust is spent, how hard the air slows it, per stud: it loses `drag` times its speed squared a second
	drag: number,
	aoe_radius: number,
	-- what is left of the blast's damage at its very edge, as a fraction of the damage at its centre
	edge_effectiveness: number?,
	arc: ("high" | "medium" | "low" | "auto")?,
	-- half the angle, in radians, of the cone a lobbed shell or a straight shot may stray within from its aim; a bomb
	-- or a homing missile does not stray
	inaccuracy: number?,
	-- a bomb: it is let go rather than fired, so it leaves its launcher with no launch speed of its own, carried
	-- on by the launcher's velocity, and gravity does the rest
	dropped: boolean?,
	-- fired ahead of a moving target, at where it will be by the time the rocket gets there, and not at where it
	-- is. Rockets do not home, so a missile that has to hit something quick, like an aircraft, needs it.
	leads: boolean?,
	-- homes on its target, tracking it in flight and steering a little ahead of it (projectile.home). Used by anti-air
	-- weapons and anti-nuke interceptors.
	homing: boolean?,
	-- how fast a homing projectile turns, in radians a second; config.HOMING_TURN_RATE if nil. BAR's `turnrate`.
	turn_rate: number?,
	-- how many seconds a homing projectile is guided for, after which it stops steering and falls, as BAR's does at
	-- the end of its `flighttime`. Worked out from the weapon's range at launch if nil (see projectiles.launch).
	guidance_time: number?,
	-- where a homing projectile steers for, off its target's middle: nothing for most shots, and just clear of its
	-- collider for the few that are to miss (config.HOMING_MISS_CHANCE). Set for each shot at launch.
	aim_offset: Vector3?,
	-- a missile that goes up and comes down on its target rather than flying at it
	missile: Missile?,
	-- a plasma shell: one that a plasma deflector stops. Rockets, missiles and beams are not.
	plasma: boolean?,
	-- a nuclear missile: used to distinguish nuke projectiles from other missiles for anti-nuke targeting
	nuclear: boolean?,
	-- drawn as a purple neon line this many studs thick, the way BAR draws its anti-air missiles, instead of as a
	-- casing; a heavier anti-air weapon's is thicker. Only how it looks.
	line_thickness: number?,
	-- a torpedo, or a depth charge, which BAR makes the same weapon: it runs under the water's surface, level, at
	-- `speed` gaining `acceleration` for `thrust_time`, and nothing slows it or pulls it down. It is the only
	-- weapon that can be aimed at something wholly under the water, and it can be aimed at nothing that is not in
	-- the water (`unit_defs.in_water`). Land in its way stops it.
	torpedo: boolean?,
	-- goes through what it strikes rather than going off on it, as BAR's `noexplode` gauss ball does: for every
	-- thirtieth of a second it spends inside something it goes off again, blast and all, and it flies on until it
	-- comes down on the ground, where it goes off one last time
	pierce: boolean?,
	-- how it is drawn, in flight and when it goes off; nil for the look its kind has by default. Only how it looks.
	look: ProjectileLook?,
}

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
-- means to shoot, keeping on it through the reload, and the weapon fires only once it points within `tolerance`
-- radians of it (`config.TURRET_TOLERANCE` if nil). With nothing to shoot for `config.TURRET_REST_DELAY` seconds it
-- turns back to face ahead. Its aim is `Entity.weapon_aims`, relative to the way its owner faces.
export type Turret = {
	turn_rate: number,
	tolerance: number?,
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

-- What a weapon is, where nothing else about it says: only what the HUD calls it and the icon it shows. A weapon with
-- no kind is named from what it does (a beam is a laser, a shell that is not plasma a cannon, ...).
export type WeaponKind = "heat_ray" | "flamethrower" | "shotgun" | "sniper" | "machine_gun" | "depth_charge" | "flak"

export type Weapon = {
	damage: number,
	reload: number,
	range: number,
	energy_per_shot: number,
	-- what it is, for the HUD, when that cannot be told from the rest (WeaponKind). Only how it is shown.
	kind: WeaponKind?,
	-- where its shots come from, in the entity's own frame: x to its right, y up, z ahead. Nil for a
	-- weapon that fires from the usual spot just above an entity's middle, like a single-weapon unit's
	-- always did before every weapon lived in one list.
	offset: Vector3?,
	-- weapons that share a non-nil group share one reload between them: firing either one starts both
	-- reloading, so only one of a group ever fires at a time. BAR's Lasher is this: one ground rocket,
	-- one anti-air missile, one cooldown between them, whichever finds a target first.
	weapon_group: string?,
	-- a dedicated anti air weapon does its full damage to aircraft; any other does only a fraction of it
	-- (`config.NON_AA_AIR_DAMAGE_FRACTION`)
	anti_air: boolean?,
	-- a weapon dedicated to intercepting nuclear missiles in flight
	anti_nuke: boolean?,
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
	-- for a laser, whether it is drawn as a heavy charged beam: its muzzle glows brighter as it reloads, and its shot
	-- has a hot core, a throbbing sheath, rings and flashes (client/charged_beam.luau). Only how it looks.
	charged_beam: boolean?,
	-- a weapon that fires from a stockpile of missiles that it builds up over time, rather than from a
	-- reload alone
	stockpile: Stockpile?,
	-- a weapon that fires only at what an attack or ground attack order names, never at what happens to come within
	-- its range, like the nuclear silo's
	manual_fire: boolean?,
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
	-- a lightning gun: it strikes the first solid thing on its line as a laser does, and sparks jump from where it
	-- strikes to what is around it (`Lightning`)
	lightning: Lightning?,
	-- a weapon that fires multiple shots in quick succession before reloading: `burst_count` shots,
	-- each `burst_interval` seconds apart (a short default when this is not given), and only once the
	-- whole burst is out does the full `reload` apply before the next one starts. A weapon whose projectile
	-- is `dropped` takes its burst as one shot, as BAR's bombers do: it starts it once the target is within half
	-- the length of the line of bombs it lays of where the first would come down, so the target is in the middle
	-- of the line, and the rest follow the first whatever they will come down on.
	burst_count: number?,
	burst_interval: number?,
	-- an EMP weapon, BAR's `paralyzer`: its damage, from a hit or a blast, goes into the EMP of what it reaches
	-- instead of its health (server/emp.luau), and it stuns for no longer than this many seconds (BAR's
	-- `paralyzetime`). Nil for a weapon that does real damage.
	paralyze_time: number?,
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
	-- how far above the ground it flies, in studs
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

-- Where something is in the timed animation its weapons wait on, and how many ticks it has been there. Something
-- with no `popup` is always "open". One that has one starts "closed", is "opening" for `Popup.open_ticks` once it
-- has something to shoot, stays "open" while it does, and after `Popup.linger_ticks` with nothing is "closing" for
-- `Popup.close_ticks` back to "closed". Its weapons fire only while it is "open"; they reload whatever it is doing.
export type AnimationState = "closed" | "opening" | "open" | "closing"

export type Animation = {
	state: AnimationState,
	ticks: number,
}

-- A pop-up: something that has to unfold before its weapons can fire, and folds away again once it has had nothing
-- to shoot for a while. All three are in simulation ticks.
export type Popup = {
	open_ticks: number,
	close_ticks: number,
	linger_ticks: number,
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

-- The tiers of how rare something is made to look on an unlock's card and in the lobby's encyclopedia, plainest first
-- (unlock_reveal's TIERS, by their tags). Not a tech tier: a T1 unit can be rare.
export type TierTag = "common" | "uncommon" | "rare" | "epic" | "legendary" | "mythic"

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
	-- a hovercraft: it rides the surface over water of any depth, like a ship, and the ground where there is no water,
	-- and is never in the water, so no torpedo is aimed at it. Nil for everything else.
	hover: boolean?,
	-- for a submarine, a ship that goes under: how far below the water's surface its underside rides, in studs,
	-- as BAR's `waterline` has it. Nil for everything that floats on top, or does not float at all.
	waterline: number?,
	-- what this entity can build, and it is its own list: the buildings a builder can place, or the units a
	-- factory can queue. Nothing shares one, so a unit that is alike another today can change tomorrow.
	build_options: { string }?,
	-- for a factory: where inside its footprint it puts down the blueprint of what it makes, in studs from its centre,
	-- X to its right and Y toward its doorway. Nil for the centre.
	production_offset: Vector2?,
	-- every weapon this entity carries, each independently targeted, reloaded and fired, save that
	-- weapons sharing a `weapon_group` reload together. Nil for anything unarmed.
	weapons: { Weapon }?,
	manual_weapon: ManualWeapon?,
	-- set for something whose weapons only fire once it has unfolded (see `Animation`)
	popup: Popup?,
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
	-- hard to pick out: an enemy weapon only picks it to shoot at from within `config.STEALTH_DETECTION_RANGE`, however
	-- far it reaches, though one ordered to attack it still can. Nil for everything that is not.
	stealth: boolean?,
	-- health it mends by itself every second, whatever it is doing, without a builder or any cost; nil if it does not
	autoheal: number?,
	-- how much of the EMP that reaches it it shrugs off, from 0 to 1: 1 is never stunned, and no EMP weapon aims at it.
	-- BAR's `paralyzemultiplier` is 1 minus this. Nil for 0.
	emp_resistance: number?,
	death_explosion: DeathExplosion?,
	-- BAR's selfdestructcountdown: how long it counts down once told to destroy itself (see server/self_destruct.luau);
	-- nil for BAR's usual 5
	self_destruct_countdown: number?,
	-- turns energy into metal while it is standing and finished; nil if it converts none
	energy_conversion: EnergyConversion?,
	-- energy this generates every second while it is standing and finished; nil if it makes none
	energy_income: number?,
	-- makes this many times the wind speed in energy a second; nil if it does not run on wind
	wind_multiplier: number?,
	-- for a tidal generator: the energy it makes a second is the tidal strength (`environment`) times this
	tidal_multiplier: number?,
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
	-- true for things that can only be built on a geothermal vent, and are snapped onto it
	requires_geo_spot: boolean?,
	-- the def this is built over in place, on the same spot, as an advanced extractor is over a plain one: that one
	-- does not block it, and is taken down and its metal refunded when this is finished
	upgrades: { string }?,
	-- false for something that cannot be reclaimed while it stands, and can only be destroyed; its wreck can
	-- still be reclaimed. nil means it can.
	reclaimable: boolean?,
	-- how rare it is made to look, over the tier its cost would give it (unlock_reveal's `tier_of`); nil for that tier
	tier: TierTag?,
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

-- What a reclaimable holds and what is left of it. Reclaiming it applies buildpower the way reclaiming a wreck does, out
-- of its buildpower total, and pays out its metal and energy totals in proportion. The totals are its def's metal_cost,
-- energy_cost and buildpower_cost unless the map says otherwise, as a BAR map does for each of its features.
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

-- What a skin does to the numbers of whatever wears it, each as a multiplier; one left out is 1. A skin with none is
-- only a look. `range` stretches every weapon's reach, and a lobbed shell is fired faster to match, so it lands there.
export type SkinStats = {
	health: number?,
	damage: number?,
	range: number?,
}

-- How a skin repaints the art of what wears it: every piece that does not glow is `color` in `material`. With
-- `keep_team`, the team-coloured pieces keep their team colour, so whose it is still reads.
export type SkinPaint = {
	color: Color3,
	material: Enum.Material,
	reflectance: number?,
	keep_team: boolean?,
}

-- One kind of pool float (DonutSettings.variants): the art it is drawn in (shared/art), lying flat about its own middle,
-- the radius of its hole in that art's units, and how often it turns up against the others.
export type DonutVariant = {
	art: string,
	hole: number,
	weight: number,
}

-- A pool donut, an inflatable swim ring worn round the waist (client/donuts.luau); an aircraft wears it round its
-- fuselage, its hole facing the nose, and a ship hangs a row of small ones down each side of its hull instead. Which
-- of `variants` a unit wears is its own, from its entity id, and the same for every player. It pops when what wears it
-- is hit, and on an aircraft it shakes above `shake_speed` (a fraction of its top speed) and flies off after
-- `fly_off_seconds` of that. On something that has been under the water, deeper than `submerge_depth` studs, for
-- `submerge_seconds`, it comes off and floats up to lie on the surface for `float_seconds`. Once nothing has knocked it
-- off for `regen_seconds`, and what wears it is out of the water, a new one inflates. It is only a look: none of it
-- touches the sim.
export type DonutSettings = {
	regen_seconds: number,
	shake_speed: number,
	fly_off_seconds: number,
	submerge_depth: number,
	submerge_seconds: number,
	float_seconds: number,
	variants: { DonutVariant },
	-- how wide its hole is against the radius of what wears it (its collider), so it is as big as the unit is
	hug: number,
	-- how far up the body it is worn, from the bottom of the body (0) to its top (1): its waist
	waist: number,
	-- on an aircraft: how wide its hole is against the fuselage's half thickness, and how far along the fuselage it is
	-- worn, from its tail (0) to its nose (1)
	fuselage_hug: number,
	nose: number,
	-- on a ship: how wide each one's hole is against the hull's width, how far up the body they hang (as `waist`) and
	-- then how many of their own widths lower than that (though never with their middles under its bottom, the
	-- waterline), how far apart their middles are against how wide each is, and how much of the hull's length is room
	-- for more of them
	side_hole: number,
	side_height: number,
	side_drop: number,
	side_spacing: number,
	side_span: number,
}

-- Something a skin hangs on what wears it, for the kinds of entity listed in `kinds`.
export type SkinAttachment = {
	kind: "donut",
	kinds: { EntityKind },
	donut: DonutSettings,
}

-- Another look for the same units (shared/skins). A skin may give a def other art altogether (`art`, def name to the
-- name of the art to draw instead), repaint it (`paint`), hang things on it (`attachments`), and, for a developer's
-- skin only, change its numbers (`stats`).
export type Skin = {
	name: string,
	display_name: string,
	description: string,
	-- only a developer may put it on, which any skin with `stats` has to be
	developer_only: boolean,
	stats: SkinStats?,
	art: { [string]: string }?,
	paint: SkinPaint?,
	attachments: { SkinAttachment },
}

export type Entity = {
	id: EntityId,
	team: TeamId,
	def_name: string,
	-- the skin it wears (shared/skins), from its team's when it was made; nil for a wreck or a reclaimable, which
	-- wear none. `unit_defs.of` reads its numbers through it.
	skin: string?,
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
	-- seconds until a manual weapon can fire again, if the entity has one
	manual_reload_remaining: number,
	-- seconds until each of its weapons can fire again, by weapon: a weapon sharing a `weapon_group`
	-- with an earlier one in the list reads and writes that one's slot instead of its own
	weapon_reloads: { number },
	-- tracks burst fire state for each weapon, by weapon, if it has a burst
	weapon_burst_remaining: { number },
	-- missiles held ready, and seconds spent on the next one, by weapon, for whichever stockpile theirs
	weapon_stockpiles: { number },
	weapon_stockpile_progress: { number },
	-- for a carrier, drones built and held ready to launch, and seconds spent on the next one (`Carrier.stockpile`)
	drone_stockpile: number,
	drone_stockpile_progress: number,
	-- where each weapon with a turret points, by weapon, in radians about the up axis from the way the entity faces
	weapon_aims: { number },
	-- where it is in the timed animation its weapons wait on
	animation: Animation,
	-- seconds a blueprint has gone without anyone building it; it starts to decay past a limit
	unfed_time: number,
	wreck: Wreck?,
	-- set for a reclaimable
	yield: Yield?,
	-- what it has done to enemies: how many it has killed, the damage it has dealt them (not counting what went past
	-- their last hit point), that damage weighed as the targeting weighs it, in power (`unit_defs.power`) taken off
	-- them, and the experience all that has earned it (see `combat.credit`)
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
