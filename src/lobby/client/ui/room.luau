-- The lobby this player is in: the map on the left, the mode and the players on the right, and leaving or starting
-- along the bottom of them.

local Players = game:GetService "Players"
local ReplicatedStorage = game:GetService "ReplicatedStorage"

local React = require(ReplicatedStorage.Packages.react)

local map_presets = require(ReplicatedStorage.Shared.map_presets)

local protocol = require(ReplicatedStorage.Lobby.protocol)

local map_preview = require(ReplicatedStorage.LobbyClient.map_preview)
local map_panel = require(script.Parent.map_panel)
local settings_panel = require(script.Parent.settings_panel)
local seats_panel = require(script.Parent.seats_panel)
local controls = require(script.Parent.controls)

type LobbyView = protocol.LobbyView

local ACTIONS = protocol.ACTIONS

local local_player = Players.LocalPlayer

-- Why the lobby cannot start, or a warning worth showing beside the start button even though it can.
local function status_of(lobby: LobbyView, is_host: boolean): (string, boolean)
	if lobby.starting then
		return "Starting the game...", false
	end
	if lobby.blocked ~= nil then
		return lobby.blocked, true
	end
	if map_presets.presets[lobby.preset] ~= nil then
		local starts = map_preview.info(lobby.preset).starts
		if #lobby.seats > starts then
			return `{#lobby.seats} players on a map with {starts} starts: some will share`, true
		end
	end
	if is_host then
		return "Ready", false
	end
	return "Waiting for the host to start", false
end

local function Room(props: {
	lobby: LobbyView,
	act: (action: string, argument: any?) -> (),
})
	local lobby = props.lobby
	local is_host = lobby.host == local_player.UserId
	local status, warning = status_of(lobby, is_host)
	local can_start = is_host and lobby.blocked == nil and lobby.starting == false

	return React.createElement("Frame", {
		[React.Tag] = "room",
	}, {
		Map = React.createElement(map_panel.MapPanel, {
			preset = lobby.preset,
			seed = lobby.seed,
			is_host = is_host,
			players = #lobby.seats,
			act = props.act,
		}),
		Side = React.createElement("Frame", {
			[React.Tag] = "room-side",
			LayoutOrder = 2,
		}, {
			Settings = React.createElement(settings_panel.SettingsPanel, {
				mode = lobby.mode,
				visibility = lobby.visibility,
				is_host = is_host,
				act = props.act,
			}),
			Seats = React.createElement(seats_panel.SeatsPanel, {
				lobby = lobby,
				act = props.act,
			}),
			Actions = React.createElement("Frame", {
				[React.Tag] = "room-actions panel",
				LayoutOrder = 3,
			}, {
				Leave = React.createElement(controls.Button, {
					kind = "button",
					label = "Leave",
					on_press = function()
						props.act(ACTIONS.leave)
					end,
					LayoutOrder = 1,
				}),
				Status = React.createElement("TextLabel", {
					[React.Tag] = if warning then "status grow warning" else "status grow",
					LayoutOrder = 2,
					Text = status,
				}),
				Start = if is_host
					then React.createElement(controls.Button, {
						kind = "button",
						tag = "primary",
						label = "Start game",
						locked = not can_start,
						on_press = function()
							props.act(ACTIONS.start)
						end,
						LayoutOrder = 3,
					})
					else nil,
			}),
		}),
	})
end

return table.freeze({
	Room = Room,
})
