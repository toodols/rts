--!strict
-- The list of lobbies this player may join, across every lobby server, and the button to make one of their own; and
-- above them the way into the campaign, a card that is its own button (campaign_card.luau).

local ReplicatedStorage = game:GetService "ReplicatedStorage"

local React = require(ReplicatedStorage.Packages.react)

local game_modes = require(ReplicatedStorage.Shared.game_modes)
local map_presets = require(ReplicatedStorage.Shared.map_presets)

local protocol = require(ReplicatedStorage.Lobby.protocol)

local map_preview = require(ReplicatedStorage.LobbyClient.map_preview)
local map_image = require(script.Parent.map_image)
local controls = require(script.Parent.controls)
local campaign_card = require(script.Parent.campaign_card)

local format = require(ReplicatedStorage.ClientShared.format)

type Summary = protocol.Summary

local function LobbyRow(props: {
	summary: Summary,
	act: (action: protocol.Action, argument: any?) -> (),
	LayoutOrder: number,
})
	local summary = props.summary
	local map = map_presets.presets[summary.preset]
	local full = summary.players >= summary.capacity
	-- a lobby whose seats are taken can still be joined to watch, while it has room for that
	local watch_only = full and (summary.spectators or 0) < game_modes.SPECTATOR_CAPACITY

	return React.createElement("Frame", {
		[React.Tag] = "lobby-row",
		LayoutOrder = props.LayoutOrder,
	}, {
		Thumb = if map ~= nil
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
				Text = `{format.escape(summary.host_name)}'s lobby`,
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
			Text = game_modes.label_of(summary.mode),
		}),
		Map = React.createElement("Frame", {
			[React.Tag] = "lobby-cell map",
			LayoutOrder = 4,
		}, {
			Name = React.createElement("TextLabel", {
				[React.Tag] = "lobby-map-name",
				LayoutOrder = 1,
				Text = if map ~= nil then map.display_name else summary.preset,
			}),
			Size = if map ~= nil
				then React.createElement("TextLabel", {
					[React.Tag] = "lobby-map-size faint",
					LayoutOrder = 2,
					Text = map_preview.units_text(map),
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
			label = if watch_only then "Watch" elseif full then "Full" else "Join",
			locked = full and watch_only == false,
			on_press = function()
				props.act("join", summary.key)
			end,
			LayoutOrder = 6,
		}),
	})
end

local function Browser(props: {
	lobbies: { Summary },
	received: boolean,
	act: (action: protocol.Action, argument: any?) -> (),
	open_campaign: () -> (),
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
			Text = if props.received then "No open lobbies right now." else "Looking for lobbies...",
		})
	end

	return React.createElement("Frame", {
		[React.Tag] = "browser panel",
	}, {
		Rail = React.createElement("Frame", {
			[React.Tag] = "rail",
			LayoutOrder = 1,
		}),
		Campaign = React.createElement(campaign_card.CampaignCard, {
			on_open = props.open_campaign,
			LayoutOrder = 2,
		}),
		Title = React.createElement("Frame", {
			[React.Tag] = "title-row",
			LayoutOrder = 3,
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
					props.act "create"
				end,
				LayoutOrder = 5,
			}),
		}),
		Columns = React.createElement("Frame", {
			[React.Tag] = "lobby-columns",
			LayoutOrder = 4,
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
			LayoutOrder = 5,
		}, rows),
	})
end

return table.freeze({
	Browser = Browser,
})
