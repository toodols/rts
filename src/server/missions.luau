-- The campaign's missions, as the game server plays them (see shared/campaign.luau). A campaign match (game_modes, kind
-- "campaign") names its mission, which match.luau publishes as Workspace's campaign.MISSION_ATTRIBUTE; once the map is
-- built, `setup` puts down what the mission starts with. The player has no start to choose: their commander goes down
-- at the mission's start (`player_start`, which lobby.luau uses) once their client has loaded, and that is all they
-- get, as in any game.
--
-- The tutorial (campaign.TUTORIAL, on the "tutorial" map): the boulder (`tutorial_boulder`, team 0) in the pass, a wall
-- until it is disintegrated (see obstacles.luau and combat's DGUN_ONLY), and on the far side an enemy team of its own,
-- with nobody playing it and no AI, which only stands there: a bot lab, two solar collectors, four grunts, and a metal
-- extractor on each of the metal spots on its side of the pass.
--
-- The overlook (campaign.OVERLOOK, on the "overlook" map): the player's commander on the plateau, and below its cliff an
-- enemy of the same kind, which only stands there: twenty things (OVERLOOK_ENEMY, and an extractor on each of its two
-- metal spots), half of them within reach of a thug at the cliff's edge and half beyond it. Its energy storage starts
-- full, so that its guards have the energy to fire for some time.
--
-- A mission with an enemy is won when the enemy has nothing left: no unit and no building, finished or not (a wreck is
-- nobody's). The game then ends in victory for every other team (game_phase.set_ended, as the scavengers' boss ends
-- it), and each player on a winning team has the mission marked complete, saved and its unlocks published
-- (server/campaign.luau). It is lost the other way round: when every team with a player on it has had something on the
-- field and has nothing left, the enemy wins. Neither is looked at before the enemy is on the field, or once the game
-- has ended. The end screen then offers to go back to the lobby or on to the next mission (campaign_exit.luau).
--
-- What a client may want is published on Workspace: `campaign_enemy_team`, the enemy's team id, and `campaign_boulder`,
-- the boulder's entity id (its model is in Workspace.Entities like everything else's), cleared when it is gone.
--
-- Playing a mission in Studio without the lobby: set a string attribute `CampaignMission` on Workspace to a mission's id
-- ("tutorial") before starting a playtest, and the server starts as though a lobby had started that mission's match
-- (on its map, whatever init.server.luau's MAP_PRESET says), seating whoever joins first on the player's team. A Studio
-- test session ignores it; hand the match in instead (`{ test = "match", match = { mode = "campaign_tutorial", ... } }`).

local ReplicatedStorage = game:GetService "ReplicatedStorage"
local Players = game:GetService "Players"
local Workspace = game:GetService "Workspace"

local types = require(ReplicatedStorage.Shared.types)
local config = require(ReplicatedStorage.Shared.config)
local campaign = require(ReplicatedStorage.Shared.campaign)
local heightmap = require(ReplicatedStorage.Shared.heightmap)
local metal_spots = require(ReplicatedStorage.Shared.metal_spots)
local game_phase = require(ReplicatedStorage.Shared.game_phase)

local state = require(script.Parent.state)
local players = require(script.Parent.players)
local spawning = require(script.Parent.spawning)
local placement = require(script.Parent.placement)
local obstacles = require(script.Parent.obstacles)
local server_campaign = require(script.Parent.campaign)

type Entity = types.Entity
type TeamId = types.TeamId

export type Outcome = "won" | "lost"

local ENEMY_TEAM_ATTRIBUTE = "campaign_enemy_team"
local BOULDER_ATTRIBUTE = "campaign_boulder"
local STUDIO_ATTRIBUTE = "CampaignMission"

local BOULDER_DEF = "tutorial_boulder"
-- Turned a quarter turn, so that its long side is across the pass, which runs east to west.
local BOULDER_FACING = math.pi / 2

-- The overlook's enemy, facing west, at the plateau. What is out in front stands `from_edge` studs east of wherever the
-- cliff's edge is at its z (campaign.overlook_edge_at), since the edge wanders: a guard reaches 39.5 studs and a thug
-- at the edge about 55 from that height, so 45 out is out of a guard's reach of the edge and well within a thug's.
-- That is half of it: the front line of guards, two solar collectors and some grunts at the foot of the cliff. The rest
-- stands where `at` says, in world (x, z), beyond a thug's reach of the edge: a guard at the foot of each ramp, a second
-- line, and the base, for the ramps or aggravators.
local OVERLOOK_ENEMY: { { def_name: string, at: Vector2, from_edge: number? } } = {
	-- in reach from the edge
	{ def_name = "guard", at = Vector2.new(0, -40), from_edge = 45 },
	{ def_name = "guard", at = Vector2.new(0, -14), from_edge = 45 },
	{ def_name = "guard", at = Vector2.new(0, 14), from_edge = 45 },
	{ def_name = "guard", at = Vector2.new(0, 40), from_edge = 45 },
	{ def_name = "solar_collector", at = Vector2.new(0, -27), from_edge = 49 },
	{ def_name = "solar_collector", at = Vector2.new(0, 27), from_edge = 49 },
	{ def_name = "grunt", at = Vector2.new(0, -50), from_edge = 34 },
	{ def_name = "grunt", at = Vector2.new(0, -6), from_edge = 34 },
	{ def_name = "grunt", at = Vector2.new(0, 6), from_edge = 34 },
	{ def_name = "grunt", at = Vector2.new(0, 50), from_edge = 34 },
	-- beyond it: the feet of the ramps, the second line, and the base
	{ def_name = "guard", at = Vector2.new(46, -62), from_edge = nil },
	{ def_name = "guard", at = Vector2.new(46, 62), from_edge = nil },
	{ def_name = "guard", at = Vector2.new(56, -18), from_edge = nil },
	{ def_name = "guard", at = Vector2.new(56, 18), from_edge = nil },
	{ def_name = "bot_lab", at = Vector2.new(78, 0), from_edge = nil },
	{ def_name = "solar_collector", at = Vector2.new(92, -28), from_edge = nil },
	{ def_name = "solar_collector", at = Vector2.new(92, 28), from_edge = nil },
	{ def_name = "energy_storage", at = Vector2.new(100, 0), from_edge = nil },
}
-- Enough energy to fill whatever the overlook's enemy can store.
local OVERLOOK_ENERGY = 1e6

-- The tutorial's enemy, from its start: what, and where, in studs east and north of it. They face west, at the player.
local TUTORIAL_ENEMY: { { def_name: string, offset: Vector2 } } = {
	{ def_name = "bot_lab", offset = Vector2.new(8, 0) },
	{ def_name = "solar_collector", offset = Vector2.new(24, -20) },
	{ def_name = "solar_collector", offset = Vector2.new(24, 20) },
	{ def_name = "grunt", offset = Vector2.new(-14, -18) },
	{ def_name = "grunt", offset = Vector2.new(-14, -6) },
	{ def_name = "grunt", offset = Vector2.new(-14, 6) },
	{ def_name = "grunt", offset = Vector2.new(-14, 18) },
}
local WEST = -math.pi / 2
local EXTRACTOR_DEF = "metal_extractor"

-- How the game ends, in the line everyone sees under the result.
local ENEMY_DESTROYED = "The enemy is destroyed"
local FORCES_DESTROYED = "Your forces are destroyed"
-- How often, in seconds of game, who has anything left is looked at.
local CHECK_SECONDS = 0.25

-- The team the mission's enemy plays as, once it has been put down.
local enemy_team: TeamId? = nil
-- Every team that has had something on the field since the mission began: only one that has can have lost it all.
local fielded: { [TeamId]: boolean } = {}
local check_timer = 0
-- How the mission ended, once it has.
local outcome: Outcome? = nil
-- The players the mission is being marked complete for, by user id: false while it saves, true once it has.
local completions: { [number]: boolean } = {}
-- The enemy team a mission played earlier in this game made, which the next one to have an enemy plays as again, so
-- that loading missions one after another (`begin`) does not leave an empty team behind for each.
local made_enemy: TeamId? = nil

-- Puts the boulder down with its middle at `at`, belonging to nobody, and makes it a wall.
local function place_boulder(at: Vector2): Entity
	local center = placement.ground_center(BOULDER_DEF, at.X, at.Y)
	local boulder = state.create_entity(BOULDER_DEF, 0, center, BOULDER_FACING, "active")
	state.flush()
	obstacles.add(boulder)
	Workspace:SetAttribute(BOULDER_ATTRIBUTE, boulder.id)
	return boulder
end

-- A finished extractor of `team_id` on every metal spot east of `east_of`, each on the spot as one built there would be.
local function place_extractors(team_id: TeamId, east_of: number)
	for _, spot in metal_spots.all() do
		if spot.center.X <= east_of then
			continue
		end
		local center = placement.resolve_center(EXTRACTOR_DEF, spot.center.X, spot.center.Z, WEST, nil)
		if center == nil or placement.can_place(EXTRACTOR_DEF, center, WEST, nil) == false then
			warn(`the mission could not put its enemy's extractor on the spot at {spot.center}`)
			continue
		end
		state.create_entity(EXTRACTOR_DEF, team_id, center, WEST, "active")
		-- so that the next one sees this spot as taken
		state.flush()
	end
end

-- Makes the mission's enemy team, keeping the first team for the player whether or not they have arrived yet.
local function create_enemy(): TeamId
	players.reserve(1)
	local team_id = made_enemy
	if team_id == nil or state.get_team(team_id) == nil then
		team_id = players.create_team "Enemy"
		made_enemy = team_id
	else
		state.reset_team(team_id)
	end
	enemy_team = team_id
	Workspace:SetAttribute(ENEMY_TEAM_ATTRIBUTE, team_id)
	return team_id
end

local function setup_tutorial()
	local layout = campaign.TUTORIAL
	place_boulder(layout.chokepoint)

	local team_id = create_enemy()
	-- first, so that nothing else takes their spots
	place_extractors(team_id, layout.chokepoint.X)
	for _, each in TUTORIAL_ENEMY do
		local at = layout.enemy_start + each.offset
		local placed = spawning.spawn_near(each.def_name, team_id, heightmap.ground_position(at.X, at.Y), WEST)
		if placed == nil then
			warn(`the tutorial found no room for its enemy's {each.def_name}`)
		end
	end
end

local function setup_overlook()
	local team_id = create_enemy()
	-- first, so that nothing else takes their spots
	place_extractors(team_id, campaign.OVERLOOK.edge_x)
	for _, each in OVERLOOK_ENEMY do
		local x = if each.from_edge ~= nil then campaign.overlook_edge_at(each.at.Y) + each.from_edge else each.at.X
		local placed = spawning.spawn_near(each.def_name, team_id, heightmap.ground_position(x, each.at.Y), WEST)
		if placed == nil then
			warn(`the overlook found no room for its enemy's {each.def_name} at {each.at}`)
		end
	end
	-- it has built nothing, so its storages start as full as the economy lets them be
	local team = state.get_team(team_id)
	if team ~= nil then
		team.energy = OVERLOOK_ENERGY
	end
end

-- Puts down what the mission being played starts with, if one is. Called once the map is built.
local function setup()
	local mission = campaign.current_mission()
	if mission == "tutorial" then
		setup_tutorial()
	elseif mission == "overlook" then
		setup_overlook()
	end
end

-- Where the player's commander goes down in the mission being played, or nil when there is none: they have no start
-- to choose.
local function player_start(): Vector2?
	local mission = campaign.current_mission()
	if mission == "tutorial" then
		return campaign.TUTORIAL.player_start
	elseif mission == "overlook" then
		return campaign.OVERLOOK.player_start
	end
	return nil
end

-- The team the mission's enemy plays as, if it has one.
local function enemy(): TeamId?
	return enemy_team
end

-- How many units and buildings each team has on the field, those being carried included.
local function count_standing(): { [TeamId]: number }
	local counts: { [TeamId]: number } = {}
	local function count(entity: Entity)
		if entity.alive and (entity.kind == "unit" or entity.kind == "building") and entity.team ~= 0 then
			counts[entity.team] = (counts[entity.team] or 0) + 1
		end
	end
	for _, entity in state.all() do
		count(entity)
	end
	for _, entity in state.carried() do
		count(entity)
	end
	return counts
end

-- The teams the players here are on.
local function player_teams(): { [TeamId]: boolean }
	local teams: { [TeamId]: boolean } = {}
	for _, player in Players:GetPlayers() do
		local team_id = players.team_of(player)
		if team_id ~= nil then
			teams[team_id] = true
		end
	end
	return teams
end

-- Every team but the enemy (and the scavengers) has won, and the mission is complete for each player on one of them.
local function win(enemy_id: TeamId)
	local winning = player_teams()
	for team_id in state.all_teams() do
		winning[team_id] = true
	end
	winning[enemy_id] = nil
	winning[0] = nil
	winning[config.SCAVENGER_TEAM] = nil
	local winners: { TeamId } = {}
	for team_id in winning do
		table.insert(winners, team_id)
	end
	table.sort(winners)
	outcome = "won"
	game_phase.set_ended(winners, ENEMY_DESTROYED)

	local mission_id = campaign.current_mission()
	if mission_id == nil then
		return
	end
	for _, player in Players:GetPlayers() do
		local team_id = players.team_of(player)
		if team_id == nil or winning[team_id] ~= true then
			continue
		end
		local user_id = player.UserId
		completions[user_id] = false
		task.spawn(function()
			server_campaign.complete(player, mission_id)
			completions[user_id] = true
		end)
	end
end

local function lose(enemy_id: TeamId)
	outcome = "lost"
	game_phase.set_ended({ enemy_id }, FORCES_DESTROYED)
end

-- Ends the mission once one side has nothing left. Called at the end of every step, once its dead are gone.
local function tick(delta: number)
	local enemy_id = enemy_team
	if enemy_id == nil or outcome ~= nil or game_phase.phase() == "ended" then
		return
	end
	check_timer += delta
	if check_timer < CHECK_SECONDS then
		return
	end
	check_timer = 0
	local standing = count_standing()
	for team_id in standing do
		fielded[team_id] = true
	end
	if fielded[enemy_id] == true and standing[enemy_id] == nil then
		win(enemy_id)
		return
	end
	-- the players have lost when every team of theirs has been on the field and none of them is any more
	local any_team = false
	for team_id in player_teams() do
		if team_id == enemy_id then
			continue
		end
		if fielded[team_id] ~= true or standing[team_id] ~= nil then
			return
		end
		any_team = true
	end
	if any_team then
		lose(enemy_id)
	end
end

-- How the mission being played ended, once it has.
local function result(): Outcome?
	return outcome
end

-- Whether `player` may be sent on without losing their finishing the mission: it has been saved, or was never to be.
local function is_settled(player: Player): boolean
	return completions[player.UserId] ~= false
end

-- Whether the mission was marked complete for the player `user_id`, saved or not yet.
local function was_completed_for(user_id: number): boolean
	return completions[user_id] ~= nil
end

-- The mission Studio was asked to play without the lobby (STUDIO_ATTRIBUTE), if it is one.
local function studio_mission(): string?
	local value = Workspace:GetAttribute(STUDIO_ATTRIBUTE)
	if typeof(value) ~= "string" or campaign.get(value) == nil then
		return nil
	end
	return value
end

-- Makes `mission_id` the mission being played, or none for nil, forgetting everything about the one before: its enemy,
-- how it ended, and whom it was completed for. Call it before the mission's map is loaded, so that the players start
-- where the mission says (lobby.restart_on_new_map), and `setup` once it has been. The attribute is cleared before it is
-- set, so that a client sees the mission begin again even when it is the same one (the tutorial starts over).
local function begin(mission_id: string?)
	enemy_team = nil
	table.clear(fielded)
	check_timer = 0
	outcome = nil
	table.clear(completions)
	Workspace:SetAttribute(ENEMY_TEAM_ATTRIBUTE, nil)
	Workspace:SetAttribute(BOULDER_ATTRIBUTE, nil)
	Workspace:SetAttribute(campaign.MISSION_ATTRIBUTE, nil)
	Workspace:SetAttribute(campaign.MISSION_ATTRIBUTE, mission_id)
end

-- The boulder is gone: nothing to point at any more.
local function forget(id: types.EntityId)
	if Workspace:GetAttribute(BOULDER_ATTRIBUTE) == id then
		Workspace:SetAttribute(BOULDER_ATTRIBUTE, nil)
	end
end

return table.freeze({
	begin = begin,
	setup = setup,
	place_boulder = place_boulder,
	player_start = player_start,
	enemy = enemy,
	tick = tick,
	result = result,
	is_settled = is_settled,
	was_completed_for = was_completed_for,
	studio_mission = studio_mission,
	forget = forget,
})
