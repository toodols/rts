-- Resolution scaling for the HUD.
--
-- Roblox sizes GUIs in raw pixels, so a panel authored at 1080p is half the apparent size on a 4K
-- monitor and overflows a small window. `TextScaled` only fits text to its own label and cannot
-- keep a layout coherent, so instead every panel carries a UIScale driven by viewport height.
-- Scaling the whole panel keeps type, padding, bar heights and outlines in proportion.
--
-- UIScale scales about the panel's AnchorPoint, which is why this is applied per panel rather than
-- to one root frame: a panel pinned to the bottom right stays pinned as it grows.

local ReplicatedStorage = game:GetService "ReplicatedStorage"
local Workspace = game:GetService "Workspace"

local React = require(ReplicatedStorage.Packages.react)

-- The height the stylesheet's pixel values were authored against.
local DESIGN_HEIGHT = 1080
-- Below the floor the HUD would stop being readable; above the ceiling it starts eating the screen.
local MIN_SCALE = 0.8
local MAX_SCALE = 1.7

local function scale_for(viewport: Vector2): number
	if viewport.Y <= 0 then
		return 1
	end
	return math.clamp(viewport.Y / DESIGN_HEIGHT, MIN_SCALE, MAX_SCALE)
end

local function current_scale(): number
	local camera = Workspace.CurrentCamera
	if camera == nil then
		return 1
	end
	return scale_for(camera.ViewportSize)
end

local function use_ui_scale(): number
	local scale, set_scale = React.useState(current_scale)

	React.useEffect(function()
		local camera = Workspace.CurrentCamera
		if camera == nil then
			return
		end
		local connection = camera:GetPropertyChangedSignal("ViewportSize"):Connect(function()
			set_scale(scale_for(camera.ViewportSize))
		end)
		-- the viewport can settle a frame after mount, so resample once on the way in
		set_scale(scale_for(camera.ViewportSize))
		return function()
			connection:Disconnect()
		end
	end, {})

	return scale
end

return table.freeze({
	use_ui_scale = use_ui_scale,
	scale_for = scale_for,
})
