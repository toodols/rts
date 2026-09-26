--!strict
-- Tests of a game between players: the match a lobby hands over, how it is won and rated, the end screen's stats,
-- alliances, and the skins teams wear.

local ReplicatedStorage = game:GetService "ReplicatedStorage"
local ServerScriptService = game:GetService "ServerScriptService"

local types = require(ReplicatedStorage.Shared.types)
local ground_levels = require(ReplicatedStorage.Shared.ground_levels)
local tick_rate = require(ReplicatedStorage.Shared.tick_rate)
local heightmap = require(ReplicatedStorage.Shared.heightmap)
local unit_defs = require(ReplicatedStorage.Shared.unit_defs)
local starts = require(ReplicatedStorage.Shared.starts)
local map_state = require(ReplicatedStorage.Shared.map_state)
local game_phase = require(ReplicatedStorage.Shared.game_phase)
local game_modes = require(ReplicatedStorage.Shared.game_modes)
local shared_skins = require(ReplicatedStorage.Shared.skins)
local geometry = require(ReplicatedStorage.Shared.geometry)
local match_report = require(ReplicatedStorage.Shared.match_report)
local appearance = require(ReplicatedStorage.Shared.appearance)
local teams = require(ReplicatedStorage.Shared.teams)
local switches = require(ReplicatedStorage.Shared.switches)
local mission_state = require(ReplicatedStorage.Shared.mission_state)

local state = require(ServerScriptService.Server.state)
local damage = require(ServerScriptService.Server.damage)
local deaths = require(ServerScriptService.Server.deaths)
local orders = require(ServerScriptService.Server.orders)
local work = require(ServerScriptService.Server.work)
local placement = require(ServerScriptService.Server.placement)
local match = require(ServerScriptService.Server.match)
local alliances = require(ServerScriptService.Server.alliances)
local scavengers = require(ServerScriptService.Server.scavengers)
local missions = require(ServerScriptService.Server.missions)
local ratings = require(ServerScriptService.Server.ratings)
local spawning = require(ServerScriptService.Server.spawning)
local server_skins = require(ServerScriptService.Server.skins)
local donuts = require(ServerScriptService.Server.donuts)

local harness = require(script.Parent.harness)

local OWN = harness.OWN
local ENEMY = harness.ENEMY
local ALLY = harness.ALLY
local advance = harness.advance
local now = harness.now
local round = harness.round
local spawn = harness.spawn
local spawn_resting = harness.spawn_resting
local unkillable = harness.unkillable
local damage_to = harness.damage_to
local clear_world = harness.clear_world
local ensure_team = harness.ensure_team
local shots_of = harness.shots_of

type Entity = types.Entity
type TeamId = types.TeamId
type Args = harness.Args
type Findings = harness.Findings
type Test = harness.Test

-- A game against the scavengers handed in the way a lobby would hand one over: two players on the one side, and one
-- who only watches.
local SCAVENGER_MATCH = table.freeze({
	mode = "scav_hard",
	preset = "highlands",
	seed = 7,
	seats = {
		{ user_id = 101, name = "First", side = 1 },
		{ user_id = 102, name = "Second", side = 1 },
		{ user_id = 103, name = "Watcher", side = game_modes.SPECTATOR_SIDE },
	},
})
-- A duel, rated, won by the commanders' end.
local DUEL_MATCH = table.freeze({
	mode = "1v1",
	preset = "highlands",
	seed = 7,
	seats = {
		{ user_id = 101, name = "Winner", side = 1 },
		{ user_id = 102, name = "Loser", side = 2 },
	},
	end_mode = "commanders",
})
-- How long a handed-in match, or a rating, may take to settle, in seconds of real time.
local SETTLE_SECONDS = 5
-- Which of the conquest test's stages each end mode should end the game at: the commanders', the builders' or the
-- rest's.
local END_STAGES: { [string]: number } = { commanders = 1, builders = 2, units = 3 }

-- Lets the engine run until `condition` holds, for SETTLE_SECONDS at most.
local function settle_until(condition: () -> boolean)
	local deadline = os.clock() + SETTLE_SECONDS
	while condition() == false and os.clock() < deadline do
		harness.settle()
	end
end

