-- What covers the screen while the game is paused (see server/pause.luau): the whole screen dimmed, with PAUSED across
-- the middle. It only dims: clicks go through to the world, so what is on the field can still be selected and looked at.

local ReplicatedStorage = game:GetService "ReplicatedStorage"
local Workspace = game:GetService "Workspace"

local React = require(ReplicatedStorage.Packages.react)

-- The server's pause attribute on Workspace, kept live.
local function use_paused(): boolean
	local paused, set_paused = React.useState(Workspace:GetAttribute "paused" == true)
	React.useEffect(function()
		local connection = Workspace:GetAttributeChangedSignal("paused"):Connect(function()
			set_paused(Workspace:GetAttribute "paused" == true)
		end)
		return function()
			connection:Disconnect()
		end
	end, {})
	return paused
end

local function PauseOverlay()
	if use_paused() == false then
		return nil
	end
	return React.createElement("Frame", {
		[React.Tag] = "pause-overlay",
	}, {
		Plate = React.createElement("Frame", {
			[React.Tag] = "pause-plate",
		}, {
			Title = React.createElement("TextLabel", {
				[React.Tag] = "pause-title",
				LayoutOrder = 1,
				Text = "PAUSED",
			}),
		}),
	})
end

return table.freeze({
	PauseOverlay = PauseOverlay,
})
