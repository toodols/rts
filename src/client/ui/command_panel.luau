-- The commands the selected units can be given as modes, each with its icon and its key: Attack - A, Fight - F, and
-- so on. It lists a command when anything selected can take part in it (`selected.for_mode`), marks the one that is on,
-- and a click on a row does what pressing its key does. In the tutorial, the command its step wants clicked
-- (Client.tutorial's `command_target`) is lit and pointed at, until it is on.

local ReplicatedStorage = game:GetService "ReplicatedStorage"

local React = require(ReplicatedStorage.Packages.react)

local command_state = require(ReplicatedStorage.Client.command_state)
local order_modes = require(ReplicatedStorage.Client.order_modes)
local selected = require(ReplicatedStorage.Client.selected)
local tutorial_pointer = require(ReplicatedStorage.Client.ui.tutorial_pointer)
local use_entities = require(ReplicatedStorage.Client.ui.use_entities)
local use_tutorial = require(ReplicatedStorage.Client.ui.use_tutorial)

local art_icon = require(ReplicatedStorage.ClientShared.art_icon)
local use_store = require(ReplicatedStorage.ClientShared.use_store)

local ArtIcon = art_icon.ArtIcon
local TutorialPointer = tutorial_pointer.TutorialPointer

local function CommandPanel()
	-- rendered again as the selection, or anything of what is in it, changes: something that has just been finished
	-- can take part in more
	use_entities.use_views(use_entities.use_selection())
	local mode = use_store.use_store(command_state.mode, command_state.subscribe_mode)
	-- what the guide wants clicked, if anything
	local target = use_tutorial.use_command_target()
	if mode == target then
		target = nil
	end

	local rows = {}
	local any = false
	for index, command in order_modes.all do
		if #selected.for_mode(command) == 0 then
			continue
		end

		any = true
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
				Text = command.key,
			}),
			-- the panel is at the left of the screen, so the pointer stands off the row's right
			Pointer = if pointed then React.createElement(TutorialPointer, { side = "right" }) else nil,
		})
	end
	if any == false then
		return nil
	end

	rows.Title = React.createElement("Frame", {
		[React.Tag] = "command-title",
		LayoutOrder = 1,
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
	})

	return React.createElement("Frame", {
		[React.Tag] = "command-panel panel",
		LayoutOrder = 2,
	}, rows)
end

return table.freeze({
	CommandPanel = CommandPanel,
})
