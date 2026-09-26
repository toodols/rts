--!strict
-- What rides the cursor: the badge of the mode it is in, how to handle the building it is placing, and why that building
-- cannot go where it is. Client.command_state and Client.build_mode own what they say; this only draws it.

local GuiService = game:GetService "GuiService"
local ReplicatedStorage = game:GetService "ReplicatedStorage"
local RunService = game:GetService "RunService"
local UserInputService = game:GetService "UserInputService"

local React = require(ReplicatedStorage.Packages.react)

local command_state = require(ReplicatedStorage.Client.command_state)
local order_modes = require(ReplicatedStorage.Client.order_modes)
local build_mode = require(ReplicatedStorage.Client.build_mode)
local mode_aim = require(ReplicatedStorage.Client.mode_aim)
local use_viewport = require(ReplicatedStorage.Client.ui.use_viewport)

local art_icon = require(ReplicatedStorage.ClientShared.art_icon)
local palette = require(ReplicatedStorage.ClientShared.palette)
local use_store = require(ReplicatedStorage.ClientShared.use_store)

local ArtIcon = art_icon.ArtIcon

-- How far under the cursor's tip the placement problem sits, clear of the pointer itself.
local PROBLEM_OFFSET = 28
-- How far right of and below the cursor's tip the mode's badge sits, clear of the pointer itself.
local BADGE_OFFSET = 18
-- An icon's bright parts are lit in its mode's colour; every icon is the one group (Shared.ui_art).
local LIT = table.freeze({ base = true })
-- A greyed name is as bright as its colour by this much.
local MUTED_SHADE = 0.9

-- The mode that is on, if one is.
local function mode_info(): order_modes.ModeInfo?
	local state = command_state.get()
	return if state.kind == "mode" then order_modes.get(state.mode) else nil
end

-- The mode that is on, as a badge riding just off the cursor's tip, so that it is always plain that the next click
-- will do something other than select: its icon lit in its colour, or its name where it has no icon, greyed while a
-- click would do nothing (Client.mode_aim).
local function ModeCursor()
	local info = use_store.use_store(mode_info, command_state.subscribe_mode)
	local aimed = use_store.use_store(mode_aim.get_aimed, mode_aim.subscribe)
	local position, set_position = React.useBinding(UDim2.new())
	local ui_scale = use_viewport.use_ui_scale()
	local on = info ~= nil

	-- follows the cursor every frame through a binding, so moving the mouse does not re-render
	React.useEffect(function(): (() -> ())?
		if on == false then
			return nil
		end
		local function follow()
			-- the mouse is in viewport space and this GUI is one inset below it, see ui/selection_box.luau
			local mouse = UserInputService:GetMouseLocation() - GuiService:GetGuiInset()
			set_position(UDim2.fromOffset(mouse.X + BADGE_OFFSET, mouse.Y + BADGE_OFFSET))
		end
		follow()
		local connection = RunService.RenderStepped:Connect(follow)
		return function()
			connection:Disconnect()
		end
	end, { on })

	if info == nil then
		return nil
	end
	local badge = if info.icon ~= nil
		then React.createElement(ArtIcon, {
			name = info.icon,
			view = "front",
			flat = true,
			lit = if aimed then LIT else nil,
			lit_color = info.color,
			muted = not aimed,
			fallback = info.label,
			tag = "mode-cursor-icon",
		})
		else React.createElement("TextLabel", {
			[React.Tag] = "mode-cursor-label",
			Text = info.label,
			TextColor3 = if aimed then info.color else palette.greyed(info.color, MUTED_SHADE),
		})
	return React.createElement("Frame", {
		[React.Tag] = "mode-cursor",
		Position = position,
	}, {
		Badge = badge,
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
	ModeCursor = ModeCursor,
	PlacementHint = PlacementHint,
	PlacementProblem = PlacementProblem,
})
