-- Leaving a campaign mission once it is over. Its end screen (client/ui/victory_screen.luau) offers to go back to the
-- lobby, or, once it is won, on to the next mission in campaign.MISSIONS, and asks through the CampaignChoice remote:
--
-- - the client fires `"lobby"` or `"next"`;
-- - the server answers `{ stage = "sending" }` once it is sending them, and `{ stage = "failed", message = ... }` when
--   it cannot, or the teleport failed however many times it was tried, after which they may ask again.
--
-- Either way the player is teleported to the lobby place. For the next mission the teleport data asks the lobby to
-- start it for them as they arrive (`{ campaign_next = <mission id> }`, see lobby/server/init.server.luau), which the
-- lobby does only if their progress says it is open to them; so they are only sent once finishing this one has been
-- saved (missions.is_settled), or SAVE_WAIT_SECONDS have passed. Nothing is asked of the client but which of the two:
-- the mission after this one is worked out here, and only offered to a player on a winning team.
--
-- Teleports do not work in Studio, so there it fails at once, and says so.

local Players = game:GetService "Players"
local ReplicatedStorage = game:GetService "ReplicatedStorage"
local RunService = game:GetService "RunService"
local TeleportService = game:GetService "TeleportService"

local campaign = require(ReplicatedStorage.Shared.campaign)
local game_phase = require(ReplicatedStorage.Shared.game_phase)
local places = require(ReplicatedStorage.Shared.places)

local players = require(script.Parent.players)
local missions = require(script.Parent.missions)

type Pending = {
	options: TeleportOptions,
	tries: number,
}

local campaign_choice: RemoteEvent = ReplicatedStorage.Shared.CampaignChoice

-- How many times a teleport is tried before the player is told it failed, and how long between.
local ATTEMPTS = 3
local RETRY_SECONDS = 2
-- How long a player going on to the next mission waits for this one's being finished to be saved.
local SAVE_WAIT_SECONDS = 15
local STUDIO_MESSAGE = "Teleports don't work in Studio: leaving a mission only works on a live server"

-- players being sent, with what they were sent with, until they leave or it fails
local pending: { [Player]: Pending } = {}

local function tell(player: Player, stage: "sending" | "failed", message: string?)
	campaign_choice:FireClient(player, { stage = stage, message = message })
end

local function give_up(player: Player, message: string)
	pending[player] = nil
	tell(player, "failed", message)
end

-- Sends `player` to the lobby with `waiting`'s options, trying ATTEMPTS times in all before giving up.
local function send(player: Player, waiting: Pending)
	while pending[player] == waiting and player.Parent ~= nil do
		waiting.tries += 1
		local sent, err = pcall(function()
			TeleportService:TeleportAsync(places.LOBBY, { player }, waiting.options)
		end)
		if sent then
			return
		end
		warn(`sending {player.Name} to the lobby failed (try {waiting.tries}): {err}`)
		if waiting.tries >= ATTEMPTS then
			give_up(player, "Couldn't get you to the lobby. Try again")
			return
		end
		task.wait(RETRY_SECONDS)
	end
end

-- Where `player` asking for `choice` is to be sent, as the teleport data to send them with, or why they may not go.
local function destination(player: Player, choice: string): ({ [string]: any }?, string?)
	local mission_id = campaign.current_mission()
	if mission_id == nil then
		return nil, "This isn't a campaign mission"
	end
	if game_phase.phase() ~= "ended" then
		return nil, "The mission isn't over yet"
	end
	if choice == "lobby" then
		return {}, nil
	end
	local team_id = players.team_of(player)
	if missions.result() ~= "won" or team_id == nil or table.find(game_phase.winners(), team_id) == nil then
		return nil, "Win this mission to go on to the next"
	end
	local next_mission = campaign.next_mission(mission_id)
	if next_mission == nil then
		return nil, "There is no next mission yet"
	end
	return { campaign_next = next_mission.id }, nil
end

local function on_choice(player: Player, choice: unknown)
	if choice ~= "lobby" and choice ~= "next" then
		return
	end
	if pending[player] ~= nil then
		return
	end
	local data, reason = destination(player, choice)
	if data == nil then
		tell(player, "failed", reason)
		return
	end
	if RunService:IsStudio() then
		tell(player, "failed", STUDIO_MESSAGE)
		return
	end
	if places.LOBBY == 0 then
		tell(player, "failed", "The lobby place isn't set up yet")
		return
	end
	local options = Instance.new "TeleportOptions"
	options:SetTeleportData(data)
	local waiting: Pending = { options = options, tries = 0 }
	pending[player] = waiting
	tell(player, "sending", nil)
	task.spawn(function()
		-- the lobby reads their progress to see whether the next mission is open to them, so it has to be saved first
		local deadline = os.clock() + SAVE_WAIT_SECONDS
		while missions.is_settled(player) == false and os.clock() < deadline do
			task.wait(0.25)
		end
		send(player, waiting)
	end)
end

-- A teleport that was accepted can still fail on the way; it is tried again while it has tries left.
local function on_init_failed(player: Player, result: Enum.TeleportResult, message: string)
	local waiting = pending[player]
	if waiting == nil then
		return
	end
	warn(`{player.Name}'s teleport to the lobby failed ({result.Name}, try {waiting.tries}): {message}`)
	if waiting.tries >= ATTEMPTS then
		give_up(player, `Couldn't get you to the lobby: {message}`)
		return
	end
	task.wait(RETRY_SECONDS)
	send(player, waiting)
end

local function init()
	campaign_choice.OnServerEvent:Connect(on_choice)
	TeleportService.TeleportInitFailed:Connect(on_init_failed)
	Players.PlayerRemoving:Connect(function(player: Player)
		pending[player] = nil
	end)
end

return table.freeze({
	init = init,
})
