-- Moving a player to another team while the game runs: onto a team there is, to share it with whoever is on it (they
-- command everything it has and spend from one bank), or onto a new one of their own. The team they leave keeps what it
-- has. Whatever they were piloting is let go of, someone only watching plays from then on, and they start as anyone
-- joining that team would (pregame.team_changed): before the game starts they take the team's start; once it is
-- playing, a team with nothing yet gets a commander.

local ReplicatedStorage = game:GetService "ReplicatedStorage"

local types = require(ReplicatedStorage.Shared.types)
local teams = require(ReplicatedStorage.Shared.teams)
local seating = require(ReplicatedStorage.Shared.seating)

local state = require(script.Parent.state)
local players = require(script.Parent.players)
local possession = require(script.Parent.possession)
local pregame = require(script.Parent.pregame)
local skins = require(script.Parent.skins)

type TeamId = types.TeamId

local function leave_team(player: Player)
	possession.release_player(player)
	seating.set_spectator(player, false)
end

-- Puts `player` on team `team_id`. Returns whether they were moved, and why not: the neutral team and the scavengers
-- are nobody's to play, and a team there is not cannot be joined.
local function join(player: Player, team_id: TeamId): (boolean, string?)
	if teams.is_playable(team_id) == false or state.get_team(team_id) == nil then
		return false, `There is no team {team_id} to join`
	end
	if players.team_of(player) == team_id then
		return false, `{player.Name} is already on team {team_id}`
	end
	leave_team(player)
	players.move(player, team_id)
	pregame.team_changed(player)
	return true, nil
end

-- Puts `player` on a new team of their own, in the skin they have equipped, and returns it.
local function split(player: Player): TeamId
	leave_team(player)
	local team_id = players.split(player)
	skins.dress_team_of(player)
	pregame.team_changed(player)
	return team_id
end

return table.freeze({
	join = join,
	split = split,
})
