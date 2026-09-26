--!strict
-- Tests of the computer opponents (server/ai) and their profiles (shared/ai_profiles.luau): whole games, and each
-- thing a profile sets how it goes about: its roster, its defences, raids, hunts, waves, retreats and defending, and a
-- builder giving up an extractor another team has taken; and the fight
-- predictor some profiles ask (server/ai/combat_sim.luau). Each game plays `seconds` of game, a long time next to the other
-- tests.

local ReplicatedStorage = game:GetService "ReplicatedStorage"
local ServerScriptService = game:GetService "ServerScriptService"

local types = require(ReplicatedStorage.Shared.types)
local heightmap = require(ReplicatedStorage.Shared.heightmap)
local map_state = require(ReplicatedStorage.Shared.map_state)
local unit_defs = require(ReplicatedStorage.Shared.unit_defs)
local starts = require(ReplicatedStorage.Shared.starts)
local spots = require(ReplicatedStorage.Shared.spots)
local geometry = require(ReplicatedStorage.Shared.geometry)
local ai_profiles = require(ReplicatedStorage.Shared.ai_profiles)

local state = require(ServerScriptService.Server.state)
local ai = require(ServerScriptService.Server.ai)
local alliances = require(ServerScriptService.Server.alliances)
local spawning = require(ServerScriptService.Server.spawning)
local players = require(ServerScriptService.Server.players)
local orders = require(ServerScriptService.Server.orders)
local placement = require(ServerScriptService.Server.placement)
local economy = require(ServerScriptService.Server.economy)
local ai_commands = require(ServerScriptService.Server.pow_commands.ai)
local combat_sim = require(ServerScriptService.Server.ai.combat_sim)

local harness = require(script.Parent.harness)

local BYSTANDER = harness.BYSTANDER
local advance = harness.advance
local now = harness.now
local round = harness.round
local spawn = harness.spawn
local unkillable = harness.unkillable
local counts_of = harness.counts_of

type Entity = types.Entity
type TeamId = types.TeamId
type Args = harness.Args
type Findings = harness.Findings
type Test = harness.Test

-- The labs a team should never have two of.
local LABS = {
	"bot_lab",
	"vehicle_lab",
	"advanced_bot_lab",
	"advanced_vehicle_lab",
	"air_lab",
	"shipyard",
	"hovercraft_platform",
}
-- The economy's buildings an AI likes to keep together.
local CLUSTERED_DEFS = {
	"wind_turbine",
	"solar_collector",
	"advanced_solar_collector",
	"fusion_reactor",
	"energy_storage",
	"construction_turret",
}
-- The most seconds, added up over its constructors, an AI's constructors may stand within reach of a tower it has seen.
local MOST_SECONDS_IN_REACH = 10

-- `args[key]` if it is a `kind`, or `fallback`.
local function arg(args: Args, key: string, kind: string, fallback: any): any
	return if typeof(args[key]) == kind then args[key] else fallback
end

-- The AI profile a test asked for: `args.profile` (`fallback` if not given) with `args.overrides`, a table of the
-- profile's numbers, over it.
local function test_profile(args: Args, fallback: string): ai_profiles.Profile
	local name = arg(args, "profile", "string", fallback)
	local profile = ai_profiles.get(name)
	assert(profile ~= nil, `there is no AI profile "{name}"; there are {table.concat(ai_profiles.names(), ", ")}`)
	if typeof(args.overrides) == "table" then
		profile = ai_profiles.with(profile, args.overrides)
	end
	return profile
end

-- Puts down an AI opponent playing by `profile` and returns its team and where its commander stands.
local function spawn_ai(name: string, profile: ai_profiles.Profile?): (TeamId, Vector3)
	local team = ai.spawn_opponent(name, nil, nil, profile)
	assert(team ~= nil, `there was no room for {name}'s commander`)
	local commander = harness.commander_of(team)
	assert(commander ~= nil, `{name} has no commander`)
	return team, commander.position
end

-- Which way the middle of the map is from `home`, flat on the ground and of length 1 (along x from the very middle).
local function toward_middle(home: Vector3): Vector3
	local flat = geometry.flatten(-home)
	return if flat.Magnitude > 1 then flat.Unit else Vector3.new(1, 0, 0)
end

-- The metal spots, nearest `from` first, or furthest first with `furthest`.
local function spots_by_distance(from: Vector3, furthest: boolean): { Vector3 }
	local found: { Vector3 } = {}
	for _, spot in spots.all "metal" do
		table.insert(found, spot.position)
	end
	table.sort(found, function(a, b): boolean
		local a_distance = geometry.distance_2d(a, from)
		local b_distance = geometry.distance_2d(b, from)
		return if furthest then a_distance > b_distance else a_distance < b_distance
	end)
	return found
end

-- A finished extractor of `team` on the metal spot at `position`, or nil if one cannot go there.
local function put_extractor(team: TeamId, position: Vector3): Entity?
	return spawning.place("metal_extractor", team, position.X, position.Z, 0)
end

-- Plays on for `seconds`, a second at a time, calling `each(elapsed)` after every second, with team `powered`, if one
-- is given, needing no economy throughout (economy.set_unlimited), so that its towers can fire.
local function play(seconds: number, powered: TeamId?, each: ((number) -> ())?)
	if powered ~= nil then
		economy.set_unlimited(powered, true)
	end
	local elapsed = 0
	while elapsed < seconds do
		advance(1)
		elapsed += 1
		if each ~= nil then
			each(elapsed)
		end
	end
	if powered ~= nil then
		economy.set_unlimited(powered, false)
	end
end

