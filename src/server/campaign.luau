-- What each player has unlocked in the campaign, and the rule that nothing locked is built (see shared/campaign.luau).
--
-- A player's progress is read from the store (shared/campaign_store.luau) as they arrive. Until it has been read they
-- have the starting unlocks, which are published on them at once, so that the client never sees nothing unlocked. A
-- read that fails, as it does in Studio when the place cannot use DataStores, leaves them the starting unlocks for the
-- session, and nothing is ever saved for them after it, so what is stored is never overwritten with less.
--
-- A team is held to what its players have unlocked: a def is buildable if any player on the team has unlocked it. A
-- team with no player, the scavengers, an enemy a mission puts down, or a team a test makes, is held to nothing.

local ReplicatedStorage = game:GetService "ReplicatedStorage"

local types = require(ReplicatedStorage.Shared.types)
local campaign = require(ReplicatedStorage.Shared.campaign)
local campaign_store = require(ReplicatedStorage.Shared.campaign_store)

local players = require(script.Parent.players)

type TeamId = types.TeamId
type Progress = campaign.Progress

-- Each player here's progress, by user id: what was read, or the starting unlocks until it has been.
local progress_by_user: { [number]: Progress } = {}
-- The players whose progress was read, whose progress may be saved.
local may_save: { [number]: boolean } = {}

local function progress_of(player: Player): Progress
	local progress = progress_by_user[player.UserId]
	if progress == nil then
		progress = campaign.new_progress()
		progress_by_user[player.UserId] = progress
	end
	return progress
end

-- Everything in `from` added to `into`.
local function merge(into: Progress, from: Progress)
	for id, done in from.completed do
		if done then
			into.completed[id] = true
		end
	end
	for name, unlocked in from.unlocks do
		if unlocked then
			into.unlocks[name] = true
		end
	end
end

-- Publishes the starting unlocks on `player` at once, then reads what they have and publishes that once it is read,
-- without waiting for it.
local function player_added(player: Player)
	local progress = progress_of(player)
	campaign_store.publish(player, progress)
	local user_id = player.UserId
	task.spawn(function()
		local loaded, reason = campaign_store.load(user_id)
		if progress_by_user[user_id] ~= progress then
			-- they left while it was being read
			return
		end
		if loaded == nil then
			warn(`could not read {player.Name}'s campaign progress, so they have the starting unlocks: {reason}`)
			return
		end
		-- anything they were given while it was being read is kept
		merge(progress, loaded)
		may_save[user_id] = true
		campaign_store.publish(player, progress)
	end)
end

local function player_removing(player: Player)
	progress_by_user[player.UserId] = nil
	may_save[player.UserId] = nil
end

-- Publishes `player`'s progress on them, and saves it if it may be. Yields while it saves.
local function commit(player: Player, save: boolean)
	local progress = progress_of(player)
	campaign_store.publish(player, progress)
	if save == false then
		return
	end
	if may_save[player.UserId] ~= true then
		warn(`{player.Name}'s campaign progress was never read, so it is not saved`)
		return
	end
	local ok, reason = campaign_store.save(player.UserId, progress)
	if ok == false then
		warn(`could not save {player.Name}'s campaign progress: {reason}`)
	end
end

-- The defs a team may build, as a set, or nil when it may build anything: a team with no player on it.
local function unlocks_of_team(team_id: TeamId): { [string]: boolean }?
	local on_team = players.players_on_team(team_id)
	if #on_team == 0 then
		return nil
	end
	local union: { [string]: boolean } = {}
	for _, player in on_team do
		for name, unlocked in progress_of(player).unlocks do
			if unlocked then
				union[name] = true
			end
		end
	end
	return union
end

-- Whether `team_id` may build or make `def_name`.
local function can_build(team_id: TeamId, def_name: string): boolean
	if campaign.is_lockable(def_name) == false then
		return true
	end
	local unlocks = unlocks_of_team(team_id)
	return unlocks == nil or campaign.is_unlocked(unlocks, def_name)
end

-- `player` has finished the mission `mission_id`: it is marked done, what it unlocks is theirs, and that is saved and
-- published. Returns whether there is such a mission. Yields while it saves.
local function complete(player: Player, mission_id: string): boolean
	local mission = campaign.get(mission_id)
	if mission == nil then
		return false
	end
	local progress = progress_of(player)
	progress.completed[mission_id] = true
	for _, name in mission.unlocks do
		progress.unlocks[name] = true
	end
	commit(player, true)
	return true
end

-- Unlocks `def_names` for `player` for this session, and publishes it; `save` saves it too. Yields while it saves.
local function grant(player: Player, def_names: { string }, save: boolean)
	local progress = progress_of(player)
	for _, name in def_names do
		progress.unlocks[name] = true
	end
	commit(player, save)
end

-- Takes `player` back to the starting unlocks for this session, and publishes it; `save` saves it too. Missions they
-- finished stay finished. Yields while it saves.
local function relock(player: Player, save: boolean)
	local progress = progress_of(player)
	progress.unlocks = campaign.starting_unlocks()
	commit(player, save)
end

-- Takes `player` back to a new player's progress, nothing finished and the starting unlocks, publishes it and saves it.
-- Yields while it saves.
local function reset(player: Player)
	local progress = progress_of(player)
	local fresh = campaign.new_progress()
	progress.completed = fresh.completed
	progress.unlocks = fresh.unlocks
	commit(player, true)
end

-- `player`'s progress as it stands, for reading only, and whether it was read from the store (and so will be saved).
local function status(player: Player): (Progress, boolean)
	return progress_of(player), may_save[player.UserId] == true
end

return table.freeze({
	player_added = player_added,
	player_removing = player_removing,
	unlocks_of_team = unlocks_of_team,
	can_build = can_build,
	complete = complete,
	grant = grant,
	relock = relock,
	reset = reset,
	status = status,
})
