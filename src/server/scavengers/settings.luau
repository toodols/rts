--!strict
-- The numbers the scavengers gamemode plays by (server/scavengers), all of them here: when things happen, how hard
-- they get, and how their beacons and units behave. The gamemode itself is off unless a game asks for it (the
-- `scavengers` switch, shared/switches.luau).

-- How far along the game is runs from 0 to 1 over this many seconds, and it is all that decides when things
-- happen: the beacons make nothing until it reaches SPAWN_PROGRESS, and from then on another beacon
-- comes at a random gap after the last.
local GAME_LENGTH = 4800
local SPAWN_PROGRESS = 0.05
-- The hardest single thing a beacon may make now, in difficulty (what a thing is worth, unit_defs.power: its metal and
-- its energy over 60), which is also the difficulty the players see. It runs from BUDGET_START at the start of the game
-- to BUDGET_END at the end, a little slower than exponentially: it is START * (END / START) ^ (progress ^
-- BUDGET_SHAPE), and a shape under 1 has it gain fastest early and ease off late, where 1 would be exponential. With
-- these numbers the Juggernaut (39,250) comes in at about 69% and the Calamity (81,333), the hardest thing there is,
-- at about 78%.
local BUDGET_START = 80
local BUDGET_END = 400000
local BUDGET_SHAPE = 0.85
local BEACON_INTERVAL_MIN = 180
local BEACON_INTERVAL_MAX = 300
-- Beacons that stand at once; no new one arrives while this many are up.
local MAX_BEACONS = 10
-- How close to anything a player owns, or to another beacon, a beacon may appear.
local BEACON_PLAYER_CLEARANCE = 150
local BEACON_SPACING = 200
-- A new beacon goes up at least BEACON_SPACING and at most this far from one already standing, so
-- they spread out from where they began. With none standing, one goes anywhere.
local BEACON_SPREAD = 350
-- How far a beacon keeps from the edge of the map.
local BEACON_EDGE_MARGIN = 40
-- Beacons grow tougher as the game goes on: a beacon's health is its def's times 1 plus this times the progress, so
-- by the end ten times what it starts with (2,000 to 20,000). Every beacon standing grows, not only new ones.
local BEACON_HEALTH_GROWTH = 9
-- Killing a beacon moves the progress on by this much. It is small beside what it buys: one beacon fewer making
-- units. Killing the last one standing brings their boss at once.
local BEACON_KILL_PROGRESS = 0.01
-- A scavenger unit that gets nothing done for this many seconds, stranded on an island, say, with no way across to
-- anything of a player's, is taken away, and what it was worth goes to making something that can get across: an
-- aircraft, a hovercraft or something amphibious. Getting FUTILE_PROGRESS studs nearer to the nearest thing
-- of a player's than it has been yet, or going after something it can reach, counts as getting something done.
local FUTILE_SECONDS = 120
local FUTILE_PROGRESS = 30
-- Seconds between one beacon's units and between its defences, which are made on separate clocks, and how many
-- defences one beacon may keep standing around itself. Units have no limit: every beacon keeps making them, so
-- how fast they come is this interval times how many beacons stand. A beacon with all the defences it will take
-- still makes units.
local SPAWN_INTERVAL = 20
local DEFENSE_SPAWN_INTERVAL = 30
local MAX_DEFENSES_PER_BEACON = 6
-- When a beacon has all the defences it will take, something new retires the weakest only if it is at least this many
-- times as hard, so what stands there stays a spread of easy and hard rather than all of the newest.
local UPGRADE_FACTOR = 2
-- What a beacon can make is everything a player can build that fights (server/scavengers/roster.luau). A thing's
-- weight is this over the square root of its difficulty, so what is cheap is made more often than what is dear without
-- the dear ever quite being left out; and what is worth less than FODDER_SHARE of the hardest thing a beacon
-- could make now is not made, so by the end of the game only the hardest few are.
local ROSTER_WEIGHT = 12
local FODDER_SHARE = 0.12
-- How often every beacon makes its units and its defences, as a multiple of the intervals above: at 0.5 they come
-- half as often, every beacon on every map and at every difficulty.
local SPAWN_RATE = 0.5
-- Not a limit the game is balanced round, only a guard for the server: with this many scavenger units out,
-- beacons and wrecks wait before adding more.
local UNIT_CEILING = 300
-- How long a wreck of a unit lies on the ground before it stands up again as a scavenger, while the gamemode is
-- on, and how near a beacon it has to lie for that: one further from every beacon just lies there. Something that
-- takes the wreck apart first, by reclaiming it, wins.
local REVIVE_SECONDS = 60
local REVIVE_RANGE = 150
-- How far from a player's things a scavenger unit notices them, and how far it wanders in one go.
local DETECTION_RANGE = 220
-- The share of scavenger units, from 0 to 1, that go looking for the nearest thing of a player's anywhere on the
-- map, by a route if they have to, and not only wander until one is near enough to notice. The rest wander, and
-- attack what they come across.
local SEEKER_SHARE = 1
local ROAM_MIN = 100
local ROAM_MAX = 300
-- Multiplier to spawn intervals for sea beacons, so they spawn scavengers less often
local SEA_SPAWN_MULTIPLIER = 2
-- Delay in seconds before a beacon's first spawn, preventing initial spawn threat
local INITIAL_SPAWN_DELAY = 15

return table.freeze({
	GAME_LENGTH = GAME_LENGTH,
	SPAWN_PROGRESS = SPAWN_PROGRESS,
	BUDGET_START = BUDGET_START,
	BUDGET_END = BUDGET_END,
	BUDGET_SHAPE = BUDGET_SHAPE,
	BEACON_INTERVAL_MIN = BEACON_INTERVAL_MIN,
	BEACON_INTERVAL_MAX = BEACON_INTERVAL_MAX,
	MAX_BEACONS = MAX_BEACONS,
	BEACON_PLAYER_CLEARANCE = BEACON_PLAYER_CLEARANCE,
	BEACON_SPACING = BEACON_SPACING,
	BEACON_SPREAD = BEACON_SPREAD,
	BEACON_EDGE_MARGIN = BEACON_EDGE_MARGIN,
	BEACON_HEALTH_GROWTH = BEACON_HEALTH_GROWTH,
	BEACON_KILL_PROGRESS = BEACON_KILL_PROGRESS,
	FUTILE_SECONDS = FUTILE_SECONDS,
	FUTILE_PROGRESS = FUTILE_PROGRESS,
	SPAWN_INTERVAL = SPAWN_INTERVAL,
	DEFENSE_SPAWN_INTERVAL = DEFENSE_SPAWN_INTERVAL,
	MAX_DEFENSES_PER_BEACON = MAX_DEFENSES_PER_BEACON,
	UPGRADE_FACTOR = UPGRADE_FACTOR,
	ROSTER_WEIGHT = ROSTER_WEIGHT,
	FODDER_SHARE = FODDER_SHARE,
	SPAWN_RATE = SPAWN_RATE,
	UNIT_CEILING = UNIT_CEILING,
	REVIVE_SECONDS = REVIVE_SECONDS,
	REVIVE_RANGE = REVIVE_RANGE,
	DETECTION_RANGE = DETECTION_RANGE,
	SEEKER_SHARE = SEEKER_SHARE,
	ROAM_MIN = ROAM_MIN,
	ROAM_MAX = ROAM_MAX,
	SEA_SPAWN_MULTIPLIER = SEA_SPAWN_MULTIPLIER,
	INITIAL_SPAWN_DELAY = INITIAL_SPAWN_DELAY,
})
