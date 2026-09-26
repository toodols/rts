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

local placement = require(ServerScriptService.Server.placement)
local state = require(ServerScriptService.Server.state)
local maps = require(ServerScriptService.Server.maps)
local missions = require(ServerScriptService.Server.missions)
local spawning = require(ServerScriptService.Server.spawning)
local damage = require(ServerScriptService.Server.damage)
local orders = require(ServerScriptService.Server.orders)
local ai = require(ServerScriptService.Server.ai)
local channel = require(ServerScriptService.Server.missions.channel)
local blockade_mission = require(ServerScriptService.Server.missions.blockade)

local harness = require(script.Parent.harness)

local OWN = harness.OWN
local advance = harness.advance
local round = harness.round
local spawn = harness.spawn
local ensure_team = harness.ensure_team

local CROSSING = channel.CROSSING

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

-- The channel as built: the shores and the island stand above the water, both straits are deep all along, and nothing
-- that walks or drives gets from one shore to the other but a commander or a Garpike, which go along the floor, while a construction ship gets from the harbour to within its
-- build range of both landing beaches' shelves, a warship close behind it, and a ship to both ends of the channel, and a
-- commander wades across; bots and tanks get from a beach up to the enemy's ground. A shipyard goes down in the harbour and a bot lab on each
-- beach's shelf, and an extractor on every metal spot.
local function channel_map(_args: Args): Findings
	local player_start, enemy_start = point "player_start", point "enemy_start"
	local harbor = point "harbor"
	local beach_north, beach_south = point "beach_north", point "beach_south"
	-- how deep each strait is at its middle, at its shallowest along its length
	local shallowest = math.huge
	for z = -250, 250, 5 do
		shallowest = math.min(shallowest, ground_levels.WATER_LEVEL - heightmap.height_at(-110, z))
		shallowest = math.min(shallowest, ground_levels.WATER_LEVEL - heightmap.height_at(125, z))
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
		grunt_across = reaches("grunt", player_start, enemy_start),
		tank_across = reaches("incisor", player_start, enemy_start),
		commander_across = reaches("commander", player_start, enemy_start),
		garpike_across = reaches("garpike", player_start, enemy_start),
		ship_to_island = reaches("construction_ship", harbor, point "island" - Vector2.new(90, 0)),
		lab_on_island = placeable("bot_lab", point "island"),
		island_height = round(heightmap.height_at(point("island").X, point("island").Y), 1),
		-- a construction ship gets within its build range (24) of each beach's shelf, and a warship close behind
		ship_to_beach_north = reaches("construction_ship", harbor, beach_north - Vector2.new(18, 0)),
		ship_to_beach_south = reaches("construction_ship", harbor, beach_south - Vector2.new(18, 0)),
		warship_to_beach_north = reaches("riptide", harbor, beach_north - Vector2.new(24, 0)),
		ship_to_sea_north = reaches("riptide", harbor, point "sea_north"),
		ship_to_sea_south = reaches("riptide", harbor, point "sea_south"),
		-- Blockade's fleets: the biggest ship down each strait from end to end
		west_lane = reaches("buccaneer", point "sea_north", point "sea_south"),
		east_lane = reaches("buccaneer", point "east_north", point "east_south"),
		-- and the island's west shore: a construction ship within its build range (24) of a lab there
		lab_on_island_west = placeable("bot_lab", point "island_west"),
		ship_to_island_west = reaches("construction_ship", harbor, point "island_west" - Vector2.new(18, 0)),
		bot_up_beach_north = reaches("grunt", beach_north, enemy_start),
		bot_up_beach_south = reaches("grunt", beach_south, enemy_start),
		tank_up_beach_north = reaches("incisor", beach_north, enemy_start),
		shipyard_in_harbor = placeable("shipyard", harbor),
		lab_on_beach_north = placeable("bot_lab", beach_north),
		lab_on_beach_south = placeable("bot_lab", beach_south),
		spots = table.concat(spot_rows, " "),
	}
	findings.pass = findings.player_height > 3
		and findings.enemy_height > 3
		and shallowest >= 10
		and findings.grunt_across == false
		and findings.tank_across == false
		and findings.commander_across
		and findings.garpike_across
		and findings.ship_to_island
		and findings.lab_on_island
		and findings.island_height > 3
		and findings.ship_to_beach_north
		and findings.ship_to_beach_south
		and findings.warship_to_beach_north
		and findings.ship_to_sea_north
		and findings.ship_to_sea_south
		and findings.west_lane
		and findings.east_lane
		and findings.lab_on_island_west
		and findings.ship_to_island_west
		and findings.bot_up_beach_north
		and findings.bot_up_beach_south
		and findings.tank_up_beach_north
		and findings.shipyard_in_harbor
		and findings.lab_on_beach_north
		and findings.lab_on_beach_south
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
-- mission lays it out, every floating defence afloat where it says, with its commander and the AI playing it by the
-- mission's profile; the HUD should show the time limit counting down from the layout's; and in that time the AI should
-- build nothing its roster leaves out (no ship, lab for one, aircraft or hovercraft) and nothing of its should come over
-- to the player's shore. Then, with the time limit cut to just past what has gone, the mission should be lost with
-- "Time ran out".
local function channel_crossing(args: Args): Findings
	local enemy = start_mission("channel", false)
	local seconds = args.seconds or 120
	local expected = tally(mission_forces.CHANNEL_ENEMY)
	expected.commander = 1
	local at_start = census(enemy)
	local afloat, placed_off = 0, 0
	for _, each in mission_forces.CHANNEL_ENEMY do
		local def = unit_defs.get(each.def_name)
		if def.footing.water ~= "float" then
			continue
		end
		local nearest = math.huge
		for _, entity in state.all() do
			if entity.alive and entity.team == enemy and entity.def_name == each.def_name then
				nearest = math.min(nearest, (Vector2.new(entity.position.X, entity.position.Z) - each.at).Magnitude)
			end
		end
		if nearest <= PLACED_SLACK then
			afloat += 1
		else
			placed_off += 1
		end
	end
	missions.publish()
	local time_left_at_start = mission_state.time_left()
	local profile = ai.profile_of(enemy)

	local crossed = 0
	local forbidden: { [string]: boolean } = {}
	advance(seconds, function()
		for _, entity in state.all() do
			if entity.alive == false or entity.team ~= enemy then
				continue
			end
			if entity.position.X < -150 then
				crossed += 1
			end
			if CROSSING[entity.def_name] ~= true and expected[entity.def_name] == nil then
				forbidden[entity.def_name] = true
			end
		end
	end)
	local built = census(enemy)
	local forbidden_names: { string } = {}
	for name in forbidden do
		table.insert(forbidden_names, name)
	end
	table.sort(forbidden_names)

	missions.publish()
	local time_left_after = mission_state.time_left() or -1
	assert(missions.retime(seconds + 3, nil))
	advance(5)
	local findings: Findings = {
		missing_at_start = missing(expected, at_start),
		afloat = afloat,
		placed_off = placed_off,
		profile = if profile ~= nil then profile.name else "none",
		time_left_at_start = time_left_at_start or -1,
		time_left_after = time_left_after,
		enemy_things_after = built,
		forbidden = table.concat(forbidden_names, ", "),
		crossed = crossed,
		result = missions.result() or "none",
		reason = game_phase.end_reason() or "none",
	}
	findings.pass = findings.missing_at_start == ""
		and placed_off == 0
		and afloat > 0
		and findings.profile == "channel"
		and math.abs((time_left_at_start or 0) - mission_forces.CHANNEL_LAYOUT.time_limit) <= 2
		and time_left_after < (time_left_at_start or 0)
		and findings.forbidden == ""
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

