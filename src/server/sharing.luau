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

local types = require(ReplicatedStorage.Shared.types)
local config = require(ReplicatedStorage.Shared.config)
local appearance = require(ReplicatedStorage.Shared.appearance)

local state = require(script.Parent.state)
local alliances = require(script.Parent.alliances)
local players = require(script.Parent.players)
local economy = require(script.Parent.economy)
local notifications = require(script.Parent.notifications)

type TeamId = types.TeamId
type Team = types.Team

export type Relation = "self" | "ally" | "enemy" | "watched"

-- What the list is told of a team's bank: only ever for the player's own team and their allies.
export type Bank = {
	metal: number,
	energy: number,
	metal_capacity: number,
	energy_capacity: number,
}

export type RosterEntry = {
	team_id: TeamId,
	name: string,
	-- the UserId of the team's player for their headshot, or 0 for a team with nobody on it
	user_id: number,
	color: Color3,
	relation: Relation,
	bank: Bank?,
}

local roster_updated: RemoteEvent = ReplicatedStorage.Shared.RosterUpdated
local share_resources: RemoteEvent = ReplicatedStorage.Shared.ShareResources

-- Whatever is asked for below this is not worth a message; the client never sends it.
local MIN_SHARE = 1

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
		if team_id == 0 or team_id == config.SCAVENGER_TEAM then
			continue
		end
		table.insert(result, team)
	end
	table.sort(result, function(a: Team, b: Team): boolean
		return a.id < b.id
	end)
	return result
end

local function roster_for(viewer: TeamId?, teams: { Team }): { RosterEntry }
	local result: { RosterEntry } = {}
	for _, team in teams do
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
	local teams = listed_teams()
	for _, player in Players:GetPlayers() do
		roster_updated:FireClient(player, roster_for(players.team_of(player), teams))
	end
end

-- Moves up to `amount` of `resource` from one team to another, capped by what the giver has and what the taker has
-- room for. Returns how much moved.
local function give(from: TeamId, to: TeamId, resource: "metal" | "energy", amount: number): number
	local giver = state.get_team(from)
	local taker = state.get_team(to)
	if giver == nil or taker == nil then
		return 0
	end
	local held = if resource == "metal" then giver.metal else giver.energy
	-- what won't fit stays with the giver, so it mustn't reach the taker's revenue either
	local room = if resource == "metal"
		then taker.metal_capacity - taker.metal
		else taker.energy_capacity - taker.energy
	local offered = math.min(amount, held, room)
	if offered <= 0 then
		return 0
	end
	local banked = if resource == "metal" then economy.add_metal(to, offered) else economy.add_energy(to, offered)
	if resource == "metal" then
		giver.metal -= banked
		economy.record_spent(from, banked, 0)
		notifications.metal_sent(from, to, banked)
	else
		giver.energy -= banked
		economy.record_spent(from, 0, banked)
	end
	return banked
end

-- A request from team `from` (nil for someone with no team) to give an ally some of what it has, checked as
-- ShareResources receives it: to an ally that is not itself, of metal or energy, in a sensible amount. Returns how
-- much moved.
local function share(from: TeamId?, to: unknown, resource: unknown, amount: unknown): number
	if from == nil or typeof(to) ~= "number" then
		return 0
	end
	if resource ~= "metal" and resource ~= "energy" then
		return 0
	end
	-- NaN and infinity fail these as well
	if typeof(amount) ~= "number" or not (amount >= MIN_SHARE and amount < math.huge) then
		return 0
	end
	if to == from or alliances.are_allied(from, to) == false then
		return 0
	end
	return give(from, to, if resource == "metal" then "metal" else "energy", amount)
end

local function on_share_resources(player: Player, to: unknown, resource: unknown, amount: unknown)
	share(players.team_of(player), to, resource, amount)
end

local function init()
	share_resources.OnServerEvent:Connect(on_share_resources)
end

return table.freeze({
	init = init,
	broadcast = broadcast,
	give = give,
	share = share,
})
