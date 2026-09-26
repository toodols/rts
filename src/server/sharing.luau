-- The player list (T) and giving resources to allies from it.
--
-- Every player is sent the roster a few times a second: every team in the game, whose it is, and whether it is
-- theirs, an ally's or an enemy's. What an ally has in the bank goes with it, so it can be topped up; what an enemy
-- has does not, since nothing about the list should tell you more about the other side than the battlefield does.
-- Someone only watching sees every team's bank.
--
-- A player gives an ally metal or energy by dragging it out of the list, which sends ShareResources. The server
-- gives no more than they have and no more than the ally has room for, so nothing is lost on a full store.

local Players = game:GetService "Players"
local ReplicatedStorage = game:GetService "ReplicatedStorage"
local ServerScriptService = game:GetService "ServerScriptService"

local types = require(ReplicatedStorage.Shared.types)
local teams = require(ReplicatedStorage.Shared.teams)
local appearance = require(ReplicatedStorage.Shared.appearance)
local decode = require(ReplicatedStorage.Shared.decode)

local remotes = require(ServerScriptService.ServerShared.remotes)

local state = require(script.Parent.state)
local alliances = require(script.Parent.alliances)
local players = require(script.Parent.players)
local economy = require(script.Parent.economy)
local notifications = require(script.Parent.notifications)

type TeamId = types.TeamId
type Team = types.Team

type Relation = types.RosterRelation
type Resource = types.Resource
type Bank = types.Bank
type RosterEntry = types.RosterEntry

local roster_updated: RemoteEvent = ReplicatedStorage.Shared.RosterUpdated
local share_resources: RemoteEvent = ReplicatedStorage.Shared.ShareResources

-- Whatever is asked for below this is not worth a message; the client never sends it.
local MIN_SHARE = 1
local RESOURCE = decode.one_of({ "metal", "energy" } :: { Resource })
local SHARE_RATE = { per_second = 10, burst = 10 }

local function bank_of(team: Team): Bank
	return {
		metal = team.metal,
		energy = team.energy,
		metal_capacity = team.metal_capacity,
		energy_capacity = team.energy_capacity,
	}
end

-- The teams the list shows: everyone playing, not the neutral team or the scavengers.
local function listed_teams(): { Team }
	local result: { Team } = {}
	for team_id, team in state.all_teams() do
		if teams.is_playable(team_id) == false then
			continue
		end
		table.insert(result, team)
	end
	table.sort(result, function(a: Team, b: Team): boolean
		return a.id < b.id
	end)
	return result
end

local function roster_for(viewer: TeamId?, listed: { Team }): { RosterEntry }
	local result: { RosterEntry } = {}
	for _, team in listed do
		local relation: Relation = if viewer == nil
			then "watched"
			elseif team.id == viewer then "self"
			elseif alliances.are_allied(viewer, team.id) then "ally"
			else "enemy"
		local members = players.players_on_team(team.id)
		table.insert(result, {
			team_id = team.id,
			name = team.name,
			user_id = if #members > 0 then members[1].UserId else 0,
			color = appearance.team_color(team.id),
			relation = relation,
			bank = if relation == "enemy" then nil else bank_of(team),
		})
	end
	return result
end

local function broadcast()
	local listed = listed_teams()
	for _, player in Players:GetPlayers() do
		remotes.tell(roster_updated, player, roster_for(players.team_of(player), listed))
	end
end

-- Moves up to `amount` of `resource` from one team to another, capped by what the giver has and what the taker has
-- room for. Returns how much moved.
local function give(from: TeamId, to: TeamId, resource: Resource, amount: number): number
	local banked = economy.transfer(from, to, resource, amount)
	if resource == "metal" and banked > 0 then
		notifications.metal_sent(from, to, banked)
	end
	return banked
end

-- Team `from` gives an ally some of what it has: only to an ally that is not itself, and only a sensible amount.
-- Returns how much moved.
local function share(from: TeamId, to: TeamId, resource: Resource, amount: number): number
	-- NaN fails this as well
	if (amount >= MIN_SHARE) == false or to == from or alliances.are_allied(from, to) == false then
		return 0
	end
	return give(from, to, resource, amount)
end

local function on_share_resources(player: Player, to: TeamId, resource: Resource, amount: number)
	local from = players.team_of(player)
	if from ~= nil then
		share(from, to, resource, amount)
	end
end

local function init()
	remotes.listen(
		share_resources,
		{ args = { decode.number, RESOURCE, decode.number }, rate = SHARE_RATE },
		on_share_resources
	)
end

return table.freeze({
	init = init,
	broadcast = broadcast,
	give = give,
	share = share,
})
