--!strict
-- The notes under the cursor: which mode it is in, how to handle the building it is placing, and why that building
-- cannot go where it is. Client.command_state and Client.build_mode own what they say; this only draws it.

local GuiService = game:GetService "GuiService"
local ReplicatedStorage = game:GetService "ReplicatedStorage"
local RunService = game:GetService "RunService"
local UserInputService = game:GetService "UserInputService"

local React = require(ReplicatedStorage.Packages.react)

local command_state = require(ReplicatedStorage.Client.command_state)
local order_modes = require(ReplicatedStorage.Client.order_modes)
local build_mode = require(ReplicatedStorage.Client.build_mode)
local use_viewport = require(ReplicatedStorage.Client.ui.use_viewport)

local use_store = require(ReplicatedStorage.ClientShared.use_store)

-- How far under the cursor's tip the placement problem sits, clear of the pointer itself.
local PROBLEM_OFFSET = 28

-- The mode that is on, if one is.
local function mode_info(): order_modes.ModeInfo?
	local state = command_state.get()
	return if state.kind == "mode" then order_modes.get(state.mode) else nil
end

-- Says which mode the cursor is in while one is on, so that it is always plain that the next click will do something
-- other than select.
local function ModeHint()
	local info = use_store.use_store(mode_info, command_state.subscribe_mode)
	local ui_scale = use_viewport.use_ui_scale()
	if info == nil then
		return nil
	end
	return React.createElement("TextLabel", {
		-- the mode is a tag too, so each can have its own colour
		[React.Tag] = `placement-hint mode-hint {info.mode}`,
		Text = order_modes.hint_of(info),
	}, {
		Scale = React.createElement("UIScale", { Scale = ui_scale }),
	})
end

local function PlacementHint()
	local placing = use_store.use_store(command_state.placing, command_state.subscribe_placing)
	local ui_scale = use_viewport.use_ui_scale()
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

-- Says under the cursor why the building it carries cannot go there, while its ghost is red: rough ground,
-- dry land for something that floats, water too shallow for it, and so on.
local function PlacementProblem()
	local problem = use_store.use_store(build_mode.get_problem, build_mode.subscribe_problem)
	local position, set_position = React.useBinding(UDim2.new())
	local ui_scale = use_viewport.use_ui_scale()

	-- follows the cursor every frame through a binding, so moving the mouse does not re-render
	React.useEffect(function(): (() -> ())?
		if problem == nil then
			return nil
		end
		local function follow()
			-- the mouse is in viewport space and this GUI is one inset below it, see ui/selection_box.luau
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
	ModeHint = ModeHint,
	PlacementHint = PlacementHint,
	PlacementProblem = PlacementProblem,
})
