-- Getting the game started (see shared/game_phase.luau), and starting it over on a new map. While it is waiting nothing steps: each player's client
-- says when it has loaded, and each player chooses where to start by clicking in their team's start box (`starts`),
-- which puts them where they clicked, or if their commander cannot stand there, on the nearest ground there that a team
-- can start on. With every player loaded and a start chosen
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
-- How players start is the start policy (`policy`): where they choose in their box, as above, or, in a campaign mission,
-- where the mission says (missions.player_start), set as they arrive, so the game waits only for their client to load,
-- and then plays at once, without a countdown.
--
-- A new map (maps.luau's `built` stage, `start_over`): nobody has chosen anywhere on it, so every player starts where the
-- policy puts them on it and gets a new starting force there, the AI's teams after them (their own stage), and a game
-- that had ended plays again.
--
-- A session nobody plays in, a Studio test or Run, skips all of it and plays from the start.

local Players = game:GetService "Players"
local ReplicatedStorage = game:GetService "ReplicatedStorage"
local ServerScriptService = game:GetService "ServerScriptService"
local Workspace = game:GetService "Workspace"

local types = require(ReplicatedStorage.Shared.types)
local game_phase = require(ReplicatedStorage.Shared.game_phase)
local heightmap = require(ReplicatedStorage.Shared.heightmap)
local starts = require(ReplicatedStorage.Shared.starts)
local decode = require(ReplicatedStorage.Shared.decode)

local remotes = require(ServerScriptService.ServerShared.remotes)

local players = require(script.Parent.players)
local spawning = require(script.Parent.spawning)
local alliances = require(script.Parent.alliances)
local match = require(script.Parent.match)
local missions = require(script.Parent.missions)

type TeamId = types.TeamId

-- How the players start: `chosen`, each where they choose in their box, the game counting down once all have; or
-- where the game says, which `spot_in` gives for each box, playing as soon as they have loaded in.
type Policy = {
	chosen: boolean,
	spot_in: (box: number) -> Vector2,
}

local client_loaded: RemoteEvent = ReplicatedStorage.Shared.ClientLoaded
local choose_start: RemoteEvent = ReplicatedStorage.Shared.ChooseStart

-- A client says once that it has loaded; a start is chosen with a click.
-- Once every player has loaded in and chosen a start, the game starts after this many seconds.
local START_COUNTDOWN_SECONDS = 3
local LOADED_RATE: remotes.Rate = { per_second = 1, burst = 2 }
local CHOOSE_RATE: remotes.Rate = { per_second = 10, burst = 10 }

local CHOSEN: Policy = table.freeze({ chosen = true, spot_in = starts.default_spot })

-- The start policy of the game being played: a campaign mission's own start, or else each player's choice, the box's
-- usual start standing in for anyone who has not chosen.
local function policy(): Policy
	local fixed = missions.player_start()
	if fixed == nil then
		return CHOSEN
	end
	return {
		chosen = false,
		spot_in = function(): Vector2
			return fixed
		end,
	}
end

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
	-- with nobody's start to choose there is nothing to count down for: the game begins at once
	if ready and policy().chosen == false then
		start()
	elseif ready and phase == "waiting" then
		game_phase.set_phase("countdown", Workspace:GetServerTimeNow() + START_COUNTDOWN_SECONDS)
	elseif ready == false and phase == "countdown" then
		game_phase.set_phase("waiting", nil)
	end
end

-- A click in the player's own box starts them right there, if their commander can stand there, or else at the ground
-- nearest it there that a team can start on.
local function on_choose(player: Player, position: Vector3)
	if game_phase.has_begun() then
		return
	end
	if policy().chosen == false then
		return
	end
	local index = game_phase.box_of(player)
	if index == nil or starts.in_box(index, position.X, position.Z) == false then
		return
	end
	local spot = if spawning.can_start_at(position.X, position.Z)
		then Vector2.new(position.X, position.Z)
		else starts.nearest_start(index, position.X, position.Z)
	if spot == nil then
		return
	end
	local chosen = heightmap.ground_position(spot.X, spot.Y)
	for _, teammate in players.players_on_team(players.team_of(player) :: TeamId) do
		game_phase.set_start(teammate, chosen)
	end
	evaluate()
end

-- A player the game has begun without starts where the policy puts them in their box, unless they chose already.
local function join_late(player: Player)
	assign_boxes()
	local index = game_phase.box_of(player)
	if game_phase.start_of(player) == nil and index ~= nil then
		local spot = policy().spot_in(index)
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

-- A new map is a new game: every player starts where the policy puts them on it, each team once however many players
-- share it, and one that had ended plays again.
local function start_over()
	if game_phase.phase() == "ended" then
		game_phase.set_phase("playing", nil)
	end
	assign_boxes()
	local placing = policy()
	for _, player in Players:GetPlayers() do
		local index = game_phase.box_of(player)
		local team_id = players.team_of(player)
		if index == nil or team_id == nil then
			continue
		end
		local spot = placing.spot_in(index)
		game_phase.set_start(player, heightmap.ground_position(spot.X, spot.Y))
		spawning.set_start(team_id, spot)
	end
	for _, player in Players:GetPlayers() do
		local team_id = players.team_of(player)
		if team_id ~= nil and spawning.owns_anything(team_id) == false then
			spawning.give_starting_force(team_id)
		end
	end
end

-- Called once a player has been given a team.
local function player_added(player: Player)
	-- someone arriving once it is over has nothing to join
	if game_phase.phase() == "ended" then
		return
	end
	if game_phase.is_playing() then
		join_late(player)
		return
	end
	assign_boxes()
	-- with no start to choose they start where the policy puts them, and have only their client to load
	local placing = policy()
	local index = game_phase.box_of(player)
	if placing.chosen == false and index ~= nil and game_phase.start_of(player) == nil then
		local spot = placing.spot_in(index)
		game_phase.set_start(player, heightmap.ground_position(spot.X, spot.Y))
	end
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
	remotes.listen(client_loaded, { args = {}, rate = LOADED_RATE }, function(player: Player)
		game_phase.set_loaded(player)
		evaluate()
	end)
	remotes.listen(choose_start, { args = { decode.vector }, rate = CHOOSE_RATE }, on_choose)
end

return table.freeze({
	init = init,
	tick = tick,
	player_added = player_added,
	player_removing = player_removing,
	team_changed = team_changed,
	start_over = start_over,
})
