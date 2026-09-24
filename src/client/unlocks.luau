-- What the local player has unlocked through the campaign (Shared.campaign), as the server publishes it on their
-- Player. Anything locked is shown as locked in the build menu, and nothing on the client starts placing or queuing
-- it; the server refuses it anyway.

local Players = game:GetService "Players"
local ReplicatedStorage = game:GetService "ReplicatedStorage"

local campaign = require(ReplicatedStorage.Shared.campaign)

-- Whether the local player may build `def_name`.
local function is_unlocked(def_name: string): boolean
	return campaign.is_unlocked(campaign.unlocks_of(Players.LocalPlayer), def_name)
end

-- Calls `listener` whenever what the local player has unlocked changes. Returns a function that stops it.
local function subscribe(listener: () -> ()): () -> ()
	local connection = Players.LocalPlayer:GetAttributeChangedSignal(campaign.UNLOCKS_ATTRIBUTE):Connect(listener)
	return function()
		connection:Disconnect()
	end
end

return table.freeze({
	is_unlocked = is_unlocked,
	subscribe = subscribe,
})
