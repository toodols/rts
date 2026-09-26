--!strict
-- The lobby's game mode, who may join it, whether allies' weapons hurt each other and, for a team game or a free for
-- all, how it is won. The host changes them; everyone else sees them. A co-op lobby's mode is its campaign mission, and
-- stays as the mission has it; its host still picks ally griefing.

local ReplicatedStorage = game:GetService "ReplicatedStorage"

local React = require(ReplicatedStorage.Packages.react)

local game_modes = require(ReplicatedStorage.Shared.game_modes)

local protocol = require(ReplicatedStorage.Lobby.protocol)

local controls = require(script.Parent.controls)

type Mode = game_modes.Mode

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
	visibility: protocol.Visibility,
	ally_griefing: boolean,
	end_mode: game_modes.EndMode,
	is_host: boolean,
	act: (action: protocol.Action, argument: any?) -> (),
})
	local locked = not props.is_host
	local current = game_modes.get(props.mode)
	-- a co-op lobby plays its mission, and nothing about the game can be changed
	local mission = if current ~= nil and current.mission ~= nil then current else nil
	local game_locked = locked or mission ~= nil
	local by_group: { [string]: { [string]: any } } = { scavengers = {}, teams = {}, ffa = {} }
	for index, mode in game_modes.MODES do
		-- a campaign mode is in no group: it is started from the campaign screen
		local group = mode.group
		if group == nil then
			continue
		end
		by_group[group][mode.id] = React.createElement(Chip, {
			label = mode.chip_label,
			active = mode.id == props.mode,
			locked = locked,
			on_pick = function()
				props.act("set_mode", mode.id)
			end,
			LayoutOrder = index,
		})
	end
	-- only a mode that puts sides out is won by an end mode; the scavengers and a mission end their own ways
	local elimination = current ~= nil and current.eliminates
	local end_modes: { [string]: any } = {}
	for index, option in game_modes.END_MODES do
		end_modes[option.id] = React.createElement(Chip, {
			label = option.label,
			active = option.id == props.end_mode,
			locked = game_locked,
			on_pick = function()
				props.act("set_end_mode", option.id)
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
		Mission = if mission ~= nil
			then React.createElement(Group, {
				label = "CO-OP MISSION",
				LayoutOrder = 3,
			}, {
				Mission = React.createElement(Chip, {
					label = mission.label,
					active = true,
					locked = true,
					on_pick = function() end,
					LayoutOrder = 1,
				}),
			})
			else nil,
		Scavengers = if mission == nil
			then React.createElement(Group, {
				label = "SCAVENGERS",
				LayoutOrder = 3,
			}, by_group.scavengers)
			else nil,
		Teams = if mission == nil
			then React.createElement(Group, {
				label = "TEAMS",
				LayoutOrder = 4,
			}, by_group.teams)
			else nil,
		Ffa = if mission == nil
			then React.createElement(Group, {
				label = "FREE FOR ALL",
				LayoutOrder = 5,
			}, by_group.ffa)
			else nil,
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
					props.act("set_visibility", "public")
				end,
				LayoutOrder = 1,
			}),
			Friends = React.createElement(Chip, {
				label = "Friends only",
				active = props.visibility == "friends",
				locked = locked,
				on_pick = function()
					props.act("set_visibility", "friends")
				end,
				LayoutOrder = 2,
			}),
		}),
		-- off, a weapon only hurts its own team's things and its enemies': nobody disintegrates an ally's extractors
		Griefing = React.createElement(Group, {
			label = "ALLY GRIEFING",
			LayoutOrder = 8,
		}, {
			Off = React.createElement(Chip, {
				label = "Off",
				active = props.ally_griefing == false,
				locked = locked,
				on_pick = function()
					props.act("set_ally_griefing", false)
				end,
				LayoutOrder = 1,
			}),
			On = React.createElement(Chip, {
				label = "On",
				active = props.ally_griefing,
				locked = locked,
				on_pick = function()
					props.act("set_ally_griefing", true)
				end,
				LayoutOrder = 2,
			}),
		}),
		Ends = if elimination
			then React.createElement(Group, {
				label = "GAME ENDS",
				LayoutOrder = 9,
			}, end_modes)
			else nil,
	})
end

return table.freeze({
	SettingsPanel = SettingsPanel,
})
