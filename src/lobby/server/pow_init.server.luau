-- Starts pow, the command bar (press ; to open it), in the lobby. Debugging and administration only; the game place
-- starts its own (server/pow_init.server.luau), with the same permissions.

local ServerScriptService = game:GetService "ServerScriptService"

local pow = require(ServerScriptService.LobbyServer.pow)

pow.init({
	permissions = {
		-- -1 is the local player in Studio
		owner = {
			["-1"] = 5,
			["195294332"] = 5,
		},
	},
	disable_data_store = true,
	extras_shared = { ServerScriptService.LobbyServer.pow_shared_ext },
	extras_server = { ServerScriptService.LobbyServer.pow_server_ext },
})
