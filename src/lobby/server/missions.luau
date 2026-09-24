-- The campaign, as the lobby sees it: each player's progress, loaded as they arrive and published on their Player so
-- the campaign screen can show it, and the missions they are being sent to play.
--
-- Progress is kept by the game server, which is where missions are finished (see shared/campaign_store.luau); the
-- lobby only reads it. What a player has unlocked is published as campaign.UNLOCKS_ATTRIBUTE, the way the game does,
-- and what they have finished as protocol.COMPLETED_ATTRIBUTE. A player whose progress cannot be read is shown a new
-- player's, so the screen still says what they start with.
--
-- A mission is played alone, as a match of its own campaign mode on its own map, started through `launch` like a
-- lobby's game but for one player and with no lobby around them. Nothing here talks to the lobbies: whether someone in
-- one may play is init.server.luau's business.

local ReplicatedStorage = game:GetService "ReplicatedStorage"

local campaign = require(ReplicatedStorage.Shared.campaign)
local campaign_store = require(ReplicatedStorage.Shared.campaign_store)
local game_modes = require(ReplicatedStorage.Shared.game_modes)
local protocol = require(ReplicatedStorage.Lobby.protocol)

type Progress = campaign.Progress
type Match = game_modes.Match
type MissionView = protocol.MissionView

-- each player's progress, once it has been read (or given up on and started afresh)
local progress_by_player: { [Player]: Progress } = {}
-- the mission each player is being sent to, or could not be
local missions_by_player: { [Player]: MissionView } = {}

local function publish(player: Player, progress: Progress)
	campaign_store.publish(player, progress)
	player:SetAttribute(protocol.COMPLETED_ATTRIBUTE, protocol.encode_completed(progress.completed))
end

-- Reads `player`'s progress and publishes it on them. Yields while it reads. Returns why it could not be read, in
-- which case a new player's progress is published instead.
local function load(player: Player): string?
	local progress, err = campaign_store.load(player.UserId)
	if player.Parent == nil then
		return nil
	end
	local reason: string? = nil
	if progress == nil then
		warn(`loading {player.Name}'s campaign progress failed: {err}`)
		reason = "Couldn't load your campaign progress; showing a new player's"
		progress = campaign.new_progress()
	end
	progress_by_player[player] = progress :: Progress
	publish(player, progress :: Progress)
	return reason
end

-- What `player` has done in the campaign, as far as this server knows: a new player's until it has been read.
local function progress_of(player: Player): Progress
	return progress_by_player[player] or campaign.new_progress()
end

local function mission_of(player: Player): MissionView?
	return missions_by_player[player]
end

-- Whether `player` is on their way to a mission, so may not ask for anything else.
local function is_busy(player: Player): boolean
	local mission = missions_by_player[player]
	return mission ~= nil and mission.stage ~= "failed"
end

-- The match that plays `mission_id` for `player` alone, and marks them as starting it; or why they cannot.
local function begin(player: Player, mission_id: string): (Match?, string?)
	if is_busy(player) then
		return nil, "A mission is already starting"
	end
	local mission = campaign.get(mission_id)
	local mode = game_modes.campaign_mode(mission_id)
	if mission == nil or mode == nil then
		return nil, "There is no such mission"
	end
	if protocol.is_mission_open(progress_of(player).completed, mission.id) == false then
		return nil, "Finish the missions before this one first"
	end
	missions_by_player[player] = { id = mission.id, stage = "starting", reason = nil }
	return {
		mode = mode.id,
		preset = mission.preset,
		seed = game_modes.DEFAULT_SEED,
		seats = { { user_id = player.UserId, name = player.DisplayName, side = 1 } },
		bonuses = {},
		ally_griefing = false,
	},
		nil
end

-- `player` has been sent to their mission; they are gone from here once the teleport goes through.
local function mark_sent(player: Player)
	local mission = missions_by_player[player]
	if mission ~= nil then
		mission.stage = "teleporting"
	end
end

-- `player`'s mission could not be started, or they could not be got to it, and why.
local function fail(player: Player, reason: string)
	local mission = missions_by_player[player]
	if mission ~= nil then
		mission.stage = "failed"
		mission.reason = reason
	end
end

local function forget(player: Player)
	progress_by_player[player] = nil
	missions_by_player[player] = nil
end

return table.freeze({
	load = load,
	progress_of = progress_of,
	mission_of = mission_of,
	is_busy = is_busy,
	begin = begin,
	mark_sent = mark_sent,
	fail = fail,
	forget = forget,
})
