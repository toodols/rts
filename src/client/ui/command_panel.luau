-- The commands the selected units can be given as modes, each with its key: Attack - A, Fight - F, and so
-- on. It lists a command when at least one selected finished unit can use it, marks the one that is on,
-- and a click on a row does what pressing its key does. In the tutorial, the command its step wants clicked
-- (Client.tutorial's `command_target`) is lit and pointed at, until it is on.

local ReplicatedStorage = game:GetService "ReplicatedStorage"

local React = require(ReplicatedStorage.Packages.react)

local unit_defs = require(ReplicatedStorage.Shared.unit_defs)

local input = require(ReplicatedStorage.Client.input)
local tutorial = require(ReplicatedStorage.Client.tutorial)
local tutorial_pointer = require(ReplicatedStorage.Client.ui.tutorial_pointer)
local use_entities = require(ReplicatedStorage.Client.ui.use_entities)
local use_tutorial = require(ReplicatedStorage.Client.ui.use_tutorial)

local TutorialPointer = tutorial_pointer.TutorialPointer

local function CommandPanel()
	local ids = use_entities.use_selection()
	local views = use_entities.use_views(ids)
	local mode, set_mode = React.useState(nil :: string?)

	React.useEffect(function()
		return input.subscribe_mode(function(next_mode: string?)
			set_mode(next_mode)
		end)
	end, {})
	-- only to re-render when the tutorial's step changes
	use_tutorial.use_tutorial()
	local target = tutorial.command_target()
	if mode == target then
		target = nil
	end

	local rows = {}
	local any = false
	for index, command in input.commands do
		local able = false
		for _, view in views do
			local def = unit_defs.defs[view.def_name]
			if
				def ~= nil
				and (unit_defs.takes_orders(def) or unit_defs.is_factory(def))
				and input.can_command(command.mode, def)
			then
				able = true
				break
			end
		end
		if able == false then
			continue
		end

		any = true
		local pointed = command.mode == target
		local tag = if mode == command.mode then "command-row active" else "command-row"
		rows[command.mode] = React.createElement("TextButton", {
			[React.Tag] = if pointed then `{tag} tutorial-highlight` else tag,
			LayoutOrder = index + 1,
			Text = "",
			[React.Event.Activated] = function()
				input.toggle_mode(command.mode)
			end,
		}, {
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
			Pointer = if pointed then React.createElement(TutorialPointer, { text = "CLICK", side = "right" }) else nil,
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
