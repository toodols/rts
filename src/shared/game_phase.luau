-- Where the game is in getting started, as both sides see it. It opens `waiting`: nothing moves while every player
-- loads in and chooses where to start, somewhere in their team's start box (`starts`). Once all of them have, it counts
-- down for `config.START_COUNTDOWN_SECONDS` and then it is `playing`, until the game is won and it is `ended`, with the
-- teams that won, which it stays: in a game against the scavengers, when their boss falls. Someone arriving, or giving up their start, during the countdown sends it back
-- to waiting (see server/lobby.luau).
--
-- A game a lobby started also waits for everyone the lobby sent to arrive, or for them to be given up on (see
-- server/match.luau); until then the names of the ones still on their way are published too.
--
-- The server sets it all and it reaches the clients as attributes: the phase, when the countdown ends and who is still
-- on their way, on Workspace, and on each player whether they have loaded, the start box they are to choose within, and where in it
-- they chose.

local Workspace = game:GetService "Workspace"

export type Phase = "waiting" | "countdown" | "playing" | "ended"

local PHASE_ATTRIBUTE = "phase"
local COUNTDOWN_ENDS_ATTRIBUTE = "countdown_ends"
local LOADED_ATTRIBUTE = "loaded"
local BOX_ATTRIBUTE = "start_box"
local START_ATTRIBUTE = "start_position"
local AWAITING_ATTRIBUTE = "awaiting"
-- the teams that won, once it has ended, by id and between commas, and a line on how it was won
local WINNERS_ATTRIBUTE = "winners"
local END_REASON_ATTRIBUTE = "end_reason"
-- when it ended, in `Workspace:GetServerTimeNow()`'s seconds
local ENDED_AT_ATTRIBUTE = "ended_at"
-- between the names of the players still on their way, which no display name can contain
local AWAITING_SEPARATOR = "\n"

-- Before the server says otherwise the game is waiting.
local function phase(): Phase
	local value = Workspace:GetAttribute(PHASE_ATTRIBUTE)
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
	local value = Workspace:GetAttribute(WINNERS_ATTRIBUTE)
	local teams: { number } = {}
	if typeof(value) == "string" then
		for _, part in string.split(value, ",") do
			local team = tonumber(part)
			if team ~= nil then
				table.insert(teams, team)
			end
		end
	end
	return teams
end

-- How the game was won, once it has ended, if the server said.
local function end_reason(): string?
	local value = Workspace:GetAttribute(END_REASON_ATTRIBUTE)
	return if typeof(value) == "string" then value else nil
end

-- When the game ended, in `Workspace:GetServerTimeNow()`'s seconds, once it has.
local function ended_at(): number?
	local value = Workspace:GetAttribute(ENDED_AT_ATTRIBUTE)
	return if typeof(value) == "number" then value else nil
end

-- When the countdown ends, in `Workspace:GetServerTimeNow()`'s seconds, while there is one.
local function countdown_ends(): number?
	local value = Workspace:GetAttribute(COUNTDOWN_ENDS_ATTRIBUTE)
	return if typeof(value) == "number" then value else nil
end

local function is_loaded(player: Player): boolean
	return player:GetAttribute(LOADED_ATTRIBUTE) == true
end

-- Where `player` chose to start, on the ground, or nil if they have not.
local function start_of(player: Player): Vector3?
	local value = player:GetAttribute(START_ATTRIBUTE)
	return if typeof(value) == "Vector3" then value else nil
end

-- The start box `player`'s team starts in, or nil before they have been given one.
local function box_of(player: Player): number?
	local value = player:GetAttribute(BOX_ATTRIBUTE)
	return if typeof(value) == "number" then value else nil
end

-- The display names of the players a lobby sent here who have not arrived yet and are still being waited for.
local function awaiting(): { string }
	local value = Workspace:GetAttribute(AWAITING_ATTRIBUTE)
	if typeof(value) ~= "string" or value == "" then
		return {}
	end
	return string.split(value, AWAITING_SEPARATOR)
end

-- Fires whenever the phase, when the countdown ends, or who is still on their way changes.
local function changed(callback: () -> ()): { RBXScriptConnection }
	return {
		Workspace:GetAttributeChangedSignal(PHASE_ATTRIBUTE):Connect(callback),
		Workspace:GetAttributeChangedSignal(COUNTDOWN_ENDS_ATTRIBUTE):Connect(callback),
		Workspace:GetAttributeChangedSignal(AWAITING_ATTRIBUTE):Connect(callback),
		Workspace:GetAttributeChangedSignal(WINNERS_ATTRIBUTE):Connect(callback),
	}
end

-- The server's side.

local function set_phase(value: Phase, ends: number?)
	-- a game only has winners once it has ended, so one started again (a map or mission loaded after it) has none
	if value ~= "ended" then
		Workspace:SetAttribute(WINNERS_ATTRIBUTE, nil)
		Workspace:SetAttribute(END_REASON_ATTRIBUTE, nil)
		Workspace:SetAttribute(ENDED_AT_ATTRIBUTE, nil)
	end
	Workspace:SetAttribute(COUNTDOWN_ENDS_ATTRIBUTE, ends)
	Workspace:SetAttribute(PHASE_ATTRIBUTE, value)
end

-- Ends the game with `teams` the winners, and `reason` a line on how, for everyone to see. The world goes on stepping,
-- for anyone who plays on after it, but nothing ends it again. It is for every way a game ends, against the scavengers
-- or each other.
local function set_ended(teams: { number }, reason: string?)
	local ids = {}
	for _, team in teams do
		table.insert(ids, tostring(team))
	end
	Workspace:SetAttribute(WINNERS_ATTRIBUTE, table.concat(ids, ","))
	Workspace:SetAttribute(END_REASON_ATTRIBUTE, reason)
	Workspace:SetAttribute(ENDED_AT_ATTRIBUTE, Workspace:GetServerTimeNow())
	set_phase("ended", nil)
end

local function set_loaded(player: Player)
	player:SetAttribute(LOADED_ATTRIBUTE, true)
end

local function set_start(player: Player, position: Vector3?)
	player:SetAttribute(START_ATTRIBUTE, position)
end

local function set_box(player: Player, index: number?)
	player:SetAttribute(BOX_ATTRIBUTE, index)
end

local function set_awaiting(names: { string })
	local value: string? = if #names > 0 then table.concat(names, AWAITING_SEPARATOR) else nil
	if Workspace:GetAttribute(AWAITING_ATTRIBUTE) ~= value then
		Workspace:SetAttribute(AWAITING_ATTRIBUTE, value)
	end
end

return table.freeze({
	LOADED_ATTRIBUTE = LOADED_ATTRIBUTE,
	BOX_ATTRIBUTE = BOX_ATTRIBUTE,
	START_ATTRIBUTE = START_ATTRIBUTE,
	phase = phase,
	is_playing = is_playing,
	has_begun = has_begun,
	countdown_ends = countdown_ends,
	is_loaded = is_loaded,
	start_of = start_of,
	box_of = box_of,
	awaiting = awaiting,
	winners = winners,
	end_reason = end_reason,
	ended_at = ended_at,
	changed = changed,
	set_phase = set_phase,
	set_ended = set_ended,
	set_loaded = set_loaded,
	set_start = set_start,
	set_box = set_box,
	set_awaiting = set_awaiting,
})
