--!strict
-- How far a game against the scavengers has got, from 0 to 1, rising steadily over `game_length` seconds. Nothing the
-- scavengers do is decided by anything else: beacons wait for it, and it is what their budget grows with (`budget`), the
-- hardest single thing a beacon may make now, in difficulty (roster.luau's `difficulty_of`). The budget is not a limit
-- on how much is out: there is none, and how many come is up to how many beacons stand. It runs from
-- settings.BUDGET_START to settings.BUDGET_END over the game, a little slower than exponentially: the log
-- of how far it has grown is `progress ^ settings.BUDGET_SHAPE` of the way, which with a shape under 1 is ahead early
-- and eases off.
--
-- It also keeps when the game began for them, which their schedules count from (`now`, by the game's clock (state.now)), and
-- what everything they field has in health.

local ReplicatedStorage = game:GetService "ReplicatedStorage"
local ServerScriptService = game:GetService "ServerScriptService"

local types = require(ReplicatedStorage.Shared.types)
local unit_defs = require(ReplicatedStorage.Shared.unit_defs)

local state = require(ServerScriptService.Server.state)

local settings = require(script.Parent.settings)

type Entity = types.Entity

local BUDGET_GROWTH = math.log(settings.BUDGET_END / settings.BUDGET_START)

-- When, by the game's clock (state.now), the game began for them: every schedule of theirs runs on the seconds since.
local began_at = state.now()
-- Added to the clock for the game's progress alone, so that progress can be set without moving the clock the
-- schedules run on.
local progress_offset = 0
-- How many seconds the game takes to reach full progress; a match against harder scavengers is shorter (see
-- `set_pace`).
local game_length = settings.GAME_LENGTH
-- What everything they field has in health, as a multiple of its def's; a match sets it from its difficulty.
local health_multiplier = 1

-- Seconds of the game so far.
local function now(): number
	return state.now() - began_at
end

local function progress(): number
	return math.clamp((now() + progress_offset) / game_length, 0, 1)
end

-- Sets how far the game has got, from 0 to 1, from now on: it carries on rising from there. The budget follows it,
-- and it is the only thing that does, so it is what sets the difficulty. Returns the progress it was set to.
local function set_progress(fraction: number): number
	local wanted = math.clamp(fraction, 0, 1)
	progress_offset = wanted * game_length - now()
	return wanted
end

local function budget(): number
	return settings.BUDGET_START * math.exp(BUDGET_GROWTH * progress() ^ settings.BUDGET_SHAPE)
end

-- Sets the progress to what makes the budget `score` (the difficulty on the scavengers' readout) and returns the
-- progress and the budget that came of it. A score outside what the budget goes through, from its start to where it
-- stops growing, is taken to the nearest end.
local function set_difficulty(score: number): (number, number)
	-- the budget's curve run backwards
	local wanted = if score > settings.BUDGET_START
		then math.min(math.log(score / settings.BUDGET_START) / BUDGET_GROWTH, 1) ^ (1 / settings.BUDGET_SHAPE)
		else 0
	local set = set_progress(wanted)
	return set, budget()
end

-- Makes the game take `multiple` times settings.GAME_LENGTH to reach full progress, keeping the progress it
-- has now: under 1 the scavengers grow stronger sooner, which is what a lobby's difficulty sets.
local function set_pace(multiple: number)
	local now_progress = progress()
	game_length = settings.GAME_LENGTH * math.max(multiple, 0.01)
	set_progress(now_progress)
end

-- How many seconds the game takes to reach full progress.
local function length(): number
	return game_length
end

local function pace(): number
	return game_length / settings.GAME_LENGTH
end

-- Sets what everything the scavengers field from now on has in health, as a multiple of its def's: a match sets it
-- from its difficulty (`game_modes.Difficulty.health`).
local function set_health_multiplier(multiple: number)
	health_multiplier = math.max(multiple, 0.01)
end

local function get_health_multiplier(): number
	return health_multiplier
end

-- What something the scavengers field has in health: its def's times the difficulty's multiplier. It keeps the share of
-- its health it had.
local function toughen(entity: Entity)
	local fraction = entity.health / entity.max_health
	entity.max_health = unit_defs.max_health(entity.def) * health_multiplier
	entity.health = entity.max_health * fraction
end

-- A new game on a new map: the clock and the progress start over. The pace and the health, which the match sets, stay.
local function reset()
	began_at = state.now()
	progress_offset = 0
end

return table.freeze({
	now = now,
	progress = progress,
	set_progress = set_progress,
	budget = budget,
	set_difficulty = set_difficulty,
	set_pace = set_pace,
	pace = pace,
	length = length,
	set_health_multiplier = set_health_multiplier,
	health_multiplier = get_health_multiplier,
	toughen = toughen,
	reset = reset,
})
