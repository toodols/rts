-- What the lobby server says this player can see, as a hook, and the one way to ask it for anything.

local ReplicatedStorage = game:GetService "ReplicatedStorage"

local React = require(ReplicatedStorage.Packages.react)

local protocol = require(ReplicatedStorage.Lobby.protocol)

type State = protocol.State

local lobby_request: RemoteFunction = ReplicatedStorage.Lobby.LobbyRequest
local lobby_state: RemoteEvent = ReplicatedStorage.Lobby.LobbyState

local EMPTY: State = { lobbies = {}, current = nil, notice = nil }

-- Asks the server to `action` (see protocol.ACTIONS) and returns its answer: whether it did, and why not if not.
local function request(action: string, argument: any?): (boolean, string?)
	local ok, done, message = pcall(function()
		return lobby_request:InvokeServer(action, argument)
	end)
	if ok == false then
		return false, "The lobby server didn't answer"
	end
	return done == true, if typeof(message) == "string" then message else nil
end

-- The state as the server last sent it, and whether any has come yet.
local function use_state(): (State, boolean)
	local state, set_state = React.useState(EMPTY)
	local received, set_received = React.useState(false)

	React.useEffect(function()
		local connection = lobby_state.OnClientEvent:Connect(function(next_state: State)
			set_state(next_state)
			set_received(true)
		end)
		task.spawn(request, protocol.ACTIONS.refresh)
		return function()
			connection:Disconnect()
		end
	end, {})

	return state, received
end

return table.freeze({
	request = request,
	use_state = use_state,
})