-- What the game made of a match handed in the way a lobby hands one over (`args.match`, a game against the
-- scavengers unless another is given): the map and seed it built, which should be the match's; the team each seat was
-- given, one each and none for a spectator, and which of them are allied, which should be those on the same side;
-- whether the scavengers are on, which they should be for a game against them, and how far the game's progress got
-- over `args.seconds` (60 by default), which a difficulty's pace sets; and who the game is still waiting for -
-- everyone, since nobody arrives in a test. For a campaign match, what its mission put down.
local function match_test(args: Args): Findings
	local handed = match.get()
	assert(handed ~= nil, "no match was handed in: pass one as `match`")
	local mode = game_modes.get(handed.mode) :: game_modes.Mode
	local built = map_state.get() :: map_state.MapState

	local seats = {}
	local seated_teams: { TeamId } = {}
	local side_of: { [TeamId]: number } = {}
	local seated_right = true
	for _, seat in handed.seats do
		-- nil for a spectator
		local team = match.team_of(seat.user_id)
		table.insert(seats, { name = seat.name, side = seat.side, team = team })
		if game_modes.is_spectator(seat) then
			seated_right = seated_right and team == nil
		elseif team == nil or side_of[team] ~= nil then
			seated_right = false
		else
			table.insert(seated_teams, team)
			side_of[team] = seat.side
		end
	end
	local allied = {}
	local allied_right = true
	for index, a in seated_teams do
		for _, b in { table.unpack(seated_teams, index + 1) } do
			local are = alliances.are_allied(a, b)
			if are then
				table.insert(allied, `{a}+{b}`)
			end
			allied_right = allied_right and are == (side_of[a] == side_of[b])
		end
	end

	match.update()
	local progress_before = scavengers.progress()
	local seconds = args.seconds or 60
	advance(seconds)
	local per_minute = (scavengers.progress() - progress_before) * 60 / seconds

	-- for a campaign match, what its mission put down, and whether it is still there once the time has run
	local enemy = mission_state.enemy_team()
	local enemy_things: { [string]: number } = {}
	local boulders = 0
	for _, entity in state.all() do
		if enemy ~= nil and entity.team == enemy then
			enemy_things[entity.def_name] = (enemy_things[entity.def_name] or 0) + 1
		end
		if entity.def_name == "tutorial_boulder" then
			boulders += 1
		end
	end
	local against_scavengers = mode.difficulty ~= nil
	local difficulty = if mode.difficulty ~= nil then game_modes.difficulty(mode.difficulty) else nil
	local expected_per_minute = if difficulty ~= nil
		then 60 / (scavengers.SETTINGS.GAME_LENGTH * difficulty.pace)
		else nil
	return {
		mission = missions.mission(),
		enemy_team = enemy,
		enemy_things = enemy_things,
		boulders = boulders,
		phase = game_phase.phase(),
		mode = handed.mode,
		preset = built.preset,
		seed = built.seed,
		seats = seats,
		allied = allied,
		scavengers_enabled = switches.is_on "scavengers",
		progress_per_minute = round(per_minute, 5),
		expected_progress_per_minute = if expected_per_minute ~= nil then round(expected_per_minute, 5) else nil,
		awaiting = game_phase.awaiting(),
		is_awaiting = match.is_awaiting(),
		pass = built.preset == handed.preset
			and built.seed == handed.seed
			and seated_right
			and allied_right
			and switches.is_on "scavengers" == against_scavengers
			and (expected_per_minute == nil or math.abs(per_minute - expected_per_minute) <= expected_per_minute * 0.01)
			and match.is_awaiting(),
	}
end

