-- Every tunable that is not a property of a single unit type lives here.

-- The simulation runs on a fixed step so that build rates, reload timers and acceleration are
-- independent of frame rate. Render frames interpolate between steps on the client.
local TICK_RATE = 20
local TICK_DELTA = 1 / TICK_RATE

-- The heightmap grid. 4 studs matches Roblox's terrain voxel resolution exactly, so deformation
-- rewrites voxels one-to-one with the cells it edits.
local CELL_STUDS = 4
-- 192 cells is 768 studs a side, three times the 256 the map used to be. The fog is scaled from the map
-- size, so the far edge still dissolves into the horizon rather than cutting off.
-- That is the size of the maps made from a seed; a map brought over from BAR is as big as it is there (see
-- map_presets' `Preset.size`).
local MAP_CELLS_X = 192
local MAP_CELLS_Z = 192
-- BAR measures distance in elmos. One stud is 11 of them, because the Peewee's 22 elmo wide collision cylinder is a 2
-- stud wide capsule; every length brought over from BAR, units and maps alike, goes through this one number.
local ELMOS_PER_STUD = 11
local TERRAIN_BASE_HEIGHT = 4
-- Gentler relief, so a smaller map still leaves plenty of ground flat enough to build on.
local TERRAIN_AMPLITUDE = 9
local TERRAIN_FREQUENCY = 0.012
-- Broad basins laid under the hills, wide and deep enough to take the ground below sea level.
local TERRAIN_BASIN_AMPLITUDE = 14
local TERRAIN_BASIN_FREQUENCY_FACTOR = 0.35

-- The sea. Ground below this height is under water, as deep as the ground is far under it. Whether a
-- thing may stand there is up to its def: land units cannot, amphibious ones like the commander can, and
-- ships need it.
local WATER_LEVEL = 0
-- Something that cannot stand in water drowns if it is in it anyway, losing all its health over DROWN_SECONDS. Water
-- shallower than what it tolerates plus DROWN_DEPTH_MARGIN studs is not counted, so that a unit pushed a hair into the
-- shore is not drowned for it.
local DROWN_SECONDS = 5
local DROWN_DEPTH_MARGIN = 0.5

-- A weapon that takes longer than this many seconds to reload shows a bar over its owner for how far along it is.
local RELOAD_BAR_MIN_SECONDS = 5

-- How near a weapon's turret has to point to what it is shooting before it fires, in radians, for a turret that
-- does not say, and how long it waits with nothing to shoot before turning back to face ahead, in seconds.
local TURRET_TOLERANCE = math.rad(3)
local TURRET_REST_DELAY = 3

-- Explosions press a crater into the ground, but only very softly: the deepest a single one goes is
-- DEFORM_MAX_DEPTH studs, which even a huge blast only approaches (depth is that times 1 - e^(-damage /
-- DEFORM_DAMAGE_SCALE)), and blasts too weak to make DEFORM_MIN_DEPTH are ignored. Ground pushed aside
-- piles up in a rim from the crater's edge out to DEFORM_RIM_REACH times its radius, DEFORM_RIM_FRACTION
-- as high as the crater is deep. A blast too small to cover a grid cell is treated as one of
-- DEFORM_MIN_RADIUS. However many land in one place, no sample ends up further than DEFORM_MAX_TOTAL
-- studs from where the map generated it.
local DEFORM_MAX_DEPTH = 1
local DEFORM_DAMAGE_SCALE = 600
local DEFORM_MIN_DEPTH = 0.02
local DEFORM_RIM_FRACTION = 0.3
local DEFORM_RIM_REACH = 1.6
local DEFORM_MIN_RADIUS = CELL_STUDS * 1.5
local DEFORM_MAX_TOTAL = 4

-- A building may only be placed where the ground under its footprint varies by less than this.
local MAX_BUILD_SLOPE_STUDS = 3

-- Teams start on a ring around the map centre, one slot every 360 / START_SLOTS degrees, so
-- nobody opens inside anybody else. Metal spots are laid out around the same points.
local START_RING_RADIUS = 210
local START_SLOTS = 4
-- Once every player has loaded in and chosen a start, the game starts after this many seconds (see lobby.luau).
local START_COUNTDOWN_SECONDS = 3

-- A metal extractor locks onto the closest metal spot to the cursor, however far away it is; this
-- is how close that spot has to be, which is no limit at all.
local METAL_SPOT_SNAP = math.huge

local STARTING_METAL = 1000
local STARTING_ENERGY = 1000
-- What a team has with nothing built: no income, and room for only 500 of each. Its commander and
-- its generators, extractors and stores add to these.
local METAL_INCOME = 0
local ENERGY_INCOME = 0
-- Converters only run while a team's energy is above this fraction of its storage, so that turning
-- energy into metal never leaves it with none to build with.
local CONVERTER_THRESHOLD = 0.5
local METAL_CAPACITY = 500
local ENERGY_CAPACITY = 500

-- Wind is a 2D vector, (x, z), whose length stays between the least and most wind: it lives in an annulus. Every
-- WIND_INTERVAL seconds it moves by a random vector up to WIND_MAX_DELTA long, and if that carries it out
-- of the annulus its length is pulled back in, or pushed out, to the nearest edge. MIN_WIND and MAX_WIND, and
-- TIDAL_STRENGTH, the energy a tidal generator makes, are only the defaults, for a map that does not set its own
-- (see environment.luau).
local MIN_WIND = 1
local MAX_WIND = 15
local TIDAL_STRENGTH = 15
local WIND_INTERVAL = 5
local WIND_MAX_DELTA = 4

-- Fraction of a dead entity's metal that survives into its wreck, and the fraction of its
-- buildpower_cost that reclaiming the wreck has to chew through.
local WRECK_METAL_FRACTION = 0.5
local WRECK_BUILDPOWER_FRACTION = 0.2
-- The fraction of a reclaimable's buildpower, its def's or its map's, that reclaiming it takes: a rock or a tree is
-- quick work, so clearing ground does not tie a builder up
local RECLAIMABLE_BUILDPOWER_FRACTION = 0.1
-- how much damage a wreck takes before it is gone, as a fraction of what the thing it was had in health
local WRECK_HEALTH_FRACTION = 0.5

-- A blueprint nobody has built on for this many seconds starts to fall apart, losing this much
-- build progress a second and refunding the metal that progress cost. Once it is back to nothing
-- it disappears.
local BLUEPRINT_DECAY_DELAY = 5
-- A builder that gets no closer to its build site, or no nearer to a clear footprint, for this many seconds
-- drops the order and goes on to the next.
local BUILD_STUCK_SECONDS = 10
local BLUEPRINT_DECAY_RATE = 30

-- Movement. Units steer directly at their waypoint and push each other apart, which keeps formations from
-- collapsing into a point. A move order finds its own way first (`pathfinder.route`), so the waypoints it is
-- given go round what it cannot cross.
local ARRIVAL_RADIUS = 1.5
-- Waypoints on the way somewhere, a route's or a chain of moves', are closed in on as near as WAYPOINT_EPSILON,
-- slowing to do it. From WAYPOINT_SKIP_RANGE out a unit checks whether it can already walk straight to the next one,
-- and goes on to it as soon as it can, so it never cuts a corner it cannot see round.
local WAYPOINT_EPSILON = 0.25
local WAYPOINT_SKIP_RANGE = 2
local SEPARATION_STRENGTH = 6
local SEPARATION_RADIUS_PADDING = 0.5
-- A unit whose velocity is below this never bothers with terrain/passability checks or moving at
-- all this tick: it counts as settled. Without a floor here, units at rest but slightly overlapping
-- (idle crowds, builders waiting by a blueprint) get just enough separation push every tick to keep
-- crossing a near-zero threshold, which was paying for a full terrain lookup forever without ever
-- visibly moving.
local MOVEMENT_SETTLE_SPEED = 0.05

-- How far past the edge of a factory's footprint its finished unit drives on its way out.
local PRODUCTION_SPOT_GAP = 3
-- How long one of a factory's own units may stand in the way of its next unit before it is told to
-- move aside.
local PRODUCTION_BLOCK_LIMIT = 3
-- Where a finished unit is told to walk so the next one has room to appear.
local PRODUCTION_RALLY_GAP = 10

-- How far outside the two colliders a guarding unit keeps from what it follows.
local GUARD_FOLLOW_GAP = 4

-- Aircraft. What is left of a weapon's damage when it hits one and the weapon is not dedicated anti air.
local NON_AA_AIR_DAMAGE_FRACTION = 0.15
-- How long an aircraft with nothing to do hovers before it settles onto the ground. One on wings cannot hover, and
-- comes down at once.
local AIR_LAND_DELAY = 2
-- How near an enemy has to be to something stealthy (`EntityDef.stealth`) for its weapons to pick it as a target,
-- in studs: about BAR's line of sight for a light unit, which is all it has to spot something its radar does not show.
local STEALTH_DETECTION_RANGE = 32
-- A hovering aircraft working on something or shooting at it keeps on the move round it, on a spot in a ring about
-- it that it picks afresh every so often (see server/orbits.luau): a builder every ORBIT_BUILD_REPICK seconds or so,
-- and a gunship every ORBIT_GUNSHIP_REPICK, each give or take ORBIT_REPICK_JITTER of that. The ring runs from
-- ORBIT_INNER to ORBIT_OUTER of how far it reaches, and each pick is the best of ORBIT_CANDIDATES spots.
local ORBIT_BUILD_REPICK = 4
local ORBIT_GUNSHIP_REPICK = 2
local ORBIT_REPICK_JITTER = 0.5
local ORBIT_INNER = 0.55
local ORBIT_OUTER = 0.8
local ORBIT_CANDIDATES = 10
-- A missile is gone after this many seconds in the air, which is longer than the flight of any rocket, since
-- one that climbs and crosses the map takes a while.
local MISSILE_MAX_AGE = 120
-- How fast a missile turns onto a new heading, as the fraction of the turn it makes in a second's flight.
local MISSILE_TURN_RATE = 6
-- How fast a homing projectile turns, in radians a second, where its weapon does not say.
local HOMING_TURN_RATE = 4
-- The chance an anti-air missile misses whatever its target does: it is fired to pass just clear of it, and falls away
-- once it has. A homing missile does not otherwise miss something that stays in its reach, so without this every one
-- would be certain to hit.
local HOMING_MISS_CHANCE = 0.1
-- Transports. A unit takes a slot for every this many studs of its radius, and a transport sets down what it
-- carries this far apart beyond their colliders.
local TRANSPORT_SLOT_RADIUS = 1.5
local TRANSPORT_UNLOAD_GAP = 1
-- Picking something up takes a transport that is effectively touching it: its centre within TRANSPORT_LOAD_RANGE
-- of the thing's centre, and its underside no more than TRANSPORT_LOAD_HEIGHT above the thing's top. It hovers
-- TRANSPORT_HOOK_GAP above it to do so. It also has to be near still next to it, moving no faster than
-- TRANSPORT_LOAD_SPEED studs a second relative to it, or than TRANSPORT_ENEMY_LOAD_SPEED if it belongs to the
-- enemy, which is what makes a moving enemy hard to catch and a tower that cannot move easy.
local TRANSPORT_LOAD_RANGE = 3
-- A transport going to pick something up flies at its usual height until it is this close to it along the ground,
-- and only then comes down to it.
local TRANSPORT_DESCEND_RANGE = 6
local TRANSPORT_LOAD_HEIGHT = 1.5
local TRANSPORT_HOOK_GAP = 0.5
local TRANSPORT_LOAD_SPEED = 3
local TRANSPORT_ENEMY_LOAD_SPEED = 1
-- What is carried dangles this far below the transport, spread this far from its middle when there is more than
-- one, and lags this many seconds behind the transport's velocity, which is what makes it swing.
local TRANSPORT_ROPE = 2
local TRANSPORT_CARGO_SPREAD = 1.5
local TRANSPORT_SWAY = 0.25

local BUILD_RANGE = 24
local RECLAIM_RANGE = 24
-- How close a resurrecting unit has to be to the wreck, and how much health what it raises comes back with.
local RESURRECT_RANGE = 24
local RESURRECT_HEALTH_FRACTION = 0.5

-- The skin (shared/skins) every team starts in, and what everything wears that nobody chose a skin for: units as they
-- are. Every special skin is opt in: a team wears one only when its player has equipped it, or a developer's command
-- puts it on. shared/skins refuses a default that is anything but plain.
local DEFAULT_SKIN = "default"

-- Scavengers. A gamemode where the map fights back: as the game begins a beacon stands in a start box nobody was
-- given, and more follow, each near one already standing, so that they spread out over the map. While a beacon
-- stands it keeps producing hostile units and defences that roam looking for players. When the last beacon falls, or
-- the progress runs out, their boss comes, and killing it wins. The scavengers are a team of their own, which is what
-- makes everything they own an enemy of every player.
local SCAVENGERS_ENABLED = true
local SCAVENGER_TEAM = 100
-- How far along the game is runs from 0 to 1 over this many seconds, and it is all that decides when things
-- happen: the beacons make nothing until it reaches SCAVENGER_SPAWN_PROGRESS, and from then on another beacon
-- comes at a random gap after the last.
local SCAVENGER_GAME_LENGTH = 4800
local SCAVENGER_SPAWN_PROGRESS = 0.05
-- The hardest single thing a beacon may make now, in difficulty (a thing's metal plus its energy, over 60), which is
-- also the difficulty the players see. It runs from SCAVENGER_BUDGET_START at the start of the game to
-- SCAVENGER_BUDGET_END at the end, a little slower than exponentially: it is START * (END / START) ^ (progress ^
-- SCAVENGER_BUDGET_SHAPE), and a shape under 1 has it gain fastest early and ease off late, where 1 would be
-- exponential. With these numbers the Juggernaut (10,733) comes in at about 70% and the Calamity (14,467), the
-- hardest thing there is, at about 74%.
local SCAVENGER_BUDGET_START = 20
local SCAVENGER_BUDGET_END = 100000
local SCAVENGER_BUDGET_SHAPE = 0.85
local SCAVENGER_BEACON_INTERVAL_MIN = 180
local SCAVENGER_BEACON_INTERVAL_MAX = 300
-- Beacons that stand at once; no new one arrives while this many are up.
local SCAVENGER_MAX_BEACONS = 10
-- How close to anything a player owns, or to another beacon, a beacon may appear.
local SCAVENGER_BEACON_PLAYER_CLEARANCE = 150
local SCAVENGER_BEACON_SPACING = 200
-- A new beacon goes up at least SCAVENGER_BEACON_SPACING and at most this far from one already standing, so
-- they spread out from where they began. With none standing, one goes anywhere.
local SCAVENGER_BEACON_SPREAD = 350
-- How far a beacon keeps from the edge of the map.
local SCAVENGER_BEACON_EDGE_MARGIN = 40
-- Beacons grow tougher as the game goes on: a beacon's health is its def's times 1 plus this times the progress, so
-- by the end five times what it starts with. Every beacon standing grows, not only new ones.
local SCAVENGER_BEACON_HEALTH_GROWTH = 4
-- Killing a beacon moves the progress on by this much. It is small beside what it buys: one beacon fewer making
-- units. Killing the last one standing brings their boss at once.
local SCAVENGER_BEACON_KILL_PROGRESS = 0.01
-- A scavenger unit that gets nothing done for this many seconds, stranded on an island, say, with no way across to
-- anything of a player's, is taken away, and what it was worth goes to making something that can get across: an
-- aircraft, a hovercraft or something amphibious. Getting SCAVENGER_FUTILE_PROGRESS studs nearer to the nearest thing
-- of a player's than it has been yet, or going after something it can reach, counts as getting something done.
local SCAVENGER_FUTILE_SECONDS = 120
local SCAVENGER_FUTILE_PROGRESS = 30
-- Seconds between one beacon's units and between its defences, which are made on separate clocks, and how many
-- defences one beacon may keep standing around itself. Units have no limit: every beacon keeps making them, so
-- how fast they come is this interval times how many beacons stand. A beacon with all the defences it will take
-- still makes units.
local SCAVENGER_SPAWN_INTERVAL = 20
local SCAVENGER_DEFENSE_SPAWN_INTERVAL = 30
local SCAVENGER_MAX_DEFENSES_PER_BEACON = 6
-- Not a limit the game is balanced round, only a guard for the server: with this many scavenger units out,
-- beacons and wrecks wait before adding more.
local SCAVENGER_UNIT_CEILING = 300
-- How long a wreck of a unit lies on the ground before it stands up again as a scavenger, while the gamemode is
-- on, and how near a beacon it has to lie for that: one further from every beacon just lies there. Something that
-- takes the wreck apart first, by reclaiming it, wins.
local SCAVENGER_REVIVE_SECONDS = 60
local SCAVENGER_REVIVE_RANGE = 300
-- How far from a player's things a scavenger unit notices them, and how far it wanders in one go.
local SCAVENGER_DETECTION_RANGE = 220
-- The share of scavenger units, from 0 to 1, that go looking for the nearest thing of a player's anywhere on the
-- map, by a route if they have to, and not only wander until one is near enough to notice. The rest wander, and
-- attack what they come across.
local SCAVENGER_SEEKER_SHARE = 1
local SCAVENGER_ROAM_MIN = 100
local SCAVENGER_ROAM_MAX = 300
-- Multiplier to spawn intervals for sea beacons, so they spawn scavengers less often
local SCAVENGER_SEA_SPAWN_MULTIPLIER = 2
-- Delay in seconds before a beacon's first spawn, preventing initial spawn threat
local SCAVENGER_INITIAL_SPAWN_DELAY = 15

local SELECTION_DRAG_THRESHOLD = 6
-- A right-drag shorter than this is treated as a plain right-click rather than a formation line.
local FORMATION_DRAG_THRESHOLD = 8

-- Units are only a few studs across, so the default altitude is low enough to actually read them.
local CAMERA_HEIGHT = 65
local CAMERA_PITCH = -55
local CAMERA_PAN_SPEED = 120
local CAMERA_MIN_HEIGHT = 22
local CAMERA_MAX_HEIGHT = 420
local CAMERA_ZOOM_STEP = 14
-- Radians the view turns per pixel of cursor movement while rotating with alt and the middle button.
local CAMERA_ROTATE_SPEED = 0.008

return table.freeze({
	TICK_RATE = TICK_RATE,
	TICK_DELTA = TICK_DELTA,

	CELL_STUDS = CELL_STUDS,
	MAP_CELLS_X = MAP_CELLS_X,
	MAP_CELLS_Z = MAP_CELLS_Z,
	ELMOS_PER_STUD = ELMOS_PER_STUD,
	TERRAIN_BASE_HEIGHT = TERRAIN_BASE_HEIGHT,
	TERRAIN_AMPLITUDE = TERRAIN_AMPLITUDE,
	TERRAIN_FREQUENCY = TERRAIN_FREQUENCY,
	TERRAIN_BASIN_AMPLITUDE = TERRAIN_BASIN_AMPLITUDE,
	TERRAIN_BASIN_FREQUENCY_FACTOR = TERRAIN_BASIN_FREQUENCY_FACTOR,
	MAX_BUILD_SLOPE_STUDS = MAX_BUILD_SLOPE_STUDS,
	WATER_LEVEL = WATER_LEVEL,
	DROWN_SECONDS = DROWN_SECONDS,
	DROWN_DEPTH_MARGIN = DROWN_DEPTH_MARGIN,
	RELOAD_BAR_MIN_SECONDS = RELOAD_BAR_MIN_SECONDS,
	TURRET_TOLERANCE = TURRET_TOLERANCE,
	TURRET_REST_DELAY = TURRET_REST_DELAY,
	DEFORM_MAX_DEPTH = DEFORM_MAX_DEPTH,
	DEFORM_DAMAGE_SCALE = DEFORM_DAMAGE_SCALE,
	DEFORM_MIN_DEPTH = DEFORM_MIN_DEPTH,
	DEFORM_RIM_FRACTION = DEFORM_RIM_FRACTION,
	DEFORM_RIM_REACH = DEFORM_RIM_REACH,
	DEFORM_MIN_RADIUS = DEFORM_MIN_RADIUS,
	DEFORM_MAX_TOTAL = DEFORM_MAX_TOTAL,

	START_RING_RADIUS = START_RING_RADIUS,
	START_SLOTS = START_SLOTS,
	START_COUNTDOWN_SECONDS = START_COUNTDOWN_SECONDS,
	METAL_SPOT_SNAP = METAL_SPOT_SNAP,

	STARTING_METAL = STARTING_METAL,
	STARTING_ENERGY = STARTING_ENERGY,
	METAL_INCOME = METAL_INCOME,
	ENERGY_INCOME = ENERGY_INCOME,
	CONVERTER_THRESHOLD = CONVERTER_THRESHOLD,
	METAL_CAPACITY = METAL_CAPACITY,
	ENERGY_CAPACITY = ENERGY_CAPACITY,

	MIN_WIND = MIN_WIND,
	MAX_WIND = MAX_WIND,
	TIDAL_STRENGTH = TIDAL_STRENGTH,
	WIND_INTERVAL = WIND_INTERVAL,
	WIND_MAX_DELTA = WIND_MAX_DELTA,
	WRECK_METAL_FRACTION = WRECK_METAL_FRACTION,
	WRECK_BUILDPOWER_FRACTION = WRECK_BUILDPOWER_FRACTION,
	RECLAIMABLE_BUILDPOWER_FRACTION = RECLAIMABLE_BUILDPOWER_FRACTION,
	WRECK_HEALTH_FRACTION = WRECK_HEALTH_FRACTION,
	BLUEPRINT_DECAY_DELAY = BLUEPRINT_DECAY_DELAY,
	BUILD_STUCK_SECONDS = BUILD_STUCK_SECONDS,
	BLUEPRINT_DECAY_RATE = BLUEPRINT_DECAY_RATE,

	ARRIVAL_RADIUS = ARRIVAL_RADIUS,
	WAYPOINT_EPSILON = WAYPOINT_EPSILON,
	WAYPOINT_SKIP_RANGE = WAYPOINT_SKIP_RANGE,
	SEPARATION_STRENGTH = SEPARATION_STRENGTH,
	SEPARATION_RADIUS_PADDING = SEPARATION_RADIUS_PADDING,
	MOVEMENT_SETTLE_SPEED = MOVEMENT_SETTLE_SPEED,

	PRODUCTION_SPOT_GAP = PRODUCTION_SPOT_GAP,
	PRODUCTION_RALLY_GAP = PRODUCTION_RALLY_GAP,
	PRODUCTION_BLOCK_LIMIT = PRODUCTION_BLOCK_LIMIT,

	GUARD_FOLLOW_GAP = GUARD_FOLLOW_GAP,

	NON_AA_AIR_DAMAGE_FRACTION = NON_AA_AIR_DAMAGE_FRACTION,
	AIR_LAND_DELAY = AIR_LAND_DELAY,
	STEALTH_DETECTION_RANGE = STEALTH_DETECTION_RANGE,
	ORBIT_BUILD_REPICK = ORBIT_BUILD_REPICK,
	ORBIT_GUNSHIP_REPICK = ORBIT_GUNSHIP_REPICK,
	ORBIT_REPICK_JITTER = ORBIT_REPICK_JITTER,
	ORBIT_INNER = ORBIT_INNER,
	ORBIT_OUTER = ORBIT_OUTER,
	ORBIT_CANDIDATES = ORBIT_CANDIDATES,
	MISSILE_MAX_AGE = MISSILE_MAX_AGE,
	MISSILE_TURN_RATE = MISSILE_TURN_RATE,
	HOMING_TURN_RATE = HOMING_TURN_RATE,
	HOMING_MISS_CHANCE = HOMING_MISS_CHANCE,
	TRANSPORT_SLOT_RADIUS = TRANSPORT_SLOT_RADIUS,
	TRANSPORT_LOAD_RANGE = TRANSPORT_LOAD_RANGE,
	TRANSPORT_DESCEND_RANGE = TRANSPORT_DESCEND_RANGE,
	TRANSPORT_LOAD_HEIGHT = TRANSPORT_LOAD_HEIGHT,
	TRANSPORT_HOOK_GAP = TRANSPORT_HOOK_GAP,
	TRANSPORT_LOAD_SPEED = TRANSPORT_LOAD_SPEED,
	TRANSPORT_ENEMY_LOAD_SPEED = TRANSPORT_ENEMY_LOAD_SPEED,
	TRANSPORT_ROPE = TRANSPORT_ROPE,
	TRANSPORT_CARGO_SPREAD = TRANSPORT_CARGO_SPREAD,
	TRANSPORT_SWAY = TRANSPORT_SWAY,
	TRANSPORT_UNLOAD_GAP = TRANSPORT_UNLOAD_GAP,

	BUILD_RANGE = BUILD_RANGE,
	RECLAIM_RANGE = RECLAIM_RANGE,
	RESURRECT_RANGE = RESURRECT_RANGE,
	RESURRECT_HEALTH_FRACTION = RESURRECT_HEALTH_FRACTION,

	DEFAULT_SKIN = DEFAULT_SKIN,

	SCAVENGERS_ENABLED = SCAVENGERS_ENABLED,
	SCAVENGER_TEAM = SCAVENGER_TEAM,
	SCAVENGER_GAME_LENGTH = SCAVENGER_GAME_LENGTH,
	SCAVENGER_SPAWN_PROGRESS = SCAVENGER_SPAWN_PROGRESS,
	SCAVENGER_BUDGET_START = SCAVENGER_BUDGET_START,
	SCAVENGER_BUDGET_END = SCAVENGER_BUDGET_END,
	SCAVENGER_BUDGET_SHAPE = SCAVENGER_BUDGET_SHAPE,
	SCAVENGER_BEACON_INTERVAL_MIN = SCAVENGER_BEACON_INTERVAL_MIN,
	SCAVENGER_BEACON_INTERVAL_MAX = SCAVENGER_BEACON_INTERVAL_MAX,
	SCAVENGER_MAX_BEACONS = SCAVENGER_MAX_BEACONS,
	SCAVENGER_BEACON_PLAYER_CLEARANCE = SCAVENGER_BEACON_PLAYER_CLEARANCE,
	SCAVENGER_BEACON_SPACING = SCAVENGER_BEACON_SPACING,
	SCAVENGER_BEACON_SPREAD = SCAVENGER_BEACON_SPREAD,
	SCAVENGER_BEACON_EDGE_MARGIN = SCAVENGER_BEACON_EDGE_MARGIN,
	SCAVENGER_BEACON_HEALTH_GROWTH = SCAVENGER_BEACON_HEALTH_GROWTH,
	SCAVENGER_BEACON_KILL_PROGRESS = SCAVENGER_BEACON_KILL_PROGRESS,
	SCAVENGER_FUTILE_SECONDS = SCAVENGER_FUTILE_SECONDS,
	SCAVENGER_FUTILE_PROGRESS = SCAVENGER_FUTILE_PROGRESS,
	SCAVENGER_SPAWN_INTERVAL = SCAVENGER_SPAWN_INTERVAL,
	SCAVENGER_DEFENSE_SPAWN_INTERVAL = SCAVENGER_DEFENSE_SPAWN_INTERVAL,
	SCAVENGER_UNIT_CEILING = SCAVENGER_UNIT_CEILING,
	SCAVENGER_MAX_DEFENSES_PER_BEACON = SCAVENGER_MAX_DEFENSES_PER_BEACON,
	SCAVENGER_REVIVE_SECONDS = SCAVENGER_REVIVE_SECONDS,
	SCAVENGER_REVIVE_RANGE = SCAVENGER_REVIVE_RANGE,
	SCAVENGER_DETECTION_RANGE = SCAVENGER_DETECTION_RANGE,
	SCAVENGER_SEEKER_SHARE = SCAVENGER_SEEKER_SHARE,
	SCAVENGER_ROAM_MIN = SCAVENGER_ROAM_MIN,
	SCAVENGER_ROAM_MAX = SCAVENGER_ROAM_MAX,
	SCAVENGER_SEA_SPAWN_MULTIPLIER = SCAVENGER_SEA_SPAWN_MULTIPLIER,
	SCAVENGER_INITIAL_SPAWN_DELAY = SCAVENGER_INITIAL_SPAWN_DELAY,

	SELECTION_DRAG_THRESHOLD = SELECTION_DRAG_THRESHOLD,
	FORMATION_DRAG_THRESHOLD = FORMATION_DRAG_THRESHOLD,

	CAMERA_HEIGHT = CAMERA_HEIGHT,
	CAMERA_PITCH = CAMERA_PITCH,
	CAMERA_PAN_SPEED = CAMERA_PAN_SPEED,
	CAMERA_MIN_HEIGHT = CAMERA_MIN_HEIGHT,
	CAMERA_MAX_HEIGHT = CAMERA_MAX_HEIGHT,
	CAMERA_ZOOM_STEP = CAMERA_ZOOM_STEP,
	CAMERA_ROTATE_SPEED = CAMERA_ROTATE_SPEED,
})
