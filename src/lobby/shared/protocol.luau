-- What the lobby server and its clients say to each other.
--
-- A client asks for everything through the `LobbyRequest` remote function, as `(action, argument)`, and is answered
-- `(ok, message)`: see ACTIONS. The server pushes a `State` down `LobbyState` whenever something the player can see
-- changes: the lobbies they may join, the one they are in, and the campaign mission they are being sent to.
--
-- A player's campaign progress is not in the state: the lobby server publishes it on their Player, as attributes, the
-- way the game server does. What they have unlocked is campaign.UNLOCKS_ATTRIBUTE, and the missions they have finished
-- are COMPLETED_ATTRIBUTE, their ids, sorted, comma separated.

local ReplicatedStorage = game:GetService "ReplicatedStorage"

local campaign = require(ReplicatedStorage.Shared.campaign)

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
	visibility: string,
}

export type SeatView = {
	user_id: number,
	name: string,
	side: number,
}

-- The lobby a player is in, as they see it.
export type LobbyView = {
	id: string,
	host: number,
	mode: string,
	preset: string,
	seed: number,
	visibility: string,
	-- each player's resource bonus in percent, by user id as a string; a player with none is left out
	bonuses: { [string]: number },
	-- whether allies' weapons hurt each other's things
	ally_griefing: boolean,
	seats: { SeatView },
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

-- Every action a client may ask for, and what its argument is.
local ACTIONS = table.freeze({
	-- no argument: only asks for the state to be sent, as a client does when it starts
	refresh = "refresh",
	-- no argument
	create = "create",
	-- a Summary's key
	join = "join",
	-- no argument
	leave = "leave",
	-- a map preset's name
	set_map = "set_map",
	-- a game mode's id
	set_mode = "set_mode",
	-- "public" or "friends"
	set_visibility = "set_visibility",
	-- `{ user_id = number, percent = number }`: that player's resource bonus, from game_modes.BONUS_MIN to BONUS_MAX.
	-- Only a developer's is heard (shared/developers.luau).
	set_bonus = "set_bonus",
	-- a boolean: whether this player is ready to start
	set_ready = "set_ready",
	-- a boolean: whether allies' weapons hurt each other's things
	set_ally_griefing = "set_ally_griefing",
	-- a side, from 1, or game_modes.SPECTATOR_SIDE to watch; outside a team game any side takes whichever seat is free
	move = "move",
	-- no argument
	start = "start",
	-- a campaign mission's id: plays it, alone, on a game server of its own. Not while in a lobby.
	play_mission = "play_mission",
	-- a campaign mission's id, for one that may be played together (its `coop`): makes a lobby that plays it, whose
	-- mode and map are the mission's and cannot be changed. Not while in a lobby.
	create_mission = "create_mission",
	-- a skin's name (shared/skins): equips it, for every game this player plays from now on. Only a developer may equip
	-- a developer's skin. The skin they have equipped is published on them as the `skin` attribute.
	equip_skin = "equip_skin",
})

-- The Player attribute the missions a player has finished are published in.
local COMPLETED_ATTRIBUTE = "campaign_completed"

-- `completed` as COMPLETED_ATTRIBUTE carries it.
local function encode_completed(completed: { [string]: boolean }): string
	local ids: { string } = {}
	for id, done in completed do
		if done then
			table.insert(ids, id)
		end
	end
	table.sort(ids)
	return table.concat(ids, ",")
end

-- The missions COMPLETED_ATTRIBUTE says `player` has finished; none until the server has published any.
local function completed_of(player: Player): { [string]: boolean }
	local set: { [string]: boolean } = {}
	local value = player:GetAttribute(COMPLETED_ATTRIBUTE)
	if typeof(value) ~= "string" then
		return set
	end
	for _, id in string.split(value, ",") do
		if id ~= "" then
			set[id] = true
		end
	end
	return set
end

-- Whether the mission `mission_id` may be played by someone who has finished `completed`: the missions are played in
-- order, so every one before it has to be finished. Any mission already finished may be played again.
local function is_mission_open(completed: { [string]: boolean }, mission_id: string): boolean
	for _, mission in campaign.MISSIONS do
		if mission.id == mission_id then
			return true
		end
		if completed[mission.id] ~= true then
			return false
		end
	end
	return false
end

return table.freeze({
	ACTIONS = ACTIONS,
	COMPLETED_ATTRIBUTE = COMPLETED_ATTRIBUTE,
	encode_completed = encode_completed,
	completed_of = completed_of,
	is_mission_open = is_mission_open,
})