-- A game between players played to its end (conquest.luau) and rated (ratings.luau), from a team or FFA `match` handed
-- in (a duel unless another is given), ended by its `end_mode` (the commanders' by default): every seated player is
-- taken to have come, and each team gets an unkillable commander at its start, and apart from it, out of reach of its
-- death, an unkillable bot lab and an unkillable grunt. After a while, which ends nothing, every side but the first
-- loses its things a kind at a time, two seconds apart: its commanders, then what else can build (the labs), then the
-- rest (the grunts). Each stage says whether the game has ended by then and how much the losers and the first side have
-- left: the game should end at the stage its end mode names, never for "never", with the losers' things all blown up
-- and the first side's untouched. With `leave = true` all the losers' players leave instead. The game should end with
-- the first side's teams the winners, rated on its ladder if it is one rated (a duel or a small team game; a free for
-- all is not).
local function conquest_test(args: Args): Findings
	local handed = match.get()
	assert(handed ~= nil, "no match was handed in: pass one as `match`")
	local rated: ratings.Rated? = nil
	local stop_rating = ratings.on_rated(function(done: ratings.Rated)
		rated = done
	end)
	settle_until(game_phase.is_playing)
	local first_side: number? = nil
	local losers: { number } = {}
	local losing_teams: { [TeamId]: boolean } = {}
	local winning_teams: { [TeamId]: boolean } = {}
	for _, seat in handed.seats do
		local team_id = match.team_of(seat.user_id)
		if team_id == nil then
			continue
		end
		match.arrived(seat.user_id)
		ensure_team(team_id).name = seat.name
		local spot = starts.default_spot(team_id)
		unkillable(spawn_resting("commander", team_id, spot.X, spot.Y))
		unkillable(spawn_resting("bot_lab", team_id, spot.X + 40, spot.Y))
		unkillable(spawn_resting("grunt", team_id, spot.X, spot.Y + 40))
		first_side = first_side or seat.side
		if seat.side ~= first_side then
			table.insert(losers, seat.user_id)
			losing_teams[team_id] = true
		else
			winning_teams[team_id] = true
		end
	end

	advance(args.seconds or 5)
	local phase_before = game_phase.phase()

	-- how many units and buildings the teams in `of` have alive
	local function left_of(of: { [TeamId]: boolean }): number
		local count = 0
		for _, entity in state.all() do
			if entity.alive and of[entity.team] == true and (entity.kind == "unit" or entity.kind == "building") then
				count += 1
			end
		end
		return count
	end
	local first_side_had = left_of(winning_teams)

	local stages: { string } = {}
	local ended_at_stage: number? = nil
	if args.leave == true then
		for _, user_id in losers do
			match.left(user_id)
		end
		advance(2)
	else
		local kinds: { { name: string, is: (types.EntityDef) -> boolean } } = {
			{ name = "commanders", is = unit_defs.is_commander },
			{
				name = "builders",
				is = function(def: types.EntityDef): boolean
					return def.builder ~= nil
				end,
			},
			{
				name = "units",
				is = function(_def: types.EntityDef): boolean
					return true
				end,
			},
		}
		for index, kind in kinds do
			if game_phase.phase() == "ended" then
				break
			end
			local killed = 0
			for _, entity in state.all() do
				if entity.alive and losing_teams[entity.team] == true and kind.is(entity.def) then
					damage.apply(entity, entity.health + 1)
					killed += 1
				end
			end
			advance(2)
			if game_phase.phase() == "ended" then
				ended_at_stage = index
			end
			table.insert(
				stages,
				`{kind.name}: killed {killed}, {game_phase.phase()}, losers have {left_of(losing_teams)},`
					.. ` first side has {left_of(winning_teams)}`
			)
		end
	end

	-- the game is rated once it has ended, which may be a moment later
	settle_until(function(): boolean
		return rated ~= nil
	end)
	stop_rating()
	local players_rated = {}
	if rated ~= nil then
		for user_id, row in rated.players do
			players_rated[user_id] = {
				outcome = row.outcome,
				mu = `{round(row.before.mu, 3)} -> {round(row.after.mu, 3)}`,
				sigma = `{round(row.before.sigma, 3)} -> {round(row.after.sigma, 3)}`,
				record = `{row.after.wins}-{row.after.losses}-{row.after.draws}`,
			}
		end
	end

	local winners = game_phase.winners()
	local winners_right = true
	for team_id in winning_teams do
		winners_right = winners_right and table.find(winners, team_id) ~= nil
	end
	for team_id in losing_teams do
		winners_right = winners_right and table.find(winners, team_id) == nil
	end
	local mode = game_modes.get(handed.mode) :: game_modes.Mode
	local ends = handed.end_mode ~= "never" or args.leave == true
	local stage_right = args.leave == true or ended_at_stage == END_STAGES[handed.end_mode]
	return {
		mode = handed.mode,
		end_mode = handed.end_mode,
		phase_before = phase_before,
		stages = stages,
		phase = game_phase.phase(),
		winners = table.concat(winners, ","),
		end_reason = game_phase.end_reason(),
		ladder = if rated ~= nil then rated.ladder else "not rated",
		players = players_rated,
		pass = phase_before == "playing"
			and if ends
				then game_phase.phase() == "ended"
					and stage_right
					and winners_right
					and left_of(losing_teams) == 0
					and left_of(winning_teams) == first_side_had
					and (rated ~= nil) == mode.rated
				else game_phase.phase() == "playing",
	}
end

-- The end screen's stats (match_stats.luau): a grunt of OWN's fights a ring of ENEMY's, then the game is ended in
-- OWN's favour and what that published on Workspace is read back: OWN's row should be the winner's, with the grunt's
-- kills and damage and the metal its commander, out of the way, made; ENEMY's should have lost what died.
local function match_stats_test(args: Args): Findings
	-- a test session has no players, so nobody made the teams a game has
	for _, team_id in { OWN, ENEMY } do
		ensure_team(team_id).name = `Team {team_id}`
	end
	local home = starts.default_spot(1)
	local veteran = unkillable(spawn_resting("grunt", OWN, home.X, home.Y))
	unkillable(spawn_resting("commander", OWN, home.X - 150, home.Y))
	local victims: { Entity } = {}
	local count = args.count or 4
	for index = 1, count do
		local angle = index / count * 2 * math.pi
		table.insert(
			victims,
			spawn_resting("grunt", ENEMY, home.X + 16 * math.cos(angle), home.Y + 16 * math.sin(angle))
		)
	end
	advance(tick_rate.TICK_DELTA)
	orders.issue(veteran, { { kind = "fight", position = veteran.position } }, false, false)
	local seconds = args.seconds or 30
	advance(seconds)
	local dead = 0
	for _, victim in victims do
		if victim.alive == false then
			dead += 1
		end
	end

	game_phase.set_ended({ OWN }, "test")
	harness.settle()
	local published = match_report.read()
	local rows: { match_report.TeamStats } = published or {}
	local own_row, enemy_row
	for _, row in rows do
		if row.team == OWN then
			own_row = row
		elseif row.team == ENEMY then
			enemy_row = row
		end
	end
	local income = (state.get_team(OWN) :: types.Team).metal_income
	return {
		published_on_end = published ~= nil,
		rows = rows,
		veteran = {
			damage_dealt = round(veteran.damage_dealt, 1),
			score_dealt = round(veteran.score_dealt, 1),
			kills = veteran.kills,
		},
		enemies_dead = dead,
		income = {
			own = income,
			enemy = (state.get_team(ENEMY) :: types.Team).metal_income,
		},
		seconds = seconds,
		pass = own_row ~= nil
			and enemy_row ~= nil
			and own_row.won == true
			and enemy_row.won == false
			and dead > 0
			and own_row.kills == veteran.kills
			and own_row.damage == math.floor(veteran.damage_dealt + 0.5)
			and own_row.lost == 0
			and enemy_row.lost == dead
			and own_row.metal > 0,
	}