-- Channel Crossing's hard mode: its enemy should have what the hard mode adds as well (another Coral past each end of
-- the line and more Agitators), and the hard mode's time limit on the clock; and the first raid should come as the layout says, its
-- bombers in the air and sent at the player's base, by a few seconds after.
local function channel_hard(_args: Args): Findings
	local enemy = start_mission("channel", true)
	local expected = tally(mission_forces.CHANNEL_ENEMY)
	for name, count in tally(mission_forces.CHANNEL_HARD_ENEMY) do
		expected[name] = (expected[name] or 0) + count
	end
	local at_start = census(enemy)
	missions.publish()
	local time_left = mission_state.time_left() or -1
	local layout = mission_forces.CHANNEL_LAYOUT
	-- something of the player's for the raid to go at
	local target = spawn("solar_collector", OWN, -270, -30)
	advance(layout.first_raid + 4)
	local bombers, attacking = 0, 0
	for _, entity in state.all() do
		if entity.alive and entity.team == enemy and entity.def_name == "whirlwind" then
			bombers += 1
			local order = entity.orders[1]
			if order ~= nil and order.kind == "attack" then
				attacking += 1
			end
		end
	end
	local findings: Findings = {
		missing_at_start = missing(expected, at_start),
		time_left = time_left,
		bombers = bombers,
		attacking = attacking,
		target_alive = target.alive,
		played_hard = missions.hard(),
	}
	findings.pass = findings.missing_at_start == ""
		and math.abs(time_left - layout.hard_time_limit) <= 2
		and bombers == layout.raid_bombers
		and attacking == bombers
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

