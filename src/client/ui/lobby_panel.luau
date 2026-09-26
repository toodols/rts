-- The panel over the middle of the screen while the game is waiting to begin (see shared/game_phase.luau): what it is
-- waiting for, or the countdown once everyone is ready, and every player with how far along they are: still on their
-- way from the lobby that started the game, loading, choosing where in their start area to start, or ready. It is gone
-- once the game is playing. A campaign mission, whose player starts where it says (Shared.campaign), begins as soon as
-- they have loaded, so then it shows only while someone is still on their way.

local Players = game:GetService "Players"
local ReplicatedStorage = game:GetService "ReplicatedStorage"
local RunService = game:GetService "RunService"
local Workspace = game:GetService "Workspace"

local React = require(ReplicatedStorage.Packages.react)

local game_phase = require(ReplicatedStorage.Shared.game_phase)
local mission_state = require(ReplicatedStorage.Shared.mission_state)
local seating = require(ReplicatedStorage.Shared.seating)

local format = require(ReplicatedStorage.ClientShared.format)
local use_store = require(ReplicatedStorage.ClientShared.use_store)

local local_player = Players.LocalPlayer

type Row = {
	name: string,
	status: string,
	ready: boolean,
	you: boolean,
}

local function rows(): { Row }
	local result: { Row } = {}
	for _, player in Players:GetPlayers() do
		-- someone who came only to watch has nothing to choose, and nobody waits on them
		if seating.is_spectator(player) then
			table.insert(
				result,
				{ name = player.DisplayName, status = "WATCHING", ready = true, you = player == local_player }
			)
			continue
		end
		local chosen = game_phase.start_of(player)
		local loaded = game_phase.is_loaded(player)
		table.insert(result, {
			name = player.DisplayName,
			status = if loaded == false then "LOADING" elseif chosen == nil then "CHOOSING" else "READY",
			ready = loaded and chosen ~= nil,
			you = player == local_player,
		})
	end
	-- the players a lobby sent who are still on their way
	for _, name in game_phase.awaiting() do
		table.insert(result, { name = name, status = "ARRIVING", ready = false, you = false })
	end
	table.sort(result, function(a: Row, b: Row): boolean
		return a.name < b.name
	end)
	return result
end

-- Whole seconds left on the countdown, rounded up, or nil while there is none.
local function seconds_left(): number?
	local ends = game_phase.countdown_ends()
	if game_phase.phase() ~= "countdown" or ends == nil then
		return nil
	end
	return math.max(0, math.ceil(ends - Workspace:GetServerTimeNow()))
end

-- Redraws whenever anything the panel shows may have changed: the phase, a player arriving or leaving, loading or
-- choosing a start, and each second of the countdown.
local function use_lobby(): (game_phase.Phase, number?, { Row })
	use_store.use_changes(function(redraw: () -> ()): () -> ()
		local connections: { RBXScriptConnection } = {}
		local stops = { game_phase.changed(redraw), mission_state.subscribe_mission(redraw) }
		local function watch(player: Player)
			table.insert(stops, game_phase.start_changed(player, redraw))
			table.insert(stops, game_phase.loaded_changed(player, redraw))
		end
		for _, player in Players:GetPlayers() do
			watch(player)
		end
		table.insert(
			connections,
			Players.PlayerAdded:Connect(function(player: Player)
				watch(player)
				redraw()
			end)
		)
		table.insert(
			connections,
			Players.PlayerRemoving:Connect(function()
				task.defer(redraw)
			end)
		)
		local shown = seconds_left()
		table.insert(
			connections,
			RunService.Heartbeat:Connect(function()
				local now = seconds_left()
				if now ~= shown then
					shown = now
					redraw()
				end
			end)
		)
		return function()
			for _, connection in connections do
				connection:Disconnect()
			end
			for _, stop in stops do
				stop()
			end
		end
	end)

	return game_phase.phase(), seconds_left(), rows()
end

local function LobbyPanel()
	local phase, seconds, players = use_lobby()
	if phase == "playing" or phase == "ended" then
		return nil
	end
	if mission_state.mission() ~= nil and #game_phase.awaiting() == 0 then
		return nil
	end

	local mine = game_phase.start_of(local_player)
	local title = if seconds ~= nil then `STARTING IN {seconds}` else "WAITING FOR PLAYERS"
	local hint = if seconds ~= nil
		then "Click to move your start"
		elseif seating.is_spectator(local_player) then "Spectating"
		elseif mine == nil then "Pick a start in your area"
		elseif #game_phase.awaiting() > 0 then "Waiting for players"
		else "Waiting for players"

	local list = {}
	for index, row in players do
		list[`Player{index}`] = React.createElement("Frame", {
			[React.Tag] = if row.ready then "lobby-row ready" else "lobby-row",
			LayoutOrder = index,
		}, {
			Name = React.createElement("TextLabel", {
				[React.Tag] = if row.you then "lobby-name you grow" else "lobby-name grow",
				LayoutOrder = 1,
				Text = format.escape(row.name),
			}),
			Status = React.createElement("TextLabel", {
				[React.Tag] = "lobby-status",
				LayoutOrder = 2,
				Text = row.status,
			}),
		})
	end

	return React.createElement("Frame", {
		[React.Tag] = if seconds ~= nil then "lobby-panel counting" else "lobby-panel",
	}, {
		Title = React.createElement("TextLabel", {
			[React.Tag] = "lobby-title",
			LayoutOrder = 1,
			Text = title,
		}),
		Hint = React.createElement("TextLabel", {
			[React.Tag] = "lobby-hint",
			LayoutOrder = 2,
			Text = hint,
		}),
		List = React.createElement("Frame", {
			[React.Tag] = "lobby-list",
			LayoutOrder = 3,
		}, list),
	})
end

return table.freeze({
	LobbyPanel = LobbyPanel,
})