end

-- unally (alliances.leave) and a shared team's single starting force (spawning.owns_anything). Teams 1-4 in one
-- alliance: 3 leaves from the middle and 4, its root, leaves after; 1 and 2 stay allied throughout.
local function unally_test(_args: Args): Findings
	for team_id = 1, 5 do
		ensure_team(team_id)
	end
	alliances.ally(1, 2)
	alliances.ally(2, 3)
	alliances.ally(3, 4)
	local root_before = alliances.root_of(1)
	local left_3 = alliances.leave(3)
	local after_3 = {
		one_two = alliances.are_allied(1, 2),
		one_four = alliances.are_allied(1, 4),
		three_one = alliances.are_allied(3, 1),
		three_four = alliances.are_allied(3, 4),
		three_may_harm_one = alliances.may_harm(3, 1),
	}
	local left_3_again = alliances.leave(3)
	local left_4 = alliances.leave(4)
	local after_4 = {
		one_two = alliances.are_allied(1, 2),
		four_one = alliances.are_allied(4, 1),
		group_of_1 = table.concat(alliances.group_of(1, state.all_teams()), ","),
	}

	-- team 5 has nothing until its starting force goes down, and then gets no second one
	local owned_before = spawning.owns_anything(5)
	spawning.give_starting_force(5)
	local owned_after = spawning.owns_anything(5)
	local commanders = 0
	for _, entity in state.all() do
		if entity.team == 5 and unit_defs.is_commander(entity.def) then
			commanders += 1
		end
	end

	return {
		root_before = root_before,
		left_3 = left_3,
		after_3 = after_3,
		left_3_again = left_3_again,
		left_4 = left_4,
		after_4 = after_4,
		owned_before = owned_before,
		owned_after = owned_after,
		commanders = commanders,
		pass = left_3
			and after_3.one_two
			and after_3.one_four
			and after_3.three_one == false
			and after_3.three_four == false
			and after_3.three_may_harm_one
			and left_3_again == false
			and left_4
			and after_4.one_two
			and after_4.four_one == false
			and after_4.group_of_1 == "1,2"
			and owned_before == false
			and owned_after
			and commanders == 1,
	}
end

