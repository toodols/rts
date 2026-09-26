--!strict
-- Where the game is in getting started, as both sides see it. It opens `waiting`: nothing moves while every player
-- loads in and chooses where to start, somewhere in their team's start box (`starts`). Once all of them have, it counts
-- down for a few seconds and then it is `playing`, until the game is won and it is `ended`, with the
-- teams that won, which it stays: in a game against the scavengers, when their boss falls. Someone arriving, or giving up their start, during the countdown sends it back
-- to waiting (see server/pregame.luau).
--
-- A game a lobby started also waits for everyone the lobby sent to arrive, or for them to be given up on (see
-- server/match.luau); until then the names of the ones still on their way are published too.
--
-- The server sets it all and it reaches the clients as replicated fields (shared/replicated.luau): the phase, when the
-- countdown ends, who is still on their way, and once it has ended who won, how and when, as the game's; and as each
-- player's whether they have loaded, the start box they are to choose within, and where in it they chose. With them
-- goes how fast the game is running (`sim_rate`).

local ReplicatedStorage = game:GetService "ReplicatedStorage"
local Workspace = game:GetService "Workspace"

local signal = require(ReplicatedStorage.Shared.signal)
local replicated = require(ReplicatedStorage.Shared.replicated)

export type Phase = "waiting" | "countdown" | "playing" | "ended"

local PHASE = replicated.world("game", "phase", replicated.STRING)
-- when the countdown ends, in `Workspace:GetServerTimeNow()`'s seconds
local COUNTDOWN_ENDS = replicated.world("game", "countdown_ends", replicated.NUMBER)
-- the display names of the players still on their way
local AWAITING = replicated.world("game", "awaiting", replicated.STRINGS)
-- the teams that won, once it has ended, and a line on how it was won
local WINNERS = replicated.world("game", "winners", replicated.NUMBERS)
local END_REASON = replicated.world("game", "end_reason", replicated.STRING)
-- when it ended, in `Workspace:GetServerTimeNow()`'s seconds
local ENDED_AT = replicated.world("game", "ended_at", replicated.NUMBER)
-- how many seconds of the game pass in a second of real time: 1 normally, more while warping, 0 while paused
local SIM_RATE = replicated.world("game", "sim_rate", replicated.NUMBER)
local LOADED = replicated.player("game", "loaded", replicated.BOOLEAN)
local BOX = replicated.player("game", "start_box", replicated.NUMBER)
local START = replicated.player("game", "start_position", replicated.VECTOR3)

-- the server's own word of each phase it sets, as it sets it
local phase_set = signal.new() :: signal.Signal<Phase>

-- Before the server says otherwise the game is waiting.
local function phase(): Phase
	local value = PHASE.get()
	if value == "countdown" or value == "playing" or value == "ended" then
		return value
	end
	return "waiting"
end

local function is_playing(): boolean
	return phase() == "playing"
end

-- Whether the game is under way or over: whether the time for choosing starts has gone.
local function has_begun(): boolean
	local now = phase()
	return now == "playing" or now == "ended"
end

-- The teams that won, once the game has ended; empty before, and if nobody did.
local function winners(): { number }
	return WINNERS.get() or {}
end

-- How the game was won, once it has ended, if the server said.
local function end_reason(): string?
	return END_REASON.get()
end

-- When the game ended, in `Workspace:GetServerTimeNow()`'s seconds, once it has.
local function ended_at(): number?
	return ENDED_AT.get()
end

-- When the countdown ends, in `Workspace:GetServerTimeNow()`'s seconds, while there is one.
local function countdown_ends(): number?
	return COUNTDOWN_ENDS.get()
end

-- How many seconds of the game pass in a second of real time, as the server says.
local function sim_rate(): number
	return SIM_RATE.get() or 1
end

local function is_loaded(player: Player): boolean
	return LOADED.get(player) == true
end

-- Where `player` chose to start, on the ground, or nil if they have not.
local function start_of(player: Player): Vector3?
	return START.get(player)
end

-- The start box `player`'s team starts in, or nil before they have been given one.
local function box_of(player: Player): number?
	return BOX.get(player)
end

-- The display names of the players a lobby sent here who have not arrived yet and are still being waited for.
local function awaiting(): { string }
	return AWAITING.get() or {}
end

-- Calls `listener` whenever the phase, when the countdown ends, who is still on their way or who won changes, until
-- the returned function is called.
local function changed(listener: () -> ()): () -> ()
	return replicated.any_changed({ PHASE, COUNTDOWN_ENDS, AWAITING, WINNERS } :: { any }, listener)
end

-- Each calls `listener` whenever that of `player`'s changes, until the returned function is called: whether they
-- have loaded, their start box, their start.
local function loaded_changed(player: Player, listener: () -> ()): () -> ()
	return LOADED.changed(player, listener)
end
local function box_changed(player: Player, listener: () -> ()): () -> ()
	return BOX.changed(player, listener)
end
local function start_changed(player: Player, listener: () -> ()): () -> ()
	return START.changed(player, listener)
end

-- The server's side.

-- Tells `listener` every phase the server sets, as it sets it, until the returned function is called. On a client, which
-- sets none, follow `changed` instead.
local function on_phase(listener: (Phase) -> ()): () -> ()
	return phase_set.subscribe(listener)
end

local function set_phase(value: Phase, ends: number?)
	-- a game only has winners once it has ended, so one started again (a map or mission loaded after it) has none
	if value ~= "ended" then
		WINNERS.set(nil)
		END_REASON.set(nil)
		ENDED_AT.set(nil)
	end
	COUNTDOWN_ENDS.set(ends)
	PHASE.set(value)
	phase_set.fire(value)
end

-- Ends the game with `teams` the winners, and `reason` a line on how, for everyone to see. The world goes on stepping,
-- for anyone who plays on after it, but nothing ends it again. It is for every way a game ends, against the scavengers
-- or each other.
local function set_ended(teams: { number }, reason: string?)
	WINNERS.set(table.clone(teams))
	END_REASON.set(reason)
	ENDED_AT.set(Workspace:GetServerTimeNow())
	set_phase("ended", nil)
end

local function set_loaded(player: Player)
	LOADED.set(player, true)
end

local function set_start(player: Player, position: Vector3?)
	START.set(player, position)
end

local function set_box(player: Player, index: number?)
	BOX.set(player, index)
end

local function set_awaiting(names: { string })
	AWAITING.set(if #names > 0 then names else nil)
end

local function set_sim_rate(rate: number)
	SIM_RATE.set(rate)
end

return table.freeze({
	phase = phase,
	is_playing = is_playing,
	has_begun = has_begun,
	countdown_ends = countdown_ends,
	sim_rate = sim_rate,
	is_loaded = is_loaded,
	start_of = start_of,
	box_of = box_of,
	awaiting = awaiting,
	winners = winners,
	end_reason = end_reason,
	ended_at = ended_at,
	changed = changed,
	loaded_changed = loaded_changed,
	box_changed = box_changed,
	start_changed = start_changed,
	on_phase = on_phase,
	set_phase = set_phase,
	set_ended = set_ended,
	set_loaded = set_loaded,
	set_start = set_start,
	set_box = set_box,
	set_awaiting = set_awaiting,
	set_sim_rate = set_sim_rate,
})
