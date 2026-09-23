-- What the lobby server and its clients say to each other.
--
-- A client asks for everything through the `LobbyRequest` remote function, as `(action, argument)`, and is answered
-- `(ok, message)`: see ACTIONS. The server pushes a `State` down `LobbyState` whenever something the player can see
-- changes: the lobbies they may join, and the one they are in.

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
	players: number,
	capacity: number,
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
	seats: { SeatView },
	starting: boolean,
	-- why it cannot start yet, if it cannot
	blocked: string?,
}

export type State = {
	lobbies: { Summary },
	current: LobbyView?,
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
	-- a side, from 1
	move = "move",
	-- no argument
	start = "start",
})

return table.freeze({
	ACTIONS = ACTIONS,
})
