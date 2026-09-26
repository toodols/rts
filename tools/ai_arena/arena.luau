-- One arena match, headless: `lune run tools/ai_arena/arena.luau -- '<json>'`, from the repository's root. The JSON
-- says what to play and the result is printed as JSON on the last line of the output. See README.md.
--
-- The modes:
--
-- - `{"mode": "duel", ...}` (the default): two AIs, each with a profile, on a map, until one side is out (its commander
--   dead, as the game's own match end has it) or time runs out; with `"watch": true` each side is looked at every second
--   for how its AI behaves (`watcher`, for tools/ai_arena/behaviour.py).
-- - `{"mode": "ai_match", ...}`: src/server/tests/ai.luau's ai_match test, run here, to hold the arena up against Studio.
-- - `{"mode": "fight", ...}`: a staged fight, played and predicted, to hold the fight predictor up against the game
--   (with `"formation"`, side a spread out as the AI spreads a group, for tools/ai_arena/formation_check.py);
--   `{"mode": "predict", ...}` predicts fights already played again, without playing them.
-- - `{"mode": "profiles"}`: the AI profiles' numbers (shared/ai_profiles.luau): the default's, the range each is searched
--   over and how, and every profile's name, for tools/ai_arena/profiles.py.
-- - `{"mode": "defs"}`: every def a staged fight can be made of; `{"mode": "maps"}`: every map; `{"mode": "reach"}`:
--   whether a constructor of each line can walk between two AIs' starts on a map.

local fs = require "@lune/fs"
local process = require "@lune/process"
local serde = require "@lune/serde"
local stdio = require "@lune/stdio"

local session = require "../lib/session"

local function round(value: number, places: number): number
	local scale = 10 ^ places
	return math.round(value * scale) / scale
end

-- the match, as JSON: on the command line, in a file named there, or on stdin if nothing is named
local given = process.args[1]
local raw_args = if given == nil or given == "-"
	then stdio.readToEnd()
	elseif string.sub(given, 1, 1) == "{" then given
	else fs.readFile(given)
local args = serde.decode("json", raw_args)

local root = args.root or process.cwd

-- What a profile's overrides say to leave out of it (ai_profiles.without): its number switched off, or with no limit.
local ABSENT = "none"

-- The profiles' numbers need no game, only the module.
if args.mode == "profiles" then
	session.load(root)
	local ai_profiles = session.shared "ai_profiles"
	local default = {}
	for key, value in ai_profiles.DEFAULT do
		if type(value) == "number" or type(value) == "string" then
			default[key] = value
		end
	end
	print(serde.encode("json", {
		ok = true,
		default = default,
		ranges = ai_profiles.RANGES,
		absent = ABSENT,
		names = ai_profiles.names(),
	}))
	return
end

local game = session.start({
	root = root,
	preset = args.preset or "highlands",
	seed = args.seed or 1337,
	scenery = args.scenery == true,
	random_seed = args.random_seed,
	entropy = args.entropy,
})

local state = game.server "state"
local ai = game.server "ai"
local match_stats = game.server "match_stats"
local unit_defs = game.shared "unit_defs"
local surface = game.shared "surface"
local ai_profiles = game.shared "ai_profiles"
local ticks_per_second = math.round(1 / game.tick_delta)

-- src/server/tests/ai.luau's ai_match, the test itself, run on the arena's clock as the headless tests run it
-- (tools/headless_tests), so that there is one ai_match to hold the arena up against Studio with.
local function ai_match(): { [string]: any }
	local request = table.clone(args)
	request.test = "ai_match"
	return game.server("tests").run(request, {
		step = function(_delta: number)
			game.advance(1)
		end,
		settle = function()
			game.advance(0)
		end,
	})
end

-- The profile a side plays by: `{"profile": name, "overrides": {...}}`, the named profile (default if not given) with
-- the overrides over it. An override of ABSENT leaves that number out of it: switched off, or with no limit.
local function profile_of(side: { [string]: any }): any
	local name = side.profile or "default"
	local profile = ai_profiles.get(name)
	assert(profile ~= nil, `there is no AI profile "{name}"`)
	if type(side.overrides) == "table" then
		local overrides = {}
		local left_out = {}
		for key, value in side.overrides do
			if value == ABSENT then
				table.insert(left_out, key)
			else
				overrides[key] = value
			end
		end
		profile = ai_profiles.with(ai_profiles.without(profile, left_out), overrides)
	end
	return profile
end

-- What a team has, as the end of a duel reads it.
local function tally(team: number): { [string]: any }
	local worth = { army = 0, builders = 0, economy = 0, defence = 0, labs = 0 }
	local units, buildings, commander = 0, 0, false
	local extractors = 0
	for _, entity in state.all() do
		if entity.alive == false or entity.team ~= team or (entity.kind ~= "unit" and entity.kind ~= "building") then
			continue
		end
		local def = entity.def
		-- what stands unfinished is worth what has been put into it
		local share = if entity.state == "blueprint"
			then math.clamp((entity.build_progress or 0) / math.max(1, def.buildpower_cost or 1), 0, 1)
			else 1
		local power = unit_defs.power(def) * share
		if unit_defs.is_commander(def) then
			commander = true
		end
		if entity.kind == "unit" then
			units += 1
			if #unit_defs.build_options(def) > 0 then
				worth.builders += power
			else
				worth.army += power
			end
		else
			buildings += 1
			if def.spot == "metal" then
				extractors += 1
			end
			if unit_defs.is_factory(def) then
				worth.labs += power
			elseif def.weapons ~= nil and #def.weapons > 0 then
				worth.defence += power
			else
				worth.economy += power
			end
		end
	end
	local team_state = state.get_team(team)
	local stats = match_stats.tally_for(team)
	local report = ai.report(team)
	return {
		commander = commander,
		units = units,
		buildings = buildings,
		extractors = extractors,
		worth = worth,
		total_worth = worth.army + worth.builders + worth.economy + worth.defence + worth.labs,
		metal_income = if team_state ~= nil then round(team_state.metal_income, 2) else 0,
		energy_income = if team_state ~= nil then round(team_state.energy_income, 2) else 0,
		metal = if team_state ~= nil then round(team_state.metal, 1) else 0,
		energy = if team_state ~= nil then round(team_state.energy, 1) else 0,
		metal_made = round(stats.metal, 1),
		destroyed = round(stats.destroyed, 1),
		kills = stats.kills,
		lost = stats.lost,
		waves_sent = if report ~= nil then report.waves_sent else 0,
		raids_sent = if report ~= nil then #report.raids else 0,
		line = if report ~= nil then report.line else nil,
		-- the fights its fight predictor was asked about, and the milliseconds they took all told
		sims = if report ~= nil then report.sims else 0,
		sim_ms = if report ~= nil then round(report.sim_seconds * 1000, 1) else 0,
	}
end

-- `watch`: a look at each side's AI every second, for the checks of how it behaves (tools/ai_arena/behaviour.py),
-- rather than who wins. For each side, over the whole game and over its first `watch_until` seconds (600):
-- - `enemy_spot_seconds`: builder-seconds spent with an extractor to build on a metal spot where an enemy's extractor
--   already stands (finished or not), and `enemy_spot_stalled` those of them spent at the spot itself;
-- - `blocked_seconds`: builder-seconds spent at a build site, within reach of it, with something in the way;
-- - `intruders`: the enemy's armed units (but its commander) that came into its territory, within TERRITORY of home
--   or EXTRACTOR_TERRITORY of one of its extractors: how many stays, the seconds they spent there all told, how many
--   were killed there, and the mean seconds a stay lasted;
-- - `extractors_lost`: its extractors, finished, destroyed;
-- - `spacing`: the mean distance from each of its armed units out beyond BASE of home to the nearest other of them
--   (only those within GROUPED of another, so that separate groups do not count),
--   averaged over the seconds with at least three out, and `damage_per_unit`, the health its armed units lost, over
--   the unit-seconds they were out.
local TERRITORY = 110
local EXTRACTOR_TERRITORY = 50
local BASE = 80
-- a unit counts toward `spacing` only with another of its army this near, in a group with it
local GROUPED = 40
local function watcher(team_of: { [string]: number }, until_seconds: number)
	local placement = game.server "placement"
	local teams = game.shared "teams"
	local geometry = game.shared "geometry"
	local sides = {}
	for side, team in team_of do
		sides[side] = {
			team = team,
			home = nil,
			stays = {},
			extractors = {},
			totals = {
				enemy_spot_seconds = 0,
				enemy_spot_stalled = 0,
				blocked_seconds = 0,
				intruder_seconds = 0,
				intruder_stays = 0,
				intruders_killed = 0,
				extractors_lost = 0,
			},
			early = {
				enemy_spot_seconds = 0,
				enemy_spot_stalled = 0,
				blocked_seconds = 0,
				intruder_seconds = 0,
				intruder_stays = 0,
				intruders_killed = 0,
				extractors_lost = 0,
			},
			stay_lengths = {},
			spacing_sum = 0,
			spacing_samples = 0,
			health = {},
			damage = 0,
			unit_seconds = 0,
		}
	end
	local function add(side, key: string, amount: number, elapsed: number)
		side.totals[key] += amount
		if elapsed <= until_seconds then
			side.early[key] += amount
		end
	end
	local function step(elapsed: number)
		local by_team: { [number]: { any } } = {}
		for _, entity in state.all() do
			if entity.alive and entity.team ~= teams.NEUTRAL then
				local list = by_team[entity.team]
				if list == nil then
					list = {}
					by_team[entity.team] = list
				end
				table.insert(list, entity)
			end
		end
		for _, side in sides do
			local mine = by_team[side.team] or {}
			local theirs = {}
			for other_team, list in by_team do
				if other_team ~= side.team then
					for _, entity in list do
						table.insert(theirs, entity)
					end
				end
			end
			local enemy_spots = {}
			for _, entity in theirs do
				if entity.kind == "building" and entity.def.spot ~= nil then
					table.insert(enemy_spots, entity.position)
				end
			end
			local my_extractors = {}
			for _, entity in mine do
				local def = entity.def
				if side.home == nil and unit_defs.is_commander(def) then
					side.home = entity.position
				end
				if entity.kind == "building" and def.spot == "metal" and entity.state == "active" then
					table.insert(my_extractors, entity.position)
					side.extractors[entity.id] = true
				end
				if entity.kind ~= "unit" or entity.state ~= "active" or def.builder == nil then
					continue
				end
				local order = nil
				for _, queued in entity.orders do
					if queued.kind ~= "move" then
						order = queued
						break
					end
				end
				if order == nil or order.kind ~= "build" or order.position == nil or order.def_name == nil then
					continue
				end
				local reach = (unit_defs.build_range(def) or 0) + 6
				local near = geometry.distance_2d(entity.position, order.position) <= reach
				if unit_defs.get(order.def_name).spot ~= nil then
					for _, taken in enemy_spots do
						if geometry.distance_2d(taken, order.position) < 1 then
							add(side, "enemy_spot_seconds", 1, elapsed)
							if near then
								add(side, "enemy_spot_stalled", 1, elapsed)
							end
							break
						end
					end
				end
				if near and entity.orders[1] == order then
					local ok, reason =
						placement.can_place(order.def_name, order.position, order.facing or 0, entity, side.team)
					if ok == false and reason == "blocked" then
						add(side, "blocked_seconds", 1, elapsed)
					end
				end
			end
			for id in side.extractors do
				local entity = state.get(id)
				if entity == nil or entity.alive == false then
					side.extractors[id] = nil
					add(side, "extractors_lost", 1, elapsed)
				end
			end
			-- how far apart its army out on the map stands, and what it takes
			local out = {}
			for _, entity in mine do
				local def = entity.def
				if
					entity.kind == "unit"
					and entity.state == "active"
					and unit_defs.is_commander(def) == false
					and def.max_speed ~= nil
					and unit_defs.is_air(def) == false
					and unit_defs.attack_range(def) ~= nil
				then
					local last = side.health[entity.id]
					if last ~= nil and entity.health < last then
						side.damage += last - entity.health
					end
					side.health[entity.id] = entity.health
					if side.home ~= nil and geometry.distance_2d(entity.position, side.home) > BASE then
						table.insert(out, entity)
						side.unit_seconds += 1
					end
				end
			end
			if #out >= 3 then
				local sum, grouped = 0, 0
				for _, entity in out do
					local nearest = math.huge
					for _, other in out do
						if other ~= entity then
							nearest = math.min(nearest, geometry.distance_2d(entity.position, other.position))
						end
					end
					if nearest <= GROUPED then
						sum += nearest
						grouped += 1
					end
				end
				if grouped >= 3 then
					side.spacing_sum += sum / grouped
					side.spacing_samples += 1
				end
			end
			-- intruders: who is in its territory now, and whose stay has ended
			local inside = {}
			for _, entity in theirs do
				local def = entity.def
				if
					entity.kind ~= "unit"
					or entity.state ~= "active"
					or unit_defs.is_commander(def)
					or def.max_speed == nil
					or unit_defs.attack_range(def) == nil
				then
					continue
				end
				local within = side.home ~= nil and geometry.distance_2d(entity.position, side.home) <= TERRITORY
				if within == false then
					for _, position in my_extractors do
						if geometry.distance_2d(entity.position, position) <= EXTRACTOR_TERRITORY then
							within = true
							break
						end
					end
				end
				if within then
					inside[entity.id] = true
				end
			end
			for id, since in side.stays do
				if inside[id] == nil then
					local entity = state.get(id)
					local killed = entity == nil or entity.alive == false
					side.stays[id] = nil
					table.insert(side.stay_lengths, elapsed - since)
					if killed then
						add(side, "intruders_killed", 1, since)
					end
				end
			end
			for id in inside do
				add(side, "intruder_seconds", 1, elapsed)
				if side.stays[id] == nil then
					side.stays[id] = elapsed
					add(side, "intruder_stays", 1, elapsed)
				end
			end
		end
	end
	local function result(): { [string]: any }
		local out = {}
		for name, side in sides do
			local lengths = side.stay_lengths
			local sum = 0
			for _, length in lengths do
				sum += length
			end
			out[name] = {
				totals = side.totals,
				early = side.early,
				mean_stay = if #lengths > 0 then round(sum / #lengths, 1) else nil,
				spacing = if side.spacing_samples > 0 then round(side.spacing_sum / side.spacing_samples, 2) else nil,
				damage_per_unit = if side.unit_seconds > 0 then round(side.damage / side.unit_seconds, 3) else nil,
			}
		end
		return out
	end
	return step, result
end

-- A duel: side "a" and side "b", each `{"profile": ..., "overrides": ...}`; "a" is put down first (as team 1) at the
-- map's first start unless `swap`, when "b" is. `line` makes both build from that line's labs. It ends once a
-- commander is dead, the other's the winner (both at once is a draw), or at `seconds` (a draw, which the scores
-- settle). `every` seconds (none by default) the teams are looked at and kept in `timeline`.
local function duel(): { [string]: any }
	local seconds = args.seconds or 900
	local every = args.every
	local order = if args.swap then { "b", "a" } else { "a", "b" }
	local team_of = {}
	for _, side in order do
		local profile = profile_of(args[side] or {})
		local team = ai.spawn_opponent(`AI {side}`, nil, nil, profile)
		assert(team ~= nil, `there was no room for side {side}'s commander`)
		team_of[side] = team
		-- a profile with a line of its own (and a roster to match) keeps it
		local line = (args[side] or {}).line or (if profile.line == nil then args.line else nil)
		if line == "bot" or line == "vehicle" then
			ai.set_line(team, line)
		end
	end
	local started = os.clock()
	local timeline = {}
	local winner: string? = nil
	local reason = "time"
	local elapsed = 0
	local next_look = every
	local watch_step, watch_result = nil, nil
	if args.watch == true then
		watch_step, watch_result = watcher(team_of, args.watch_until or 600)
	end
	-- a side is out once its commander is, as the game's own match end has it (server/elimination.luau)
	local evaluator = game.server("elimination").new()
	local sides = {
		{ teams = { team_of.a }, end_mode = "commanders" },
		{ teams = { team_of.b }, end_mode = "commanders" },
	}
	while elapsed < seconds do
		game.advance(ticks_per_second)
		elapsed += 1
		if watch_step ~= nil then
			watch_step(elapsed)
		end
		local out = evaluator.look(sides)
		if out[1] or out[2] then
			reason = "commander"
			winner = if out[2] == false then "a" elseif out[1] == false then "b" else nil
			break
		end
		if next_look ~= nil and elapsed >= next_look then
			next_look += every
			table.insert(timeline, {
				at = elapsed,
				a = tally(team_of.a),
				b = tally(team_of.b),
				a_summary = ai.describe(team_of.a),
				b_summary = ai.describe(team_of.b),
			})
		end
	end
	local result = {
		ok = true,
		preset = args.preset or "highlands",
		seed = args.seed or 1337,
		swap = args.swap == true,
		line = args.line,
		map_size = { game.shared("heightmap").half_extents() },
		winner = winner,
		reason = reason,
		seconds = elapsed,
		a = tally(team_of.a),
		b = tally(team_of.b),
		real_seconds = round(os.clock() - started, 2),
	}
	if args.profile == true then
		-- where the time went, by the step's own sections (server/profiler.luau), heaviest first
		local rows = {}
		for index, row in game.server("profiler").report() do
			if index > 25 then
				break
			end
			table.insert(rows, `{row.label} {round(row.seconds, 2)}s {round(row.fraction * 100, 1)}%`)
		end
		result.profile = rows
	end
	if every ~= nil or watch_result ~= nil then
		result.timeline = timeline
		result.a_report = ai.report(team_of.a)
		result.b_report = ai.report(team_of.b)
	end
	if watch_result ~= nil then
		result.watch = watch_result()
	end
	return result
