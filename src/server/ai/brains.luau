--!strict
-- Every team the AI plays has a brain: what it remembers from one thought to the next, each part of it kept by the part
-- of the AI whose it is (the army's by army.luau, its groups by groups.luau, and so on). This module keeps the brains, by
-- team, and the clock they all think by (the simulation's), says what a team's brain lets it build (`may_build`, `can_build`), and takes
-- the line it is told to play (`tell_line`).

local ReplicatedStorage = game:GetService "ReplicatedStorage"
local ServerScriptService = game:GetService "ServerScriptService"

local types = require(ReplicatedStorage.Shared.types)
local unit_defs = require(ReplicatedStorage.Shared.unit_defs)
local geometry = require(ReplicatedStorage.Shared.geometry)
local ai_profiles = require(ReplicatedStorage.Shared.ai_profiles)

local build_rules = require(ServerScriptService.Server.build_rules)
local state = require(ServerScriptService.Server.state)

local danger_field = require(script.Parent.danger_field)
local snapshot = require(ServerScriptService.Server.snapshot)

-- The clock every brain thinks by: the game's (state.now).
local now = state.now

type Entity = types.Entity
type EntityId = types.EntityId
type TeamId = types.TeamId
type Field = danger_field.Field
type Profile = ai_profiles.Profile

-- Which kind of lab it builds its army from.
export type Line = ai_profiles.Line

-- How a wave ended, or a group out apart from the army: it had nothing left it could attack, the danger where it stood
-- was too much for it, it lost too much of itself, it was called home to see off an enemy there, or none of it is left.
export type WaveEnd = "won" | "outmatched" | "broken" | "defend" | "lost"

-- A wave the army set out in, or a group sent out apart from it: when (seconds since the brain began), how many went,
-- what they were worth, and, for a wave, what it had to be worth to go, or, for a group, what it went after first; and
-- how it ended once it has. For a group, how many of what it went after it saw destroyed, and, for a raid, how often it
-- slipped away from a threat to another target rather than come home. What is looked in on from outside
-- (inspect.luau) keeps these; a group keeps its own to count on.
export type Sortie = {
	at: number,
	units: number,
	worth: number,
	needed: number?,
	target: string?,
	ended: WaveEnd?,
	kills: number?,
	slipped: number?,
}

-- What a group out apart from the army is (groups.luau): a raid, a few of its fastest units after the enemy's
-- extractors and constructors; a hunt, after the enemy's units in its territory; or a strike, at a target of the
-- enemy's away from where the wave is.
export type GroupKind = "raid" | "hunt" | "strike"

-- A group out apart from the army: what it is after, once it has chosen, whether it is on its way home, to be let go
-- back into the army once it is there, when the fight it is in is next predicted again, and what it was remembered as
-- when it was sent. Its units are those assigned to it.
export type Group = {
	kind: GroupKind,
	target: EntityId?,
	returning: boolean,
	next_check: number,
	sortie: Sortie,
}

-- A hurt fighter on its way home to be mended, or waiting there: since when it has been waiting (or walking, until it
-- gets there), the most health it has had since, and whether a construction turret is where it went.
export type Retreat = {
	since: number,
	health: number,
	arrived: boolean,
	turret: EntityId?,
}

-- What one of its units has been given to do, apart from waiting with the army or building what the economy wants:
--
-- - "wave": out with the wave that set out;
-- - "group": out in `group`, a raid, a hunt or a strike;
-- - "escort": guarding `builder`, out on the map;
-- - "defend": sent from home to see off an intruder, apart from the rest;
-- - "retreat": gone home to be mended (`retreat`);
-- - "assist": a builder helping with something for want of anything better, looked at again from `ends_at`;
-- - "expand": a builder out on the map, beyond the base, which wants an escort;
-- - "flee": a builder that ran from danger, left to get home until `ends_at`;
-- - "salvage": a rezbot sent to the wreck or rock `target`.
export type Assignment =
	{ job: "wave" }
	| { job: "group", group: Group }
	| { job: "escort", builder: EntityId }
	| { job: "defend" }
	| { job: "retreat", retreat: Retreat }
	| { job: "assist", ends_at: number }
	| { job: "expand" }
	| { job: "flee", ends_at: number }
	| { job: "salvage", target: EntityId }

export type Job = "wave" | "group" | "escort" | "defend" | "retreat" | "assist" | "expand" | "flee" | "salvage"

-- Every unit's assignment (ai/assignments.luau), and, by job, which units have it, in the order they were given it: the
-- one place a unit's job is kept, looked up by unit or gone over by job.
export type Assignments = {
	of: { [EntityId]: Assignment },
	by_job: { [Job]: { EntityId } },
}

-- The wave out: what it was worth when it set out, and what it is going after. Its units are those with the job.
export type Wave = {
	worth: number,
	target: EntityId?,
}

-- The army (army.luau): the wave out, if one is; the intruder the whole army was called to see off, if it was; when
-- the next wave may set out, and how many have; and when the fight of the wave out is next predicted again (by its
-- profile's retreat_rule "sim").
export type Army = {
	wave: Wave?,
	defending: EntityId?,
	next_attack_at: number,
	waves_sent: number,
	next_sim_check: number,
}

-- The groups out apart from the army (groups.luau), in the order they were sent; when the next raid, and the next
-- strike, may be sent; and the enemy's units a hunt is after, which the army leaves to it.
export type Groups = {
	out: { Group },
	next_raid_at: number,
	next_strike_at: number,
	hunted: { [EntityId]: boolean },
}

-- What its labs may still spend on fighters, by the profile's army_share (labs.luau), and the clock when that was last
-- counted.
export type ArmyBudget = {
	metal: number,
	at: number,
}

-- A site a builder of its own gave up on, for something standing there it could not clear, and when it may be tried
-- again (errands.luau).
export type BadSite = {
	position: Vector3,
	expires: number,
}

export type Brain = {
	team: TeamId,
	profile: Profile,
	-- the clock when it began, which escalation counts from
	started: number,
	home: Vector3,
	-- the way from home toward the middle of the map, flat and of length 1
	forward: Vector3,
	-- the line it plays, once it was told one or has chosen (economy_planner.luau's `resolve_line`)
	line: Line?,
	field: Field,
	-- the stream of server/rng.luau it rolls from, its team's own
	stream: string,
	next_think: number,
	next_field: number,
	opened: boolean,
	-- what each of its units has been given to do (`Assignment`)
	assignments: Assignments,
	-- each unit it sent somewhere, and where (squads.luau)
	goals: { [EntityId]: Vector3 },
	army: Army,
	groups: Groups,
	-- the widest splash of the enemy's that it spreads out against, by the profile's spread (squads.luau)
	splash: number,
	army_budget: ArmyBudget,
	-- builders at a site something they cannot clear stands on, since when, and the sites given up on that way
	blocked: { [EntityId]: number },
	bad_sites: { BadSite },
	-- hurt fighters it gave up on mending, which are not sent home again until they are over the profile's
	-- retreat_health (retreats.luau)
	waived: { [EntityId]: boolean },
	-- buildings with no room left beside them for another of their kind (siting.luau)
	full: { [EntityId]: boolean },
	-- its builders that have been hit since its last thought (errands.luau)
	hit: { [EntityId]: boolean },
}

-- How often a brain thinks.
local THINK_INTERVAL = 1
-- Every job there is, in the order a brain goes over them.
local JOBS: { Job } = { "wave", "group", "escort", "defend", "retreat", "assist", "expand", "flee", "salvage" }

local brains: { [TeamId]: Brain } = {}
-- Units of a team the AI plays that something else commands (a mission's raiders): no brain counts them or gives them
-- orders (census.luau passes over them). Kept until the unit is gone.
local left_alone: { [EntityId]: boolean } = {}

-- The AI leaves the unit `unit_id` to whatever commands it, for as long as it lives.
local function leave_alone(unit_id: EntityId)
	left_alone[unit_id] = true
end

local function is_left_alone(unit_id: EntityId): boolean
	return left_alone[unit_id] == true
end

-- `unit_id` is gone.
local function forget(unit_id: EntityId)
	left_alone[unit_id] = nil
end

local function get(team_id: TeamId): Brain?
	return brains[team_id]
end

-- Every brain, by team. Read only.
local function all(): { [TeamId]: Brain }
	return brains
end

-- A new brain for team `team_id`, at home at `home`, playing by `profile`, which begins to think now.
local function add(team_id: TeamId, home: Vector3, profile: Profile): Brain
	local forward = geometry.flatten(-home)
	local started = now()
	local by_job: { [Job]: { EntityId } } = {}
	for _, job: Job in JOBS do
		by_job[job] = {}
	end
	local brain: Brain = {
		team = team_id,
		profile = profile,
		started = started,
		home = home,
		forward = if forward.Magnitude > 1 then forward.Unit else Vector3.new(1, 0, 0),
		line = profile.line,
		field = danger_field.new(),
		stream = `ai {team_id}`,
		next_think = started + (team_id % 7) / 7 * THINK_INTERVAL,
		next_field = started,
		opened = false,
		assignments = { of = {}, by_job = by_job },
		goals = {},
		army = {
			wave = nil,
			defending = nil,
			next_attack_at = started,
			waves_sent = 0,
			next_sim_check = started,
		},
		groups = { out = {}, next_raid_at = started, next_strike_at = started, hunted = {} },
		splash = 0,
		army_budget = { metal = 0, at = started },
		blocked = {},
		bad_sites = {},
		waived = {},
		full = {},
		hit = {},
	}
	brains[team_id] = brain
	return brain
end

local function remove(team_id: TeamId)
	brains[team_id] = nil
end

-- Has `brain` play `line` from now on, if it is told one.
local function tell_line(brain: Brain, line: Line?)
	if line ~= nil then
		brain.line = line
	end
end

-- Whether team `team_id` may build or make `def_name`: the campaign lets it, and, if the AI plays it, its profile's
-- roster has it.
local function may_build(team_id: TeamId, def_name: string): boolean
	if build_rules.allows(team_id, def_name) == false then
		return false
	end
	local brain = brains[team_id]
	local roster = if brain ~= nil then brain.profile.roster else nil
	return roster == nil or roster[def_name] == true
end

local function can_build(builder: Entity, def_name: string): boolean
	return table.find(unit_defs.build_options(builder.def), def_name) ~= nil and may_build(builder.team, def_name)
end

snapshot.keep("ai_brains", function()
	return { brains = brains, left_alone = left_alone }
end, function(saved)
	brains = saved.brains
	left_alone = saved.left_alone
end)

return table.freeze({
	THINK_INTERVAL = THINK_INTERVAL,
	JOBS = JOBS,
	now = now,
	get = get,
	all = all,
	add = add,
	remove = remove,
	tell_line = tell_line,
	may_build = may_build,
	can_build = can_build,
	leave_alone = leave_alone,
	is_left_alone = is_left_alone,
	forget = forget,
})
