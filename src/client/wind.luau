--!strict
-- The wind as the client draws it: the one the server sends (shared/environment.luau's, see server/wind.luau),
-- eased toward rather than jumped to, closing most of the gap in a couple of EASE_SECONDS. The rain and the grass
-- (atmospherics.luau) and the wind readout (ui/wind_block.luau) all show this one, so they always agree.

local ReplicatedStorage = game:GetService "ReplicatedStorage"
local RunService = game:GetService "RunService"

local environment = require(ReplicatedStorage.Shared.environment)

local EASE_SECONDS = 1

local eased = Vector3.zero

-- The wind the server sends, as it lies over the ground, in studs a second.
local function sent(): Vector3
	local wind = environment.wind()
	return Vector3.new(wind.X, 0, wind.Y)
end

-- The wind as it is drawn now, over the ground (y is always 0), in studs a second.
local function now(): Vector3
	return eased
end

local function init()
	-- starting where the wind is, rather than swinging up to it from a calm
	eased = sent()
	RunService.Heartbeat:Connect(function(delta: number)
		eased = eased:Lerp(sent(), 1 - math.exp(-delta / EASE_SECONDS))
	end)
end

return table.freeze({
	init = init,
	now = now,
})
