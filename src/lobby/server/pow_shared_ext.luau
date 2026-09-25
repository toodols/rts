-- The lobby's pow types, which the command bar on the client needs as much as the server does. pow copies this module
-- into ReplicatedStorage and runs it on both sides.
--
-- pow calls its extension modules to let them register types and commands, so this one returns a function rather
-- than the dictionary RULES.md asks of every other module.

local ReplicatedStorage = game:GetService "ReplicatedStorage"

local campaign = require(ReplicatedStorage.Shared.campaign)
local pow_types = require(ReplicatedStorage.Shared.pow_types)
local skins = require(ReplicatedStorage.Shared.skins)

return function(extras: { types: { [string]: any }, commands: { [string]: any } })
	local mission_ids: { string } = {}
	for _, mission in campaign.MISSIONS do
		table.insert(mission_ids, mission.id)
	end

	-- One of shared/skins' skins, by name.
	extras.types.skin = pow_types.named("skin", "A skin, by name", skins.names())
	-- One of the campaign's missions, by id.
	extras.types.mission = pow_types.named("mission", "A campaign mission, by id", mission_ids)
end