-- Channel Crossing's balance, a combined assault on one beach: `args.riptides` (6) Riptides and `args.supporters` (6)
-- Supporters come up the east strait from off the island and are sent fighting to the water off the north beach, while
-- `args.garpikes` (10) Garpikes drive under the strait from the island's shore straight to the beach, and from there
-- fight their way to the Agitator over it; some 5,300 metal in all, what the player's economy pays for some twelve
-- minutes in (eight Garpikes are a coin toss). They fight for `args.seconds` (120). The beach's Urchin and guards and the Agitator over it should be gone, with something of the
-- assault left to cover a landing; and not all of the line should be, so that where the player lands matters. The
-- fleet alone (`garpikes = 0`) should not manage it: the Agitators outrange every ship.
local function channel_assault(args: Args): Findings
	local enemy = start_mission("channel", false)
	advance(2)
	local beach = mission_map.here "beach_north"
	local from = Vector2.new(95, beach.Y)
	local to = Vector2.new(beach.X - 20, beach.Y)
	local assault: { Entity } = {}
	local function launch(def_name: string, count: number, at: Vector2, chain: { types.Order })
		for index = 1, count do
			local here = at + Vector2.new(0, (index - count / 2) * 5)
			local unit = spawning.spawn_near(def_name, OWN, stand(def_name, here), math.pi / 2)
			if unit ~= nil then
				table.insert(assault, unit)
				orders.issue(unit, table.clone(chain), false, false)
			end
		end
	end
	-- what defends the beach: its Urchin, the guards over it, and the Agitator nearest it
	local defenders: { Entity } = {}
	local agitator: Entity? = nil
	for _, entity in state.all() do
		if entity.alive == false or entity.team ~= enemy or entity.kind ~= "building" then
			continue
		end
		if
			(entity.def_name == "urchin" or entity.def_name == "guard")
			and entity.position.X > 100
			and math.abs(entity.position.Z - beach.Y) <= 14
		then
			table.insert(defenders, entity)
		elseif
			entity.def_name == "agitator"
			and (agitator == nil or math.abs(entity.position.Z - beach.Y) < math.abs(agitator.position.Z - beach.Y))
		then
			agitator = entity
		end
	end
	assert(agitator ~= nil, "the enemy has no Agitator")
	launch(
		"riptide",
		args.riptides or 6,
		from - Vector2.new(0, 4),
		{ { kind = "fight", position = stand("riptide", to) } }
	)
	launch(
		"supporter",
		args.supporters or 6,
		from + Vector2.new(0, 4),
		{ { kind = "fight", position = stand("supporter", to) } }
	)
	-- the Garpikes drive straight under the line to the beach, and only then fight their way up to the Agitator
	launch("garpike", args.garpikes or 10, from - Vector2.new(20, 0), {
		{ kind = "move", position = stand("garpike", beach) },
		{ kind = "fight", position = agitator.position },
	})
	advance(args.seconds or 120)
	local standing = 0
	for _, defender in defenders do
		if defender.alive then
			standing += 1
		end
	end
	local left = 0
	for _, unit in assault do
		if unit.alive then
			left += 1
		end
	end
	local line_left = (census(enemy).urchin or 0) + (census(enemy).coral or 0)
	local findings: Findings = {
		assault = #assault,
		assault_left = left,
		beach_defenders = #defenders,
		beach_defenders_left = standing,
		agitator_standing = agitator.alive,
		line_left = line_left,
	}
	findings.pass = #defenders >= 3 and standing == 0 and agitator.alive == false and left >= 3 and line_left >= 3
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
-- afloat over it, as nothing but a torpedo is fired from under the water; one ashore on the enemy's beach shelf fights a
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
	local beach = point "beach_north"
	local ashore_shots, ashore_hurt, ashore_under = duel("guard", beach + Vector2.new(4, 10), beach)
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
	channel_assault = { run = channel_assault },
	blockade_balance = { run = blockade_balance },
	channel_map = { run = channel_map, defaults = { preset = "channel" } },
	channel_crossing = { run = channel_crossing },
	channel_victory = { run = channel_victory },
	channel_hard = { run = channel_hard },
	blockade = { run = blockade },
}

return table.freeze(TESTS)
