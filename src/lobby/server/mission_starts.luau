--!strict
-- The campaign missions players here are being sent to play. A mission is played alone, as a match of its own campaign
-- mode on its own map, started through `launch` like a lobby's game but for one player and with no lobby around them,
-- and only once the missions before it are finished (their campaign progress, server_shared/campaign_session.luau).
-- Nothing here talks to the lobbies: whether someone in one may play is init.server.luau's business.

local ReplicatedStorage = game:GetService "ReplicatedStorage"
local ServerScriptService = game:GetService "ServerScriptService"

local campaign = require(ReplicatedStorage.Shared.campaign)
local game_modes = require(ReplicatedStorage.Shared.game_modes)
local protocol = require(ReplicatedStorage.Lobby.protocol)

local campaign_session = require(ServerScriptService.ServerShared.campaign_session)

type Match = game_modes.Match
type MissionView = protocol.MissionView

-- the mission each player is being sent to, or could not be
local missions_by_player: { [Player]: MissionView } = {}

local function mission_of(player: Player): MissionView?
	return missions_by_player[player]
end

-- Whether `player` is on their way to a mission, so may not ask for anything else.
local function is_busy(player: Player): boolean
	local mission = missions_by_player[player]
	return mission ~= nil and mission.stage ~= "failed"
end

-- Why `player` may not play the mission the key `mission_id` names (campaign.key: its id, or its hard mode's), alone or
-- with others, if they may not: there has to be such a mission, and it has to be open to them (campaign.is_open).
local function refusal(player: Player, mission_id: string): string?
	local mission, hard = campaign.parse_key(mission_id)
	if mission == nil then
		return "There is no such mission"
	end
	if campaign.is_open(campaign_session.progress_of(player).completed, mission_id) == false then
		return if hard then "Finish the mission first" else "Finish the missions before this one first"
	end
	return nil
end

-- The match that plays the mission the key `mission_id` names for `player` alone, and marks them as starting it; or
-- why they cannot.
local function begin(player: Player, mission_id: string): (Match?, string?)
	if is_busy(player) then
		return nil, "A mission is already starting"
	end
	local refused = refusal(player, mission_id)
	if refused ~= nil then
		return nil, refused
	end
	local match = game_modes.mission_match(
		mission_id,
		{ { user_id = player.UserId, name = player.DisplayName, side = 1 } }
	) :: Match
	missions_by_player[player] = { id = mission_id, stage = "starting", reason = nil }
	return match, nil
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
	missions_by_player[player] = nil
end

return table.freeze({
	mission_of = mission_of,
	is_busy = is_busy,
	refusal = refusal,
	begin = begin,
	mark_sent = mark_sent,
	fail = fail,
	forget = forget,
})
