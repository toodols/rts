-- This player's campaign progress as the lobby server published it on them, as a hook that follows it as it changes:
-- what they have unlocked (campaign.UNLOCKS_ATTRIBUTE) and the missions they have finished
-- (protocol.COMPLETED_ATTRIBUTE).

local Players = game:GetService "Players"
local ReplicatedStorage = game:GetService "ReplicatedStorage"

local React = require(ReplicatedStorage.Packages.react)

local campaign = require(ReplicatedStorage.Shared.campaign)

local protocol = require(ReplicatedStorage.Lobby.protocol)

export type Campaign = {
	unlocks: { [string]: boolean },
	completed: { [string]: boolean },
}

local player = Players.LocalPlayer

local function read(): Campaign
	return {
		unlocks = campaign.unlocks_of(player),
		completed = protocol.completed_of(player),
	}
end

local function use_campaign(): Campaign
	local state, set_state = React.useState(read)

	React.useEffect(function()
		local function update()
			set_state(read())
		end
		local unlocks = player:GetAttributeChangedSignal(campaign.UNLOCKS_ATTRIBUTE):Connect(update)
		local completed = player:GetAttributeChangedSignal(protocol.COMPLETED_ATTRIBUTE):Connect(update)
		-- it may have been published between the first render and now
		update()
		return function()
			unlocks:Disconnect()
			completed:Disconnect()
		end
	end, {})

	return state
end

return table.freeze({
	use_campaign = use_campaign,
})
