-- The panel over the middle of the screen while the game is waiting to begin (see shared/game_phase.luau): what it is
-- waiting for, or the countdown once everyone is ready, and every player with how far along they are, still loading,
-- choosing a start, or on the one they chose. It is gone once the game is playing.

local Players = game:GetService "Players"
local ReplicatedStorage = game:GetService "ReplicatedStorage"
local RunService = game:GetService "RunService"
local Workspace = game:GetService "Workspace"

local React = require(ReplicatedStorage.Packages.react)

local game_phase = require(ReplicatedStorage.Shared.game_phase)

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
		local slot = game_phase.start_of(player)
		local loaded = game_phase.is_loaded(player)
		table.insert(result, {
			name = player.DisplayName,
			status = if loaded == false then "LOADING" elseif slot == nil then "CHOOSING" else `START {slot}`,
			ready = loaded and slot ~= nil,
			you = player == local_player,
		})
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
	local _, bump = React.useState(0)
	local function redraw()
		bump(function(count: number): number
			return count + 1
		end)
	end

	React.useEffect(function()
		local connections: { RBXScriptConnection } = game_phase.changed(redraw)
		local function watch(player: Player)
			table.insert(connections, player:GetAttributeChangedSignal(game_phase.START_ATTRIBUTE):Connect(redraw))
			table.insert(connections, player:GetAttributeChangedSignal(game_phase.LOADED_ATTRIBUTE):Connect(redraw))
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
		end
	end, {})

	return game_phase.phase(), seconds_left(), rows()
end

local function LobbyPanel()
	local phase, seconds, players = use_lobby()
	if phase == "playing" then
		return nil
	end

	local mine = game_phase.start_of(local_player)
	local title = if seconds ~= nil then `STARTING IN {seconds}` else "WAITING FOR PLAYERS"
	local hint = if seconds ~= nil
		then "Click another start to move"
		elseif mine == nil then "Click a start on the map to choose it"
		else "Waiting for everyone to load and choose a start"

	local list = {}
	for index, row in players do
		list[`Player{index}`] = React.createElement("Frame", {
			[React.Tag] = if row.ready then "lobby-row ready" else "lobby-row",
			LayoutOrder = index,
		}, {
			Name = React.createElement("TextLabel", {
				[React.Tag] = if row.you then "lobby-name you grow" else "lobby-name grow",
				LayoutOrder = 1,
				Text = row.name,
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