-- Puts down `teams` AI opponents (2 by default) and lets them play for `seconds` (240), looking at every team each
-- `every` seconds (60): what it has of each def, finished or not, its incomes, how many of its economy's buildings stand
-- beside another of their kind, and whether it ever had two of any lab, which it never should. By the end each should
-- make more metal than its commander alone does. `real_seconds` is how long it all took. `line` ("bot" or "vehicle")
-- makes every team build from that line's labs, and `enemy_air` puts that many aircraft of a team of their own down,
-- idle in a corner, for every AI to see. `trace` (a team) keeps, after every `every` seconds, a line of what that team
-- has: its stores, and each of its things with where it stands, for holding a Studio run of the same game up against the
-- arena's (tools/ai_arena); `trace_detail` true keeps every thing's line rather than their sums.
local function ai_match(args: Args): Findings
	local count = arg(args, "teams", "number", 2)
	local seconds = arg(args, "seconds", "number", 240)
	local every = arg(args, "every", "number", 60)

	local teams: { TeamId } = {}
	for index = 1, count do
		local team = spawn_ai(`AI {index}`, nil)
		table.insert(teams, team)
		if args.line == "bot" or args.line == "vehicle" then
			ai.set_line(team, args.line)
		end
	end
	if typeof(args.enemy_air) == "number" and args.enemy_air > 0 then
		harness.ensure_team(BYSTANDER)
		local half_x, half_z = heightmap.half_extents()
		for index = 1, args.enemy_air do
			unkillable(spawn("whirlwind", BYSTANDER, -half_x + 10 + index * 4, half_z - 10))
		end
	end

	local duplicate_labs: { string } = {}
	local function look(team: TeamId): Findings
		local counts = counts_of(team)
		local mine: { Entity } = {}
		for _, entity in state.all() do
			if entity.alive and entity.team == team then
				table.insert(mine, entity)
			end
		end
		for _, lab in LABS do
			if (counts[lab] or 0) > 1 then
				table.insert(duplicate_labs, `team {team} had {counts[lab]} {lab}`)
			end
		end
		-- how many of each clustered def stand touching another of the same def
		local touching: { [string]: string } = {}
		for _, def_name in CLUSTERED_DEFS do
			local total, beside = 0, 0
			for _, entity in mine do
				if entity.def_name ~= def_name then
					continue
				end
				total += 1
				local half = unit_defs.footprint_half_extents(entity.def)
				for _, other in mine do
					if other ~= entity and other.def_name == def_name then
						local other_half = unit_defs.footprint_half_extents(other.def)
						local dx = math.abs(entity.position.X - other.position.X)
						local dz = math.abs(entity.position.Z - other.position.Z)
						if dx <= half.X + other_half.X + 0.5 and dz <= half.Y + other_half.Y + 0.5 then
							beside += 1
							break
						end
					end
				end
			end
			if total > 0 then
				touching[def_name] = `{beside}/{total}`
			end
		end
		local state_team = state.get_team(team) :: types.Team
		return {
			summary = ai.describe(team),
			metal_income = round(state_team.metal_income, 1),
			energy_income = round(state_team.energy_income, 1),
			counts = counts,
			beside_their_kind = touching,
		}
	end

	local traced: { string } = {}
	local function trace_line(elapsed: number)
		local team = args.trace
		local state_team = state.get_team(team) :: types.Team
		local things = {}
		local sx, sz, n = 0, 0, 0
		for _, entity in state.all() do
			if entity.alive and entity.team == team then
				n += 1
				sx += entity.position.X
				sz += entity.position.Z
				if args.trace_detail == true then
					table.insert(
						things,
						string.format(
							"%d %s %.4f %.4f %.3f %d",
							entity.id,
							entity.def_name,
							entity.position.X,
							entity.position.Z,
							entity.health,
							#entity.orders
						)
					)
				end
			end
		end
		table.sort(things)
		table.insert(
			traced,
			string.format(
				"%g m %.3f e %.3f n %d x %.3f z %.3f%s",
				elapsed,
				state_team.metal,
				state_team.energy,
				n,
				sx,
				sz,
				if #things > 0 then "\n  " .. table.concat(things, "\n  ") else ""
			)
		)
	end
	local started = os.clock()
	local snapshots: { Findings } = {}
	local elapsed = 0
	while elapsed < seconds do
		local span = math.min(every, seconds - elapsed)
		advance(span)
		elapsed += span
		local at: Findings = { at = elapsed }
		for _, team in teams do
			at[`team_{team}`] = look(team)
		end
		table.insert(snapshots, at)
		if args.trace ~= nil then
			trace_line(elapsed)
		end
	end
	local commander_metal = unit_defs.get("commander").metal_income or 0
	local all_growing = true
	for _, team in teams do
		all_growing = all_growing and (state.get_team(team) :: types.Team).metal_income > commander_metal
	end
	return {
		snapshots = snapshots,
		duplicate_labs = duplicate_labs,
		trace = if args.trace ~= nil then traced else nil,
		real_seconds = round(os.clock() - started, 1),
		pass = #duplicate_labs == 0 and all_growing,
	}
end

