-- Getting the game started (see shared/game_phase.luau). While it is waiting nothing steps: each player's client
-- says when it has loaded, and each player chooses where to start by clicking in their team's start box (`starts`),
-- which puts them on the nearest ground there that a team can start on. With every player loaded and a start chosen
-- it counts down, and when the countdown is out every team's commander is put where its player chose and the game is
-- playing. Someone arriving, or leaving the rest all ready, is taken account of whenever it happens; during the
-- countdown, anyone not ready sends it back to waiting. A player arriving once the game is playing starts in their box
-- at once, where the box's usual start is.
--
-- A team's box is its side's: allied teams share one, as BAR's ally teams do, and the sides take the boxes in order of
-- their lowest team, so a match's first side (see match.luau) has the first box. A player's box can change while the
-- game is waiting, as others arrive and leave; a start chosen in the old box is dropped, to be chosen again.
--
-- Players who share a team (pow's team_join) share its start too: whichever of them chooses chooses for all of them,
-- and the team gets one commander there.
--
-- In a campaign mission there is nothing to choose: the player's start is the mission's (missions.player_start), set
-- as they arrive, so the game waits only for their client to load.
--
-- A session nobody plays in, a Studio test or Run, skips all of it and plays from the start.

local Players = game:GetService "Players"
local ReplicatedStorage = game:GetService "ReplicatedStorage"
local Workspace = game:GetService "Workspace"

local types = require(ReplicatedStorage.Shared.types)
local config = require(ReplicatedStorage.Shared.config)
local game_phase = require(ReplicatedStorage.Shared.game_phase)
local heightmap = require(ReplicatedStorage.Shared.heightmap)
local starts = require(ReplicatedStorage.Shared.starts)

local players = require(script.Parent.players)
local spawning = require(script.Parent.spawning)
local alliances = require(script.Parent.alliances)
local match = require(script.Parent.match)
local missions = require(script.Parent.missions)

type TeamId = types.TeamId

local client_loaded: RemoteEvent = ReplicatedStorage.Shared.ClientLoaded
local choose_start: RemoteEvent = ReplicatedStorage.Shared.ChooseStart

local function is_ready(player: Player): boolean
	return game_phase.is_loaded(player) and game_phase.start_of(player) ~= nil
end

-- Gives every player here, but `leaving`, the start box of their side: every team a match seated counts, so that its
-- sides keep their boxes while their players are still arriving. A start no longer in its player's box is dropped.
local function assign_boxes(leaving: Player?)
	local teams: { [TeamId]: boolean } = {}
	for team_id = 1, match.seated_count() do
		teams[team_id] = true
	end
	for _, player in Players:GetPlayers() do
		local team_id = players.team_of(player)
		if player ~= leaving and team_id ~= nil then
			teams[team_id] = true
		end
	end
	-- each side by the lowest team on it, and the sides in that order
	local lowest_of_side: { [TeamId]: TeamId } = {}
	for team_id in teams do
		local root = alliances.root_of(team_id)
		local lowest = lowest_of_side[root]
		if lowest == nil or team_id < lowest then
			lowest_of_side[root] = team_id
		end
	end
	local order: { TeamId } = {}
	for _, lowest in lowest_of_side do
		table.insert(order, lowest)
	end
	table.sort(order)

	for _, player in Players:GetPlayers() do
		local team_id = players.team_of(player)
		if player == leaving or team_id == nil then
			continue
		end
		local side = table.find(order, lowest_of_side[alliances.root_of(team_id)]) :: number
		local index = (side - 1) % starts.box_count() + 1
		game_phase.set_box(player, index)
		local chosen = game_phase.start_of(player)
		if chosen ~= nil and starts.in_box(index, chosen.X, chosen.Z) == false then
			game_phase.set_start(player, nil)
		end
	end
end

-- Puts `player`'s team's commander where they chose to start, unless a teammate's already stands.
local function spawn(player: Player)
	local team_id = players.team_of(player)
	local chosen = game_phase.start_of(player)
	if team_id == nil or chosen == nil or spawning.owns_anything(team_id) then
		return
	end
	spawning.set_start(team_id, Vector2.new(chosen.X, chosen.Z))
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
	if game_phase.has_begun() then
		return
	end
	local phase = game_phase.phase()
	local count = 0
	local ready = true
	for _, player in Players:GetPlayers() do
		-- a spectator has no team, and nothing to be ready for
		if player == leaving or players.team_of(player) == nil then
			continue
		end
		count += 1
		if is_ready(player) == false then
			ready = false
		end
	end
	-- a game a lobby started also waits for everyone it sent (see match.luau)
	ready = ready and count > 0 and match.is_awaiting() == false
	if ready and phase == "waiting" then
		game_phase.set_phase("countdown", Workspace:GetServerTimeNow() + config.START_COUNTDOWN_SECONDS)
	elseif ready == false and phase == "countdown" then
		game_phase.set_phase("waiting", nil)
	end
end

-- A click in the player's own box starts them at the ground nearest it there that a team can start on.
local function on_choose(player: Player, position: unknown)
	if game_phase.has_begun() or typeof(position) ~= "Vector3" then
		return
	end
	-- a campaign mission says where its player starts
	if missions.player_start() ~= nil then
		return
	end
	local index = game_phase.box_of(player)
	if index == nil or starts.in_box(index, position.X, position.Z) == false then
		return
	end
	local spot = starts.nearest_start(index, position.X, position.Z)
	if spot == nil then
		return
	end
	local start = heightmap.ground_position(spot.X, spot.Y)
	for _, teammate in players.players_on_team(players.team_of(player) :: TeamId) do
		game_phase.set_start(teammate, start)
	end
	evaluate()
end

-- A player the game has begun without starts where their box's usual start is, unless they chose already.
local function join_late(player: Player)
	assign_boxes()
	local index = game_phase.box_of(player)
	if game_phase.start_of(player) == nil and index ~= nil then
		local spot = starts.default_spot(index)
		game_phase.set_start(player, heightmap.ground_position(spot.X, spot.Y))
	end
	spawn(player)
end

-- Where a teammate of `player`'s has chosen to start, if any has.
local function teammate_start(player: Player): Vector3?
	local team_id = players.team_of(player)
	if team_id == nil then
		return nil
	end
	for _, teammate in players.players_on_team(team_id) do
		local chosen = game_phase.start_of(teammate)
		if teammate ~= player and chosen ~= nil then
			return chosen
		end
	end
	return nil
end

-- Called once `player` has been moved to another team: they take its start, or choose one if nobody on it has. Once
-- the game is playing, a team that has nothing yet gets its commander where its box's usual start is.
local function team_changed(player: Player)
	if game_phase.phase() == "ended" then
		return
	end
	game_phase.set_start(player, teammate_start(player))
	if game_phase.is_playing() then
		join_late(player)
		return
	end
	assign_boxes()
	evaluate()
end

-- A new map, while the game is playing: nobody has chosen anywhere on it, so every player starts where their box's usual
-- start is, or where the campaign mission being played says. Called once it is built, before the commanders go down.
local function restart_on_new_map()
	assign_boxes()
	local mission_start = missions.player_start()
	for _, player in Players:GetPlayers() do
		local index = game_phase.box_of(player)
		local team_id = players.team_of(player)
		if index == nil or team_id == nil then
			continue
		end
		local spot = if mission_start ~= nil then mission_start else starts.default_spot(index)
		game_phase.set_start(player, heightmap.ground_position(spot.X, spot.Y))
		spawning.set_start(team_id, spot)
	end
end

-- Called once a player has been given a team.
local function player_added(player: Player)
	-- someone arriving once it is over has nothing to join
	if game_phase.phase() == "ended" then
		return
	end
	-- in a campaign mission they start where it says, and have nothing to choose: only their client to load
	local mission_start = missions.player_start()
	if mission_start ~= nil and players.team_of(player) ~= nil and game_phase.start_of(player) == nil then
		game_phase.set_start(player, heightmap.ground_position(mission_start.X, mission_start.Y))
	end
	if game_phase.is_playing() then
		join_late(player)
		return
	end
	assign_boxes()
	evaluate()
end

local function player_removing(player: Player)
	-- they are still in the list while this runs
	if game_phase.has_begun() == false then
		assign_boxes(player)
	end
	evaluate(player)
end

-- Counts the countdown out, and while waiting keeps who is still on their way up to date: someone arriving, or the
-- wait for them running out, can be what makes everyone ready. Runs every frame, stepping or not.
local function tick()
	local phase = game_phase.phase()
	if phase == "waiting" then
		if match.update() then
			evaluate()
		end
		return
	end
	if phase ~= "countdown" then
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
	team_changed = team_changed,
	restart_on_new_map = restart_on_new_map,
})
