-- The drag rectangle drawn while box-selecting. `input` owns the rectangle; this only draws it.

local GuiService = game:GetService "GuiService"
local ReplicatedStorage = game:GetService "ReplicatedStorage"
local RunService = game:GetService "RunService"
local UserInputService = game:GetService "UserInputService"

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
	attack = "ATTACK (A) · drag for an area · shift keeps · right click cancels",
	reclaim = "RECLAIM (E) · drag for an area · shift keeps · right click cancels",
	repair = "REPAIR (R) · drag for an area · shift keeps · right click cancels",
	resurrect = "RESURRECT (W) · drag for an area · shift keeps · right click cancels",
	fight = "FIGHT (F) · drag to spread · shift keeps · right click cancels",
	load = "LOAD (J) · shift keeps · right click cancels",
	unload = "UNLOAD (U) · drag to spread · shift keeps · right click cancels",
	guard = "GUARD (O) · shift keeps · right click cancels",
	disintegrator = "DISINTEGRATOR (D) · shift queues · right click cancels",
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
		Text = "[ ] rotate · shift keeps · right click cancels",
	}, {
		Scale = React.createElement("UIScale", { Scale = ui_scale }),
	})
end

-- How far under the cursor's tip the placement problem sits, clear of the pointer itself.
local PROBLEM_OFFSET = 28

-- Says under the cursor why the building it carries cannot go there, while its ghost is red: rough ground,
-- dry land for something that floats, water too shallow for it, and so on.
local function PlacementProblem()
	local problem, set_problem = React.useState(build_mode.get_problem())
	local position, set_position = React.useBinding(UDim2.new())
	local ui_scale = use_viewport.use_ui_scale()

	React.useEffect(function()
		return build_mode.subscribe_problem(function(next_problem: string?)
			set_problem(next_problem)
		end)
	end, {})

	-- follows the cursor every frame through a binding, so moving the mouse does not re-render
	React.useEffect(function()
		if problem == nil then
			return nil
		end
		local function follow()
			-- the mouse is in viewport space and this GUI is one inset below it, see SelectionBox
			local mouse = UserInputService:GetMouseLocation() - GuiService:GetGuiInset()
			set_position(UDim2.fromOffset(mouse.X, mouse.Y + PROBLEM_OFFSET))
		end
		follow()
		local connection = RunService.RenderStepped:Connect(follow)
		return function()
			connection:Disconnect()
		end
	end, { problem })

	if problem == nil then
		return nil
	end

	return React.createElement("TextLabel", {
		[React.Tag] = "placement-problem",
		Position = position,
		Text = problem,
	}, {
		Scale = React.createElement("UIScale", { Scale = ui_scale }),
	})
end

return table.freeze({
	PlacementProblem = PlacementProblem,
	SelectionBox = SelectionBox,
	PlacementHint = PlacementHint,
	ModeHint = ModeHint,
})
