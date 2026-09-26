--!strict
-- Starts pow, the command bar (press ; to open it), in the lobby, with the lobby's commands (see
-- server_shared/pow_setup.luau): debugging and administration only.

local ServerScriptService = game:GetService "ServerScriptService"

local pow_setup = require(ServerScriptService.ServerShared.pow_setup)

pow_setup.start(ServerScriptService.LobbyServer.pow, {
	shared = { ServerScriptService.LobbyServer.pow_shared_ext },
	server = { ServerScriptService.LobbyServer.pow_server_ext },
})
