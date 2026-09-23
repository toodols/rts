-- Getting the game started (see shared/game_phase.luau). While it is waiting nothing steps: each player's client
-- says when it has loaded, and each player chooses a start among the map's, one to a player. With every player loaded
-- and on a start it counts down, and when the countdown is out every team's commander is put on its start and the game
-- is playing. Someone arriving, or leaving the rest all ready, is taken account of whenever it happens; during the
-- countdown, anyone not ready sends it back to waiting. A player arriving once the game is playing is given the first
-- start nobody has and their commander at once.
--
-- A session nobody plays in, a Studio test or Run, skips all of it and plays from the start.

local Players = game:GetService "Players"
local ReplicatedStorage = game:GetService "ReplicatedStorage"
local Workspace = game:GetService "Workspace"

local config = require(ReplicatedStorage.Shared.config)
local game_phase = require(ReplicatedStorage.Shared.game_phase)
local starts = require(ReplicatedStorage.Shared.starts)

local players = require(script.Parent.players)
local spawning = require(script.Parent.spawning)

local client_loaded: RemoteEvent = ReplicatedStorage.Shared.ClientLoaded
local choose_start: RemoteEvent = ReplicatedStorage.Shared.ChooseStart

-- The player on each start, by slot.
local function taken(): { [number]: Player }
	local by_slot = {}
	for _, player in Players:GetPlayers() do
		local slot = game_phase.start_of(player)
		if slot ~= nil then
			by_slot[slot] = player
		end
	end
	return by_slot
end

local function is_ready(player: Player): boolean
	return game_phase.is_loaded(player) and game_phase.start_of(player) ~= nil
end

-- Puts `player`'s team's commander on the start they chose.
local function spawn(player: Player)
	local team_id = players.team_of(player)
	local slot = game_phase.start_of(player)
	if team_id == nil or slot == nil then
		return
	end
	spawning.set_start(team_id, slot)
	spawning.give_starting_force(team_id)
end

local function start()
	game_phase.set_phase("playing", nil)
	for _, player in Players:GetPlayers() do
		spawn(player)
	end
end

-- Moves between waiting and counting down as players become ready or stop being, once there is anyone at all.
-- `leaving` is a player on their way out, who no longer counts.
local function evaluate(leaving: Player?)
	local phase = game_phase.phase()
	if phase == "playing" then
		return
	end
	local count = 0
	local ready = true
	for _, player in Players:GetPlayers() do
		if player == leaving then
			continue
		end
		count += 1
		if is_ready(player) == false then
			ready = false
		end
	end
	ready = ready and count > 0
	if ready and phase == "waiting" then
		game_phase.set_phase("countdown", Workspace:GetServerTimeNow() + config.START_COUNTDOWN_SECONDS)
	elseif ready == false and phase == "countdown" then
		game_phase.set_phase("waiting", nil)
	end
end

local function on_choose(player: Player, slot: unknown)
	if game_phase.is_playing() then
		return
	end
	if typeof(slot) ~= "number" or slot ~= math.floor(slot) or slot < 1 or slot > starts.count() then
		return
	end
	local holder = taken()[slot]
	if holder ~= nil and holder ~= player then
		return
	end
	game_phase.set_start(player, slot)
	evaluate()
end

-- A player the game has begun without: they take the first start nobody has, or share the first if all are taken.
local function join_late(player: Player)
	if game_phase.start_of(player) == nil then
		local by_slot = taken()
		local slot = 1
		for candidate = 1, starts.count() do
			if by_slot[candidate] == nil then
				slot = candidate
				break
			end
		end
		game_phase.set_start(player, slot)
	end
	spawn(player)
end

-- Called once a player has been given a team.
local function player_added(player: Player)
	if game_phase.is_playing() then
		join_late(player)
		return
	end
	evaluate()
end

local function player_removing(player: Player)
	-- they are still in the list while this runs
	evaluate(player)
end

-- Counts the countdown out. Runs every frame, stepping or not.
local function tick()
	if game_phase.phase() ~= "countdown" then
		return
	end
	local ends = game_phase.countdown_ends()
	if ends ~= nil and Workspace:GetServerTimeNow() >= ends then
		start()
	end
end

-- `skip` plays from the start, for a session nobody plays in.
local function init(skip: boolean)
	game_phase.set_phase(if skip then "playing" else "waiting", nil)
	client_loaded.OnServerEvent:Connect(function(player: Player)
		game_phase.set_loaded(player)
		evaluate()
	end)
	choose_start.OnServerEvent:Connect(on_choose)
end

return table.freeze({
	init = init,
	tick = tick,
	player_added = player_added,
	player_removing = player_removing,
})
