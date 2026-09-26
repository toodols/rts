--!strict
-- A computer player. Each team it plays has a brain of its own (brains.luau), which looks the team over once a second
-- (census.luau) and gives its builders, labs and army their orders through the same `orders.issue` and
-- `production.enqueue` a player's commands come through, so it plays by the rules everything else does: it pays for
-- what it builds, walks where it goes and can be beaten. What it knows of the enemy is its profile's to say (`sees`):
-- by default everything, wherever it is, which no player knows; with "team_sight" only what its side's things are near.
--
-- It sees the map through a danger field (danger_field.luau): where the enemy's weapons reach, and how hard. Its
-- builders only go to build, and its rezbots to raise a wreck, where the field is quiet and by a way that is quiet too;
-- a builder whose errand turns dangerous on the way drops it, one caught where it is not or taking hits out on the map
-- runs for home; and its army only attacks where what it would face is well short of what it has.
--
-- A thought, in order (`think`):
--
-- - labs.luau: what its labs make.
-- - errands.luau: its builders, given what the economy planner wants built (economy_planner.luau) where it goes
--   (siting.luau), or something to help with, and its rezbots.
-- - retreats.luau, escorts.luau, groups.luau: hurt fighters sent home to be mended, escorts for the builders out on the
--   map, and groups apart from the army: raids, hunters and strikes, so that it fights on several fronts at once.
-- - army.luau: the army, with what it goes after (targets.luau), seeing off intruders (defence.luau), and the fight
--   predictor it may ask (predictions.luau).
--
-- How much of all that it does is its profile's (shared/ai_profiles.luau), which each brain carries: what it may build
-- at all, its line, how eagerly it spreads its extractors and how many it guards, how big its army grows before it goes
-- and how that grows over the game, and whether it sends raids of its fastest units at the enemy's extractors and
-- constructors apart from its army. Where these files say "the profile's", the number is there; the default profile is
-- the AI as it always played.
--
-- Some of it was taken from BARb, BAR's own computer player (CircuitAI's "barbarian" branch, with its settings in the
-- game's luarules/configs/BARb/stable), and is off in the default profile and on in the "barb" one: hurt fighters go
-- home to be mended (retreats.luau), an enemy near home or an extractor is met by only as much of the army as it takes
-- (defence.luau), the energy it wants for its metal grows over the game (economy_planner.luau's `energy_per_metal`),
-- escorts go with only the first few builders for the first minutes, guards wait for the income, the commander helps
-- its lab until it has its first constructors (errands.luau's `help_lab`), and raids go for constructors first. Where
-- each came from in BARb is said beside it, and in shared/ai_profiles.luau.
--
-- What is looked in on from outside, for commands and tests, is inspect.luau's.

local ReplicatedStorage = game:GetService "ReplicatedStorage"
local ServerScriptService = game:GetService "ServerScriptService"

local types = require(ReplicatedStorage.Shared.types)
local heightmap = require(ReplicatedStorage.Shared.heightmap)
local starts = require(ReplicatedStorage.Shared.starts)
local ai_profiles = require(ReplicatedStorage.Shared.ai_profiles)

local state = require(ServerScriptService.Server.state)
local spawning = require(ServerScriptService.Server.spawning)
local players = require(ServerScriptService.Server.players)
local alliances = require(ServerScriptService.Server.alliances)

local brains = require(script.brains)
local assignments = require(script.assignments)
local catalog = require(script.catalog)
local censuses = require(script.census)
local danger_field = require(script.danger_field)
local economy_planner = require(script.economy_planner)
local errands = require(script.errands)
local labs = require(script.labs)
local retreats = require(script.retreats)
local escorts = require(script.escorts)
local groups = require(script.groups)
local squads = require(script.squads)
local army = require(script.army)
local inspect = require(script.inspect)
local sorties = require(script.sorties)

type Entity = types.Entity
type EntityId = types.EntityId
type OrderKind = types.OrderKind
type TeamId = types.TeamId
type Brain = brains.Brain
type Line = brains.Line
type Profile = ai_profiles.Profile

-- How often a brain's danger field is worked out again.
local FIELD_INTERVAL = 2

-- How many opponents to put down once the game is under way, the line and profile each plays (if it is told them),
-- and whether that has been done.
local opponents_wanted = 0
local opponent_orders: { ai_profiles.Opponent } = {}
local opponents_placed = false

-- Forgets what it remembered about anything that is gone, and the sites it gave up on that may be tried again.
local function prune(brain: Brain)
	assignments.prune(brain)
	for _, tally in { brain.goals, brain.waived, brain.full, brain.blocked } :: { { [EntityId]: any } } do
		for id in tally do
			if state.get(id) == nil then
				tally[id] = nil
			end
		end
	end
	local now = brains.now()
	for index = #brain.bad_sites, 1, -1 do
		if now >= brain.bad_sites[index].expires then
			table.remove(brain.bad_sites, index)
		end
	end
end

local function think(brain: Brain)
	local now = brains.now()
	brain.next_think = now + brains.THINK_INTERVAL
	local team = state.get_team(brain.team)
	if team == nil then
		return
	end
	prune(brain)
	local census = censuses.take(brain)
	if now >= brain.next_field or danger_field.fits_map(brain.field) == false then
		if danger_field.fits_map(brain.field) == false then
			brain.field = danger_field.new()
		end
		danger_field.refresh(brain.field, census.enemies)
		brain.next_field = now + FIELD_INTERVAL
	end
	local economy = censuses.read_economy(team, census, brain.profile)
	if brain.profile.spread ~= nil then
		brain.splash = squads.widest_splash(census.enemies)
	end

	local commander = census.commander
	if brain.opened == false then
		if commander ~= nil and #census.factories == 0 and #census.builders == 1 and #census.structures == 0 then
			if #commander.orders == 0 then
				errands.open(brain, census, commander)
			end
			return
		end
		brain.opened = true
	end
	economy_planner.resolve_line(brain, census)

	labs.run_factories(brain, census, economy)
	errands.run_builders(brain, census, economy)
	errands.run_rezbots(brain, census)
	retreats.run_retreats(brain, census)
	escorts.run_escorts(brain, census)
	groups.run_groups(brain, census)
	army.run_army(brain, census, economy)
	sorties.fronts(brain, #groups.fronts(brain, nil))
end

-- Where the team's commander stands, or its start if it has none.
local function home_of(team_id: TeamId): Vector3
	for _, entity in state.all() do
		if entity.alive and entity.team == team_id and catalog.role_of(entity.def_name).commander then
			return entity.position
		end
	end
	return heightmap.ground_position(starts.center(team_id).X, starts.center(team_id).Y)
end

-- Hands team `team_id`, which should already have its commander, to the AI, playing by `profile` (the default if not
-- given).
local function add(team_id: TeamId, profile: Profile?)
	brains.add(team_id, home_of(team_id), profile or ai_profiles.DEFAULT)
end

-- Makes team `team_id`'s AI build from `line`'s labs, whatever it would have chosen.
local function set_line(team_id: TeamId, line: Line)
	local brain = brains.get(team_id)
	if brain ~= nil then
		brains.tell_line(brain, line)
	end
end

-- Makes team `team_id`'s AI play by `profile` from now on, and build from its line if it names one. Returns whether the
-- AI plays the team.
local function set_profile(team_id: TeamId, profile: Profile): boolean
	local brain = brains.get(team_id)
	if brain == nil then
		return false
	end
	brain.profile = profile
	brains.tell_line(brain, profile.line)
	return true
end

-- The profile team `team_id`'s AI plays by, if the AI plays it.
local function profile_of(team_id: TeamId): Profile?
	local brain = brains.get(team_id)
	return if brain ~= nil then brain.profile else nil
end

-- Team `team_id` is no longer the AI's, and what was seen of its AI is forgotten.
local function remove(team_id: TeamId)
	brains.remove(team_id)
	inspect.forget(team_id)
end

local function is_ai(team_id: TeamId): boolean
	return brains.get(team_id) ~= nil
end

-- Every team the AI plays, in order.
local function teams(): { TeamId }
	local list: { TeamId } = {}
	for team_id in brains.all() do
		table.insert(list, team_id)
	end
	table.sort(list)
	return list
end

-- Makes a new team for the AI, named `name`, allied with team `ally` if given, playing by `profile` (the default if not
-- given), and puts its commander down at `at`, or at the start furthest from everyone. Returns its team, or nil if
-- there was no room for the commander; no team is made when there is no free start.
local function spawn_opponent(name: string?, at: Vector2?, ally: TeamId?, profile: Profile?): TeamId?
	local start = at or spawning.free_start()
	if start == nil then
		return nil
	end
	local count = 0
	for _ in brains.all() do
		count += 1
	end
	local team_id = players.create_team(name or `AI {count + 1}`)
	if ally ~= nil then
		alliances.ally(team_id, ally)
	end
	spawning.set_start(team_id, start)
	if spawning.give_starting_force(team_id) == false then
		return nil
	end
	add(team_id, profile)
	return team_id
end

-- Hands team `team_id` to the AI, playing by `profile` (the default if not given), first putting its commander down at
-- `at`, or at the start furthest from everyone, if it has nothing on the map yet. Returns false if there was no room
-- for the commander.
local function take_over(team_id: TeamId, at: Vector2?, profile: Profile?): boolean
	if spawning.owns_anything(team_id) == false then
		local start = at or spawning.free_start()
		if start == nil then
			return false
		end
		spawning.set_start(team_id, start)
		if spawning.give_starting_force(team_id) == false then
			return false
		end
	end
	add(team_id, profile)
	return true
end

-- A new map: every team the AI plays starts over, at the start furthest from everyone, as a player does. Called once
-- the map is built and the players' commanders stand. With no start free it takes the one numbered as the team. Each
-- keeps its profile.
local function restart_on_new_map()
	for _, team_id in teams() do
		local profile = (brains.get(team_id) :: Brain).profile
		spawning.set_start(team_id, spawning.free_start() or starts.center(team_id))
		spawning.give_starting_force(team_id)
		add(team_id, profile)
	end
end

-- `opponents` teams are put down for the AI on the first step of the game, the first few playing the line and profile
-- in `given` (by position); and what each brain does is kept from now on, for whoever looks in (inspect.luau).
local function init(opponents: number, given: { ai_profiles.Opponent }?)
	inspect.init()
	errands.init()
	opponents_wanted = math.max(0, math.floor(opponents))
	opponent_orders = given or {}
end

-- Called once per step, after income and before orders, so what the AI decides is what its units do this step.
local function tick(_delta: number)
	if opponents_placed == false then
		opponents_placed = true
		for index = 1, opponents_wanted do
			local order: ai_profiles.Opponent? = opponent_orders[index]
			local team_id = spawn_opponent(nil, nil, nil, if order ~= nil then order.profile else nil)
			local line: Line? = if order ~= nil then order.line else nil
			if team_id ~= nil and line ~= nil then
				set_line(team_id, line)
			end
		end
	end
	local now = brains.now()
	-- team by team, in order
	for _, team_id in teams() do
		local brain = brains.get(team_id) :: Brain
		if now >= brain.next_think then
			think(brain)
		end
	end
end

-- For the AI arena's staged fights (tools/ai_arena/formation_check.py): the places a group of `units` sent to `goal`
-- with an order of `kind` is spread over (squads.luau's `formation`), `spacing` studs apart, against no splash.
local function formation_for(
	units: { Entity },
	goal: Vector3,
	kind: OrderKind,
	spacing: number
): { [EntityId]: Vector3 }?
	return squads.formation(units, goal, kind, spacing, 0, Vector3.new(1, 0, 0), {})
end

return table.freeze({
	init = init,
	tick = tick,
	add = add,
	remove = remove,
	set_line = set_line,
	set_profile = set_profile,
	profile_of = profile_of,
	is_ai = is_ai,
	teams = teams,
	spawn_opponent = spawn_opponent,
	take_over = take_over,
	restart_on_new_map = restart_on_new_map,
	describe = inspect.describe,
	report = inspect.report,
	formation_for = formation_for,
})
