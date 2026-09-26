--!strict
-- The lobby this player is in: the map on the left, the mode and the players on the right, and leaving or starting
-- along the bottom of them. Every player but the host marks themselves ready there, and the host can start once they
-- all have.

local Players = game:GetService "Players"
local ReplicatedStorage = game:GetService "ReplicatedStorage"

local React = require(ReplicatedStorage.Packages.react)

local map_presets = require(ReplicatedStorage.Shared.map_presets)
local game_modes = require(ReplicatedStorage.Shared.game_modes)

local protocol = require(ReplicatedStorage.Lobby.protocol)

local map_panel = require(script.Parent.map_panel)
local settings_panel = require(script.Parent.settings_panel)
local seats_panel = require(script.Parent.seats_panel)
local controls = require(script.Parent.controls)

type LobbyView = protocol.LobbyView

local local_player = Players.LocalPlayer

-- Why the lobby cannot start, or a warning worth showing beside the start button even though it can.
local function status_of(lobby: LobbyView, is_host: boolean): (string, boolean)
	if lobby.teleporting then
		return "Teleporting to the game...", false
	end
	if lobby.starting then
		return "Reserving a server...", false
	end
	if lobby.blocked ~= nil then
		return lobby.blocked, true
	end
	-- in a co-op mission everyone starts where the mission says, however many starts its map has
	local mode = game_modes.get(lobby.match.mode)
	local map = map_presets.presets[lobby.match.preset]
	if mode ~= nil and mode.mission == nil and map ~= nil then
		local starts = #map.starts
		local players = game_modes.player_count(lobby.match.seats)
		if players > starts then
			return `{players} players on a map with {starts} starts: some will share`, true
		end
	end
	if is_host then
		return "Ready", false
	end
	return "Waiting for the host to start", false
end

local function Room(props: {
	lobby: LobbyView,
	act: (action: protocol.Action, argument: any?) -> (),
})
	local lobby = props.lobby
	local mode = game_modes.get(lobby.match.mode)
	local is_host = lobby.host == local_player.UserId
	local status, warning = status_of(lobby, is_host)
	local can_start = is_host and lobby.blocked == nil and lobby.starting == false
	-- whether this is a player who is not the host, who has to say they are ready
	local must_ready = false
	for _, seat in lobby.match.seats do
		if seat.user_id == local_player.UserId and is_host == false and seat.side ~= game_modes.SPECTATOR_SIDE then
			must_ready = true
		end
	end
	local ready = table.find(lobby.ready, local_player.UserId) ~= nil

	return React.createElement("Frame", {
		[React.Tag] = "room",
	}, {
		Map = React.createElement(map_panel.MapPanel, {
			preset = lobby.match.preset,
			seed = lobby.match.seed,
			is_host = is_host,
			fixed = mode ~= nil and mode.mission ~= nil,
			players = game_modes.player_count(lobby.match.seats),
			act = props.act,
		}),
		Side = React.createElement("Frame", {
			[React.Tag] = "room-side",
			LayoutOrder = 2,
		}, {
			Settings = React.createElement(settings_panel.SettingsPanel, {
				mode = lobby.match.mode,
				visibility = lobby.visibility,
				ally_griefing = lobby.match.ally_griefing,
				end_mode = lobby.match.end_mode,
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
						props.act "leave"
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
							props.act "start"
						end,
						LayoutOrder = 3,
					})
					elseif must_ready then React.createElement(controls.Button, {
						kind = "button",
						tag = if ready then nil else "primary",
						label = if ready then "Not ready" else "Ready",
						locked = lobby.starting,
						on_press = function()
							props.act("set_ready", not ready)
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
