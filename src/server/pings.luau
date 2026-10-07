-- Pings: a player marks a spot on the map (a double click of the middle mouse button, see client/pings.luau), and it
-- is shown to them and to everyone on a team allied with theirs, and to nobody else, with the name of the player who
-- pinged, in their team's colour. A player on no team, one only watching, cannot ping, but sees everyone's.

local Players = game:GetService "Players"
local ReplicatedStorage = game:GetService "ReplicatedStorage"
local ServerScriptService = game:GetService "ServerScriptService"

local types = require(ReplicatedStorage.Shared.types)
local ground_levels = require(ReplicatedStorage.Shared.ground_levels)
local heightmap = require(ReplicatedStorage.Shared.heightmap)
local decode = require(ReplicatedStorage.Shared.decode)
local seating = require(ReplicatedStorage.Shared.seating)

local remotes = require(ServerScriptService.ServerShared.remotes)

local players = require(script.Parent.players)
local state = require(script.Parent.state)
local alliances = require(script.Parent.alliances)

type TeamId = types.TeamId

local ping: RemoteEvent = ReplicatedStorage.Shared.Ping

-- A player pings no more often than once in half a second, so that holding a spot down cannot flood their allies'
-- screens.
local PING_RATE = { per_second = 2, burst = 1 }

local function on_ping(player: Player, point: Vector3)
	local x, z = point.X, point.Z
	local team = players.team_of(player)
	if team == nil or state.get_team(team) == nil then
		return
	end

	-- it goes on the ground, or on the sea over water, wherever the client said it was up or down
	local at = Vector3.new(x, math.max(heightmap.height_at(x, z), ground_levels.WATER_LEVEL), z)
	for _, other in Players:GetPlayers() do
		local other_team = players.team_of(other)
		local watching = other_team == nil and seating.is_spectator(other)
		if watching or (other_team ~= nil and alliances.are_allied(other_team, team)) then
			remotes.tell(
				ping,
				other,
				{ at = at, team = team :: TeamId, player = player.UserId, name = player.DisplayName }
			)
		end
	end
end

local function init()
	remotes.listen(ping, { args = { decode.on_map }, rate = PING_RATE }, on_ping)
end

return table.freeze({
	init = init,
})
