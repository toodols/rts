--!strict
-- What the lobby server and its clients say to each other.
--
-- A client asks for everything through the `LobbyRequest` remote function, as `(action, argument)`, and is answered
-- `(ok, message)`: see ACTIONS, which says what argument each action takes, and `read`, which the server hears a
-- request by. The server pushes a `State` down `LobbyState` whenever something the player can see
-- changes: the lobbies they may join, the one they are in, and the campaign mission they are being sent to.
--
-- A player's campaign progress is not in the state: the lobby server publishes it on their Player, as attributes, the
-- way the game server does (see shared/campaign_progress.luau).

local ReplicatedStorage = game:GetService "ReplicatedStorage"

local game_modes = require(ReplicatedStorage.Shared.game_modes)
local decode = require(ReplicatedStorage.Shared.decode)

type Match = game_modes.Match

-- Who may see and join a lobby: anyone, or only its host's friends.
export type Visibility = "public" | "friends"

-- The levels (campaign.level) a lobby's host may let in, from LEVEL_MIN to LEVEL_MAX in steps of LEVEL_STEP.
local LEVEL_MIN = 0
local LEVEL_MAX = 100
local LEVEL_STEP = 10

-- A lobby as the browser lists it.
export type Summary = {
	-- what the browser asks to join it by
	key: string,
	lobby_id: string,
	-- the server it is on
	job_id: string,
	host: number,
	host_name: string,
	mode: string,
	preset: string,
	-- players, not counting spectators
	players: number,
	capacity: number,
	spectators: number,
	visibility: Visibility,
	-- the levels it lets in (see LEVEL_MIN)
	level_min: number,
	level_max: number,
}

-- The lobby a player is in, as they see it.
export type LobbyView = {
	id: string,
	host: number,
	visibility: Visibility,
	-- the levels it lets in (see LEVEL_MIN)
	level_min: number,
	level_max: number,
	-- each player's level, by user id as a string
	levels: { [string]: number },
	-- the game it will start: its mode, map, seats and the rest
	match: Match,
	-- the user ids of the players who have said they are ready to start
	ready: { number },
	starting: boolean,
	-- everyone has been sent to the game and the lobby is only waiting for them to go
	teleporting: boolean,
	-- why it cannot start yet, if it cannot
	blocked: string?,
}

-- The campaign mission this player asked to play, while it is being started, and after it could not be.
export type MissionView = {
	-- an id from campaign.MISSIONS
	id: string,
	-- "starting" while a server is reserved, "teleporting" once they are on their way, "failed" if they could not be
	stage: "starting" | "teleporting" | "failed",
	-- why it failed
	reason: string?,
}

export type State = {
	lobbies: { Summary },
	current: LobbyView?,
	mission: MissionView?,
	-- something to tell the player that is not an answer to a request of theirs, like a failed start
	notice: string?,
}

-- Every action a client may ask for.
export type Action =
	"refresh"
	| "create"
	| "join"
	| "leave"
	| "set_map"
	| "set_mode"
	| "set_visibility"
	| "set_level_range"
	| "set_bonus"
	| "set_ready"
	| "set_ally_griefing"
	| "set_end_mode"
	| "move"
	| "start"
	| "play_mission"
	| "create_mission"
	| "equip_skin"

-- Every action, and what its argument is, as the server reads it (shared/decode.luau).
local ACTIONS: { [Action]: decode.Decoder<any> } = table.freeze({
	-- no argument: only asks for the state to be sent, as a client does when it starts
	refresh = decode.none,
	-- no argument
	create = decode.none,
	-- a Summary's key
	join = decode.text,
	-- no argument
	leave = decode.none,
	-- a map preset's name
	set_map = decode.text,
	-- a game mode's id
	set_mode = decode.text,
	-- a Visibility
	set_visibility = decode.text,
	-- `{ min = number, max = number }`: the levels it lets in. Refused if it would leave out anyone in it.
	set_level_range = decode.record({ min = decode.number, max = decode.number }),
	-- `{ user_id = number, percent = number }`: that player's resource bonus, from game_modes.BONUS_MIN to BONUS_MAX.
	-- Only a developer's is heard (shared/developers.luau).
	set_bonus = decode.record({ user_id = decode.number, percent = decode.number }),
	-- a boolean: whether this player is ready to start
	set_ready = decode.boolean,
	-- a boolean: whether allies' weapons hurt each other's things
	set_ally_griefing = decode.boolean,
	-- an end mode's id, from game_modes.END_MODES: how a team game or a free for all is won
	set_end_mode = decode.text,
	-- a side, from 1, or game_modes.SPECTATOR_SIDE to watch; outside a team game any side takes whichever seat is free
	move = decode.integer,
	-- no argument
	start = decode.none,
	-- a campaign mission's key (campaign.key: its id, or its hard mode's): plays it, alone, on a game server of its own.
	-- Not while in a lobby.
	play_mission = decode.text,
	-- a campaign mission's key, for one that may be played together (its `coop`): makes a lobby that plays it, whose
	-- mode and map are the mission's and cannot be changed. Not while in a lobby.
	create_mission = decode.text,
	-- a skin's name (shared/skins): equips it, for every game this player plays from now on. Only a developer may equip
	-- a developer's skin. The skin they have equipped is published on them (skins.equipped_by).
	equip_skin = decode.text,
} :: { [Action]: decode.Decoder<any> })

-- `action` as the action it names and `argument` as it takes it, if it is one and `argument` is what it takes; nil
-- for anything else a client sends.
local function read(action: unknown, argument: unknown): (Action?, any)
	if typeof(action) ~= "string" then
		return nil, nil
	end
	local takes = ACTIONS[action :: Action]
	if takes == nil then
		return nil, nil
	end
	local ok, value = takes(argument)
	if ok == false then
		return nil, nil
	end
	return action :: Action, value
end

return table.freeze({
	LEVEL_MIN = LEVEL_MIN,
	LEVEL_MAX = LEVEL_MAX,
	LEVEL_STEP = LEVEL_STEP,
	ACTIONS = ACTIONS,
	read = read,
})
