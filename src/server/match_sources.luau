--!strict
-- Where the match a server plays can come from, each read into an ordinary Match (shared/game_modes.luau) before
-- anything is set up for it (session_config.luau decides which is played):
--
-- - A lobby starts a match by reserving a server of this place and teleporting its players into it together, which
--   reads the match they hand over (server_shared/reserved_match.luau).
-- - A campaign mission played straight from Studio is the match a lobby would start for it, seating the first player to
--   arrive, or nobody in a Run, which nobody plays.

local Players = game:GetService "Players"
local ReplicatedStorage = game:GetService "ReplicatedStorage"
local RunService = game:GetService "RunService"
local ServerScriptService = game:GetService "ServerScriptService"

local game_modes = require(ReplicatedStorage.Shared.game_modes)
local campaign = require(ReplicatedStorage.Shared.campaign)

local reserved_match = require(ServerScriptService.ServerShared.reserved_match)

type Match = game_modes.Match
type Seat = game_modes.Seat

-- How long to wait for the first player, to read the match from their teleport data when the store has none, or to
-- seat them in a mission played straight from Studio.
local FIRST_PLAYER_WAIT = 30

-- The first player to arrive, waiting up to FIRST_PLAYER_WAIT for them; nil if nobody does.
local function first_player(): Player?
	local first = Players:GetPlayers()[1]
	if first ~= nil then
		return first
	end
	local arrived: Player? = nil
	local connection = Players.PlayerAdded:Connect(function(player: Player)
		arrived = player
	end)
	local waited = 0
	while arrived == nil and waited < FIRST_PLAYER_WAIT do
		waited += task.wait()
	end
	connection:Disconnect()
	return arrived
end

-- The match a lobby, or a finished mission's server, started this server for, if this is a server one reserved and it
-- can be found. Yields while it reads.
local function from_reservation(): Match?
	if RunService:IsStudio() then
		return nil
	end
	return reserved_match.receive(first_player)
end

-- The match a lobby would start to play the campaign mission the key `mission_id` names (campaign.key: its id, or its
-- hard mode's) alone, seating the first player to arrive; nil for a mission there is not. Yields until someone arrives,
-- but for a Run, which nobody plays.
local function for_mission(mission_id: string): Match?
	local seats: { Seat } = {}
	local first = if RunService:IsRunMode() or campaign.parse_key(mission_id) == nil then nil else first_player()
	if first ~= nil then
		table.insert(seats, { user_id = first.UserId, name = first.DisplayName, side = 1 })
	end
	return game_modes.mission_match(mission_id, seats)
end

return table.freeze({
	from_reservation = from_reservation,
	for_mission = for_mission,
})
