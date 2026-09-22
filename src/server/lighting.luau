-- Scene lighting. Set on the server so it replicates to every client.
--
-- The fog is doing real work, not just mood: render distance collapses on low graphics quality and
-- the far edge of the terrain culls visibly. Fading the distance out to the horizon colour means
-- the cut lands inside the fade instead of as a hard edge against the sky.

local Lighting = game:GetService "Lighting"
local ReplicatedStorage = game:GetService "ReplicatedStorage"

local config = require(ReplicatedStorage.Shared.config)

local HORIZON = Color3.fromRGB(108, 124, 142)

local function init()
	Lighting.Ambient = Color3.fromRGB(88, 96, 110)
	Lighting.OutdoorAmbient = Color3.fromRGB(104, 114, 130)
	Lighting.Brightness = 2
	Lighting.ClockTime = 15.5
	Lighting.GeographicLatitude = 20
	Lighting.ExposureCompensation = -0.1

	-- Start the fade a little inside the map's half width and finish it past the far corner, so the
	-- whole map is legible from a zoomed-out camera while the edge still dissolves.
	local half_width = config.MAP_CELLS_X * config.CELL_STUDS / 2
	Lighting.FogColor = HORIZON
	Lighting.FogStart = half_width * 0.9
	Lighting.FogEnd = half_width * 3.1

	local atmosphere = Lighting:FindFirstChildOfClass "Atmosphere"
	if atmosphere == nil then
		atmosphere = Instance.new "Atmosphere"
		atmosphere.Parent = Lighting
	end
	atmosphere.Density = 0.32
	atmosphere.Haze = 1.4
	atmosphere.Glare = 0.15
	atmosphere.Color = HORIZON
	atmosphere.Decay = Color3.fromRGB(84, 96, 112)
end

return table.freeze({
	init = init,
})
