--!strict
-- Each player's campaign progress (shared/campaign_progress.luau), the same in every place of the experience: the game
-- marks a mission finished as its players win it, and the lobby shows it on the campaign screen. It is kept in a
-- DataStore, one record a player, and published on them (campaign_progress.publish).
--
-- Until theirs is read they have a new player's, the starting unlocks, and so if it cannot be read, for the session.
-- Every change is one of campaign_progress' transitions, applied to what this server holds and, inside the store's own
-- update, to what is stored, so that what another place saved meanwhile is kept.

local ReplicatedStorage = game:GetService "ReplicatedStorage"

local campaign = require(ReplicatedStorage.Shared.campaign)
local campaign_progress = require(ReplicatedStorage.Shared.campaign_progress)
local signal = require(ReplicatedStorage.Shared.signal)

local record_store = require(script.Parent.record_store)
local player_session = require(script.Parent.player_session)

type Progress = campaign_progress.Progress
type Outcome = player_session.Outcome

-- told of each player whose progress was published, as it was
local published = signal.new() :: signal.Signal<Player>

local session = player_session.new({
	label = "campaign progress",
	store = record_store.new({
		store = "campaign_progress",
		decode = campaign_progress.decode,
		encode = campaign_progress.encode,
	}),
	key = record_store.player_key,
	fresh = campaign_progress.new,
	publish = function(player: Player, progress: Progress)
		campaign_progress.publish(player, progress)
		published.fire(player)
	end,
})

-- `player` has finished the mission `mission_id`, in its hard mode for `hard`: it is marked done (and its hard mode,
-- for `hard`) and what it unlocks is theirs, saved. Yields while it saves. Refused for a mission there is not.
local function complete(player: Player, mission_id: string, hard: boolean): (Outcome, string?)
	if campaign.get(mission_id) == nil then
		return "refused", "There is no such mission"
	end
	return session.change(player, function(progress: Progress): Progress
		return campaign_progress.complete(progress, mission_id, hard)
	end, true)
end

-- Unlocks `def_names` for `player`; `save` keeps them past this session. Yields while it saves.
local function grant(player: Player, def_names: { string }, save: boolean): (Outcome, string?)
	return session.change(player, function(progress: Progress): Progress
		return campaign_progress.grant(progress, def_names)
	end, save)
end

-- Takes `player` back to the starting unlocks, the missions they finished staying finished; `save` keeps it past this
-- session. Yields while it saves.
local function relock(player: Player, save: boolean): (Outcome, string?)
	return session.change(player, campaign_progress.relock, save)
end

-- Takes `player` back to a new player's progress, saved. Yields while it saves.
local function reset(player: Player): (Outcome, string?)
	return session.change(player, function(): Progress
		return campaign_progress.new()
	end, true)
end

return table.freeze({
	joined = session.joined,
	left = session.left,
	progress_of = session.get,
	status = session.status,
	wait_loaded = session.wait_loaded,
	complete = complete,
	grant = grant,
	relock = relock,
	reset = reset,
	on_published = published.subscribe,
})
