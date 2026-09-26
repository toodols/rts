-- Scene lighting the map's atmosphere does not cover (see shared/atmosphere.luau, which each client lights its view by).
-- Set on the server so it replicates to every client.
--
-- The fog is doing real work, not just mood: render distance collapses on low graphics quality and
-- the far edge of the terrain culls visibly. Fading the distance out to the horizon colour means
-- the cut lands inside the fade instead of as a hard edge against the sky.

local Lighting = game:GetService "Lighting"
local ReplicatedStorage = game:GetService "ReplicatedStorage"

local heightmap = require(ReplicatedStorage.Shared.heightmap)
local atmosphere = require(ReplicatedStorage.Shared.atmosphere)

-- Start the fade a little inside the map's half width and finish it past the far corner, so the whole map is legible
-- from a zoomed-out camera while the edge still dissolves. Called again whenever the map is replaced, since maps are
-- not all the same size.
local function fit_fog()
	local half_x, half_z = heightmap.half_extents()
	local half_width = math.max(half_x, half_z)
	Lighting.FogStart = half_width * 0.9
	Lighting.FogEnd = half_width * 3.1
end

-- The fog in the horizon's colour, and the haze a client dresses by the atmosphere, which it needs to be there.
local function init()
	Lighting.FogColor = atmosphere.DEFAULT.haze_color :: Color3
	fit_fog()
	if Lighting:FindFirstChildOfClass "Atmosphere" == nil then
		Instance.new("Atmosphere").Parent = Lighting
	end
end

return table.freeze({
	init = init,
	fit_fog = fit_fog,
})
