-- The campaign mission this game is, if it is one (Shared.campaign): the server says so with an attribute on
-- Workspace, and the HUD puts itself in that mission's state.

local ReplicatedStorage = game:GetService "ReplicatedStorage"
local Workspace = game:GetService "Workspace"

local campaign = require(ReplicatedStorage.Shared.campaign)

local function current(): string?
	return campaign.current_mission()
end

-- Whether this game is the tutorial, whose HUD is pared down to what it teaches.
local function is_tutorial(): boolean
	return campaign.current_mission() == "tutorial"
end

-- Calls `listener` with the mission whenever it changes. Returns a function that stops it.
local function subscribe(listener: (mission: string?) -> ()): () -> ()
	local connection = Workspace:GetAttributeChangedSignal(campaign.MISSION_ATTRIBUTE):Connect(function()
		listener(campaign.current_mission())
	end)
	return function()
		connection:Disconnect()
	end
end

return table.freeze({
	current = current,
	is_tutorial = is_tutorial,
	subscribe = subscribe,
})
