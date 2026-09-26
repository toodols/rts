--!strict
-- The rule that nothing locked in the campaign is built (see shared/campaign.luau): a team is held to what its players
-- have unlocked, and a def is buildable if any of them has unlocked it. What each player has unlocked is their campaign
-- progress (server_shared/campaign_session.luau).
--
-- A team's players are everyone who has been seated on it this game: someone who leaves the server still counts for
-- it, so a team does not come free of its unlocks by its players going, and someone moved to another team counts for
-- that one instead. A team nobody has been seated on (the scavengers, an enemy a mission puts down, an AI's, a team a
-- test makes) is held to nothing. What each team may build is worked out as its players are seated and moved and as
-- their progress is published, not every time it is asked, which is every tick by every builder and lab.

local ReplicatedStorage = game:GetService "ReplicatedStorage"
local ServerScriptService = game:GetService "ServerScriptService"

local types = require(ReplicatedStorage.Shared.types)
local campaign = require(ReplicatedStorage.Shared.campaign)

local campaign_session = require(ServerScriptService.ServerShared.campaign_session)

local players = require(script.Parent.players)

type TeamId = types.TeamId
type Set = { [string]: boolean }

-- What each player seated on each team has unlocked, by team and user id, as it was last published.
local unlocked_by: { [TeamId]: { [number]: Set } } = {}
-- What each team may build, worked out from that; a team nobody has been seated on has none.
local allowed: { [TeamId]: Set } = {}

local function work_out(team_id: TeamId)
	local union: Set = campaign.starting_unlocks()
	for _, set in unlocked_by[team_id] do
		for name, unlocked in set do
			if unlocked then
				union[name] = true
			end
		end
	end
	allowed[team_id] = union
end

-- Counts what `player` has unlocked for the team they are on now, and no longer for any other.
local function track(player: Player)
	local user_id = player.UserId
	local team_id = players.team_of(player)
	for other, by_user in unlocked_by do
		if other ~= team_id and by_user[user_id] ~= nil then
			by_user[user_id] = nil
			work_out(other)
		end
	end
	if team_id == nil then
		return
	end
	local by_user = unlocked_by[team_id]
	if by_user == nil then
		by_user = {}
		unlocked_by[team_id] = by_user
	end
	by_user[user_id] = table.clone(campaign_session.progress_of(player).unlocks)
	work_out(team_id)
end

-- The defs a team may build, as a set, or nil when it may build anything: a team nobody has been seated on.
local function of_team(team_id: TeamId): Set?
	return allowed[team_id]
end

-- Whether `team_id` may build or make `def_name`.
local function can_build(team_id: TeamId, def_name: string): boolean
	if campaign.is_lockable(def_name) == false then
		return true
	end
	local unlocks = allowed[team_id]
	return unlocks == nil or campaign.is_unlocked(unlocks, def_name)
end

-- Follows every player's team and progress from now on.
local function init()
	players.on_team_changed(track)
	campaign_session.on_published(track)
end

return table.freeze({
	init = init,
	of_team = of_team,
	can_build = can_build,
})
