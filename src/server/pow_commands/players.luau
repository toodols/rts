-- The pow commands every place has (server_shared/pow_common.luau), with what only a game knows of a player: their
-- team, and which teams wear each skin.
--
-- pow calls its extension modules to let them register commands, so this one returns a function rather than the
-- dictionary RULES.md asks of every other module.

local ReplicatedStorage = game:GetService "ReplicatedStorage"
local ServerScriptService = game:GetService "ServerScriptService"

local pow_types = require(ReplicatedStorage.Shared.pow_types)

local pow_common = require(ServerScriptService.ServerShared.pow_common)
local pow_builders = require(ServerScriptService.ServerShared.pow_builders)

local players = require(ServerScriptService.Server.players)
local state = require(ServerScriptService.Server.state)

local team_readout = require(script.Parent.team_readout)

local GAME: pow_common.Place = table.freeze({
	player_lines = function(player: Player): { string }
		local team_id = players.team_of(player)
		return (if team_id ~= nil then team_readout.full(team_id) else nil) or { "  not on a team" }
	end,
	skin_note = function(name: string): string?
		local wearing: { string } = {}
		for id, team in state.all_teams() do
			if team.skin == name then
				table.insert(wearing, tostring(id))
			end
		end
		table.sort(wearing)
		return `teams: {pow_builders.list_or(wearing, "none")}`
	end,
})

return function(extras: pow_types.Extras)
	local commands = extras.commands

	pow_common.register(commands, GAME)
end
