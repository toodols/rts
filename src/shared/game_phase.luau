-- Where the game is in getting started, as both sides see it. It opens `waiting`: nothing moves while every player
-- loads in and chooses where to start. Once all of them have, it counts down for `config.START_COUNTDOWN_SECONDS` and
-- then it is `playing`, which it stays. Someone arriving, or giving up their start, during the countdown sends it back
-- to waiting (see server/lobby.luau).
--
-- The server sets it all and it reaches the clients as attributes: the phase, and when the countdown ends, on
-- Workspace, and whether each player has loaded and the start they chose on the player.

local Workspace = game:GetService "Workspace"

export type Phase = "waiting" | "countdown" | "playing"

local PHASE_ATTRIBUTE = "phase"
local COUNTDOWN_ENDS_ATTRIBUTE = "countdown_ends"
local LOADED_ATTRIBUTE = "loaded"
local START_ATTRIBUTE = "start_slot"

-- Before the server says otherwise the game is waiting.
local function phase(): Phase
	local value = Workspace:GetAttribute(PHASE_ATTRIBUTE)
	if value == "countdown" or value == "playing" then
		return value
	end
	return "waiting"
end

local function is_playing(): boolean
	return phase() == "playing"
end

-- When the countdown ends, in `Workspace:GetServerTimeNow()`'s seconds, while there is one.
local function countdown_ends(): number?
	local value = Workspace:GetAttribute(COUNTDOWN_ENDS_ATTRIBUTE)
	return if typeof(value) == "number" then value else nil
end

local function is_loaded(player: Player): boolean
	return player:GetAttribute(LOADED_ATTRIBUTE) == true
end

-- The start `player` chose, by slot, or nil if they have not.
local function start_of(player: Player): number?
	local value = player:GetAttribute(START_ATTRIBUTE)
	return if typeof(value) == "number" then value else nil
end

-- Fires whenever the phase, or when the countdown ends, changes.
local function changed(callback: () -> ()): { RBXScriptConnection }
	return {
		Workspace:GetAttributeChangedSignal(PHASE_ATTRIBUTE):Connect(callback),
		Workspace:GetAttributeChangedSignal(COUNTDOWN_ENDS_ATTRIBUTE):Connect(callback),
	}
end

-- The server's side.

local function set_phase(value: Phase, ends: number?)
	Workspace:SetAttribute(COUNTDOWN_ENDS_ATTRIBUTE, ends)
	Workspace:SetAttribute(PHASE_ATTRIBUTE, value)
end

local function set_loaded(player: Player)
	player:SetAttribute(LOADED_ATTRIBUTE, true)
end

local function set_start(player: Player, slot: number?)
	player:SetAttribute(START_ATTRIBUTE, slot)
end

return table.freeze({
	LOADED_ATTRIBUTE = LOADED_ATTRIBUTE,
	START_ATTRIBUTE = START_ATTRIBUTE,
	phase = phase,
	is_playing = is_playing,
	countdown_ends = countdown_ends,
	is_loaded = is_loaded,
	start_of = start_of,
	changed = changed,
	set_phase = set_phase,
	set_loaded = set_loaded,
	set_start = set_start,
})
