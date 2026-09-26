--!strict
-- Roblox's own teams, kept to the game's: a Team for each alliance a player is in, named for its teams and in the colour
-- of the first of them, and one for the spectators, with every player on theirs. Roblox's team chat reaches only a
-- player's own Team, so this is what has it reach exactly their allies (and a spectator's, only the other spectators).
--
-- It is worked out afresh from the game's teams every frame (`sync`), which keeps up with every way they change: a
-- player seated, moved to another team or split off (players.luau), teams allied or unallied (alliances.luau), a game
-- restored (snapshot). A Team is only ever made or taken down when that changes which there should be.

local Players = game:GetService "Players"
local ReplicatedStorage = game:GetService "ReplicatedStorage"
local Teams = game:GetService "Teams"

local appearance = require(ReplicatedStorage.Shared.appearance)
local seating = require(ReplicatedStorage.Shared.seating)
local types = require(ReplicatedStorage.Shared.types)

local alliances = require(script.Parent.alliances)
local players = require(script.Parent.players)
local state = require(script.Parent.state)

type TeamId = types.TeamId

local SPECTATORS = "spectators"
local SPECTATORS_NAME = "Spectators"
local SPECTATORS_COLOR = BrickColor.new "Dark stone grey"
-- BrickColor.palette's indices
local PALETTE_SIZE = 128

-- The Teams made, by what they are for: an alliance by the id of the first team in it, or SPECTATORS.
local made: { [string]: Team } = {}

-- A team colour no Team made has already, as near `wanted` as can be. Team chat tells Teams apart by their colour, so no
-- two may share one.
local function free_color(wanted: BrickColor): BrickColor
	local taken: { [number]: boolean } = {}
	for _, team in made do
		taken[team.TeamColor.Number] = true
	end
	if taken[wanted.Number] == nil then
		return wanted
	end
	for index = 0, PALETTE_SIZE - 1 do
		local color = BrickColor.palette(index)
		if taken[color.Number] == nil then
			return color
		end
	end
	return wanted
end

local function make(key: string, name: string, color: BrickColor): Team
	local team = Instance.new "Team"
	team.Name = name
	team.TeamColor = free_color(color)
	-- nobody is put on a Team but by `sync`
	team.AutoAssignable = false
	team.Parent = Teams
	made[key] = team
	return team
end

-- The Team `player` should be on, as a key of `made`, with its name and colour when it is an alliance's: their team's
-- alliance, the spectators, or none for a player not seated yet. `alliance_of` holds what has been worked out already
-- this frame, by team id.
local function wanted_key(
	player: Player,
	alliance_of: { [TeamId]: { key: string, name: string, color: BrickColor } }
): string?
	local team_id = players.team_of(player)
	if team_id == nil then
		return if seating.is_spectator(player) then SPECTATORS else nil
	end
	local alliance = alliance_of[team_id]
	if alliance == nil then
		local group = alliances.group_of(team_id, state.all_teams())
		local first = if #group > 0 then group[1] else team_id
		local names = {}
		for _, member in group do
			table.insert(names, (state.get_team(member) :: types.Team).name)
		end
		alliance = {
			key = tostring(first),
			name = if #names > 0 then table.concat(names, ", ") else `Team {team_id}`,
			color = BrickColor.new(appearance.team_color(first)),
		}
		alliance_of[team_id] = alliance
	end
	return alliance.key
end

-- Puts every player on the Team they should be on, making the Teams wanted and taking down the ones nobody should be on.
local function sync()
	local alliance_of: { [TeamId]: { key: string, name: string, color: BrickColor } } = {}
	local wanted: { [Player]: string } = {}
	for _, player in Players:GetPlayers() do
		local key = wanted_key(player, alliance_of)
		if key ~= nil then
			wanted[player] = key
		end
	end

	local in_use: { [string]: boolean } = {}
	for _, alliance in alliance_of do
		in_use[alliance.key] = true
		local team: Team? = made[alliance.key]
		if team == nil then
			make(alliance.key, alliance.name, alliance.color)
		elseif team.Name ~= alliance.name then
			team.Name = alliance.name
		end
	end
	for _, key in wanted do
		if key == SPECTATORS and (made[SPECTATORS] :: Team?) == nil then
			make(SPECTATORS, SPECTATORS_NAME, SPECTATORS_COLOR)
		end
		in_use[key] = true
	end

	for _, player in Players:GetPlayers() do
		local key: string? = wanted[player]
		local team: Team? = if key ~= nil then made[key] else nil
		if player.Team ~= team then
			player.Team = team
		end
		local neutral = key == nil
		if player.Neutral ~= neutral then
			player.Neutral = neutral
		end
	end

	for key, team in made do
		if in_use[key] == nil then
			made[key] = nil
			team:Destroy()
		end
	end
end

return table.freeze({
	sync = sync,
})