-- Guarding an ally's unit (orders' run_guard, and commands' IssueOrder by order_kinds' `friendly_only`), with OWN and ALLY
-- allied and ENEMY against both. A grunt of OWN's guards one of ALLY's that walks off: they should end up together,
-- still guarding. Then an enemy grunt attacks the ally's: the guard should shoot back. Then a Construction Bot of OWN's
-- guards one of ALLY's that builds a solar collector: it should work on the ally's blueprint until it is finished. A
-- guard of an enemy's unit, or of nobody's, should be refused as a command, and an enemy's dropped as an order that got
-- through anyway. Last, ALLY leaves the alliance: both guard orders should be dropped.
local function ally_guard(_args: Args): Findings
	for _, team_id in { OWN, ENEMY, ALLY } do
		harness.fill_bank(team_id)
	end
	alliances.ally(OWN, ALLY)
	local home = starts.default_spot(1)

	local function guarding(entity: Entity): boolean
		return entity.orders[1] ~= nil and entity.orders[1].kind == "guard"
	end

	-- following: the ally's grunt walks 60 studs off and the guard keeps up
	-- each resting on the ground, since one that stands still is never lifted to it, and one sunk into it is hidden
	-- from every shot
	local guarded = unkillable(spawn_resting("grunt", ALLY, home.X, home.Y))
	local guard = unkillable(spawn_resting("grunt", OWN, home.X - 12, home.Y))
	local own_grunt = spawn_resting("grunt", OWN, home.X - 12, home.Y + 12)
	local enemy_grunt = unkillable(spawn_resting("grunt", ENEMY, home.X + 150, home.Y + 150))
	-- whether a guard order of OWN's aimed at `target` is taken, sent as a player's client sends it (IssueOrder)
	local commander = harness.join(OWN)
	local function may_guard(target: Entity): boolean
		local probe = spawn_resting("grunt", OWN, home.X - 30, home.Y - 30)
		harness.send("IssueOrder", commander, { kind = "guard", ids = { probe.id }, target_id = target.id })
		local taken = guarding(probe)
		deaths.destroy(probe, "removed")
		return taken
	end
	local may = {
		own = may_guard(own_grunt),
		ally = may_guard(guarded),
		enemy = may_guard(enemy_grunt),
		nobody = may_guard(spawn_resting("grunt", teams.NEUTRAL, home.X - 60, home.Y - 60)),
	}
	orders.issue(guard, { { kind = "guard", position = nil, target_id = guarded.id } }, false, false)
	local walk_to = heightmap.ground_position(home.X + 60, home.Y)
	orders.issue(guarded, { { kind = "move", position = walk_to, target_id = nil } }, false, false)
	advance(20)
	local follow = {
		ally_left_to_go = round(geometry.distance_2d(guarded.position, walk_to), 1),
		apart = round(geometry.distance_2d(guard.position, guarded.position), 1),
		still_guarding = guarding(guard),
	}

	-- fighting: an enemy grunt comes up to the ally's and attacks it; the guard beside it shoots back. The attacker
	-- cannot be killed, since the ally's grunt shoots back too and a dead one's count of shots is forgotten with it.
	local range = unit_defs.attack_range(unit_defs.get "grunt") :: number
	local attacker = unkillable(spawn_resting("grunt", ENEMY, guarded.position.X, guarded.position.Z + range * 0.6))
	orders.issue(attacker, { { kind = "attack", position = nil, target_id = guarded.id } }, false, false)
	-- the guard's gun is still reloading as the attack starts, so the attacker gets its shots in first and the guard
	-- is seen answering an attack rather than getting in ahead of it
	guard.weapon_reloads[1] = 3
	local shots_before = shots_of(guard.id, 1)
	local guarded_health = guarded.health
	advance(10)
	local fight = {
		range = round(range, 1),
		guard_to_attacker = round(geometry.distance_2d(guard.position, attacker.position), 1),
		attacker_shots = shots_of(attacker.id, 1),
		ally_damage = round(guarded_health - guarded.health, 1),
		guard_shots = shots_of(guard.id, 1) - shots_before,
		-- dealt by the guard and the ally's grunt together
		attacker_damage = round(damage_to(attacker), 1),
		still_guarding = guarding(guard),
	}
	deaths.destroy(attacker, "removed")
	advance(tick_rate.TICK_DELTA)

	-- assisting: a Construction Bot of OWN's guards one of ALLY's that builds a solar collector
	local site_x, site_z = home.X - 40, home.Y - 40
	local ally_bot = unkillable(spawn_resting("construction_bot", ALLY, site_x, site_z + 20))
	local own_bot = unkillable(spawn_resting("construction_bot", OWN, site_x - 20, site_z + 20))
	advance(tick_rate.TICK_DELTA)
	local site = placement.resolve_center("solar_collector", site_x, site_z, 0, ally_bot)
		or heightmap.ground_position(site_x, site_z)
	orders.issue(own_bot, { { kind = "guard", position = nil, target_id = ally_bot.id } }, false, false)
	orders.issue(
		ally_bot,
		{ { kind = "build", position = site, target_id = nil, def_name = "solar_collector", facing = 0 } },
		false,
		false
	)
	local ally_ticks, assisting_ticks = 0, 0
	local finished = false
	local deadline = now() + 40
	while now() < deadline and finished == false do
		advance(tick_rate.TICK_DELTA)
		local blueprint = work.recent(ally_bot.id, "build")
		if blueprint ~= nil then
			ally_ticks += 1
			if work.recent(own_bot.id, "build") == blueprint then
				assisting_ticks += 1
			end
		end
		for _, entity in state.all() do
			if entity.def_name == "solar_collector" and entity.team == ALLY and entity.state == "active" then
				finished = true
			end
		end
	end
	local assist = {
		ally_ticks = ally_ticks,
		assisting_ticks = assisting_ticks,
		finished = finished,
		still_guarding = guarding(own_bot),
	}

	-- an enemy's unit: refused as a command (`may` above), and dropped as an order that got through anyway
	orders.issue(own_grunt, { { kind = "guard", position = nil, target_id = enemy_grunt.id } }, false, false)
	advance(tick_rate.TICK_DELTA * 2)
	local enemy_order_dropped = #own_grunt.orders == 0

	-- the alliance ends: both guards let go
	local guarding_before_leave = guarding(guard) and guarding(own_bot)
	local left = alliances.leave(ALLY)
	advance(tick_rate.TICK_DELTA * 2)
	local dropped_on_leave = guarding(guard) == false and guarding(own_bot) == false

	return {
		may_guard = may,
		follow = follow,
		fight = fight,
		assist = assist,
		enemy_order_dropped = enemy_order_dropped,
		guarding_before_leave = guarding_before_leave,
		left = left,
		dropped_on_leave = dropped_on_leave,
		pass = may.own
			and may.ally
			and may.enemy == false
			and may.nobody == false
			and follow.still_guarding
			and follow.apart < 16
			and fight.attacker_shots > 0
			and fight.ally_damage > 0
			and fight.guard_shots > 0
			and fight.attacker_damage > 0
			and fight.still_guarding
			and assist.assisting_ticks > 0
			and assist.finished
			and enemy_order_dropped
			and guarding_before_leave
			and left
			and dropped_on_leave,
	}
