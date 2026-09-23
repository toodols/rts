-- The drag rectangle drawn while box-selecting. `input` owns the rectangle; this only draws it.

local GuiService = game:GetService "GuiService"
local ReplicatedStorage = game:GetService "ReplicatedStorage"

local React = require(ReplicatedStorage.Packages.react)

local input = require(ReplicatedStorage.Client.input)
local build_mode = require(ReplicatedStorage.Client.build_mode)
local use_viewport = require(ReplicatedStorage.Client.ui.use_viewport)

type Rect = {
	min: Vector2,
	max: Vector2,
}

local function SelectionBox()
	local rect, set_rect = React.useState(nil :: Rect?)

	React.useEffect(function()
		return input.subscribe_rect(function(next_rect: Rect?)
			set_rect(next_rect)
		end)
	end, {})

	if rect == nil then
		return nil
	end

	-- These are two different spaces and they are one topbar apart.
	--
	-- The rectangle is in viewport space: that is what UserInputService:GetMouseLocation returns,
	-- and it is the space Camera:ViewportPointToRay and Camera:WorldToViewportPoint work in, which
	-- is why picking and box-selecting land on the right units. The HUD's ScreenGui leaves
	-- IgnoreGuiInset false so its panels dodge the Roblox topbar, which puts its origin a GUI inset
	-- below the top of the viewport. Drawing viewport coordinates there without taking the inset
	-- back off is what leaves the box sitting below the cursor.
	local inset = GuiService:GetGuiInset()
	local size = rect.max - rect.min
	return React.createElement("Frame", {
		[React.Tag] = "selection-box",
		Position = UDim2.fromOffset(rect.min.X - inset.X, rect.min.Y - inset.Y),
		Size = UDim2.fromOffset(size.X, size.Y),
	})
end

local MODE_HINTS: { [string]: string } = {
	attack = "In attacking (A) mode · click an enemy to attack it, or the ground to attack that spot, or drag out a circle to attack everything of the enemy's inside it · shift keeps the mode · right click cancels",
	reclaim = "In reclaiming (E) mode · click something to reclaim it, or drag out a circle to reclaim everything inside it · shift keeps the mode · right click cancels",
	repair = "In repairing (R) mode · click a damaged friendly to repair it, or drag out a circle to repair everything damaged inside it · shift keeps the mode · right click cancels",
	resurrect = "In resurrecting (W) mode · click a wreck to raise it, after refilling its metal, or drag out a circle to resurrect every wreck inside it · shift keeps the mode · right click cancels",
	fight = "In fighting (F) mode · click the ground to walk there, stopping to shoot whatever is in reach on the way, and builders to help build, repair or reclaim what is in reach, or drag to spread them along what you trace · shift keeps the mode and adds another waypoint · right click cancels",
	load = "In loading (J) mode · click a friendly unit to have the selected transports pick it up · shift keeps the mode · right click cancels",
	unload = "In unloading (U) mode · click the ground to set everything aboard down there, or drag to spread the transports along what you trace · shift keeps the mode · right click cancels",
	guard = "In guarding (O) mode · click a friendly unit or building to follow and defend it, assisting what it builds or reclaims · shift keeps the mode · right click cancels",
	disintegrator = "In disintegrator (D) mode · click to have the commander close in and fire at that spot · shift queues the shot and keeps aiming · right click cancels",
}

-- Says which mode the cursor is in while a reclaim, repair or disintegrator mode is on, so that it is
-- always plain that the next click will do something other than select.
local function ModeHint()
	local mode, set_mode = React.useState(nil :: string?)
	local ui_scale = use_viewport.use_ui_scale()

	React.useEffect(function()
		return input.subscribe_mode(function(next_mode: string?)
			set_mode(next_mode)
		end)
	end, {})

	local text = if mode ~= nil then MODE_HINTS[mode] else nil
	if mode == nil or text == nil then
		return nil
	end

	return React.createElement("TextLabel", {
		-- the mode is a tag too, so each can have its own colour
		[React.Tag] = `placement-hint mode-hint {mode}`,
		Text = text,
	}, {
		Scale = React.createElement("UIScale", { Scale = ui_scale }),
	})
end

local function PlacementHint()
	local placing, set_placing = React.useState(build_mode.active())
	local ui_scale = use_viewport.use_ui_scale()

	React.useEffect(function()
		return build_mode.subscribe(function(def_name: string?)
			set_placing(def_name)
		end)
	end, {})

	if placing == nil then
		return nil
	end

	return React.createElement("TextLabel", {
		[React.Tag] = "placement-hint",
		Text = "[ ] rotate · right click cancels · hold shift to keep placing",
	}, {
		Scale = React.createElement("UIScale", { Scale = ui_scale }),
	})
end

return table.freeze({
	SelectionBox = SelectionBox,
	PlacementHint = PlacementHint,
	ModeHint = ModeHint,
})