end

-- A staged fight, to hold the AI's fight predictor (server/ai/combat_sim.luau) up against the real game: side "a" and side
-- "b", each a list of `{"def": name, "count": n}`, are put down `distance` studs apart across the middle of the map,
-- a's to the west, and whatever of them moves is sent to fight its way to the other side's middle, as the AI sends a
-- wave. What does not move (a defence) stands where it was put, `spread` studs round its side's middle at the most
-- (b's `defences`, a list like its units). The predictor is asked what will happen before a tick is played, and then
-- the game plays it for `seconds` (90), or until one side has nothing armed left. Both sides have all the energy they
-- want.
local function fight(): { [string]: any }
	local seconds = args.seconds or 90
	local distance = args.distance or 120
	local combat_sim = game.server "ai.combat_sim"
	local spawning = game.server "spawning"
	local players = game.server "players"
	local orders = game.server "orders"
	local heightmap = game.shared "heightmap"
	local paths = game.server "paths"
	local centre_x = args.centre_x or 0
	local centre_z = args.centre_z or 0
	local sides = {
		a = { team = players.create_team "A", x = centre_x - distance / 2, facing = math.pi / 2 },
		b = { team = players.create_team "B", x = centre_x + distance / 2, facing = -math.pi / 2 },
	}
	local members = { a = {}, b = {} }
	local missing = {}
	local function put(side: string, list: { any }?, spread: number)
		local at = sides[side]
		for _, entry in list or {} do
			for index = 1, entry.count or 1 do
				local x, z = at.x, centre_z
				if spread > 0 then
					local angle = (index * 2.39996 + #members[side]) % (math.pi * 2)
					local r = spread * math.sqrt((index - 0.5) / (entry.count or 1))
					x += math.cos(angle) * r
					z += math.sin(angle) * r
				end
				local placed = spawning.spawn_near(entry.def, at.team, heightmap.ground_position(x, z), at.facing)
				if placed == nil then
					table.insert(missing, `{side} {entry.def}`)
				else
					table.insert(members[side], placed)
				end
			end
		end
	end
	put("a", args.a, 0)
	put("b", args.b, 0)
	put("a", args.a_defences, args.spread or 24)
	put("b", args.b_defences, args.spread or 24)
	-- a weapon that costs more a shot than a team's store holds never fires, so neither side has an economy to want for
	for _, at in sides do
		game.server("economy").set_unlimited(at.team, true)
	end

	local predicted_at = os.clock()
	local prediction = combat_sim.simulate(members.a, members.b, { horizon = args.horizon or seconds })
	local predict_ms = (os.clock() - predicted_at) * 1000
	-- where everything stood, for predicting the fight again without playing it (the "predict" mode)
	local start = { a = {}, b = {} }
	for side, list in members do
		for _, entity in list do
			local p = entity.position
			table.insert(
				start[side],
				{ def = entity.def_name, x = round(p.X, 2), y = round(p.Y, 2), z = round(p.Z, 2) }
			)
		end
	end

	-- every mover is sent as the AI sends a wave (server/ai/routes.luau's orders_to), with all the routes it wants;
	-- `formation` (studs) sends side a's units each to a place of its own, as the AI spreads a group out with its
	-- profile's spread (server/ai/squads.luau's `formation`), rather than all to one point
	local asker = { name = "arena", share = math.huge, max_expansions = 20000 }
	local function send(side: string, goal: Vector3)
		local movers = {}
		for _, unit in members[side] do
			local def = unit.def
			if def.kind == "unit" and (def.max_speed or 0) > 0 then
				table.insert(movers, unit)
			end
		end
		local places = if side == "a"
				and typeof(args.formation) == "number"
				and args.formation > 0
			then ai.formation_for(movers, goal, "fight", args.formation)
			else nil
		for _, unit in movers do
			local def = unit.def
			local place = if places ~= nil then places[unit.id] or goal else goal
			local route = paths.route(asker, nil, def, unit.position, place, "fight")
			orders.issue(unit, paths.or_straight(route, def, place, "fight"), false, false)
		end
	end
	send("a", heightmap.ground_position(sides.b.x, centre_z))
	send("b", heightmap.ground_position(sides.a.x, centre_z))

	local function left(side: string): { any }
		local alive = {}
		for _, entity in members[side] do
			if entity.alive and state.get(entity.id) ~= nil then
				table.insert(alive, entity)
			end
		end
		return alive
	end
	local start_worth = { a = combat_sim.worth_of(members.a), b = combat_sim.worth_of(members.b) }
	local elapsed = 0
	while elapsed < seconds do
		game.advance(ticks_per_second)
		elapsed += 1
		if combat_sim.worth_of(left "a") <= 0 or combat_sim.worth_of(left "b") <= 0 then
			break
		end
	end
	local worth = { a = combat_sim.worth_of(left "a"), b = combat_sim.worth_of(left "b") }
	local share_a = if start_worth.a > 0 then worth.a / start_worth.a else 0
	local share_b = if start_worth.b > 0 then worth.b / start_worth.b else 0
	local margin = share_a - share_b
	return {
		ok = true,
		missing = missing,
		start = start,
		real = {
			winner = if margin > 0 then "a" elseif margin < 0 then "b" else nil,
			start_worth = { a = round(start_worth.a, 1), b = round(start_worth.b, 1) },
			worth = { a = round(worth.a, 1), b = round(worth.b, 1) },
			margin = round(margin, 3),
			seconds = elapsed,
		},
		predicted = {
			winner = if prediction.winner == 1 then "a" elseif prediction.winner == 2 then "b" else nil,
			start_worth = { a = round(prediction.start_worth[1], 1), b = round(prediction.start_worth[2], 1) },
			worth = { a = round(prediction.worth[1], 1), b = round(prediction.worth[2], 1) },
			margin = round(prediction.margin, 3),
			seconds = prediction.seconds,
			ms = round(predict_ms, 3),
		},
	}
end

local ok, result = pcall(function()
	if args.mode == "fight" then
		return fight()
	elseif args.mode == "predict" then
		-- the fight predictor asked again about fights already played (each `{"a": [...], "b": [...]}` as a fight's
		-- `start` has them), with `horizon`, for trying a change to it without playing the fights again
		local combat_sim = game.server "ai.combat_sim"
		local predictions = {}
		local started = os.clock()
		for _, fight_start in args.fights do
			local sides = {}
			for _, side in { "a", "b" } do
				local list = {}
				for _, entry in fight_start[side] do
					table.insert(list, { def_name = entry.def, position = vector.create(entry.x, entry.y, entry.z) })
				end
				sides[side] = list
			end
			local prediction = combat_sim.simulate(sides.a, sides.b, { horizon = args.horizon or 90 })
			table.insert(predictions, {
				winner = if prediction.winner == 1 then "a" elseif prediction.winner == 2 then "b" else nil,
				worth = { a = round(prediction.worth[1], 1), b = round(prediction.worth[2], 1) },
				margin = round(prediction.margin, 3),
				seconds = prediction.seconds,
			})
		end
		return {
			ok = true,
			predictions = predictions,
			ms_each = round((os.clock() - started) * 1000 / math.max(1, #args.fights), 3),
		}
	elseif args.mode == "defs" then
		-- what a staged fight can be made of: every def's worth, whether it flies, moves, is armed and shoots aircraft
		-- down, builds, its tech level and its category
		local list = {}
		for name, def in unit_defs.defs do
			table.insert(list, {
				name = name,
				kind = def.kind,
				power = round(unit_defs.power(def), 2),
				air = unit_defs.is_air(def),
				speed = def.max_speed or 0,
				armed = unit_defs.attack_range(def) ~= nil,
				anti_air = unit_defs.defends_against_air(def),
				builder = def.builder ~= nil,
				tech_level = def.tech_level or 1,
				category = def.category,
			})
		end
		return { ok = true, defs = list }
	elseif args.mode == "ai_match" then
		return ai_match()
	elseif args.mode == "reach" then
		-- whether a construction bot and a construction vehicle could each walk from one AI's start to the other's
		local first = ai.spawn_opponent "AI a"
		local second = ai.spawn_opponent "AI b"
		assert(first ~= nil and second ~= nil, "there was no room for two commanders")
		local homes = {}
		for _, entity in state.all() do
			if entity.alive and unit_defs.is_commander(entity.def) then
				homes[entity.team] = entity.position
			end
		end
		local pathfinder = game.shared "pathfinder"
		local reach = {}
		for _, probe in { "construction_bot", "construction_vehicle" } do
			local def = unit_defs.get(probe)
			local from = surface.position(def, homes[first].X, homes[first].Z)
			local to = surface.position(def, homes[second].X, homes[second].Z)
			reach[probe] = pathfinder.find_path(def, from, to, 200000).complete
		end
		local half_x, half_z = game.shared("heightmap").half_extents()
		return {
			ok = true,
			reach = reach,
			distance = math.round(vector.magnitude(homes[first] - homes[second])),
			size = { half_x, half_z },
		}
	elseif args.mode == "maps" then
		-- every map there is, and how big, for choosing the ones to play on
		local heightmap = game.shared "heightmap"
		local half_x, half_z = heightmap.half_extents()
		local maps = {}
		for name, preset in game.shared("map_presets").presets do
			table.insert(maps, { name = name, campaign_only = preset.campaign_only == true })
		end
		return { ok = true, maps = maps, this_map = { half_x = half_x, half_z = half_z } }
	end
	return duel()
end)
if not ok then
	result = { ok = false, error = tostring(result) }
end
print(serde.encode("json", result))