end

-- Skins (shared/skins). Special skins are opt in: a unit of a team nobody chose a skin for wears the plain default. A
-- team put in the pool skin has its unit re-skinned, and the def is as it is, the very same table; the golden skin, put
-- on a team that already has a unit, doubles that unit's health (keeping it full) and stretches and strengthens its
-- weapon, and what the team makes after wears it too. Only developers may wear it. Then two duels between `args.def`
-- (grunt by default): a golden one against a plain one at 80% of the plain range, for `args.seconds` (30 by default),
-- which the golden one should win, and a golden one against a plain one standing at 130% of the plain range, out of its
-- reach, for 10 seconds, which only the golden one should be hurting.
local function skins_test(args: Args): Findings
	local def_name = args.def or "grunt"
	for _, team_id in { OWN, ENEMY } do
		ensure_team(team_id)
	end
	local base = unit_defs.get(def_name)
	local base_weapon = (base.weapons :: { types.Weapon })[1]

	local first = spawn(def_name, OWN, -40, -40)
	local unchosen = { skin = first.skin, same_def = first.def == base, max_health = first.max_health }
	server_skins.set_team(OWN, "pool")
	local pool = { skin = first.skin, same_def = first.def == base, max_health = first.max_health }

	server_skins.set_team(OWN, "golden")
	local golden = first.def
	local golden_weapon = (golden.weapons :: { types.Weapon })[1]
	local reskinned = {
		skin = first.skin,
		health = round(first.health, 1),
		max_health = round(first.max_health, 1),
		range = round(golden_weapon.range / base_weapon.range, 3),
		damage = round(golden_weapon.damage / base_weapon.damage, 3),
		same_table_again = first.def == golden,
	}
	local later = spawn(def_name, OWN, -40, -30)
	local made_later = { skin = later.skin, max_health = later.max_health }

	-- a golden one against a plain one, `distance` apart on open ground, the golden one ordered to attack, and the
	-- plain one too if `both`
	local home = starts.default_spot(1)
	local function duel(distance: number, seconds: number, both: boolean): { [string]: any }
		clear_world()
		local ours = spawn_resting(def_name, OWN, home.X, home.Y)
		local theirs = spawn_resting(def_name, ENEMY, home.X + distance, home.Y)
		advance(tick_rate.TICK_DELTA)
		orders.issue(ours, { { kind = "attack", target_id = theirs.id } }, false, false)
		if both then
			orders.issue(theirs, { { kind = "attack", target_id = ours.id } }, false, false)
		end
		local our_start, their_start = ours.health, theirs.health
		advance(seconds)
		return {
			golden_alive = ours.alive,
			plain_alive = theirs.alive,
			golden_lost = round(our_start - math.max(0, ours.health), 1),
			plain_lost = round(their_start - math.max(0, theirs.health), 1),
		}
	end
	local close = duel(base_weapon.range * 0.8, args.seconds or 30, true)
	local far = duel(base_weapon.range * 1.3, 10, false)

	server_skins.set_team(OWN, shared_skins.DEFAULT_SKIN)
	return {
		default_skin = shared_skins.DEFAULT_SKIN,
		unchosen = unchosen,
		pool = pool,
		golden_reskinned = reskinned,
		golden_made_later = made_later,
		players_may_wear_golden = shared_skins.may_wear("golden", false),
		developers_may_wear_golden = shared_skins.may_wear("golden", true),
		close_duel = close,
		out_of_reach = far,
		pass = unchosen.skin == shared_skins.DEFAULT_SKIN
			and unchosen.same_def
			and pool.skin == "pool"
			and pool.same_def
			and reskinned.skin == "golden"
			and reskinned.max_health == round(unit_defs.max_health(base) * 2, 1)
			and reskinned.health == reskinned.max_health
			and reskinned.range > 1
			and reskinned.damage > 1
			and reskinned.same_table_again
			and made_later.skin == "golden"
			and made_later.max_health == unit_defs.max_health(base) * 2
			and shared_skins.may_wear("golden", false) == false
			and shared_skins.may_wear("golden", true)
			and close.golden_alive
			and close.plain_alive == false
			and far.plain_lost > 0
			and far.golden_lost == 0,
	}
end

-- What server/donuts.luau publishes about `entity`'s donut, as the client reads it: nil when it wears none.
local function donut_of(entity: Entity): { on: boolean, shake: number, event: string? }?
	local published: { [string]: any } = {}
	donuts.publish(entity, entity.def, function(name: string, value: any)
		published[name] = value
	end)
	if published.donut == nil then
		return nil
	end
	return { on = published.donut, shake = published.donut_shake or 0, event = published.donut_event }
end

