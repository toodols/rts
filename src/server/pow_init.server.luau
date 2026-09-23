-- Starts pow, the in-game command bar (press ; to open it). Debugging and administration only.

local ServerScriptService = game:GetService "ServerScriptService"

local pow = require(ServerScriptService.Server.pow)

pow.init({
	permissions = {
		-- -1 is the local player in Studio
		owner = {
			["-1"] = 5,
			["195294332"] = 5,
		},
	},
	disable_data_store = true,
	extras_shared = { ServerScriptService.Server.pow_shared_ext },
	extras_server = { ServerScriptService.Server.pow_server_ext },
})
