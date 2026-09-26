-- Starts pow, the in-game command bar (press ; to open it), with this game's commands (see
-- server_shared/pow_setup.luau): debugging and administration only.

local ReplicatedStorage = game:GetService "ReplicatedStorage"
local ServerScriptService = game:GetService "ServerScriptService"

local pow_setup = require(ServerScriptService.ServerShared.pow_setup)

local commands = ServerScriptService.Server.pow_commands

pow_setup.start(ServerScriptService.Server.pow, {
	shared = { ServerScriptService.Server.pow_shared_ext },
	server = {
		commands.players,
		commands.switches,
		commands.maps,
		commands.teams,
		commands.ai,
		commands.scavengers,
		commands.campaign,
		commands.status,
		commands.donuts,
	},
	client = { ReplicatedStorage.Client.pow_client_ext },
})
