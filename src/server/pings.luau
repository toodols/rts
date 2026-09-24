-- Pings: a player marks a spot on the map (a double click of the middle mouse button, see client/pings.luau), and it
-- is shown to them and to everyone on a team allied with theirs, and to nobody else. A player on no team, one only
-- watching, cannot ping.

local Players = game:GetService "Players"
local ReplicatedStorage = game:GetService "ReplicatedStorage"

local types = require(ReplicatedStorage.Shared.types)
local config = require(ReplicatedStorage.Shared.config)
local heightmap = require(ReplicatedStorage.Shared.heightmap)

local players = require(script.Parent.players)
local alliances = require(script.Parent.alliances)

type TeamId = types.TeamId

local ping: RemoteEvent = ReplicatedStorage.Shared.Ping

-- A player pings no more often than this, in seconds, so that holding a spot down cannot flood their allies' screens.
local MIN_INTERVAL = 0.5

local last_ping: { [Player]: number } = {}

local function on_ping(player: Player, point: unknown)
	if typeof(point) ~= "Vector3" then
		return
	end
	local x, z = point.X, point.Z
	-- NaN is not equal to itself, and an infinite point is out of bounds
	if x ~= x or z ~= z or heightmap.in_bounds(x, z) == false then
		return
	end
	local team = players.team_of(player)
	if team == nil then
		return
	end
	local now = os.clock()
	if now - (last_ping[player] or -math.huge) < MIN_INTERVAL then
		return
	end
	last_ping[player] = now

	-- it goes on the ground, or on the sea over water, wherever the client said it was up or down
	local at = Vector3.new(x, math.max(heightmap.height_at(x, z), config.WATER_LEVEL), z)
	for _, other in Players:GetPlayers() do
		local other_team = players.team_of(other)
		if other_team ~= nil and alliances.are_allied(other_team, team) then
			ping:FireClient(other, { at = at, team = team :: TeamId })
		end
	end
end

local function init()
	ping.OnServerEvent:Connect(on_ping)
	Players.PlayerRemoving:Connect(function(player: Player)
		last_ping[player] = nil
	end)
end

return table.freeze({
	init = init,
})