-- pow's ai_add, run through the command itself (harness.command): a player's commander at the
-- first box's usual start, then each case in turn. Every case reports, for each team it put down, the team, where its
-- commander stands, its allies and how far it is from the nearest other commander, and whatever it logged. An AI put
-- down with no spot given has to stand spawning.MIN_START_SPACING from every other commander (less a little for the commander
-- stepping off a blocked start), a boxed one in its box, one at a spot at that spot; a bad team or a spot off the map
-- puts nobody down and says why; and every AI asked for is either put down or answered with an error. "Crowd" asks for
-- more than the map has room for, so it has to end in an error.
local function ai_add_test(_args: Args): Findings
	local ai_add = harness.command(ai_commands, "ai_add")

	local function commanders(): { [TeamId]: Vector2 }
		local found: { [TeamId]: Vector2 } = {}
		for _, entity in state.all() do
			if entity.alive and unit_defs.is_commander(entity.def) then
				found[entity.team] = Vector2.new(entity.position.X, entity.position.Z)
			end
		end
		return found
	end
	local function nearest_other(team_id: TeamId, all: { [TeamId]: Vector2 }): number
		local nearest = math.huge
		for other, at in all do
			if other ~= team_id then
				nearest = math.min(nearest, (at - all[team_id]).Magnitude)
			end
		end
		return nearest
	end

	local player_team = players.create_team "Player"
	spawning.set_start(player_team, starts.default_spot(1))
	spawning.give_starting_force(player_team)
	local joined_team = players.create_team "Joined"

	-- `expect`: "free" (MIN_START_SPACING clear), "box" (that and in box 2), "spot" (at 100, -100), "error" (nobody put
	-- down) or "fill" (free, until an error)
	local cases: { { label: string, args: { any }, want: number, expect: string, ally: boolean?, profile: string? } } =
		{
			{ label = "default", args = {}, want = 1, expect = "free" },
			{ label = "pair", args = { "Pair", 2 }, want = 2, expect = "free" },
			{ label = "boxed", args = { "Boxed", 1, 2 }, want = 1, expect = "box" },
			{ label = "spot", args = { "Spot", 1, 100, -100 }, want = 1, expect = "spot" },
			{
				label = "friend",
				args = { "Friend", 1, 0, "ally", player_team },
				want = 1,
				expect = "free",
				ally = true,
			},
			{ label = "lined", args = { "Lined", 1, 0, "enemy", 0, "vehicle" }, want = 1, expect = "free" },
			{
				label = "profiled",
				args = { "Profiled", 1, 0, "enemy", 0, "any", "raider" },
				want = 1,
				expect = "free",
				profile = "raider",
			},
			{ label = "bad_profile", args = { "x", 1, 0, "enemy", 0, "any", "nobody" }, want = 0, expect = "error" },
			{ label = "bad_team", args = { "x", 1, 0, "ally", 999 }, want = 0, expect = "error" },
			{ label = "off_map", args = { "Off", 1, 9999, 9999 }, want = 0, expect = "error" },
			{ label = "joined", args = { "J", 1, 0, "join", joined_team }, want = 1, expect = "free" },
			{ label = "many", args = { "Many", 6 }, want = 6, expect = "free" },
			{ label = "crowd", args = { "Crowd", 60 }, want = 60, expect = "fill" },
		}

	local spacing = spawning.MIN_START_SPACING - 20
	local results: { Findings } = {}
	local pass = true
	for _, case in cases do
		local before = commanders()
		local logs = ai_add(case.args, nil)
		local after = commanders()
		local placed: { Findings } = {}
		local errors: { string } = {}
		for _, log in logs do
			if log.type == "error" then
				table.insert(errors, log.value)
			end
		end
		local ok = true
		for team_id, at in after do
			if typeof(before[team_id]) == "Vector2" then
				continue
			end
			local allies: { number } = {}
			for _, ally in alliances.group_of(team_id, state.all_teams()) do
				if ally ~= team_id then
					table.insert(allies, ally)
				end
			end
			table.sort(allies)
			local nearest = nearest_other(team_id, after)
			table.insert(placed, {
				team = team_id,
				x = round(at.X, 1),
				z = round(at.Y, 1),
				allies = allies,
				nearest = round(nearest, 1),
			})
			local spot_ok = if case.expect == "spot"
				then (at - Vector2.new(100, -100)).Magnitude < 30
				elseif case.expect == "box" then nearest >= spacing and starts.in_box(2, at.X, at.Y)
				else nearest >= spacing
			local ally_ok = alliances.are_allied(team_id, player_team) == (case.ally == true)
			ok = ok and spot_ok and ally_ok and ai.is_ai(team_id)
			local profile = ai.profile_of(team_id)
			local profile_name = if profile ~= nil then profile.name else nil
			ok = ok and profile_name == (case.profile or "default")
		end
		table.sort(placed, function(a, b): boolean
			return a.team < b.team
		end)
		if case.expect == "error" then
			ok = ok and #placed == 0 and #errors > 0
		elseif case.expect == "fill" then
			ok = ok and #placed < case.want and #errors > 0
		else
			ok = ok and #placed == case.want and #errors == 0
		end
		-- every AI asked for is put down or answered with an error
		ok = ok and (#placed == case.want or #errors > 0)
		pass = pass and ok
		local log_text: { string } = {}
		for _, log in logs do
			table.insert(log_text, log.value)
		end
		table.insert(results, {
			label = case.label,
			ok = ok,
			placed = placed,
			log = table.concat(log_text, "\n"),
		})
	end

	-- the closest two commanders but the one put at a spot, which stands where it is told whatever is near
	local total = 0
	local closest = math.huge
	local final = commanders()
	local told: { [TeamId]: boolean } = {}
	for _, result in results do
		if result.label == "spot" then
			for _, one in result.placed do
				told[one.team] = true
			end
		end
	end
	for team_id, at in final do
		total += 1
		for other, other_at in final do
			if other ~= team_id and told[team_id] == nil and told[other] == nil then
				closest = math.min(closest, (at - other_at).Magnitude)
			end
		end
	end
	return {
		pass = pass and closest >= spacing,
		preset = map_state.preset().name,
		boxes = starts.box_count(),
		min_spacing = spawning.MIN_START_SPACING,
		commanders = total,
		closest = round(closest, 1),
		cases = results,
	}
end

-- Puts down an AI opponent and `towers` (6) unkillable guard towers of a team of their own beside the metal spots
-- nearest its home past `from` (80) studs, and lets it play for `seconds` (480), looking once a second at how many of
-- its constructors stand within reach of a tower. `builder_seconds_in_reach` should stay near nothing, and it should lose
-- no constructor to them.
local function ai_danger(args: Args): Findings
	local seconds = arg(args, "seconds", "number", 480)
	local tower_count = arg(args, "towers", "number", 6)
	local from = arg(args, "from", "number", 80)
	local team, home = spawn_ai("AI", nil)
	local tower_spots: { Vector3 } = {}
	for _, position in spots_by_distance(home, false) do
		if geometry.distance_2d(position, home) >= from then
			table.insert(tower_spots, position)
		end
	end
	harness.ensure_team(BYSTANDER)
	local towers: { Entity } = {}
	for index = 1, math.min(tower_count, #tower_spots) do
		local spot = tower_spots[index]
		local toward = geometry.flatten(home - spot)
		local at = spot + (if toward.Magnitude > 1 then toward.Unit else Vector3.new(1, 0, 0)) * 8
		table.insert(towers, unkillable(spawn("guard", BYSTANDER, at.X, at.Z)))
	end
	local reach = (unit_defs.attack_range(unit_defs.get "guard") :: number) + 2

	-- a constructor, of the kind that puts extractors down, and not the commander
	local function is_constructor(entity: Entity): boolean
		local def = entity.def
		return entity.kind == "unit"
			and unit_defs.is_commander(def) == false
			and table.find(unit_defs.build_options(def), "metal_extractor") ~= nil
	end
	local in_reach = 0
	local constructors: { [number]: Entity } = {}
	local started = os.clock()
	play(seconds, nil, function()
		for _, entity in state.all() do
			if entity.alive == false or entity.team ~= team or is_constructor(entity) == false then
				continue
			end
			constructors[entity.id] = entity
			for _, tower in towers do
				if geometry.distance_2d(entity.position, tower.position) <= reach then
					in_reach += 1
					break
				end
			end
		end
	end)
	local lost = 0
	for _, constructor in constructors do
		if constructor.alive == false then
			lost += 1
		end
	end
	return {
		summary = ai.describe(team),
		towers = #towers,
		tower_reach = round(reach, 1),
		builder_seconds_in_reach = in_reach,
		constructors_lost = lost,
		counts = counts_of(team),
		real_seconds = round(os.clock() - started, 1),
		pass = in_reach <= MOST_SECONDS_IN_REACH and lost == 0,
	}
end

-- The roster lock: an AI playing by `profile` ("swarm", whose roster leaves out some of what its bot lab and its
-- constructors could make) plays for `seconds` (240), and every second everything its team has, everything its labs
-- have queued and everything its builders have been told to build is looked at. `outside` lists each def seen that its
-- roster does not have (the commander it starts with aside), and should be empty; `counts` shows it built at all.
local function ai_roster(args: Args): Findings
	local seconds = arg(args, "seconds", "number", 240)
	local profile = test_profile(args, "swarm")
	local roster = profile.roster
	assert(roster ~= nil, `the profile "{profile.name}" has no roster`)
	local team = spawn_ai("AI", profile)
	local started_with: { [string]: boolean } = {}
	for name in counts_of(team) do
		started_with[name] = true
	end
	local outside: { [string]: string } = {}
	local function check(def_name: string, how: string)
		if roster[def_name] ~= true and started_with[def_name] ~= true and outside[def_name] == nil then
			outside[def_name] = `{how} at {round(now(), 0)} s`
		end
	end
	local started = os.clock()
	local queued_total = 0
	play(seconds, nil, function()
		for _, entity in state.all() do
			if entity.alive == false or entity.team ~= team then
				continue
			end
			check(entity.def_name, "stood")
			for _, queued in entity.queue do
				queued_total += 1
				check(queued, "queued")
			end
			for _, order in entity.orders do
				if order.kind == "build" and order.def_name ~= nil then
					check(order.def_name, "ordered")
				end
			end
		end
	end)
	local outside_list: { string } = {}
	for name, how in outside do
		table.insert(outside_list, `{name} ({how})`)
	end
	table.sort(outside_list)
	local counts = counts_of(team)
	local built = 0
	for name, count in counts do
		if started_with[name] ~= true then
			built += count
		end
	end
	return {
		pass = #outside_list == 0 and built > 0 and queued_total > 0,
		profile = profile.name,
		outside = outside_list,
		built = built,
		queued_seen = queued_total,
		counts = counts,
		summary = ai.describe(team),
		real_seconds = round(os.clock() - started, 1),
	}
end

-- Defence weight: two AIs play side by side for `seconds` (300), one by the default profile and one by `profile`
-- ("raider", which guards none of its extractors), and what each built to stand guard is counted: guards and
-- anti-air, against its extractors. The default should have guards by its extractors, and the other no more than
-- `max_guards` (0) plus its profile's home_guards.
local function ai_defense(args: Args): Findings
	local seconds = arg(args, "seconds", "number", 300)
	local max_guards = arg(args, "max_guards", "number", 0)
	local profile = test_profile(args, "raider")
	local default_team = spawn_ai("Default", ai_profiles.DEFAULT)
	local other_team = spawn_ai(profile.name, profile)
	local started = os.clock()
	local most_guards = { default = 0, other = 0 }
	play(seconds, nil, function(elapsed: number)
		if elapsed % 5 ~= 0 then
			return
		end
		most_guards.default = math.max(most_guards.default, counts_of(default_team).guard or 0)
		most_guards.other = math.max(most_guards.other, counts_of(other_team).guard or 0)
	end)
	local function look(team: TeamId): Findings
		local counts = counts_of(team)
		return {
			guards = counts.guard or 0,
			thistles = counts.thistle or 0,
			extractors = counts.metal_extractor or 0,
			summary = ai.describe(team),
		}
	end
	local default_look = look(default_team)
	return {
		pass = most_guards.other <= max_guards + profile.home_guards and default_look.guards > 0,
		profile = profile.name,
		most_guards = most_guards,
		default = default_look,
		other = look(other_team),
		real_seconds = round(os.clock() - started, 1),
	}
end

-- Harassment: an AI playing by `profile` ("raider") starts with a finished bot lab and `raiders` (6) of `unit` ("tick")
-- by home, and a team of an enemy's stands at the far end of the map: a finished extractor on each of the `extractors`
-- (6) metal spots furthest from the AI and `builders` (2) constructors beside them, nothing to defend them. For `seconds`
-- (150) it plays; what it sent (ai.report) and what the enemy lost is looked at. Every raid should be its profile's
-- raid_size, go after an extractor or a constructor, and the enemy should lose some; `army_attacked` says whether the
-- main army set out too, which it has no need to. With `guarded`, an unkillable guard with the energy to fire stands by
-- each extractor and constructor, and no raid should go out at all. With `chain`, some raid should have seen at least
-- two of what it went after destroyed before it came home (`most_kills`), going on from one undefended target to the
-- next ("sim_barb" raids so, by its raid_rule "sim").
local function ai_raids(args: Args): Findings
	local seconds = arg(args, "seconds", "number", 150)
	local raider_count = arg(args, "raiders", "number", 6)
	local unit = arg(args, "unit", "string", "tick")
	local extractor_count = arg(args, "extractors", "number", 6)
	local builder_count = arg(args, "builders", "number", 2)
	local guarded = args.guarded == true
	local profile = test_profile(args, "raider")
	assert(profile.raid_size ~= nil, `the profile "{profile.name}" does not raid`)

	local team, home = spawn_ai("AI", profile)
	local toward = toward_middle(home)
	local lab_at = home + toward * 20
	spawning.spawn_near(
		if profile.line == "vehicle" then "vehicle_lab" else "bot_lab",
		team,
		heightmap.ground_position(lab_at.X, lab_at.Z),
		0
	)
	for index = 1, raider_count do
		local at = home + toward * 10 + Vector3.new(index * 3 - raider_count * 1.5, 0, 6)
		spawning.spawn_near(unit, team, heightmap.ground_position(at.X, at.Z), 0)
	end

	local enemy = BYSTANDER
	harness.ensure_team(enemy)
	local extractors: { Entity } = {}
	for _, position in spots_by_distance(home, true) do
		if #extractors >= extractor_count then
			break
		end
		local extractor = put_extractor(enemy, position)
		if extractor ~= nil then
			table.insert(extractors, extractor)
		end
	end
	assert(#extractors > 0, "there was nowhere to put the enemy's extractors")
	local builders: { Entity } = {}
	for index = 1, builder_count do
		local near = extractors[(index - 1) % #extractors + 1].position
		local placed = spawning.spawn_near("construction_bot", enemy, near + Vector3.new(6, 0, 6), 0)
		if placed ~= nil then
			table.insert(builders, placed)
		end
	end
	if guarded then
		local guarded_things: { Entity } = table.clone(extractors)
		for _, builder in builders do
			table.insert(guarded_things, builder)
		end
		for _, thing in guarded_things do
			local guard = spawning.spawn_near("guard", enemy, thing.position + Vector3.new(-8, 0, -8), 0)
			if guard ~= nil then
				unkillable(guard)
			end
		end
	end

	local started = os.clock()
	local attacked = false
	play(seconds, enemy, function()
		local report = ai.report(team)
		if report ~= nil and report.mode == "attack" then
			attacked = true
		end
	end)
	local extractors_lost, builders_lost = 0, 0
	for _, extractor in extractors do
		if extractor.alive == false or state.get(extractor.id) == nil then
			extractors_lost += 1
		end
	end
	for _, builder in builders do
		if builder.alive == false or state.get(builder.id) == nil then
			builders_lost += 1
		end
	end
	local report = ai.report(team) :: { [string]: any }
	local right_size, right_target = true, true
	local most_kills = 0
	for _, raid in report.raids do
		right_size = right_size and raid.units == profile.raid_size
		right_target = right_target and (raid.target == "metal_extractor" or raid.target == "construction_bot")
		most_kills = math.max(most_kills, raid.kills or 0)
	end
	local pass = if guarded
		then #report.raids == 0 and extractors_lost == 0
		else #report.raids > 0 and right_size and right_target and extractors_lost + builders_lost > 0
	if args.chain == true then
		pass = pass and most_kills >= 2
	end
	return {
		pass = pass,
		profile = profile.name,
		guarded = guarded,
		raids = report.raids,
		raids_out = report.raids_out,
		most_kills = most_kills,
		enemy_extractors = #extractors,
		extractors_lost = extractors_lost,
		enemy_builders = #builders,
		builders_lost = builders_lost,
		army_attacked = attacked,
		summary = ai.describe(team),
		real_seconds = round(os.clock() - started, 1),
	}
end

-- Escalation: an AI playing by `profile` ("swarm", with `growth` (0.5) as its wave_growth a wave and its profile's
-- wave_cap_seconds unless `cap` is given) is given a `unit` ("grunt") at home every `feed_every` (2) seconds, and across
-- the map stand `towers` (2) unkillable guards with the energy to fire, which beat every wave in the end, so that it
-- pulls back, regroups and goes again. For `seconds` (360) it plays; each wave it sent is listed with how many went,
-- what they were worth, what a wave had to be worth then and how it ended. There should be at least two waves, and what
-- a wave has to be worth should grow from the first wave to the last, and so should the waves.
local function ai_waves(args: Args): Findings
	local seconds = arg(args, "seconds", "number", 360)
	local feed_every = arg(args, "feed_every", "number", 2)
	local unit = arg(args, "unit", "string", "grunt")
	local tower_count = arg(args, "towers", "number", 2)
	local overrides: { [string]: any } = if typeof(args.overrides) == "table" then table.clone(args.overrides) else {}
	overrides.wave_growth = arg(args, "growth", "number", overrides.wave_growth or 0.5)
	if typeof(args.cap) == "number" then
		overrides.wave_cap_seconds = args.cap
	end
	local profile = test_profile({ profile = args.profile, overrides = overrides }, "swarm")

	local team, home = spawn_ai("AI", profile)
	local toward = toward_middle(home)
	local enemy = BYSTANDER
	harness.ensure_team(enemy)
	-- the far side of the map from it
	local far = Vector3.new(-home.X, 0, -home.Z)
	for index = 1, tower_count do
		local at = far + Vector3.new(-toward.Z, 0, toward.X) * (index - (tower_count + 1) / 2) * 10
		local tower = spawning.spawn_near("guard", enemy, heightmap.ground_position(at.X, at.Z), 0)
		if tower ~= nil then
			unkillable(tower)
		end
	end

	local started = os.clock()
	local fed = 0
	local next_feed = 0
	play(seconds, enemy, function(elapsed: number)
		if elapsed >= next_feed then
			next_feed = elapsed + feed_every
			local at = home + toward * 30
			if spawning.spawn_near(unit, team, heightmap.ground_position(at.X, at.Z), 0) ~= nil then
				fed += 1
			end
		end
	end)
	local report = ai.report(team) :: { [string]: any }
	local waves = report.waves
	local rounded: { Findings } = {}
	for _, wave in waves do
		table.insert(rounded, {
			at = round(wave.at, 0),
			units = wave.units,
			worth = round(wave.worth, 0),
			needed = round(wave.needed, 0),
			ended = wave.ended or "out",
		})
	end
	local first, last = waves[1], waves[#waves]
	return {
		pass = #waves >= 2 and last.needed > first.needed and last.units > first.units,
		profile = profile.name,
		growth = profile.wave_growth,
		cap = profile.wave_cap_seconds or "none",
		fed = fed,
		waves = rounded,
		needed_now = round(report.wave_needed, 0),
		summary = ai.describe(team),
		real_seconds = round(os.clock() - started, 1),
	}
end

-- Retreat and repair: an AI playing by `profile` ("barb", which sends fighters under half their health home) starts
-- with a finished bot lab and a construction turret beside home, and `count` (4) of `unit` ("grunt") out in front of
-- home at `hurt` (0.3) of their health. For `seconds` (60) it plays; each should have gone home and been mended to
-- whole, and the AI should have had some of them retreating on the way. With a profile that does not retreat
-- ("default"), `healed` should stay 0: they are never sent to be mended.
local function ai_retreat(args: Args): Findings
	local seconds = arg(args, "seconds", "number", 60)
	local count = arg(args, "count", "number", 4)
	local unit = arg(args, "unit", "string", "grunt")
	local hurt = arg(args, "hurt", "number", 0.3)
	local profile = test_profile(args, "barb")
	local team, home = spawn_ai("AI", profile)
	local toward = toward_middle(home)
	local side = Vector3.new(-toward.Z, 0, toward.X)
	local lab_at = home + toward * 20
	spawning.spawn_near("bot_lab", team, heightmap.ground_position(lab_at.X, lab_at.Z), 0)
	local turret_at = home - toward * 8 + side * 10
	local mender =
		spawning.spawn_near("construction_turret", team, heightmap.ground_position(turret_at.X, turret_at.Z), 0)
	local hurt_units: { Entity } = {}
	for index = 1, count do
		local at = home + toward * 70 + side * (index * 4 - count * 2)
		local placed = spawning.spawn_near(unit, team, heightmap.ground_position(at.X, at.Z), 0)
		if placed ~= nil then
			placed.health = placed.max_health * hurt
			table.insert(hurt_units, placed)
		end
	end

	local started = os.clock()
	local most_retreating = 0
	play(seconds, nil, function()
		local report = ai.report(team)
		if report ~= nil then
			most_retreating = math.max(most_retreating, report.retreating)
		end
	end)
	local healed = 0
	local shares: { number } = {}
	for _, hurt_unit in hurt_units do
		local share = if hurt_unit.alive then hurt_unit.health / hurt_unit.max_health else 0
		table.insert(shares, round(share, 2))
		if share >= 0.98 then
			healed += 1
		end
	end
	local retreats = profile.retreat_health ~= nil
	return {
		pass = if retreats then healed == #hurt_units and most_retreating > 0 else healed == 0,
		profile = profile.name,
		turret = mender ~= nil,
		units = #hurt_units,
		healed = healed,
		health_shares = shares,
		most_retreating = most_retreating,
		summary = ai.describe(team),
		real_seconds = round(os.clock() - started, 1),
	}
end

-- Defence in proportion: an AI playing by `profile` ("barb") has `army` (10) of `unit` ("grunt") waiting at its rally
-- point, and an enemy `intruder` ("tick") comes to one of its extractors, `alert` studs off it (20). For `seconds` (20)
-- it plays; with the profile's defend_share only a few of its army should go (the most `defenders` it had is
-- under the army and over 0), and with none ("default") all of them. Its hunters are kept home (no hunt_groups, unless
-- `overrides` gives some), since a hunt would see the intruder off first; ai_hunt looks at them.
local function ai_defend(args: Args): Findings
	local seconds = arg(args, "seconds", "number", 20)
	local army_size = arg(args, "army", "number", 10)
	local unit = arg(args, "unit", "string", "grunt")
	local intruder_def = arg(args, "intruder", "string", "tick")
	local alert = arg(args, "alert", "number", 20)
	local profile = test_profile(args, "barb")
	if typeof(args.overrides) ~= "table" or args.overrides.hunt_groups == nil then
		profile = ai_profiles.without(profile, { "hunt_groups" })
	end
	local team, home = spawn_ai("AI", profile)
	local toward = toward_middle(home)
	for index = 1, army_size do
		local at = home + toward * 40 + Vector3.new(index * 3 - army_size * 1.5, 0, 0)
		spawning.spawn_near(unit, team, heightmap.ground_position(at.X, at.Z), 0)
	end
	-- an extractor of its own on the nearest spot over 60 studs from home, and the intruder beside it
	local side = Vector3.new(-toward.Z, 0, toward.X)
	local extractor: Entity? = nil
	for _, position in spots_by_distance(home, false) do
		if geometry.distance_2d(position, home) > 60 then
			extractor = put_extractor(team, position)
			if extractor ~= nil then
				break
			end
		end
	end
	assert(extractor ~= nil, "there was nowhere to put its extractor")
	local enemy = BYSTANDER
	harness.ensure_team(enemy)
	local intruder_at = extractor.position + side * alert
	local intruder = unkillable(spawn(intruder_def, enemy, intruder_at.X, intruder_at.Z))

	local started = os.clock()
	local most_defenders = 0
	local recalled = false
	play(seconds, nil, function()
		local report = ai.report(team) :: { [string]: any }
		most_defenders = math.max(most_defenders, report.defenders)
		recalled = recalled or report.mode == "defend"
	end)
	local proportional = profile.defend_share ~= nil
	return {
		pass = if proportional
			then most_defenders > 0 and most_defenders < army_size and recalled == false
			else recalled,
		profile = profile.name,
		army = army_size,
		most_defenders = most_defenders,
		whole_army_sent = recalled,
		intruder_alive = intruder.alive,
		summary = ai.describe(team),
		real_seconds = round(os.clock() - started, 1),
	}
end

-- Hunters: an AI playing by `profile` ("sim_barb", which hunts) has `army` (8) of `unit` ("tick") waiting at its rally
-- point and an extractor of its own on the nearest spot over 60 studs from home, and `intruders` (2) of an enemy's
-- `intruder` ("tick") come to it, `alert` studs off (20). For `seconds` (40) it plays; a hunt should go out
-- (ai.report's hunts) of fewer than its whole army, the intruders should all be dead by the end, and the army should
-- not have been called home (`whole_army_sent`). With a profile that does not hunt, `hunts` stays empty.
local function ai_hunt(args: Args): Findings
	local seconds = arg(args, "seconds", "number", 40)
	local army_size = arg(args, "army", "number", 8)
	local unit = arg(args, "unit", "string", "tick")
	local intruder_def = arg(args, "intruder", "string", "tick")
	local intruder_count = arg(args, "intruders", "number", 2)
	local alert = arg(args, "alert", "number", 20)
	local profile = test_profile(args, "sim_barb")
	local team, home = spawn_ai("AI", profile)
	local toward = toward_middle(home)
	for index = 1, army_size do
		local at = home + toward * 40 + Vector3.new(index * 3 - army_size * 1.5, 0, 0)
		spawning.spawn_near(unit, team, heightmap.ground_position(at.X, at.Z), 0)
	end
	local side = Vector3.new(-toward.Z, 0, toward.X)
	local extractor: Entity? = nil
	for _, position in spots_by_distance(home, false) do
		if geometry.distance_2d(position, home) > 60 then
			extractor = put_extractor(team, position)
			if extractor ~= nil then
				break
			end
		end
	end
	assert(extractor ~= nil, "there was nowhere to put its extractor")
	local enemy = BYSTANDER
	harness.ensure_team(enemy)
	local intruders: { Entity } = {}
	for index = 1, intruder_count do
		local at = extractor.position + side * (alert + index * 3)
		table.insert(intruders, spawn(intruder_def, enemy, at.X, at.Z))
	end

	local started = os.clock()
	local recalled = false
	play(seconds, nil, function()
		local report = ai.report(team) :: { [string]: any }
		recalled = recalled or report.mode == "defend"
	end)
	local alive = 0
	for _, intruder in intruders do
		if intruder.alive and state.get(intruder.id) ~= nil then
			alive += 1
		end
	end
	local report = ai.report(team) :: { [string]: any }
	local hunts = report.hunts
	local most_hunters = 0
	for _, hunt in hunts do
		most_hunters = math.max(most_hunters, hunt.units)
	end
	return {
		pass = if profile.hunt_groups ~= nil
			then #hunts > 0 and most_hunters < army_size and alive == 0 and recalled == false
			else #hunts == 0,
		profile = profile.name,
		army = army_size,
		hunts = hunts,
		most_hunters = most_hunters,
		intruders_left = alive,
		whole_army_sent = recalled,
		summary = ai.describe(team),
		real_seconds = round(os.clock() - started, 1),
	}
end

-- A spot lost on the way: an AI playing by `profile` ("sim_barb") has a constructor sent to put an extractor on the
-- metal spot nearest home that is over `distance` (80) studs from it, and once it is on its way an enemy's extractor is
-- put on that spot. Within `within` seconds (3) the constructor should have given that errand up (`still_going` false)
-- rather than walk there and stand at it.
local function ai_lost_spot(args: Args): Findings
	local within = arg(args, "within", "number", 3)
	local distance = arg(args, "distance", "number", 80)
	local profile = test_profile(args, "sim_barb")
	local team, home = spawn_ai("AI", profile)
	local at = home + toward_middle(home) * 10
	local builder = spawning.spawn_near("construction_bot", team, heightmap.ground_position(at.X, at.Z), 0)
	assert(builder ~= nil, "there was no room for the constructor")
	local spot: Vector3? = nil
	for _, position in spots_by_distance(home, false) do
		if geometry.distance_2d(position, home) > distance then
			spot = position
			break
		end
	end
	assert(spot ~= nil, "there was no spot far enough from home")
	local center = placement.ground_center("metal_extractor", spot.X, spot.Z)
	orders.issue(builder, {
		{ kind = "build", position = center, target_id = nil, def_name = "metal_extractor", facing = 0 },
	}, false, false)
	advance(2)
	local enemy = BYSTANDER
	harness.ensure_team(enemy)
	local taken = put_extractor(enemy, spot)
	assert(taken ~= nil, "the enemy's extractor could not go on the spot")
	local started = os.clock()
	advance(within)
	local still_going = false
	for _, order in builder.orders do
		if order.kind == "build" and order.position ~= nil and geometry.distance_2d(order.position, center) < 1 then
			still_going = true
		end
	end
	return {
		pass = builder.alive and still_going == false,
		profile = profile.name,
		still_going = still_going,
		orders_now = #builder.orders,
		real_seconds = round(os.clock() - started, 1),
	}
end

-- Two AIs, one by `a` ("default") and one by `b` ("barb"), play each other from starts across the map for `seconds`
-- (300), looked at every `every` seconds (60): each one's incomes, what everything it has is worth (as unit_defs.power
-- counts it), what it has lost and killed of finished things, its extractors and whether its commander stands, and
-- what its AI has sent out. `swap` puts `b` down first, to see what the starts have to do with it; `line` makes both
-- build from that line's labs. `ahead` names the one that has lost the less and killed the more, all told, at the end,
-- and `decided` the one whose commander stands if only one does. Which should win is what is being found out, so it is
-- reported, not judged.
local function ai_versus(args: Args): Findings
	local seconds = arg(args, "seconds", "number", 300)
	local every = arg(args, "every", "number", 60)
	local profile_a = test_profile({ profile = args.a, overrides = args.a_overrides }, "default")
	local profile_b = test_profile({ profile = args.b, overrides = args.b_overrides }, "barb")
	local first, second = profile_a, profile_b
	if args.swap == true then
		first, second = profile_b, profile_a
	end
	local team_first = spawn_ai(`{first.name} (1)`, first)
	local team_second = spawn_ai(`{second.name} (2)`, second)
	local team_a = if args.swap == true then team_second else team_first
	local team_b = if args.swap == true then team_first else team_second
	for _, team in { team_a, team_b } do
		if args.line == "bot" or args.line == "vehicle" then
			ai.set_line(team, args.line)
		end
	end

	-- every finished thing of either team, what it is worth, and what each team has lost
	local known: { [number]: { team: TeamId, worth: number } } = {}
	local lost: { [TeamId]: number } = { [team_a] = 0, [team_b] = 0 }
	local function tally()
		local seen: { [number]: boolean } = {}
		for _, entity in state.all() do
			if
				entity.alive
				and entity.state == "active"
				and (entity.team == team_a or entity.team == team_b)
				and entity.kind ~= "wreck"
			then
				seen[entity.id] = true
				if known[entity.id] == nil then
					known[entity.id] = { team = entity.team, worth = unit_defs.power(entity.def) }
				end
			end
		end
		for id, what in known do
			if seen[id] ~= true then
				lost[what.team] += what.worth
				known[id] = nil
			end
		end
	end
	local function look(team: TeamId, other: TeamId): Findings
		local worth, extractors = 0, 0
		for _, entity in state.all() do
			if entity.alive and entity.team == team and entity.kind ~= "wreck" then
				worth += unit_defs.power(entity.def)
				if entity.def_name == "metal_extractor" or entity.def_name == "advanced_metal_extractor" then
					extractors += 1
				end
			end
		end
		local state_team = state.get_team(team) :: types.Team
		local report = ai.report(team) :: { [string]: any }
		return {
			profile = report.profile,
			metal_income = round(state_team.metal_income, 1),
			energy_income = round(state_team.energy_income, 0),
			worth = round(worth, 0),
			lost = round(lost[team], 0),
			killed = round(lost[other], 0),
			extractors = extractors,
			commander = harness.commander_of(team) ~= nil,
			waves_sent = report.waves_sent,
			raids_sent = #report.raids,
			retreating = report.retreating,
			defenders = report.defenders,
		}
	end

	local started = os.clock()
	local snapshots: { Findings } = {}
	local next_look = every
	play(seconds, nil, function(elapsed: number)
		tally()
		if elapsed >= next_look or elapsed >= seconds then
			next_look += every
			table.insert(snapshots, { at = elapsed, a = look(team_a, team_b), b = look(team_b, team_a) })
		end
	end)
	local final_a = look(team_a, team_b)
	local final_b = look(team_b, team_a)
	local margin_a = final_a.killed - final_a.lost
	local margin_b = final_b.killed - final_b.lost
	local decided: string? = nil
	if final_a.commander ~= final_b.commander then
		decided = if final_a.commander then profile_a.name else profile_b.name
	end
	return {
		a = profile_a.name,
		b = profile_b.name,
		swapped = args.swap == true,
		ahead = if margin_a == margin_b then "even" elseif margin_a > margin_b then profile_a.name else profile_b.name,
		decided = decided,
		snapshots = snapshots,
		real_seconds = round(os.clock() - started, 1),
	}
end

-- The fight predictor (server/ai/combat_sim.luau) on fights whose ends are plain, with no game played: made-up fighters,
-- each a def and a place, on open ground. Five Grunts against one should win with most of their worth left
-- (`five_on_one`); three against three, mirrored, should come out about even (`even`); three Aggravators against a
-- Thug, whose reach theirs outdoes, should win by far (`outranged`); and three Grunts told to come up from far off at a
-- Guard (`approach`) should be staged just out of its reach, and lose to it, rather than fight from where they are,
-- which is too far off for anyone to shoot in the few seconds given (`from_afar`, which should end with nobody hurt).
local function ai_predictor(_args: Args): Findings
	local function line(def_name: string, count: number, x: number): { combat_sim.Fighter }
		local fighters: { combat_sim.Fighter } = {}
		for index = 1, count do
			local z = (index - (count + 1) / 2) * 3
			table.insert(
				fighters,
				{ def_name = def_name, position = heightmap.ground_position(x, z), health = nil, skin = nil }
			)
		end
		return fighters
	end
	local function summary(outcome: combat_sim.Outcome): Findings
		return {
			winner = outcome.winner,
			margin = round(outcome.margin, 3),
			start_worth = { round(outcome.start_worth[1], 1), round(outcome.start_worth[2], 1) },
			worth = { round(outcome.worth[1], 1), round(outcome.worth[2], 1) },
			seconds = outcome.seconds,
		}
	end
	local five_on_one = combat_sim.simulate(line("grunt", 5, -10), line("grunt", 1, 10))
	local even = combat_sim.simulate(line("grunt", 3, -10), line("grunt", 3, 10))
	local outranged = combat_sim.simulate(line("aggravator", 3, -45), line("thug", 1, 0))
	local far = line("grunt", 3, -300)
	local guard = line("guard", 1, 0)
	local from_afar = combat_sim.simulate(far, guard, { horizon = 5 })
	local approach = combat_sim.simulate(far, guard, {
		approach = { from = heightmap.ground_position(-300, 0), to = heightmap.ground_position(0, 0) },
	})
	return {
		five_on_one = summary(five_on_one),
		even = summary(even),
		outranged = summary(outranged),
		from_afar = summary(from_afar),
		approach = summary(approach),
		pass = five_on_one.winner == 1
			and five_on_one.margin > 0.5
			and math.abs(even.margin) < 0.2
			and outranged.winner == 1
			and outranged.margin > 0.5
			and from_afar.worth[1] == from_afar.start_worth[1]
			and from_afar.worth[2] == from_afar.start_worth[2]
			and approach.winner == 2,
	}
end

local TESTS: { [string]: Test } = {
	ai_match = { run = ai_match },
	ai_add = { run = ai_add_test },
	ai_danger = { run = ai_danger },
	ai_roster = { run = ai_roster },
	ai_defense = { run = ai_defense },
	ai_raids = { run = ai_raids },
	ai_waves = { run = ai_waves },
	ai_retreat = { run = ai_retreat },
	ai_defend = { run = ai_defend },
	ai_hunt = { run = ai_hunt },
	ai_lost_spot = { run = ai_lost_spot },
	ai_versus = { run = ai_versus, diagnostic = true },
	ai_predictor = { run = ai_predictor },
}

return table.freeze(TESTS)
