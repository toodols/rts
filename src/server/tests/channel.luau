--!strict
-- Tests of the channel (shared/map_designs/channel.luau) and the two missions played on it, Channel Crossing
-- (server/missions/channel.luau) and Blockade (server/missions/blockade.luau).

local ReplicatedStorage = game:GetService "ReplicatedStorage"
local ServerScriptService = game:GetService "ServerScriptService"

local types = require(ReplicatedStorage.Shared.types)
local heightmap = require(ReplicatedStorage.Shared.heightmap)
local ground_levels = require(ReplicatedStorage.Shared.ground_levels)
local unit_defs = require(ReplicatedStorage.Shared.unit_defs)
local pathfinder = require(ReplicatedStorage.Shared.pathfinder)
local spots = require(ReplicatedStorage.Shared.spots)
local surface = require(ReplicatedStorage.Shared.surface)
local map_presets = require(ReplicatedStorage.Shared.map_presets)
local mission_map = require(ReplicatedStorage.Shared.mission_map)
local mission_state = require(ReplicatedStorage.Shared.mission_state)
local mission_forces = require(ReplicatedStorage.Shared.mission_forces)
local game_phase = require(ReplicatedStorage.Shared.game_phase)
local geometry = require(ReplicatedStorage.Shared.geometry)

local placement = require(ServerScriptService.Server.placement)
local state = require(ServerScriptService.Server.state)
local maps = require(ServerScriptService.Server.maps)
local missions = require(ServerScriptService.Server.missions)
local spawning = require(ServerScriptService.Server.spawning)
local damage = require(ServerScriptService.Server.damage)
local orders = require(ServerScriptService.Server.orders)
local ai = require(ServerScriptService.Server.ai)
local blockade_mission = require(ServerScriptService.Server.missions.blockade)

local harness = require(script.Parent.harness)

local OWN = harness.OWN
local advance = harness.advance
local round = harness.round
local spawn = harness.spawn
local ensure_team = harness.ensure_team

type Entity = types.Entity
type TeamId = types.TeamId
type Findings = harness.Findings
type Args = harness.Args
type Test = harness.Test

-- How far from where the mission's layout puts it a floating defence may stand, put on the building grid.
local PLACED_SLACK = 4
-- How far a route may be searched for.
local SEARCH = 100000

local function point(name: string): Vector2
	local points = map_presets.get("channel").points :: { [string]: Vector2 }
	return points[name]
end

-- Where something of `def_name` would stand at (x, z), on the ground or the water as it would.
local function stand(def_name: string, at: Vector2): Vector3
	return surface.position(unit_defs.get(def_name), at.X, at.Y)
end

