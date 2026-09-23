# rts

A Total Annihilation style RTS for Roblox: 3D, server-authoritative, built on a heightmap world
with metal / energy / buildpower economics.

## Getting started

```bash
aftman install          # rojo, wally, selene, stylua, luau-lsp
wally install           # react, react-roblox, promise, janitor
rojo build rts-game.project.json -o rts.rbxlx # then open in Studio and `rojo serve rts-game.project.json`
```

Stylesheets are SCSS compiled by [outlass](https://github.com/toodols/outlass) into a Roblox
`StyleSheet` module:

```bash
./build_stylesheets.bat            # one shot
./build_stylesheets.bat --watch    # rebuild on change
```

It uses `outlass` from PATH if installed, otherwise builds it from `../outlass`.

`build_preview.bat` renders the same SCSS in a browser instead, via dart-sass, as a reference to
diff the Roblox render against — see `src/client/ui/stylesheets/preview/README.md`.

## Checks

```bash
selene src
stylua src
rojo sourcemap rts-game.project.json --output sourcemap.json
luau-lsp analyze --defs=globalTypes.d.luau --sourcemap=sourcemap.json --ignore="**/Packages/**" --ignore="**/pow/**" src
```

`globalTypes.d.luau` is fetched from the luau-lsp repo and is not checked in.

## Command bar

[pow](https://github.com/toodols/pow) (checked out in `pow/`) is the in-game command bar for debugging
and administration. Press `;` to open it, `help` lists commands. It is started by
`src/server/pow_init.server.luau`, which also sets who may use it, and this game's own commands live in
`src/server/pow_server_ext.luau`:

| Command | Effect |
| --- | --- |
| `godmode` / `godmode true` / `godmode false` | toggle, enable or disable commanding every team; you can select and order any team's units and build with any team's builders |
| `scavengers` / `scavengers true` / `scavengers false` | toggle, enable or disable the scavengers gamemode: whether beacons appear and make anything. What is already out there carries on |
| `beacon` | put a scavenger beacon down now, wherever the rules would put one |

## Lobby

The lobby is a place of its own, built from `rts-lobby.project.json` (the game is `rts-game.project.json`):

```bash
rojo build rts-lobby.project.json -o lobby.rbxlx   # or `rojo serve rts-lobby.project.json` into the lobby place
```

It shares `src/shared` and the game's SCSS partials with the game, and adds `src/lobby`: `server/` (the lobbies and
their rules, the cross-server list, and launching), `shared/` (the remotes and the protocol) and `client/` (the React
screens). `build_stylesheets.bat` compiles its sheet, `src/lobby/client/stylesheets/lobby.scss`, alongside the game's.

A player makes a lobby, or joins one from the list, which shows every open lobby on every lobby server: each server
lists its own in a MemoryStore sorted map and reads everyone else's every 5 seconds. Joining a lobby on another server
teleports the player to that server, where they are seated as they arrive. A lobby is public or friends only; a
friends-only lobby is listed only to the host's friends and only they can join it.

The host picks the map and the mode (`shared/game_modes.luau`): Scav Easy / Normal / Hard / Brutal (everyone against
the scavengers, whose strength grows faster the harder it is), 1v1 up to 5v5, or FFA. In a team game players pick
their team by clicking one of its open places. Each map has a picture drawn on the client from its own heightmap and
theme, the same way the terrain is painted (`shared/ground_paint.luau`), at the map's true aspect ratio and with a grid
of BAR map units (512 elmos, about 47 studs) over it, so maps can be compared by size.

Starting reserves a server of the game place, leaves the match (mode, map, seed, who sits on which side) in a
MemoryStore hash map under that server's PrivateServerId, and teleports everyone there. The game server reads it back
as it starts (`server/match.luau`): each seated player gets a team, teams on a side are allied, and the scavengers are
turned off or paced to the difficulty. Any other game server, and Studio, plays the usual game.

The place ids are in `shared/places.luau`. Teleports do not work in Studio, so starting a game or joining a lobby on
another server can only be tried in a live server.

## How it fits together

The simulation is authoritative and lives entirely in `src/server`, stepping at a fixed 20 Hz
(`config.TICK_RATE`). It knows nothing about Roblox instances. `instances.luau` mirrors each
entity into `Workspace.Entities` as an anchored model whose attributes carry its state, which is
both how the world replicates and how the client picks units with a raycast.

`src/shared` holds everything both sides need: unit definitions, tunables, the heightmap and
footprint maths. The heightmap is generated from a seed by a pure function, so the client rebuilds
the server's terrain locally instead of receiving it.

### Economy and buildpower

A builder with buildpower `B` working on a blueprint costing `(M metal, E energy, C buildpower)`
pushes `B` buildpower per second into it and pays `M/C` metal and `E/C` energy per point of
buildpower applied. A Bot Lab (`B = 150`) building a Grunt (`M = 54, E = 900, C = 1650`) finishes in
11s, spending about 4.9 metal/s and 82 energy/s.

Builders register their drains during a tick and the whole batch settles at the end, so a team that
cannot afford everything at once has the shortfall spread proportionally across every drain rather
than awarded to whichever builder ran first.

Placing a building does not put a blueprint down. It sends the builder to the spot, and the blueprint
appears when the builder arrives (builders sent to the same spot share it; if something has taken the
spot by then, the order is dropped). A blueprint that nobody has built on for 5 seconds starts to come
apart, losing 30 buildpower of progress a second and refunding the metal that progress cost, and it
disappears once there is nothing left.

A blueprint's max health is its completion percentage of the finished thing's health, and current
health moves by the same flat amount whenever max health moves — so damage taken mid-build is
carried through to completion rather than healed away by further progress. A blueprint that dies
leaves nothing behind.

A factory builds its queue one unit at a time, and the unit in progress is tied to the front of the
queue: cancelling it destroys the blueprint immediately and refunds the metal and energy paid into it.
If the spot in front of the factory is blocked by one of its own units for 3 seconds, that unit is
ordered to move clear ahead of everything else it was doing.

### Wrecks and reclaim

A finished entity that dies leaves a wreck holding 50% of its metal, over a buildpower pool of 20%
of its `buildpower_cost`. Reclaiming runs construction backwards at the same metal-per-buildpower
rate, so pulling a wreck apart is much faster than building the unit was. Anything with
`reclaiming = true` can reclaim wrecks or still-standing entities; anything with `assisting = true`
can pour buildpower into a blueprint alongside its owner.

Reclaiming something still standing strips its health: every point of buildpower applied removes
`max_health / buildpower_cost` of it, so a reclaimer with buildpower `B` takes `buildpower_cost / B`
seconds. When health reaches 0 it is gone with no wreck, and its whole metal cost goes to the
reclaimer that finished it that tick (for a blueprint, the metal actually spent and the buildpower
actually put in).

A commander does not die quietly. When one is destroyed it explodes, dealing 4000 damage at its centre
to everything within 24 studs, falling to a quarter of that at the edge, to friends and enemies alike,
and anything that dies to the blast can leave a wreck or explode in turn. Being reclaimed does not
set it off.

Deaths already compute an overkill ratio (`combat.DEBRIS_OVERKILL_RATIO`); debris fields are the
next thing to build on it. Today every death leaves a wreck.

A construction turret takes assist, reclaim, repair and guard orders like a construction_bot, for whatever is
within its reach, but cannot move and cannot make anything; a move order is dropped and an order for
something out of reach ends. With nothing to do it puts its buildpower into the nearest friendly
blueprint within reach, including a factory's unit in progress, and failing that repairs the nearest damaged unit or
building of its own team or an ally in reach, never an enemy's, and a repair order works on an ally's units the same way. Repairing restores a damaged finished
friendly at the rate buildpower would build it, and costs nothing but the buildpower. A unit that can
repair and is guarding something damaged repairs it once it is settled beside it and has nothing else
to do. An extractor placed by hand locks onto the
closest metal spot that is not already taken, whether by an extractor, a blueprint, or a build order
waiting in some builder's queue. The Guard (light laser tower) fires on enemies in range by itself, at
20 energy a shot, and the two stores add their capacity to the team's while they stand.

The vehicle lab makes the Incisor, a light laser tank, the way the bot lab makes bots. The Twin Guard
carries two turrets, each with its own range, reload and target, and prefers a target its other turret
is not already shooting. The commander builds everything but the construction turret; construction_bots build
all of it.

Every def has a display name (BAR's) and a subtitle, its name in plain words: a Lasher is a missile
truck, an Aggravator a rocket bot, a Graverobber a rezbot, a Rascal a scout vehicle. The selection
panel and the build menu show both. The Graverobber can repair and reclaim and does nothing else, the
Centurion carries a pair of lasers that each pick their own target, and the Lasher throws missiles the
way the Aggravator throws rockets. A rocket's blast is a third the size BAR gives it.
The Mammoth (BAR's `corsumo`, from the advanced bot lab) is the biggest thing on legs: 15,600 health, a laser that
takes 302 a shot, and a walk of 23 elmos a second, all BAR's. A def with `autoheal` mends that much health a second
by itself, with no builder and no cost, while it fights and while it walks; the Gunslinger (BAR's `armmav`, now
with all of its BAR numbers) heals 50 a second. Its shell falls under gravity and is aimed along the low arc, so it
needs a clear line to its target.

### Wind

Wind is a 2D vector, (x, z), whose length lives between `MIN_WIND` (1) and `MAX_WIND` (15), an annulus. Every
`WIND_INTERVAL` seconds (5) it moves by a random vector up to `WIND_MAX_DELTA` (4) long, and if that carries
its length out of the annulus it is pulled back in, or pushed out, to the nearest edge, keeping its direction
(`server/wind.luau`). The wind speed is its length. A wind turbine makes as much energy a second as the wind
speed times its `wind_multiplier` (1 for now). The wind is sent as the `wind` attribute of Workspace and shown
beside metal and energy in the resource bar, with streaks drifting along the wind vector behind it. Builders
can place the turbine with Z then D.

### Map presets

The ground comes from a preset in `shared/map_presets.luau`, chosen by `MAP_PRESET` in `server/init.server.luau`
and sent to clients with the seed. `highlands` is the rolling hills the map has always had. `islands` is islands
in an ocean: one flat-topped island under every team start, a few more scattered between, and at least one
volcano, a cone about 55 degrees steep with a crater that nothing can be built on. `continents` is two
continents with sea all round them, joined by two narrow land bridges; teams start at the far ends, slots 1 and 2
facing each other across the water (a preset may set its own start positions with `start_position`), and the
spread of underwater metal spots lies on the sea floor around them. A preset is a function of the
seed alone, so the server and the client build the same ground. Adding one is adding an entry to that table.

### Scavengers

A gamemode (`config.SCAVENGERS_ENABLED`, or the `scavengers` command) where the map fights back. The
scavengers are a team of their own (`config.SCAVENGER_TEAM`), so everything they own is an enemy of every
player and `combat` needs no special case for them; they have no economy, and their weapons are never short of
energy. All of it lives in `src/server/scavengers.luau`.

Progress runs from 0 to 1 over `config.SCAVENGER_GAME_LENGTH` seconds, an hour, and it is all that decides
when things happen. Once it reaches `SCAVENGER_FIRST_BEACON_PROGRESS` a beacon appears at a random empty spot far
from every player and every other beacon, with room to move around it, and another follows every 3 to 5 minutes
while fewer than `SCAVENGER_MAX_BEACONS` stand. Where there is water at the spot it is a sea beacon
(`scavenger_sea_beacon`), which floats in water at least 12 studs deep and makes ships, and where there is not it is
a land beacon on level ground, which makes everything else. Spots are drawn over the whole map, so how many of each
a map gets follows how much of it is sea: a map of islands gets mostly sea beacons. A beacon has 20000 health and
cannot be reclaimed, so it has to be destroyed; what it leaves is a wreck worth half its metal cost.

While a beacon stands it makes a unit every 10 seconds and a defence every 15, on separate clocks: a beacon
with all the defences it will take (`SCAVENGER_MAX_DEFENSES_PER_BEACON`) goes on making units. What they can
field is a budget in difficulty, which is a thing's metal plus its energy, over 60. The budget grows
exponentially with progress from `SCAVENGER_BUDGET_START`, and how fast is worked out so that by
`SCAVENGER_ROSTER_PROGRESS` (half way) it is `SCAVENGER_ROSTER_COPIES` times the hardest thing in the roster:
everything the game has is on offer by then, and the budget only buys more of it after. A beacon makes only what
fits in what is left of the budget after everything the scavengers already have out. Once `SCAVENGER_MAX_UNITS`
are out, or a beacon has all the defences it will take, a new one takes the place of the easiest only if it is at
least twice as hard, and never a unit that is attacking. These numbers are all in `config.luau` to be tuned.

What they can make is everything a player can: `build_roster` takes every def that some builder or factory lists,
that has a weapon or drones to fight with, and that is not itself a drone, so a new unit is in it without being
added. Ships are made by sea beacons and the rest by land ones. A def's weight is 12 over the square root of its
difficulty, so cheap things are common and dear ones rare. Because the budget is sized to the hardest thing in the
roster, adding a much harder one, like the Calamity at over 14,000, steepens the whole curve; `SCAVENGER_ROSTER_COPIES`
and `SCAVENGER_ROSTER_PROGRESS` set how much. Things that only shoot at aircraft (the Thistle, the Trasher, the
Valiant) are made only while a player has something in the air. A bomber gets a plain attack order so that it flies its
runs, and a carrier with nothing of its own to fire goes to its spot and lets its drones fight. Drones are their
carrier's: the AI leaves them alone, and they count towards neither the budget nor the unit limit.

While the gamemode is on, the wreck of any unit comes back as a scavenger. Each gains resurrection progress, the
same progress the purple bar over it shows and a Graverobber works on, at the rate that fills it in
`SCAVENGER_REVIVE_SECONDS` (a minute), and then stands up on the scavengers' team with the health a raised unit
has, at no cost to them. Only units come back, never a commander, and whatever takes the wreck apart first by
reclaiming it wins. With as many scavenger units out as are allowed, a full wreck waits for room. What they raise
counts towards the budget like anything else, so a field of wrecks left alone is a horde that the beacons then make
less to add to.

Units scatter. A new one first heads off away from its beacon, up to 60 degrees either side of straight out, and
leaves hunting alone for a few seconds; after that, with nothing of a player's near, it seeks: it heads for
the nearest thing of a player's anywhere on the map, to a staging spot at 80% of `SCAVENGER_DETECTION_RANGE`
from it, by a straight run or else by a route. `SCAVENGER_SEEKER_SHARE` is the share of units that do, all of
them by default, and the rest wander to a spot a fair way off whenever they have nothing to do. It also hunts:
anything of a player's within `SCAVENGER_DETECTION_RANGE` that a unit can shoot is attacked, and the chase ends
when it can no longer be. Hunters do not all make for the target itself, which
would stop them in a clump at the front with the rest unable to get into range. Each walks to a spot of its own
at shooting range, on the ring round the target, spread across the half of it that it is coming from and fixed
by its id, and attacks from there. A unit that is trying to go somewhere and getting nowhere gives up on it, and
one that is within range of a target it cannot see over the ground goes to the target itself instead, up onto
the cliff if there is a way up, and gives it up if there is not. It never just walks straight at a target.

Where a unit goes, it goes by a straight run across ground it can stand on the whole way
(`pathfinder.has_straight_path`) whenever it has one, because that is nearly free. Only when it has none does it
ask `pathfinder` for a route round the water or the cliff, which is issued as a chain of move orders ending in
the attack. Aircraft go straight at their target. A route that gets no closer than a place within weapon
range still counts, since the unit can shoot across. Routes cost from about a millisecond to a good deal more, so
one step gives out one, none may search more than `PATH_MAX_EXPANSIONS` cells (`find_path`'s `max_expansions`),
a route is trusted for 30 seconds, and a unit that was refused or found no way waits, and gives up on that
target for a while. A route that a search is cut off from still leads part of the way, and a seeker asks again
from where it gets to; one that ends less than 30 studs nearer than it started counts as no way there. A unit
whose short wanders all fail, stranded behind water, asks for a route to somewhere else on the map instead. On a map cut into islands there is usually no route to be had, and the units stay
where they are.

While the gamemode is on the resource bar has one more block, beside the wind, showing the difficulty: the
scavengers' budget, to two significant figures (`~840`, `~1.3k`). The server sends it as the
`scavenger_difficulty` attribute of Workspace and clears it when the gamemode is turned off, which takes the
block away and narrows the bar again. See `src/client/ui/scavenger_block.luau`.

### Placing lines and grids

While a building is being placed, holding shift and dragging lays out a line of them along whichever axis
the drag runs further, and holding shift and alt lays out a grid with the start and the cursor as opposite
corners. They are axis aligned and edge to edge on the building grid, up to 100 at a time, and boxes show
where each goes and whether it fits. Letting go orders every one that fits, queued after what the builders
are already doing. Things bound to a metal spot only ever take the one place.

### Resurrection

A unit with `resurrecting = true` (the Graverobber) can raise wrecks: press W for resurrecting mode and
click a wreck. A wreck has to be full of metal first, so one that has been reclaimed from is refilled, the
team paying back the metal at the rate reclaiming took it. Then the buildpower goes into the resurrection,
which takes as much as building the unit did and costs its energy but no metal, and a purple bar over the
wreck shows how far along it is. When it finishes the wreck is replaced by the unit, on the team that raised
it, at `config.RESURRECT_HEALTH_FRACTION` of its health. Only units come back, not buildings.

### Water

The sea is at height 0 (`config.WATER_LEVEL`), and the terrain has basins that dip below it. Ground below
that is under water, as deep as it is far below (`heightmap.water_depth`). Every def says how deep the water
may be where it stands (`max_water_depth`): land units and buildings not at all, the commander anything.
A def may also say how deep it has to be (`min_water_depth`), which is what makes something a ship: it
floats on the surface instead of standing on the bed, and that goes for buildings too: a shipyard sits on
the water's surface, while a building without a `min_water_depth` that is built underwater stands on the sea
floor (`unit_defs.surface_height` is the one place that decides). Units treat water they cannot stand in as a wall and
slide along it, but every order that walks somewhere finds its way round a lake (see Pathfinding below). Buildings are
refused where the water is wrong for them, so a shipyard goes in deep water. The one metal extractor stands
on dry land or on the sea floor: most metal spots are on dry land, and a few more (`UNDERWATER_SPOT_COUNT`,
laid out after the rest so they move nothing) are underwater. An underwater one is built by something that
can get to it, like a commander or a Construction Ship. A ship's waypoints, the path drawn for it and the
markers for an order it is given are on the water's surface, not the sea floor under it. Team starts
(`starts.luau`) are moved to the nearest dry, level ground. The server logs how much of the map is under
water when it renders the terrain. The Shipyard builds the Supporter, the Riptide and the Construction Ship,
which makes a shipyard and a metal extractor. Shells burst on the surface of the sea rather than sinking to
the floor.

The Riptide is a gun ship whose one cannon fires along a low arc (`arc = "low"`): unlike a high lob it needs
a clear line to its target, and the ground or a friend in the way stops it.

### Slope

Every ground unit has a `slope_class`, BAR's movement class for it (`BOT2`, `TANK3`, ...), and each class
has BAR's `maxslope`: the steepest ground angle it can stand on, 54 degrees for bots and the commander and 27
for tanks. Ships, aircraft and buildings have no class and no limit. `shared/passability.luau` works out,
for each limit, which cells of the heightmap are passable and keeps the answer as a `buffer` with a byte a
cell (classes with the same limit share one map), so a pathfinder can ask `passability.passable_cell` or
read `passability.map_for(class).cells` directly instead of measuring slopes. A cell's steepness is the average
slope of its four corners, and ground exactly at the limit is passable. Like water, ground too steep for a
unit is a wall it slides along or stops at, and a unit already standing on it may leave. Craters refresh the
cells they change (`deformation.flush`). BAR's `slopeMod`, which slows a unit on a slope it can climb, and
footprint sizes are not modelled.

### Pathfinding

`shared/pathfinder.luau` finds the way for everything that walks. `pathfinder.find_path(def, from, to)` returns
`{ orders, complete }`, where `orders` is a chain of `move` orders that carries a unit of that def from `from` to
`to` over ground it can stand on, ready for `orders.issue`. It is A* over the heightmap's cells, eight ways with no
corner cutting, on the slope maps above and the water rules for the def (a cell is open only if the water is right
at all four of its corners, which is exactly what `movement` tests at any point in it). A destination it cannot
reach gets the route to the nearest reachable cell and `complete = false`. A unit standing where it should not is
still given a way out.

Routes keep clear of walls where they can and squeeze past them where they cannot. For each kind of ground (slope
class and water limits) the pathfinder keeps which cells are open and how far each is from the nearest that is not,
with the map's edge counting as a wall, worked out for the whole map the first time a kind of unit asks and patched
where craters land (`pathfinder.refresh`, from `deformation`). A cell is tight for a unit when its radius and
`WALL_MARGIN` (1.5 studs) do not fit there; stepping into one costs `TIGHT_PENALTY` (4) times as much, so a route
takes the gap only when going round is a good deal further. The route is then pulled tight across ground that is not
tight, so its orders are only the turns it needs, and inside a squeeze it follows the gap point to point.

`pathfinder.has_straight_path(def, from, to)` says whether a unit can walk the whole straight line, by the same
tests, reading one byte a cell on the line, so it is nearly free: the line has to keep clear of walls, unless one
of its ends is in a squeeze itself. `pathfinder.route(def, from, to)` puts the two together: one move straight
there when the line is good, and otherwise the route `find_path` finds.

A player's move and fight go through it (`commands.luau`): a move is issued as the chain of moves of its route, and
a fight as a chain of fight waypoints along it, so the unit fights its way along all of them. So does each move or
fight a factory hands the units it makes (its rally, worked out from where each unit appears). One order searches
for at most 12 of its units, and the rest of those whose line is not good are sent straight there; units with a
good line never need one. Every other order that walks to something, an attack, a build, a reclaim, a repair, a
guard or an unload, finds its way through `server/navigation.luau` the same way, out of sight of the order: straight
when it can, a route when it cannot (at most 4 searches a tick in all), worked out again when its goal moves more
than 4 studs or it has made no headway for a second. An attack does not stop at being in range: it walks on until it
has a clear shot (`combat.can_shoot`), since something behind a hill cannot be shot from in front of it.

Waypoints, a route's or a player's shift-queued ones, are closed in on as near as `WAYPOINT_EPSILON` (0.25 studs),
slowing to get there, and from `WAYPOINT_SKIP_RANGE` (2 studs) out the unit checks every tick whether it can go
straight to the next already, and goes on as soon as it can, so it never cuts a corner it cannot see round. Aircraft
go straight everywhere, and count as on a waypoint within the circle they turn in. Other units and buildings are not
part of any of it. `passability.initialize` has to have run.

### Terrain deformation

Explosions press a crater into the ground, but only softly. A shell's blast, or the death explosion of
something that has one, digs a bowl at its centre that rises smoothly to ground level at its radius, with the
ground it pushed aside heaped in a low rim (out to 1.6 times the radius) around it. The depth is
`DEFORM_MAX_DEPTH` (1 stud) times `1 - e^(-damage / DEFORM_DAMAGE_SCALE)`, so it grows with the blast but never
passes a stud, however huge, and a blast too weak to make `DEFORM_MIN_DEPTH` leaves no mark. A blast smaller
than a grid cell digs as one of `DEFORM_MIN_RADIUS`, and one that goes off high above the ground, like a shell
bursting on an aircraft, digs nothing. Craters overlap and deepen, but no sample ends up more than
`DEFORM_MAX_TOTAL` studs from where the map generated it.

The heightmap itself is edited (`heightmap.deform`), so everything that stands on it agrees at once. Once a
tick `server/deformation.luau` rewrites just the voxels the edits touch (`terrain.rewrite`) and sends the
changed samples to the clients as `TerrainDeformed`, which apply them on top of the heightmap they rebuilt
from the seed; a client that arrives late asks for every edit made so far. Buildings do not sink or float:
the ground under a footprint, and a cell around it, is left alone. Units and wrecks standing where the ground
moved are set back down on it. Nothing else has been adjusted for the changed ground, so a metal spot marker
drawn where the ground used to be can sit up to a stud off it.

### High arc weapons

A weapon whose projectile sets `arc = "high"` (the Wolverine, the Quaker, the Agitator and the Persecutor) lobs a shell: no
thrust, no drag, just gravity. It is angled so that it comes down on its target, leading one that is moving,
and strays within a cone from BAR's `accuracy`. Because the arc carries it over whatever is in between, such a
weapon needs no line of sight and never fires at a friend that stands in the way. The shell still explodes on
the first thing it meets, and the blast falls off toward `edge_effectiveness`.

### Missile launchers

The Catalyst (tactical missiles) and the Apocalypse (nuclear ones) fire from a stockpile instead of a reload. Each
builds a missile every `stockpile.build_time` seconds (20 and 90) up to `limit`, ten, and a finished missile is
paid for in metal and energy when it comes off: with too little of either it waits, complete, until it can be
paid for, and nothing is made while the stockpile is full. They **never** pick a target of their own, so a
missile is spent only where it is sent, and a launcher does nothing until it is given an attack or attack-ground
order. One order sends one missile and is then finished (queue more with shift); with none ready it waits for
the next.

A missile (`projectile.missile`) flies at one speed the whole way, in three legs: straight up to `climb` studs
over its launcher, across to its target at that height, and then down onto it once the line to the target is
as steep as `dive_angle`. It turns onto each new heading over a moment, so it curves rather than snapping. It
touches nothing until it dives, so it goes over everything in the way and needs no line of sight, but like a
shell it comes down where its target was when it left, never in the air, and it does not lead a moving
target. It explodes on what it meets or the ground, and a launcher stays clear of its own missile until it
comes back down. The Apocalypse's range covers the whole map. Missiles live for `MISSILE_MAX_AGE` seconds,
longer than any other rocket, which a nuke crossing the map needs.

A launcher shows a bar over it for how far along its next missile is, with the number it holds under it. Any
weapon that takes longer than `config.RELOAD_BAR_MIN_SECONDS` (5) to reload, like the Pulsar's, shows a bar over
its owner for how far along it is to its next shot. Both come from attributes on the model (`stockpile_progress`,
`reload_progress`) and are drawn by `world_bars.luau`.

The numbers for both are chosen, not BAR's, like the aircraft's. Both are built by the advanced construction_bots, X
then A and X then E, and neither can be carried.

### Line of sight

Nothing fires blind. Each shooter picks the nearest enemy in range it has a clear line to: the ground
in the way stops a shot outright, and so does one of its own side: a shooter never fires through a
friend on purpose. Friendly fire happens only once a shot has left, when a friend walks into a rocket's
path and takes it. Lasers hit the first solid thing on their line. A rocket, like the Aggravator's,
thrusts along a straight line for two seconds, then loses its momentum and falls, and explodes on
whatever it meets or on the ground, hurting everything near the blast.

### Attack mode

Press A with anything that can shoot selected to enter attack mode, and the next left click is an attack.
Click an enemy and the selection attacks it, exactly as a right click on it would. Click anywhere else and
it is an attack-ground order (`attack_ground`) on that spot of the ground: each unit closes in until the
spot is within its range, then keeps shooting at it, whatever else comes into range, until it is given
another order (so an order queued behind one waits for that). A shot at a spot is held to the same rules as
one at a target: it is taken only when the spot is in range and the line to it is clear of the ground and of
friends, and a lobbed shell needs no line at all. Anything on the line that is not a friend takes the shot
in the spot's place, and a shot that finds nothing goes into the ground, where a rocket explodes.

### Fight mode

Press F with anything that can move selected to enter fight mode, and the next left click on the ground
puts a fight waypoint there (`fight`). It is walked to like a move, with one difference: whenever a unit has
something it could shoot at this moment (an enemy within range of any of its weapons that it has a clear
line to, reloading or not), it stops and shoots it, and it sets off again once nothing is left to shoot
at. That repeats until it reaches the waypoint, which ends the order. Units that cannot shoot have nothing to
stop for, so for them it is a plain move, which keeps a mixed group together, and a bomber, which cannot
stop, flies on and bombs what it crosses. Like the other modes, a plain click replaces what the units were
doing and ends the mode; shift adds the waypoint to the end of their queue and keeps the mode on, so a
route of fight waypoints (or fight waypoints among moves) can be laid, and space puts it at the front. An
enemy in the way is fought, not walked past, but a shot through a friend is still never taken.

### Aircraft

The Air Lab builds the Construction Aircraft (a builder), the Valiant (fighter), the Whirlwind (bomber), the
Hercules (light transport) and the Hephaestus (heavy transport). The Construction Aircraft builds, repairs,
reclaims and assists like the Construction Vehicle, with the same list of buildings, and since every reach a
builder has is measured along the ground it works from up in the air, over water and terrain no ground builder
can cross. It does not settle onto the ground while it has orders, so it stays up through a build or a
reclaim; an aircraft with no orders left still lands after the delay below. An
aircraft has `air` set on its def: it takes off and lands straight up and down, so it needs no runway. It
climbs to its `altitude` when it has somewhere to go, hovers for `config.AIR_LAND_DELAY` seconds once it
has nothing to do, then settles onto the ground. Aircraft fly over water and over everything on the ground:
they crowd only each other, and an airborne one neither blocks a placement nor is caught in a ground blast
or the disintegrator. Shot down, one leaves its wreck on the ground below.

The Valiant and the Whirlwind fly on `wings`. They still take off and land straight up and down, but they cannot
hover: in the air they hold their height only by moving forward. While one has something to do it flies flat
out, as BAR's planes do, and turns no faster than its `turn_rate`, so where it has nowhere in particular to be,
like a Valiant in range of what it is shooting, it circles. When where it is going is behind it and nearer than
its `run_out`, it holds its heading until it is not and only then turns back, which is BAR's rule and what makes
a bomber's attack a pass. It counts as having reached a point once it is within the circle it turns in, since it
cannot stop on it. With nothing left to do it does not wait in the air for `AIR_LAND_DELAY`: it comes straight
down, slowing to a stop as it lands.

Their cruise altitudes and `run_out` come from BAR's `corveng` and `corshad` (`cruisealtitude`, and `turnradius`
64, which the engine takes as that many frames of flight at full speed). BAR has no turn rate: turning comes out
of its flight model. `turn_rate` is that model's steady turn with full bank, elevator and rudder, from each unit's
`maxbank`, `maxelevator`, `maxrudder` and `speedtofront`, which is a circle of about 23 studs for both.

Every weapon that is not dedicated anti air (`anti_air = true`) does `config.NON_AA_AIR_DAMAGE_FRACTION`
(20%) of its damage to an aircraft, rockets and their blasts included. A weapon can also name the layer it
shoots at with `target_layer`: the Valiant hits aircraft only, and the Whirlwind's bombs hit the ground
only. A lobbed shell is never thrown at something in the air. An attack order a weapon cannot carry out is
dropped.

The Thistle (an anti air tower, built wherever the Guard is) and the Trasher (an anti air bot, from the Bot
Lab) each throw a missile at aircraft and at nothing else, at full damage, with BAR's launch speed,
acceleration and flight time. BAR's missiles home in on their target and this game's rockets do not, so a
straight one would miss anything that moves: their projectile sets `leads = true`, which aims it ahead of a
moving target, at where it will be when the missile gets there. Without it neither hit an aircraft in a test of
twelve passes; with it a Thistle averaged one hit a pass and a Trasher two. The Trasher's movement class is
BAR's `ABOT3`, an amphibious bot, so it climbs what the other bots do and wades as the commander does.

The Whirlwind attacks by flying over its target at full speed and on past it (`bombing_runs`), dropping
bombs as it goes, then coming round for another pass once it is its `run_out` clear. A bomb has
`dropped = true`: it has no launch speed of its own, but it carries on at the bomber's velocity as it falls,
so it comes down well ahead of where it was let go. Its weapon is BAR's `corbomb`: five bombs 0.26667 seconds
apart, a 6 second reload, and map gravity. The burst is one shot, as in BAR: the bomber starts it once the target
is within half the length of the line of bombs it lays of where the first would come down, allowing for how far a
moving target will have gone by then, so the target is in the middle of the line. The rest follow the first at
what it was let go at, whatever they will come down on, short of the target and then past it. Each bomb is also
pushed sideways onto the aim, by as much as brings it onto the aim's line when it lands but no more than BAR's
one elmo a frame, which makes up for a bomber that is not quite lined up. It needs no line of sight, and it only
bombs from the air.

A weapon's reload is not rounded to the tick. Whatever is left of a tick after a reload runs out is carried: the
shot is taken as though that long ago, already that far into its flight and from where its owner was then, and
the next reload starts that much sooner. So a burst 0.26667 seconds apart is laid 0.26667 seconds apart, not
alternately 0.25 and 0.3. A weapon with nothing to shoot waits ready, and does not save up the shots it could
have taken.

The Hercules (light transport) and the Hephaestus (heavy transport) carry things. Every unit and static
defence has a `weight_class`, `"light"` or `"heavy"`, or none, which cannot be carried at all; a
transport's `carries` says how much it can lift, and a `"heavy"` one takes light and heavy while a
`"light"` one takes light only. The commander, the Guard, the Thistle, the Twin Guard and the Warden are heavy, and every
T1 ground unit is light. A load is measured in slots (one for every `config.TRANSPORT_SLOT_RADIUS` studs of
radius) against the transport's `capacity`.

A transport can pick up the enemy's things as well as its own. It flies to the thing at its usual height and
only comes down once it is within `TRANSPORT_DESCEND_RANGE` of it, so it never drags itself along ground that is
higher than where the thing stands. It comes down over the thing, or a little to one side of it if that lets it
come lower, as at the foot of a slope. An aircraft rests on the highest ground under any part of it, not only
under its middle, so it does not sink into a slope it is over. It has to come down until it and the thing are
effectively touching (`TRANSPORT_LOAD_RANGE`, `TRANSPORT_LOAD_HEIGHT`), keeping pace with it, and be moving
no faster than `TRANSPORT_LOAD_SPEED` relative to it, or `TRANSPORT_ENEMY_LOAD_SPEED` if it is the enemy's. A
tower never moves, so it is easy; an enemy unit that is on the move is hard. What is aboard is inactive:
nothing sees, shoots, orders or moves it. It is still drawn, hanging from the transport on a rope and
swinging as the transport moves, and a transport with something aboard does not land. A building is put down
square to the grid, at the nearest spot that is free. A transport that dies takes its cargo with it.

The Valiant's and the Whirlwind's numbers are BAR's `corveng` and `corshad`, apart from their climb speeds and
their turn rates (see above). The other aircraft's numbers are chosen, not copied from BAR unit files like the
rest.

### Carriers and drones

A def with a `carrier` (the Mantis) keeps `count` drones parked on top of it. While an enemy is within its
`engage_range` they take off and each attacks it, with the drone def's own weapon, through the ordinary attack
order; when nothing is in range they fly back to their perch and park again, holding fire. A drone that is shot
down is replaced `respawn_seconds` later, free of charge. If the carrier dies its drones go with it. A drone def
has `drone = true`: it cannot be selected or ordered, no factory builds it and it leaves no wreck. Nothing in
`server/drones.luau` is specific to the Mantis, so another carrier is a def with a `carrier` and a drone def.

### Building grid

Buildings sit on a grid of `CELL_STUDS` (4 studs, the same cells as the heightmap and the terrain
voxels). A building's footprint is its collider rounded up to whole cells, so a 5 stud solar
collector takes a 2 x 2 block of cells and neighbours pack edge to edge. Its centre snaps so that
its edges land on grid lines, whichever way it is turned, and metal spots are laid on the grid too.
The server rejects a placement that is not on it.

### Controls

| Input | Effect |
| --- | --- |
| Left click empty ground | clear selection |
| Left click entity | select just that entity, if it is yours (anything else counts as empty ground; in godmode every real team is yours) |
| Shift + left click entity | add to / remove from selection, if it is yours |
| Left drag | box-select your units and buildings: only the top kind in the box (armed units, then unarmed units, then buildings; blueprints count as what they will become), shift takes all and keeps the current selection |
| Right click ground | move |
| Right click entity | attack an enemy, reclaim a wreck, assist a blueprint, or guard a friendly (follow it; builders work on what it is building or reclaiming) |
| Right drag a line | spread the selection evenly along that line |
| Shift + any order | queue it instead of replacing the queue |
| Space + any order | put it at the front of the queue, pushing everything else back |
| Middle mouse drag / arrow keys | pan · mouse wheel zooms |
| Z / X / C / V with a builder selected | building categories: economy, offense, utility, production. Each key places the category's main building: metal extractor (Z), guard (X), nothing yet (C), bot lab (V). An extractor locks onto the closest free metal spot |
| X / Q / W while placing | pick another building in the same category: from economy, X solar collector, Q energy storage, W metal storage; from offense, X twin guard, A thistle, V catalyst, E apocalypse; from production, X vehicle lab, A construction turret, S shipyard, D air lab |
| Right click a friendly with a transport selected | load it aboard, if the transport can carry it; otherwise the transport guards it |
| J with transports selected | load mode: the next left click on a friendly unit sends them to pick it up (shift queues and stays in the mode), right click / Esc cancels |
| U with transports selected | unload mode: the next left click on the ground sends them there to set everything aboard down (shift queues and stays in the mode), right click / Esc cancels |
| Q | select everything of yours on the screen of the same type as what is selected (while placing an economy building, Q picks the energy storage instead) |
| Tab | select your commander and pan the camera to it; with several, each press moves to the next and wraps round |
| D with a commander selected | aim its disintegrator (a red rectangle from the commander toward the cursor, as long as its range, that destroys everything in it): the next left click gives it a `dgun` order at that spot, an order like any other: the commander closes in until the spot is in range, fires once its weapon is ready and has the energy, and moves on to the next order. Shift queues it behind what the commander is doing and keeps aiming, space puts it at the front. Allies and your own units in the rectangle go with everything else, but a shot that an enemy commander is in the way of is dropped. Right click / Esc cancels |
| A with armed units selected | attack mode: the next left click attacks an enemy under the cursor, or the spot of ground if there is none (shift queues and stays in the mode), right click / Esc cancels |
| F with units selected | fight mode: the next left click on the ground sends them there, stopping to shoot whatever is in reach on the way (shift queues it and stays in the mode), right click / Esc cancels |
| E with reclaimers selected | reclaim mode: the next left click on an entity sends the selected reclaimers at it (shift queues and stays in the mode), right click / Esc cancels |
| R with repairers selected | repair mode, the same as reclaim mode: the next left click on a damaged friendly sends them to repair it |
| `[` / `]` while placing | rotate a quarter turn counterclockwise / clockwise · right click cancels |

A factory's build orders **always** queue, with or without shift; shift adds five at a time.

## Not built yet

- Models, mostly. Fifteen buildings have procedural art from `tools/model_pipeline`: the three laser towers, both
  construction turrets, the fusion reactors, the energy converters and the four storages. It is kept as data in
  `src/shared/art/` and built by each client with EditableMesh (`client/art.luau`), which the experience has to
  allow (Game Settings > Security > Allow Mesh / Image APIs); the server's model for them is an invisible hitbox.
  Tower heads turn with their turrets' aim, construction turrets turn toward their work, and reactor rings spin.
  Every other building is a box the size of its collider. Units are procedural stand-ins that fit inside
  theirs (`server/unit_placeholder.luau`): vehicles are tracked boxes with a cab and a barrel, ships the same
  without tracks, bots are stacked cylinders whose proportions come from a hash of their name, and aircraft
  are flat isosceles triangles. Anything that builds, repairs, reclaims or assists has a yellow part. A
  vehicle is a def with `vehicle = true`.
- Pathfinding round other units and buildings. Only the ground is routed round; units are pushed apart from each
  other and off buildings as they go.
- Debris fields, resource buildings, and any win condition.
