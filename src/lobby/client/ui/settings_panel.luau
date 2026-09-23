-- The lobby's game mode and who may join it. The host changes them; everyone else sees them.

local ReplicatedStorage = game:GetService "ReplicatedStorage"

local React = require(ReplicatedStorage.Packages.react)

local game_modes = require(ReplicatedStorage.Shared.game_modes)

local protocol = require(ReplicatedStorage.Lobby.protocol)

local controls = require(script.Parent.controls)

type Mode = game_modes.Mode

local ACTIONS = protocol.ACTIONS

local function Chip(props: {
	label: string,
	active: boolean,
	locked: boolean,
	on_pick: () -> (),
	LayoutOrder: number,
})
	return React.createElement(controls.Button, {
		kind = "chip",
		tag = if props.active then "active" else nil,
		label = props.label,
		locked = props.locked,
		on_press = props.on_pick,
		LayoutOrder = props.LayoutOrder,
	})
end

-- One line of choices under a caption.
local function Group(props: { label: string, LayoutOrder: number, children: any })
	return React.createElement("Frame", {
		[React.Tag] = "group",
		LayoutOrder = props.LayoutOrder,
	}, {
		Label = React.createElement("TextLabel", {
			[React.Tag] = "group-label",
			LayoutOrder = 1,
			Text = props.label,
		}),
		Chips = React.createElement("Frame", {
			[React.Tag] = "chips",
			LayoutOrder = 2,
		}, props.children),
	})
end

local function SettingsPanel(props: {
	mode: string,
	visibility: string,
	is_host: boolean,
	act: (action: string, argument: any?) -> (),
})
	local locked = not props.is_host
	local by_kind: { [string]: { [string]: any } } = { scavengers = {}, teams = {}, ffa = {} }
	for index, mode in game_modes.MODES do
		local label = mode.label
		if mode.kind == "scavengers" then
			-- the group's caption already says scavengers
			label = (game_modes.difficulty(mode.difficulty :: string) :: game_modes.Difficulty).label
		end
		by_kind[mode.kind][mode.id] = React.createElement(Chip, {
			label = label,
			active = mode.id == props.mode,
			locked = locked,
			on_pick = function()
				props.act(ACTIONS.set_mode, mode.id)
			end,
			LayoutOrder = index,
		})
	end

	return React.createElement("Frame", {
		[React.Tag] = "settings-panel panel",
		LayoutOrder = 1,
	}, {
		Rail = React.createElement("Frame", {
			[React.Tag] = "rail",
			LayoutOrder = 1,
		}),
		Title = React.createElement("Frame", {
			[React.Tag] = "title-row",
			LayoutOrder = 2,
		}, {
			Accent = React.createElement("Frame", {
				[React.Tag] = "accent-bar",
				LayoutOrder = 1,
			}),
			Name = React.createElement("TextLabel", {
				[React.Tag] = "heading",
				LayoutOrder = 2,
				Text = "Game mode",
			}),
		}),
		Scavengers = React.createElement(Group, {
			label = "SCAVENGERS",
			LayoutOrder = 3,
		}, by_kind.scavengers),
		Teams = React.createElement(Group, {
			label = "TEAMS",
			LayoutOrder = 4,
		}, by_kind.teams),
		Ffa = React.createElement(Group, {
			label = "FREE FOR ALL",
			LayoutOrder = 5,
		}, by_kind.ffa),
		Seam = React.createElement("Frame", {
			[React.Tag] = "seam",
			LayoutOrder = 6,
		}),
		Visibility = React.createElement(Group, {
			label = "WHO CAN JOIN",
			LayoutOrder = 7,
		}, {
			Public = React.createElement(Chip, {
				label = "Public",
				active = props.visibility == "public",
				locked = locked,
				on_pick = function()
					props.act(ACTIONS.set_visibility, "public")
				end,
				LayoutOrder = 1,
			}),
			Friends = React.createElement(Chip, {
				label = "Friends only",
				active = props.visibility == "friends",
				locked = locked,
				on_pick = function()
					props.act(ACTIONS.set_visibility, "friends")
				end,
				LayoutOrder = 2,
			}),
		}),
	})
end

return table.freeze({
	SettingsPanel = SettingsPanel,
})