-- Whether a `def_name` finds its way from `from` to `to`, all the way (pathfinder.plan's `complete`).
local function reaches(def_name: string, from: Vector2, to: Vector2): boolean
	local path = pathfinder.plan(unit_defs.get(def_name), stand(def_name, from), stand(def_name, to), SEARCH)
	return path ~= nil and path.complete
end

-- Whether a `def_name` may be put down on the grid at `at`.
local function placeable(def_name: string, at: Vector2): boolean
	local center = placement.resolve_center(def_name, at.X, at.Y, 0, nil)
	return center ~= nil and placement.can_place(def_name, center, 0, nil)
end

-- The channel as built: the shores and the island stand above the water, both straits are deep all along, the east half
-- is the west half mirrored, and nothing that walks or drives gets from one shore to the other but a commander or a
-- Garpike, which go along the floor, while a construction ship gets from the harbour to the island's west shore and a
-- warship to within its reach of the enemy's shore, and a ship to both ends of the channel. A Garpike gets from the
-- harbour's shore up onto the enemy's ground. A shipyard goes down in the harbour and a bot lab on the island, and an
-- extractor on every metal spot.
local function channel_map(_args: Args): Findings
	local player_start, enemy_start = point "player_start", point "enemy_start"
	local harbor = point "harbor"
	local east_shore = point "east_shore"
	-- how deep each strait is at its middle, at its shallowest along its length
	local shallowest = math.huge
	for z = -250, 250, 5 do
		shallowest = math.min(shallowest, ground_levels.WATER_LEVEL - heightmap.height_at(-120, z))
		shallowest = math.min(shallowest, ground_levels.WATER_LEVEL - heightmap.height_at(120, z))
	end
	-- how far the halves are from mirroring each other, at their worst
	local asymmetry = 0
	for x = 4, 316, 8 do
		for z = -252, 252, 8 do
			asymmetry = math.max(asymmetry, math.abs(heightmap.height_at(x, z) - heightmap.height_at(-x, z)))
		end
	end
	-- where the east shore's waterline is, and how high the ground 10 and 20 studs inland of it, at each of its
	-- Agitators' rows
	local shore_rows: { string } = {}
	for _, z in { -120, 0, 120 } do
		local x = 100
		while heightmap.height_at(x, z) < ground_levels.WATER_LEVEL and x < 300 do
			x += 1
		end
		table.insert(
			shore_rows,
			`{z}:{x}/{round(heightmap.height_at(x + 10, z), 1)}/{round(heightmap.height_at(x + 20, z), 1)}`
		)
	end
	local spot_rows: { string } = {}
	local spots_ok = true
	for _, spot in spots.all "metal" do
		local ok = placeable("metal_extractor", Vector2.new(spot.position.X, spot.position.Z))
		spots_ok = spots_ok and ok
		table.insert(spot_rows, `{math.round(spot.position.X)},{math.round(spot.position.Z)}:{ok}`)
	end
	-- a ship's way out of the harbour: from its middle
	local findings: Findings = {
		player_height = round(heightmap.height_at(player_start.X, player_start.Y), 1),
		enemy_height = round(heightmap.height_at(enemy_start.X, enemy_start.Y), 1),
		shallowest_middle = round(shallowest, 1),
		asymmetry = round(asymmetry, 2),
		grunt_across = reaches("grunt", player_start, enemy_start),
		tank_across = reaches("incisor", player_start, enemy_start),
		commander_across = reaches("commander", player_start, enemy_start),
		garpike_across = reaches("garpike", player_start, enemy_start),
		ship_to_island = reaches("construction_ship", harbor, point "island" - Vector2.new(90, 0)),
		lab_on_island = placeable("bot_lab", point "island"),
		island_height = round(heightmap.height_at(point("island").X, point("island").Y), 1),
		-- a warship gets within its reach (43) of an Agitator 20 studs inland on the enemy's shore
		warship_to_east_shore = reaches("riptide", harbor, east_shore - Vector2.new(12, 0)),
		ship_to_sea_north = reaches("riptide", harbor, point "sea_north"),
		ship_to_sea_south = reaches("riptide", harbor, point "sea_south"),
		-- Blockade's fleets: the biggest ship down each strait from end to end
		west_lane = reaches("buccaneer", point "sea_north", point "sea_south"),
		east_lane = reaches("buccaneer", point "east_north", point "east_south"),
		-- and the island's west shore: a construction ship within its build range (24) of a lab there
		lab_on_island_west = placeable("bot_lab", point "island_west"),
		ship_to_island_west = reaches("construction_ship", harbor, point "island_west" - Vector2.new(18, 0)),
		shipyard_in_harbor = placeable("shipyard", harbor),
		spots = table.concat(spot_rows, " "),
		east_waterline = table.concat(shore_rows, " "),
	}
	findings.pass = findings.player_height > 3
		and findings.enemy_height > 3
		and shallowest >= 10
		and asymmetry < 0.01
		and findings.grunt_across == false
		and findings.tank_across == false
		and findings.commander_across
		and findings.garpike_across
		and findings.ship_to_island
		and findings.lab_on_island
		and findings.island_height > 3
		and findings.warship_to_east_shore
		and findings.ship_to_sea_north
		and findings.ship_to_sea_south
		and findings.west_lane
		and findings.east_lane
		and findings.lab_on_island_west
		and findings.ship_to_island_west
		and findings.shipyard_in_harbor
		and spots_ok
	return findings
end

-- Loads mission `mission_id` (in its hard mode for `hard`) as the mission_load command would, and puts the player's
-- commander down at its start as a player's arriving would. Returns the mission's enemy team and the commander.
local function start_mission(mission_id: string, hard: boolean): (TeamId, Entity)
	local loaded, err = maps.load({ mission = mission_id, hard = hard })
	assert(loaded, err)
	ensure_team(OWN)
	local start = mission_map.here(mission_map.PLAYER_START)
	local commander = spawning.spawn_near("commander", OWN, heightmap.ground_position(start.X, start.Y), math.pi / 2)
	assert(commander ~= nil, "no room for the commander")
	advance(1)
	return mission_state.enemy_team() :: TeamId, commander
end

-- How many living things of `team`'s there are of each def.
local function census(team: TeamId): { [string]: number }
	local counts: { [string]: number } = {}
	for _, entity in state.all() do
		if entity.alive and entity.team == team and (entity.kind == "unit" or entity.kind == "building") then
			counts[entity.def_name] = (counts[entity.def_name] or 0) + 1
		end
	end
	return counts
end

-- How many of each def `things` holds.
local function tally(things: { mission_forces.Thing }): { [string]: number }
	local counts: { [string]: number } = {}
	for _, thing in things do
		counts[thing.def_name] = (counts[thing.def_name] or 0) + 1
	end
	return counts
end

local function missing(expected: { [string]: number }, found: { [string]: number }): string
	local short: { string } = {}
	for def_name, count in expected do
		if (found[def_name] or 0) < count then
			table.insert(short, `{def_name} {found[def_name] or 0}/{count}`)
		end
	end
	table.sort(short)
	return table.concat(short, ", ")
end

-- Channel Crossing (server/missions/channel.luau) played for `args.seconds` (120): its enemy should stand as the
-- mission lays it out, every Agitator and floating defence within PLACED_SLACK of where it says, with its commander and
-- no AI playing it; the HUD should show the time limit counting down from the layout's; and in that time the enemy
-- should build nothing and nothing of its should come over to the player's shore. Then, with the time limit cut to just
-- past what has gone, the mission should be lost with "Time ran out".
local function channel_crossing(args: Args): Findings
	local enemy = start_mission("channel", false)
	local seconds = args.seconds or 120
	local expected = tally(mission_forces.CHANNEL_ENEMY)
	expected.commander = 1
	local at_start = census(enemy)
	local placed_off: { string } = {}
	for _, each in mission_forces.CHANNEL_ENEMY do
		if each.def_name ~= "agitator" and unit_defs.get(each.def_name).footing.water ~= "float" then
			continue
		end
		local nearest = math.huge
		for _, entity in state.all() do
			if entity.alive and entity.team == enemy and entity.def_name == each.def_name then
				nearest = math.min(nearest, (Vector2.new(entity.position.X, entity.position.Z) - each.at).Magnitude)
			end
		end
		if nearest > PLACED_SLACK then
			table.insert(placed_off, `{each.at.X},{each.at.Y}:{round(nearest, 1)}`)
		end
	end
	missions.publish()
	local time_left_at_start = mission_state.time_left()
	local profile = ai.profile_of(enemy)

	local crossed = 0
	local things_at_start = 0
	for _, count in at_start do
		things_at_start += count
	end
	advance(seconds, function()
		for _, entity in state.all() do
			if entity.alive and entity.team == enemy and entity.position.X < -150 then
				crossed += 1
			end
		end
	end)
	local after = census(enemy)
	local things_after, grown = 0, {}
	for def_name, count in after do
		things_after += count
		if count > (at_start[def_name] or 0) then
			table.insert(grown, def_name)
		end
	end
	table.sort(grown)

	missions.publish()
	local time_left_after = mission_state.time_left() or -1
	assert(missions.retime(seconds + 3, nil))
	advance(5)
	local findings: Findings = {
		missing_at_start = missing(expected, at_start),
		placed_off = table.concat(placed_off, " "),
		profile = if profile ~= nil then profile.name else "none",
		time_left_at_start = time_left_at_start or -1,
		time_left_after = time_left_after,
		things_at_start = things_at_start,
		things_after = things_after,
		built = table.concat(grown, ", "),
		crossed = crossed,
		result = missions.result() or "none",
		reason = game_phase.end_reason() or "none",
	}
	findings.pass = findings.missing_at_start == ""
		and findings.placed_off == ""
		and findings.profile == "none"
		and math.abs((time_left_at_start or 0) - mission_forces.CHANNEL_LAYOUT.time_limit) <= 2
		and time_left_after < (time_left_at_start or 0)
		and findings.built == ""
		and crossed == 0
		and findings.result == "lost"
		and findings.reason == "Time ran out"
	return findings
end

-- Channel Crossing won: its enemy's commander killed outright, the mission should end in victory at once, whatever else
-- the enemy has left.
local function channel_victory(_args: Args): Findings
	local enemy = start_mission("channel", false)
	advance(2)
	local killed = 0
	for _, entity in state.all() do
		if entity.alive and entity.team == enemy and unit_defs.is_commander(entity.def) then
			damage.apply(entity, 1e9, nil)
			killed += 1
		end
	end
	advance(2)
	local left = census(enemy)
	local findings: Findings = {
		killed = killed,
		result = missions.result() or "none",
		winners = game_phase.winners(),
		guards_left = left.guard or 0,
	}
	findings.pass = killed == 1 and findings.result == "won" and table.find(game_phase.winners(), enemy) == nil
	return findings
end

-- Channel Crossing's hard mode, played for `args.seconds` (450): its enemy should have what the hard mode adds as well
-- (two more Corals and an Air Lab), and the hard mode's time limit on the clock. The Air Lab should make Whirlwinds,
-- and the first raid should go at the player's base once raid_bombers of them wait by it; the raids that follow grow.
local function channel_hard(args: Args): Findings
	local enemy = start_mission("channel", true)
	local expected = tally(mission_forces.CHANNEL_ENEMY)
	for name, count in tally(mission_forces.CHANNEL_HARD_ENEMY) do
		expected[name] = (expected[name] or 0) + count
	end
	local at_start = census(enemy)
	missions.publish()
	local time_left = mission_state.time_left() or -1
	local layout = mission_forces.CHANNEL_LAYOUT
	-- something of the player's for the raids to go at, that they cannot kill
	local target = harness.unkillable(spawn("solar_collector", OWN, -270, -30))
	local made: { [number]: boolean } = {}
	local first_raid_at: number? = nil
	local first_raid_size = 0
	local most_attacking = 0
	local began = state.now()
	advance(args.seconds or 450, function()
		local attacking = 0
		for _, entity in state.all() do
			if
				entity.alive
				and entity.team == enemy
				and entity.def_name == "whirlwind"
				and entity.state == "active"
			then
				made[entity.id] = true
				local order = entity.orders[1]
				if order ~= nil and order.kind == "attack" then
					attacking += 1
				end
			end
		end
		if first_raid_at == nil and attacking > 0 then
			first_raid_at = state.now() - began
			first_raid_size = attacking
		end
		most_attacking = math.max(most_attacking, attacking)
	end)
	local bombers = 0
	for _ in made do
		bombers += 1
	end
	local findings: Findings = {
		missing_at_start = missing(expected, at_start),
		time_left = time_left,
		bombers_made = bombers,
		first_raid_at = if first_raid_at ~= nil then round(first_raid_at, 0) else -1,
		first_raid_size = first_raid_size,
		most_attacking = most_attacking,
		target_hurt = round(harness.damage_to(target), 0),
		played_hard = missions.hard(),
	}
	findings.pass = findings.missing_at_start == ""
		and math.abs(time_left - layout.hard_time_limit) <= 2
		and first_raid_size == layout.raid_bombers
		and most_attacking > first_raid_size
		and findings.played_hard
	return findings
end

-- Blockade (server/missions/blockade.luau): the player's harbour base should go down beside their commander, its
-- shipyard in the harbour, and Channel Crossing's enemy lie wrecked where it stood. With `args.prep` (3) seconds to
-- prepare and the waves' gaps a tenth as long, the first wave should come in by sea at the channel's north end, down
-- both straits, and head south. Then each wave is sunk as it comes, `args.seconds` (240) at most, and the mission should
-- be won once the last has come and gone, with nothing through. Played again with nothing in the way, and the waves
-- let be, it should be lost to the ships that get through, with "Too many ships got through".
local function blockade(args: Args): Findings
	local enemy = start_mission("blockade", false)
	advance(1)
	local base = census(OWN)
	local expected = tally(mission_forces.BLOCKADE_BASE)
	local wrecks = 0
	for _, entity in state.all() do
		if entity.kind == "wreck" then
			wrecks += 1
		end
	end
	local yards = 0
	local harbor_at = mission_map.here "harbor"
	for _, entity in state.all() do
		if
			entity.alive
			and entity.def_name == "shipyard"
			and (Vector2.new(entity.position.X, entity.position.Z) - harbor_at).Magnitude <= 6
		then
			yards += 1
		end
	end

	assert(missions.retime(args.prep or 3, 0.1))
	-- the first wave, as it comes in and a few seconds on
	advance(12)
	local function wave_units(): { Entity }
		local units: { Entity } = {}
		for _, entity in state.all() do
			if entity.alive and entity.team == enemy and entity.kind == "unit" then
				table.insert(units, entity)
			end
		end
		return units
	end
	local function mean_z(units: { Entity }): number
		local total = 0
		for _, unit in units do
			total += unit.position.Z
		end
		return if #units > 0 then total / #units else 0
	end
	local first = wave_units()
	local before = mean_z(first)
	local afloat, west, east = 0, 0, 0
	for _, unit in first do
		if unit.position.Y >= ground_levels.WATER_LEVEL - 1 then
			afloat += 1
		end
		if unit.position.X < 0 then
			west += 1
		else
			east += 1
		end
	end
	advance(10)
	local after = mean_z(first)

	-- every wave sunk as it comes, until the mission ends
	local seconds = args.seconds or 240
	local waited = 0
	while missions.result() == nil and waited < seconds do
		for _, unit in wave_units() do
			damage.apply(unit, 1e9, nil)
		end
		advance(2)
		waited += 2
	end
	local won = missions.result()
	local sunk_escapes = blockade_mission.escapes()

	-- and again, letting the waves through
	start_mission("blockade", false)
	assert(missions.retime(3, 0.1))
	local let_through = 0
	while missions.result() == nil and let_through < (args.through_seconds or 600) do
		advance(5)
		let_through += 5
	end
	missions.publish()
	local waves = mission_state.waves()
	local findings: Findings = {
		missing_base = missing(expected, base),
		east_wrecks = wrecks,
		yards_in_harbor = yards,
		first_wave = #first,
		first_afloat = afloat,
		first_west = west,
		first_east = east,
		heading_south = round(after - before, 1),
		waited = waited,
		result = won or "none",
		sunk_escapes = sunk_escapes,
		lost_result = missions.result() or "none",
		lost_reason = game_phase.end_reason() or "none",
		escaped_shown = if waves ~= nil then waves.escaped or -1 else -1,
		lost_after = let_through,
	}
	findings.pass = findings.missing_base == ""
		and wrecks >= #mission_forces.CHANNEL_ENEMY
		and yards == 1
		and #first > 0
		and afloat == #first
		and west > 0
		and east > 0
		and after - before > 3
		and won == "won"
		and sunk_escapes == 0
		and findings.lost_result == "lost"
		and findings.lost_reason == "Too many ships got through"
		and findings.escaped_shown == mission_forces.BLOCKADE_LAYOUT.escape_limit
	return findings
end

-- Channel Crossing's defences, one at a time: `args.riptides` (5) Riptides, some 2,100 metal, sail to a point off
-- defence `args.target` (3, the island's south Agitator, the nearest to the harbour; numbered as
-- mission_forces.CHANNEL_ENEMY has them) and turn in at it. They set out from the harbour for one west of the middle,
-- and from the south end of the east strait for one east of it, every defence west of the middle being gone first.
-- Those `args.gone` numbers are gone first as well, and with `args.alone` every other defence. They fight for
-- `args.seconds` (120). The defence should be gone with at least two of the fleet left.
local function channel_agitator(args: Args): Findings
	local enemy = start_mission("channel", args.hard == true)
	advance(2)
	-- what stands of each of CHANNEL_ENEMY's things, by its number there: the enemy's nearest of that def to where it
	-- was laid
	local things: { Entity } = {}
	for _, each in mission_forces.CHANNEL_ENEMY do
		local at = Vector3.new(each.at.X, 0, each.at.Y)
		local nearest: Entity? = nil
		for _, entity in state.all() do
			if
				entity.alive
				and entity.team == enemy
				and entity.def_name == each.def_name
				and (
					nearest == nil
					or geometry.distance_2d(entity.position, at) < geometry.distance_2d(nearest.position, at)
				)
			then
				nearest = entity
			end
		end
		table.insert(things, nearest :: Entity)
	end
	local function is_defence(entity: Entity): boolean
		return entity.def_name == "agitator" or entity.def_name == "urchin" or entity.def_name == "coral"
	end
	local target = things[args.target or 3]
	assert(target ~= nil and is_defence(target), "there is no such defence")
	local on_island = target.position.X < 0
	local gone: { number } = args.gone or {}
	for index, thing in things do
		if
			thing ~= target
			and is_defence(thing)
			and (args.alone or table.find(gone, index) ~= nil or (on_island == false and thing.position.X < 0))
		then
			damage.apply(thing, 1e9, nil)
		end
	end
	-- the point the fleet sails to first: in the strait, beyond the target from the middle of its line
	local strait_x = if on_island then -150 else 120
	local ahead = if on_island then 25 else 100
	local beyond = if target.position.Z >= 0 then ahead else -ahead
	local fleet: { Entity } = {}
	for index = 1, args.riptides or 5 do
		local at = if on_island then Vector2.new(-165 + index * 6, 95) else Vector2.new(100 + index * 6, 235)
		local unit = spawning.spawn_near("riptide", OWN, stand("riptide", at), math.pi / 2)
		if unit ~= nil then
			-- with `args.tough`, a fleet that cannot be sunk, to see how long it takes and how many of its shots land
			if args.tough then
				harness.unkillable(unit)
			end
			table.insert(fleet, unit)
			orders.issue(unit, {
				{
					kind = "move",
					position = stand("riptide", Vector2.new(strait_x + (index - 3) * 8, target.position.Z + beyond)),
				},
				{ kind = "attack", target_id = target.id },
			}, false, false)
		end
	end
	local closest = math.huge
	local killed_at: number? = nil
	local began = state.now()
	advance(args.seconds or 120, function()
		if killed_at == nil and target.alive == false then
			killed_at = state.now() - began
		end
		for _, unit in fleet do
			if unit.alive then
				closest = math.min(closest, geometry.distance_2d(unit.position, target.position))
			end
		end
	end)
	local shots = 0
	local left, others = 0, 0
	for _, unit in fleet do
		shots += harness.shots_of(unit.id, 1)
		if unit.alive then
			left += 1
		end
	end
	local middle, orders_left = Vector3.zero, 0
	for _, unit in fleet do
		middle += unit.position / #fleet
		orders_left += #unit.orders
	end
	local each_fired: { string } = {}
	for index, agitator in things do
		if agitator ~= target and is_defence(agitator) and agitator.alive then
			others += 1
			table.insert(each_fired, `{index}:{harness.shots_of(agitator.id, 1)}`)
		end
	end
	local findings: Findings = {
		fleet = #fleet,
		fleet_left = left,
		target_standing = target.alive,
		target_health = round(target.health, 0),
		target_at = `{round(target.position.X, 1)},{round(target.position.Y, 1)},{round(target.position.Z, 1)}`,
		killed_at = if killed_at ~= nil then round(killed_at, 0) else -1,
		closest = round(closest, 1),
		fleet_shots = shots,
		others_standing = others,
		others_fired = table.concat(each_fired, " "),
		fleet_at = `{round(middle.X, 0)},{round(middle.Z, 0)}`,
		orders_left = orders_left,
	}
	findings.pass = target.alive == false and left >= 2
	return findings
end

-- Channel Crossing's landing: every Agitator, Urchin and Coral gone, `args.garpikes` (8) Garpikes, some 1,800 metal,
-- drive under the east strait from off the island to the enemy's shore and fight their way to its commander, for
-- `args.seconds` (150). The enemy's commander should be dead, and the mission won.
local function channel_landing(args: Args): Findings
	local enemy = start_mission("channel", false)
	advance(2)
	for _, entity in state.all() do
		if
			entity.alive
			and entity.team == enemy
			and (entity.def_name == "agitator" or entity.def_name == "urchin" or entity.def_name == "coral")
		then
			damage.apply(entity, 1e9, nil)
		end
	end
	advance(1)
	local enemy_start = point "enemy_start"
	local landing: { Entity } = {}
	for index = 1, args.garpikes or 8 do
		local at = Vector2.new(90, (index - 4.5) * 6)
		local unit = spawning.spawn_near("garpike", OWN, stand("garpike", at), math.pi / 2)
		if unit ~= nil then
			table.insert(landing, unit)
			orders.issue(unit, {
				{ kind = "move", position = stand("garpike", point "east_shore" + Vector2.new(14, at.Y)) },
				{ kind = "fight", position = stand("garpike", enemy_start) },
			}, false, false)
		end
	end
	advance(args.seconds or 150)
	local left = 0
	local where: { string } = {}
	for _, unit in landing do
		if unit.alive then
			left += 1
			table.insert(where, `{round(unit.position.X, 0)},{round(unit.position.Z, 0)}:{#unit.orders}`)
		end
	end
	local commander_health = -1
	for _, entity in state.all() do
		if entity.alive and entity.team == enemy and unit_defs.is_commander(entity.def) then
			commander_health = round(entity.health, 0)
		end
	end
	local findings: Findings = {
		garpikes = #landing,
		garpikes_left = left,
		garpikes_at = table.concat(where, " "),
		commander_health = commander_health,
		result = missions.result() or "none",
		enemy_left = census(enemy),
	}
	findings.pass = findings.result == "won"
	return findings
end

-- Blockade's balance: the harbour base alone, with nothing added, at the usual pace but `args.prep` (10) seconds to
-- prepare, played until too many ships get through or the waves run out. Which wave it falls to (`fell_to_wave`) says
-- how much the player has to add: the base's guards and fleet by the harbour should sink some of what passes down the
-- west strait, but nothing stops the east, so it should fall before the last.
local function blockade_balance(args: Args): Findings
	start_mission("blockade", false)
	assert(missions.retime(args.prep or 10, nil))
	local waited = 0
	while missions.result() == nil and waited < 900 do
		advance(5)
		waited += 5
	end
	missions.publish()
	local waves = mission_state.waves()
	local findings: Findings = {
		result = missions.result() or "none",
		reason = game_phase.end_reason() or "none",
		fell_to_wave = if waves ~= nil then waves.wave else -1,
		escaped = if waves ~= nil then waves.escaped or -1 else -1,
		seconds = waited,
	}
	findings.pass = findings.result == "lost" and findings.fell_to_wave < 7
	return findings
end

-- The Garpike (unit_defs/vehicle_t1.luau), on the channel: one on the floor of the west strait holds fire at a Riptide
-- afloat over it, as nothing but a torpedo is fired from under the water; one ashore on the enemy's shore fights a
-- guard beside it. Each gets `args.seconds` (15).
local function garpike(args: Args): Findings
	local seconds = args.seconds or 15
	local function duel(target_def: string, target_at: Vector2, shooter_at: Vector2): (number, number, boolean)
		local target = harness.unkillable(harness.spawn_resting(target_def, harness.ENEMY, target_at.X, target_at.Y))
		local shooter = harness.unkillable(harness.spawn_resting("garpike", OWN, shooter_at.X, shooter_at.Y))
		local under = unit_defs.submerged(shooter.def, shooter.position)
		orders.issue(shooter, { { kind = "attack", target_id = target.id } }, false, false)
		advance(seconds)
		local shots = harness.shots_of(shooter.id, 1)
		local hurt = harness.damage_to(target)
		harness.clear_world()
		return shots, hurt, under
	end
	ensure_team(OWN)
	ensure_team(harness.ENEMY)
	local under_shots, under_hurt, submerged = duel("riptide", Vector2.new(-110, -20), Vector2.new(-110, -8))
	local ashore = point "east_shore" + Vector2.new(14, 0)
	local ashore_shots, ashore_hurt, ashore_under = duel("guard", ashore + Vector2.new(4, 10), ashore)
	local findings: Findings = {
		submerged = submerged,
		under_water_shots = under_shots,
		under_water_damage = round(under_hurt, 0),
		ashore_submerged = ashore_under,
		ashore_shots = ashore_shots,
		ashore_damage = round(ashore_hurt, 0),
	}
	findings.pass = submerged and under_shots == 0 and ashore_under == false and ashore_hurt > 0
	return findings
end

local TESTS: { [string]: Test } = {
	garpike = { run = garpike, defaults = { preset = "channel" } },
	channel_agitator = { run = channel_agitator },
	channel_landing = { run = channel_landing },
	blockade_balance = { run = blockade_balance },
	channel_map = { run = channel_map, defaults = { preset = "channel" } },
	channel_crossing = { run = channel_crossing },
	channel_victory = { run = channel_victory },
	channel_hard = { run = channel_hard },
	blockade = { run = blockade },
}

return table.freeze(TESTS)
