-- The commands the selected units can be given as modes, each with its icon and the player's key for it (Attack - A,
-- Fight - F, and so on in the BAR profile). It lists a command when anything selected can take part in it (`selected.for_mode`), marks the one that is on,
-- and a click on a row does what pressing its key does. It starts collapsed to its title, which opens and closes it; the
-- keys work either way. In the tutorial, the command its step wants clicked (Client.tutorial's `command_target`) is lit
-- and pointed at, until it is on, and while the list is collapsed its title is instead.

local ReplicatedStorage = game:GetService "ReplicatedStorage"

local React = require(ReplicatedStorage.Packages.react)

local keybinds = require(ReplicatedStorage.Shared.keybinds)

local command_state = require(ReplicatedStorage.Client.command_state)
local order_modes = require(ReplicatedStorage.Client.order_modes)
local selected = require(ReplicatedStorage.Client.selected)
local tutorial_pointer = require(ReplicatedStorage.Client.ui.tutorial_pointer)
local use_entities = require(ReplicatedStorage.Client.ui.use_entities)
local use_tutorial = require(ReplicatedStorage.Client.ui.use_tutorial)

local art_icon = require(ReplicatedStorage.ClientShared.art_icon)
local keybind_state = require(ReplicatedStorage.ClientShared.keybind_state)
local use_store = require(ReplicatedStorage.ClientShared.use_store)

local ArtIcon = art_icon.ArtIcon
local TutorialPointer = tutorial_pointer.TutorialPointer

-- The chevron at the end of the title: up while the list is collapsed, since it opens upward, and down while it is open.
-- Two arms ARM_LENGTH pixels long, turned here since the stylesheet cannot turn them.
local ARM_LENGTH = 9
local function Chevron(props: { up: boolean })
	local turn = if props.up then -45 else 45
	local function arm(x: number, rotation: number)
		return React.createElement("Frame", {
			[React.Tag] = "command-chevron-arm",
			AnchorPoint = Vector2.new(0.5, 0.5),
			Position = UDim2.new(0.5, x, 0.5, 0),
			Rotation = rotation,
			Size = UDim2.fromOffset(ARM_LENGTH, 2),
		})
	end
	return React.createElement("Frame", {
		[React.Tag] = "command-chevron",
		LayoutOrder = 4,
	}, {
		Left = arm(-3, turn),
		Right = arm(3, -turn),
	})
end

local function CommandPanel()
	-- rendered again as the selection, or anything of what is in it, changes: something that has just been finished
	-- can take part in more
	use_entities.use_views(use_entities.use_selection())
	-- kept while nothing is selected too, since the panel then renders nothing but stays mounted
	local open, set_open = React.useState(false)
	local mode = use_store.use_store(command_state.mode, command_state.subscribe_mode)
	local bindings = keybind_state.use_bindings()
	-- what the guide wants clicked, if anything
	local target = use_tutorial.use_command_target()
	if mode == target then
		target = nil
	end

	local rows = {}
	-- how many commands are listed, collapsed or not
	local count = 0
	-- whether the command the guide wants is listed, collapsed or not
	local target_listed = false
	for index, command in order_modes.all do
		if #selected.for_mode(command) == 0 then
			continue
		end

		count += 1
		if command.mode == target then
			target_listed = true
		end
		if open == false then
			continue
		end
		local pointed = command.mode == target
		local tag = if mode == command.mode then "command-row active" else "command-row"
		rows[command.mode] = React.createElement("TextButton", {
			[React.Tag] = tutorial_pointer.lit(tag, pointed),
			LayoutOrder = index + 1,
			Text = "",
			[React.Event.Activated] = function()
				command_state.toggle_mode(command.mode)
			end,
		}, {
			Icon = if command.icon ~= nil
				then React.createElement(ArtIcon, {
					name = command.icon,
					view = "front",
					flat = true,
					tag = "command-icon",
					LayoutOrder = 0,
				})
				else React.createElement("Frame", {
					[React.Tag] = "command-icon",
					LayoutOrder = 0,
				}),
			Name = React.createElement("TextLabel", {
				[React.Tag] = "command-name grow",
				LayoutOrder = 1,
				Text = command.label,
			}),
			Key = React.createElement("TextLabel", {
				[React.Tag] = "command-key",
				LayoutOrder = 2,
				Text = keybinds.label(bindings[command.action]),
			}),
			-- the panel is at the left of the screen, so the pointer stands off the row's right
			Pointer = if pointed then React.createElement(TutorialPointer, { side = "right" }) else nil,
		})
	end
	if count == 0 then
		return nil
	end

	-- collapsed, the guide points at the title, to open the list
	local pointed = target_listed and open == false
	rows.Title = React.createElement("TextButton", {
		[React.Tag] = tutorial_pointer.lit("command-title", pointed),
		LayoutOrder = 1,
		Text = "",
		[React.Event.Activated] = function()
			set_open(not open)
		end,
	}, {
		Accent = React.createElement("Frame", {
			[React.Tag] = "accent-bar",
			LayoutOrder = 1,
		}),
		Name = React.createElement("TextLabel", {
			[React.Tag] = "heading grow",
			LayoutOrder = 2,
			Text = "Commands",
		}),
		Count = React.createElement("TextLabel", {
			[React.Tag] = "badge badge-count",
			LayoutOrder = 3,
			Text = tostring(count),
		}),
		Chevron = React.createElement(Chevron, { up = not open }),
		Pointer = if pointed then React.createElement(TutorialPointer, { side = "right" }) else nil,
	})

	return React.createElement("Frame", {
		[React.Tag] = "command-panel panel",
		LayoutOrder = 2,
	}, rows)
end

return table.freeze({
	CommandPanel = CommandPanel,
})
