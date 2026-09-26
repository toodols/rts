--!strict
-- The campaign's missions, as the game server plays them (see shared/campaign.luau). Each mission's own part is its
-- handler (kit.Handler), one to a mission id in HANDLERS: what it starts with, and whatever it does besides being
-- won by destroying its enemy. What they have in common is here.
--
-- A map is loaded with the mission played on it, if one is (maps.luau): as the old world is cleared the mission begins
-- (`begin`, which a campaign match's first map, whose mode names its mission, does as well), and once the new map is
-- built and the players' commanders are down on it, `setup` makes the mission's enemy, a team of its own with nobody
-- playing it and no AI, and has the handler put down what the mission starts with. The player has no start to choose:
-- their commander goes down at the mission's start (`player_start`, which pregame.luau's start policy uses) once their
-- client has loaded, and that is all they get, as in any game; each players' team whose commander has gone down is
-- handed to the handler's `on_commander_down`, for a mission that gives them more. An AI's team (one put down with
-- ai_add, say) is not.
--
-- Who is out is elimination.luau's to say, each of the players' teams a side of its own by the handler's end mode
-- ("units" unless it says), and the enemy by the handler's enemy end mode (the same). A mission is won when the enemy
-- is out, once the handler says it
-- can be beaten (`is_beaten`); the game then ends in victory for every other team (game_phase.set_ended), and each
-- player on a winning team has the mission marked complete, saved and its unlocks published
-- (server_shared/campaign_session.luau), which `completed` tells of once it has been for every one of them. It is lost
-- when every one of the players' teams is out, or when the handler says it has been some other way (`lost`): the enemy
-- wins. Neither is looked at before the enemy is on the field,
-- or once the mission has ended. The end screen then offers to go back to the lobby or on to the next mission
-- (campaign_exit.luau), which `changed` tells of how the mission stands.
--
-- The mission's state is kept here; what the clients see of it is published with the rest of what they are sent
-- (`publish`, from the server's loop) as shared/mission_state.luau's fields, which nothing here reads back.
--
-- A mission with a hard mode (campaign.Mission's `hard_mode`) is played in it when it is begun so: on the same map and
-- from mostly the same start, with no guide (client/tutorial.luau leaves it be) and a harder enemy, which is each
-- handler's own (its `setup` is told). Winning it marks the hard mode complete as well as the mission, and unlocks its
-- `hard_mode_unlocks` as well.
--
-- To play a mission in Studio without the lobby, see server/session_config.luau.

local ReplicatedStorage = game:GetService "ReplicatedStorage"
local ServerScriptService = game:GetService "ServerScriptService"

local types = require(ReplicatedStorage.Shared.types)
local campaign = require(ReplicatedStorage.Shared.campaign)
local unit_defs = require(ReplicatedStorage.Shared.unit_defs)
local game_modes = require(ReplicatedStorage.Shared.game_modes)
local game_phase = require(ReplicatedStorage.Shared.game_phase)
local mission_map = require(ReplicatedStorage.Shared.mission_map)
local mission_state = require(ReplicatedStorage.Shared.mission_state)
local signal = require(ReplicatedStorage.Shared.signal)

local campaign_session = require(ServerScriptService.ServerShared.campaign_session)

local state = require(ServerScriptService.Server.state)
local players = require(ServerScriptService.Server.players)
local match = require(ServerScriptService.Server.match)
local elimination = require(ServerScriptService.Server.elimination)
local ai = require(ServerScriptService.Server.ai)

local kit = require(script.kit)
local tutorial = require(script.tutorial)
local overlook = require(script.overlook)
local counterattack = require(script.counterattack)
local skirmish = require(script.skirmish)
local channel = require(script.channel)
local blockade = require(script.blockade)
local snapshot = require(ServerScriptService.Server.snapshot)

type EntityId = types.EntityId
type TeamId = types.TeamId
type Handler = kit.Handler

export type Outcome = "won" | "lost"

-- How the game ends, in the line everyone sees under the result, by the players' end mode for a loss.
local ENEMY_DESTROYED = "The enemy is destroyed"
local FORCES_DESTROYED = "Your forces are destroyed"
local COMMANDERS_DEAD = "Your commander is dead"
-- How often, in seconds of game, who has anything left is looked at.
local CHECK_SECONDS = 0.25

-- Each mission's handler, by mission id.
local HANDLERS: { [string]: Handler } = table.freeze({
	tutorial = tutorial.handler,
	overlook = overlook.handler,
	counterattack = counterattack.handler,
	prairie = skirmish.handler,
	channel = channel.handler,
	blockade = blockade.handler,
})
for _, mission in campaign.MISSIONS do
	assert(HANDLERS[mission.id] ~= nil, `the mission "{mission.id}" has no handler`)
end

-- The mission being played, if one is, and whether in its hard mode.
local current: string? = nil
local current_hard = false
-- The team the mission's enemy plays as, once it has been put down.
local enemy_team: TeamId? = nil
local evaluator = elimination.new()
local check_timer = 0
-- How much of what keeps the enemy in by its end mode stood at the last look: its things, by the usual "units".
local enemy_left = 0
-- The players' teams whose commander has gone down, handed to the handler.
local commanded: { [TeamId]: boolean } = {}
-- How the mission ended, once it has, and the teams that won it.
local outcome: Outcome? = nil
local winning: { TeamId } = {}
-- The players the mission is being marked complete for, by user id: false while it saves, true once it has.
local completions: { [number]: boolean } = {}
-- Told whenever the mission begins or ends.
local changed = signal.new()
-- Told once the mission won has been marked complete for every player it is being marked for.
local completed = signal.new()

local function handler(): Handler?
	return if current ~= nil then HANDLERS[current] else nil
end

-- The mission being played, if one is.
local function mission(): string?
	return current
end

-- Whether the mission being played is in its hard mode.
local function hard(): boolean
	return current_hard
end

-- Where the player's commander goes down in the mission being played, so that they have no start to choose; nil when
-- none is, or its map names none (mission_map.player_start), and they choose one as in any game.
local function player_start(): Vector2?
	local playing = if current ~= nil then campaign.get(current) else nil
	return if playing ~= nil then mission_map.player_start(playing.preset) else nil
end

-- Makes the mission's enemy team: a team of its own past every seat the match has, and past the one player a mission
-- is always played by, whether or not they have arrived yet.
local function create_enemy(): TeamId
	players.reserve(math.max(match.seated_count(), 1))
	local team_id = players.create_team "Enemy"
	enemy_team = team_id
	mission_state.publish_enemy(team_id)
	return team_id
end

-- Puts down what the mission being played starts with, if one is. Called once its map is built and the players'
-- commanders are down on it.
local function setup()
	local playing = handler()
	if playing ~= nil then
		local mission_def = campaign.get(current :: string) :: campaign.Mission
		playing.setup(create_enemy(), { mission = mission_def, hard = current_hard })
	end
end

-- The teams the players here are on, but the enemy's, in order.
local function player_teams(): { TeamId }
	local found: { TeamId } = {}
	for _, player in players.seated() do
		local team_id = players.team_of(player) :: TeamId
		if team_id ~= enemy_team and table.find(found, team_id) == nil then
			table.insert(found, team_id)
		end
	end
	table.sort(found)
	return found
end

-- Hands each players' team whose commander has gone down since the last look to `playing`. The teams are found first,
-- since what the handler puts down for them joins the world at once.
local function hand_new_commanders(playing: Handler)
	local on_commander_down = playing.on_commander_down
	if on_commander_down == nil then
		return
	end
	local found: { TeamId } = {}
	for _, entity in state.all() do
		if
			entity.alive
			and unit_defs.is_commander(entity.def)
			and kit.is_players(entity.team, enemy_team)
			and ai.is_ai(entity.team) == false
			and commanded[entity.team] ~= true
			and table.find(found, entity.team) == nil
		then
			table.insert(found, entity.team)
		end
	end
	table.sort(found)
	for _, team_id in found do
		commanded[team_id] = true
		on_commander_down(team_id)
	end
end

-- The mission is over: `winners` won it, and it ended `how`.
local function finish(how: Outcome, winners: { TeamId }, reason: string)
	outcome = how
	winning = winners
	game_phase.set_ended(winners, reason)
	changed.fire()
end

-- Whether every player the mission is being marked complete for has had it saved.
local function all_completed(): boolean
	for _, done in completions do
		if done == false then
			return false
		end
	end
	return true
end

-- Every one of the players' teams has won, and the mission is complete for each player on one of them.
local function win()
	local candidates: { [TeamId]: boolean } = {}
	for _, team_id in player_teams() do
		candidates[team_id] = true
	end
	for team_id in state.all_teams() do
		candidates[team_id] = true
	end
	local winners: { TeamId } = {}
	for team_id in candidates do
		if kit.is_players(team_id, enemy_team) then
			table.insert(winners, team_id)
		end
	end
	table.sort(winners)
	local mission_id = current :: string
	local in_hard = current_hard
	for _, player in players.seated() do
		if table.find(winners, players.team_of(player) :: TeamId) == nil then
			continue
		end
		local user_id = player.UserId
		completions[user_id] = false
		task.spawn(function()
			campaign_session.complete(player, mission_id, in_hard)
			-- a mission begun since forgets whom this one was completed for
			if completions[user_id] == false then
				completions[user_id] = true
				if all_completed() then
					completed.fire()
				end
			end
		end)
	end
	finish("won", winners, ENEMY_DESTROYED)
	if next(completions) == nil then
		completed.fire()
	end
end

-- Ends the mission once one side is out, and runs it on. Called at the end of every step, once its dead are gone.
local function tick(delta: number)
	local playing = handler()
	local enemy_id = enemy_team
	if playing == nil or enemy_id == nil or outcome ~= nil then
		return
	end
	if playing.tick ~= nil then
		playing.tick(delta)
	end
	check_timer += delta
	if check_timer < CHECK_SECONDS then
		return
	end
	check_timer = 0
	hand_new_commanders(playing)
	-- the enemy first, and then each of the players' teams, a side of its own
	local players_end_mode: game_modes.EndMode = playing.end_mode or "units"
	local enemy_end_mode: game_modes.EndMode = playing.enemy_end_mode or "units"
	local teams_here = player_teams()
	local sides: { elimination.Side } = { { teams = { enemy_id }, end_mode = enemy_end_mode } }
	for _, team_id in teams_here do
		table.insert(sides, { teams = { team_id }, end_mode = players_end_mode })
	end
	local out, standing = evaluator.look(sides)
	local counted = standing[enemy_end_mode]
	enemy_left = if counted ~= nil then counted[enemy_id] or 0 else 0
	if playing.on_enemy_counted ~= nil then
		playing.on_enemy_counted(enemy_left)
	end
	if out[1] and (playing.is_beaten == nil or playing.is_beaten()) then
		win()
		return
	end
	local lost_by = if playing.lost ~= nil then playing.lost() else nil
	if lost_by ~= nil then
		finish("lost", { enemy_id }, lost_by)
		return
	end
	if #teams_here == 0 then
		return
	end
	for index = 2, #sides do
		if out[index] == false then
			return
		end
	end
	finish("lost", { enemy_id }, if players_end_mode == "commanders" then COMMANDERS_DEAD else FORCES_DESTROYED)
end

-- Publishes what the HUD shows of the mission being played, with the rest of what the players are sent.
local function publish()
	local playing = handler()
	local hud = if playing ~= nil and playing.hud ~= nil then playing.hud(enemy_left) else nil
	mission_state.publish_hud(hud)
end

-- How many of the enemy's units of the mission being played are on their way onto the field, still to come down.
local function arriving(): number
	local playing = handler()
	return if playing ~= nil and playing.arriving ~= nil then playing.arriving() else 0
end

-- How the mission being played ended, once it has.
local function result(): Outcome?
	return outcome
end

-- The teams that won the mission being played, once it has ended; none before, or if the enemy did.
local function winners(): { TeamId }
	return if outcome == "won" then table.clone(winning) else {}
end

-- Whether `player` may be sent on without losing their finishing the mission: it has been saved, or was never to be.
local function is_settled(player: Player): boolean
	return completions[player.UserId] ~= false
end

-- Makes `mission_id` the mission being played, in its hard mode for `in_hard`, or none for nil, forgetting everything
-- about the one before: its enemy, whose team is taken down (and the AI that played it stops, so that the new map does
-- not start it over, ai.restart_on_new_map), how it ended, and whom it was completed for. A client sees the mission
-- begin again even when it is the same one (the tutorial starts over).
local function begin(mission_id: string?, in_hard: boolean)
	assert(mission_id == nil or HANDLERS[mission_id] ~= nil, `there is no mission "{mission_id}"`)
	for _, each in HANDLERS do
		if each.reset ~= nil then
			each.reset()
		end
	end
	local old_enemy = enemy_team
	if old_enemy ~= nil then
		ai.remove(old_enemy)
		players.remove_team(old_enemy)
	end
	current = mission_id
	current_hard = mission_id ~= nil and in_hard
	enemy_team = nil
	evaluator.reset()
	check_timer = 0
	enemy_left = 0
	table.clear(commanded)
	outcome = nil
	winning = {}
	table.clear(completions)
	mission_state.publish_enemy(nil)
	mission_state.publish_hud(nil)
	mission_state.publish_mission(mission_id, current_hard)
	changed.fire()
end

-- Re-times the mission being played (kit.Handler.retime). Returns whether it could be, and why not.
local function retime(prep: number?, pace: number?): (boolean, string?)
	local playing = handler()
	if playing == nil then
		return false, "No mission is being played"
	end
	local retimed = playing.retime
	if retimed == nil then
		return false, `{current} has nothing to time`
	end
	retimed(prep, pace)
	return true, nil
end

-- Something is gone, which the mission being played need not remember.
local function forget(id: EntityId)
	local playing = handler()
	if playing ~= nil and playing.forget ~= nil then
		playing.forget(id)
	end
end

snapshot.keep("missions", function()
	return {
		evaluator = evaluator.kept(),
		current = current,
		current_hard = current_hard,
		enemy_team = enemy_team,
		check_timer = check_timer,
		enemy_left = enemy_left,
		commanded = commanded,
		outcome = outcome,
		winning = winning,
		completions = completions,
	}
end, function(saved)
	evaluator.put_back(saved.evaluator)
	current = saved.current
	current_hard = saved.current_hard
	enemy_team = saved.enemy_team
	check_timer = saved.check_timer
	enemy_left = saved.enemy_left
	commanded = saved.commanded
	outcome = saved.outcome
	winning = saved.winning
	completions = saved.completions
end)

return table.freeze({
	setup = setup,
	changed = changed.subscribe,
	completed = completed.subscribe,
	begin = begin,
	tick = tick,
	forget = forget,
	mission = mission,
	hard = hard,
	player_start = player_start,
	publish = publish,
	arriving = arriving,
	result = result,
	winners = winners,
	is_settled = is_settled,
	retime = retime,
})
