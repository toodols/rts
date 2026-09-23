-- The list of lobbies this player may join, across every lobby server, and the button to make one of their own.

local ReplicatedStorage = game:GetService "ReplicatedStorage"

local React = require(ReplicatedStorage.Packages.react)

local game_modes = require(ReplicatedStorage.Shared.game_modes)
local map_presets = require(ReplicatedStorage.Shared.map_presets)

local protocol = require(ReplicatedStorage.Lobby.protocol)

local map_preview = require(ReplicatedStorage.LobbyClient.map_preview)
local map_image = require(script.Parent.map_image)
local controls = require(script.Parent.controls)

type Summary = protocol.Summary

local ACTIONS = protocol.ACTIONS

local function format_units(units: Vector2): string
	return `{math.round(units.X)} × {math.round(units.Y)}`
end

local function LobbyRow(props: {
	summary: Summary,
	act: (action: string, argument: any?) -> (),
	LayoutOrder: number,
})
	local summary = props.summary
	local mode = game_modes.get(summary.mode)
	local known_map = map_presets.presets[summary.preset] ~= nil
	local full = summary.players >= summary.capacity

	return React.createElement("Frame", {
		[React.Tag] = "lobby-row",
		LayoutOrder = props.LayoutOrder,
	}, {
		Thumb = if known_map
			then React.createElement(map_image.MapImage, {
				preset = summary.preset,
				seed = game_modes.DEFAULT_SEED,
				grid = false,
				tag = "lobby-thumb",
				LayoutOrder = 1,
			})
			else React.createElement("Frame", { [React.Tag] = "lobby-thumb", LayoutOrder = 1 }),
		Host = React.createElement("Frame", {
			[React.Tag] = "lobby-cell host",
			LayoutOrder = 2,
		}, {
			Name = React.createElement("TextLabel", {
				[React.Tag] = "lobby-host",
				LayoutOrder = 1,
				Text = `{summary.host_name}'s lobby`,
			}),
			Visibility = React.createElement("TextLabel", {
				[React.Tag] = if summary.visibility == "friends" then "tag friends" else "tag",
				LayoutOrder = 2,
				Text = if summary.visibility == "friends" then "FRIENDS ONLY" else "PUBLIC",
			}),
		}),
		Mode = React.createElement("TextLabel", {
			[React.Tag] = "lobby-cell mode readout",
			LayoutOrder = 3,
			Text = if mode ~= nil then mode.label else summary.mode,
		}),
		Map = React.createElement("Frame", {
			[React.Tag] = "lobby-cell map",
			LayoutOrder = 4,
		}, {
			Name = React.createElement("TextLabel", {
				[React.Tag] = "lobby-map-name",
				LayoutOrder = 1,
				Text = if known_map then map_preview.info(summary.preset).name else summary.preset,
			}),
			Size = if known_map
				then React.createElement("TextLabel", {
					[React.Tag] = "lobby-map-size faint",
					LayoutOrder = 2,
					Text = format_units(map_preview.info(summary.preset).units),
				})
				else nil,
		}),
		Players = React.createElement("TextLabel", {
			[React.Tag] = if full then "lobby-cell players readout full" else "lobby-cell players readout",
			LayoutOrder = 5,
			Text = `{summary.players}/{summary.capacity}`,
		}),
		Join = React.createElement(controls.Button, {
			kind = "button",
			tag = "join",
			label = if full then "Full" else "Join",
			locked = full,
			on_press = function()
				props.act(ACTIONS.join, summary.key)
			end,
			LayoutOrder = 6,
		}),
	})
end

local function Browser(props: {
	lobbies: { Summary },
	received: boolean,
	act: (action: string, argument: any?) -> (),
})
	local rows: { [string]: any } = {}
	for index, summary in props.lobbies do
		rows[summary.key] = React.createElement(LobbyRow, {
			summary = summary,
			act = props.act,
			LayoutOrder = index,
		})
	end
	if #props.lobbies == 0 then
		rows.Empty = React.createElement("TextLabel", {
			[React.Tag] = "empty",
			Text = if props.received
				then "No open lobbies right now. Make one and others can join it."
				else "Looking for lobbies...",
		})
	end

	return React.createElement("Frame", {
		[React.Tag] = "browser panel",
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
				Text = "Open lobbies",
			}),
			Count = React.createElement("TextLabel", {
				[React.Tag] = "badge",
				LayoutOrder = 3,
				Text = tostring(#props.lobbies),
			}),
			Spacer = React.createElement("Frame", {
				[React.Tag] = "grow",
				LayoutOrder = 4,
			}),
			Create = React.createElement(controls.Button, {
				kind = "button",
				tag = "primary",
				label = "Create lobby",
				on_press = function()
					props.act(ACTIONS.create)
				end,
				LayoutOrder = 5,
			}),
		}),
		Columns = React.createElement("Frame", {
			[React.Tag] = "lobby-columns",
			LayoutOrder = 3,
		}, {
			Thumb = React.createElement("Frame", { [React.Tag] = "lobby-thumb blank", LayoutOrder = 1 }),
			Host = React.createElement("TextLabel", {
				[React.Tag] = "lobby-cell column-name host",
				LayoutOrder = 2,
				Text = "LOBBY",
			}),
			Mode = React.createElement("TextLabel", {
				[React.Tag] = "lobby-cell mode column-name",
				LayoutOrder = 3,
				Text = "MODE",
			}),
			Map = React.createElement("TextLabel", {
				[React.Tag] = "lobby-cell map column-name",
				LayoutOrder = 4,
				Text = "MAP",
			}),
			Players = React.createElement("TextLabel", {
				[React.Tag] = "lobby-cell players column-name",
				LayoutOrder = 5,
				Text = "PLAYERS",
			}),
			-- as wide as the join buttons below, so the columns line up
			Join = React.createElement("Frame", { [React.Tag] = "join-space", LayoutOrder = 6 }),
		}),
		List = React.createElement("ScrollingFrame", {
			[React.Tag] = "lobby-list",
			LayoutOrder = 4,
		}, rows),
	})
end

return table.freeze({
	Browser = Browser,
})