-- The pool skin's donut as the server keeps it (server/donuts.luau), which is what every client draws. A pool grunt:
-- its donut is on once it is finished, a hit pops it (published `event` "1:pop"), it stays off for `regen_seconds` and
-- is on again after. A pool Valiant ordered across the map flat out shakes it, and it flies off. A commander
-- (amphibious) set down on the sea floor, `args.depth` deep (8 by default), if the map has water that deep: its donut
-- is still on at first, floats off once it has been down `submerge_seconds`, and stays off past `regen_seconds` while it
-- is still down there; and a ship on the water beside it keeps its own. It is played on islands, which have both. A golden grunt wears none. Then the debug
-- calls: force_off takes it off, and force_on puts it back.
local function donut_state(args: Args): Findings
	for _, team_id in { OWN, ENEMY } do
		ensure_team(team_id)
	end
	server_skins.set_team(OWN, "pool")
	local settings = shared_skins.get("pool").donut :: shared_skins.DonutSettings
	-- on dry land, where nothing but the hit knocks its donut off
	local land = harness.find_spot(function(x: number, z: number): boolean
		return heightmap.height_at(x, z) > ground_levels.WATER_LEVEL + 2
	end)
	assert(land ~= nil, "no dry land on this map")
	local grunt = spawn(args.def or "grunt", OWN, land.X, land.Z)
	advance(tick_rate.TICK_DELTA * 2)
	local first = donut_of(grunt)

	damage.apply(grunt, 10, nil)
	advance(tick_rate.TICK_DELTA)
	local popped = donut_of(grunt)
	advance(settings.regen_seconds - 1)
	local before_regen = donut_of(grunt)
	advance(2)
	local after_regen = donut_of(grunt)

	local plane = spawn("valiant", OWN, -150, 0)
	advance(tick_rate.TICK_DELTA)
	orders.issue(plane, { { kind = "move", position = heightmap.ground_position(150, 0) } }, false, false)
	local most_shake, flew_at = 0, nil :: number?
	local started = now()
	advance(args.seconds or 20, function()
		local published = donut_of(plane)
		if published == nil then
			return
		end
		most_shake = math.max(most_shake, published.shake)
		if flew_at == nil and published.event ~= nil and string.find(published.event, "fly") ~= nil then
			flew_at = round(now() - started, 1)
		end
	end)

	local depth = args.depth or 8
	local sea = harness.find_spot(function(x: number, z: number): boolean
		return harness.deep_all_round(x, z, depth, 12)
	end)
	local underwater: { [string]: any } = { found = sea ~= nil }
	local underwater_right = true
	if sea ~= nil then
		local diver = spawn_resting("commander", OWN, sea.X, sea.Z)
		local ship = spawn_resting(args.ship or "supporter", OWN, sea.X + 20, sea.Z)
		advance(tick_rate.TICK_DELTA * 2)
		underwater.under_the_surface = round(ground_levels.WATER_LEVEL - diver.position.Y, 1)
		underwater.diver_at_once = donut_of(diver)
		advance(settings.submerge_seconds)
		underwater.diver = donut_of(diver)
		underwater.ship = donut_of(ship)
		advance(settings.regen_seconds + 2)
		underwater.diver_after_regen_time = donut_of(diver)
		underwater.ship_after = donut_of(ship)
		local function is_on(published: any): boolean
			return published ~= nil and published.on == true
		end
		underwater_right = is_on(underwater.diver_at_once)
			and is_on(underwater.diver) == false
			and underwater.diver ~= nil
			and string.find(underwater.diver.event or "", "float") ~= nil
			and is_on(underwater.ship)
			and is_on(underwater.diver_after_regen_time) == false
			and is_on(underwater.ship_after)
	end

	server_skins.set_team(OWN, "golden")
	advance(tick_rate.TICK_DELTA)
	local golden = donut_of(grunt)
	server_skins.set_team(OWN, "pool")
	advance(tick_rate.TICK_DELTA * 2)
	local forced_off = donuts.force_off(grunt, "pop")
	local after_force_off = donut_of(grunt)
	local forced_on = donuts.force_on(grunt)
	local after_force_on = donut_of(grunt)
	server_skins.set_team(OWN, shared_skins.DEFAULT_SKIN)
	return {
		first = first,
		popped = popped,
		before_regen = before_regen,
		after_regen = after_regen,
		plane = { max_speed = unit_defs.get("valiant").max_speed, most_shake = most_shake, flew_off_after = flew_at },
		underwater = underwater,
		golden = golden or "none",
		forced_off = forced_off,
		after_force_off = after_force_off,
		forced_on = forced_on,
		after_force_on = after_force_on,
		pass = first ~= nil
			and first.on
			and popped ~= nil
			and popped.on == false
			and popped.event == "1:pop"
			and before_regen ~= nil
			and before_regen.on == false
			and after_regen ~= nil
			and after_regen.on
			and most_shake > 0
			and flew_at ~= nil
			and underwater_right
			and golden == nil
			and forced_off
			and after_force_off ~= nil
			and after_force_off.on == false
			and forced_on
			and after_force_on ~= nil
			and after_force_on.on,
	}
end

-- Every team the largest mode seats has a colour of its own (shared/appearance.luau), none of them the grey of no
-- team's or the scavengers' purple; a team past them takes one of them again rather than going grey.
local function team_colors(_args: Args): Findings
	local neutral = appearance.team_color(teams.NEUTRAL)
	local scavenger = appearance.team_color(teams.SCAVENGER)
	local seen: { [string]: number } = {}
	local clashes: { string } = {}
	for team = 1, game_modes.LARGEST_CAPACITY do
		local color = appearance.team_color(team)
		local key = color:ToHex()
		if seen[key] ~= nil or color == neutral or color == scavenger then
			table.insert(clashes, `team {team}: {key}`)
		end
		seen[key] = team
	end
	local beyond = appearance.team_color(game_modes.LARGEST_CAPACITY + 1)
	return {
		teams = game_modes.LARGEST_CAPACITY,
		clashes = clashes,
		pass = #clashes == 0 and beyond ~= neutral,
	}
end

-- What a player's client sends of their commands is only taken as far as it is what it should be (server/commands.luau,
-- through server_shared/remotes.luau): a fight or a move to a spot that is no real point, an area order of no real
-- radius, and a
-- blueprint off the map or turned by no real angle order nothing, and neither do builders sent as ids that are not
-- numbers; the same sent right does.
local function order_remotes(_args: Args): Findings
	local commander = harness.join(OWN)
	local grunt = spawn_resting("grunt", OWN, 0, 0)
	local bot = spawn_resting("construction_bot", OWN, 10, 0)
	local here = grunt.position
	harness.send("IssueOrder", commander, { kind = "fight", ids = { grunt.id }, position = Vector3.new(0 / 0, 0, 10) })
	harness.send(
		"IssueOrder",
		commander,
		{ kind = "move", ids = { grunt.id }, positions = { Vector3.new(10, 0, math.huge) } }
	)
	harness.send(
		"IssueOrder",
		commander,
		{ kind = "area_reclaim", ids = { bot.id }, position = here, radius = math.huge }
	)
	harness.send("IssueOrder", commander, { kind = "fight", ids = { tostring(grunt.id) }, position = here })
	local extent = heightmap.half_extents()
	harness.send("PlaceBlueprint", commander, {
		def_name = "solar_collector",
		position = Vector3.new(extent * 4, 0, 0),
		facing = 0,
		ids = { bot.id },
	})
	harness.send("PlaceBlueprint", commander, {
		def_name = "solar_collector",
		position = here + Vector3.new(0, 0, 30),
		facing = 0 / 0,
		ids = { bot.id },
	})
	local refused = #grunt.orders == 0 and #bot.orders == 0
	harness.send(
		"IssueOrder",
		commander,
		{ kind = "move", ids = { grunt.id }, positions = { here + Vector3.new(30, 0, 0) } }
	)
	harness.send("PlaceBlueprint", commander, {
		def_name = "solar_collector",
		position = here + Vector3.new(0, 0, 30),
		facing = 0,
		ids = { bot.id },
	})
	local taken = #grunt.orders > 0 and #bot.orders > 0
	return {
		refused = refused,
		taken = taken,
		pass = refused and taken,
	}
end

-- A seat is only ever on a side its mode has, or watching: a lobby refuses a move to any other, a fraction or NaN
-- included (they pass a plain range check), and a stored match with a seat on one is no match.
local function mode_sides(_args: Args): Findings
	local duel = game_modes.get "1v1" :: game_modes.Mode
	local wrong: { string } = {}
	for _, side in { game_modes.SPECTATOR_SIDE, 1, 2 } do
		if game_modes.has_side(duel, side) == false then
			table.insert(wrong, `{side} refused`)
		end
	end
	for _, side in { 1.5, 0 / 0, 3, -1, math.huge } do
		if game_modes.has_side(duel, side) then
			table.insert(wrong, `{side} allowed`)
		end
	end
	local duel_match = game_modes.new_match(duel.id, "highlands", table.clone(DUEL_MATCH.seats))
	local stored = game_modes.encode(duel_match)
	stored.seats[1].side = 1.5
	local decoded = game_modes.decode(stored)
	return {
		wrong = wrong,
		fractional_seat_decoded = decoded ~= nil,
		pass = #wrong == 0 and decoded == nil and game_modes.decode(game_modes.encode(duel_match)) ~= nil,
	}
end

local TESTS: { [string]: Test } = {
	team_colors = { run = team_colors },
	order_remotes = { run = order_remotes },
	mode_sides = { run = mode_sides },
	match = { run = match_test, defaults = { match = SCAVENGER_MATCH } },
	conquest = { run = conquest_test, defaults = { match = DUEL_MATCH } },
	match_stats = { run = match_stats_test },
	unally = { run = unally_test },
	ally_guard = { run = ally_guard },
	skins = { run = skins_test },
	donut_state = { run = donut_state, defaults = { preset = "islands" } },
}

return table.freeze(TESTS)
