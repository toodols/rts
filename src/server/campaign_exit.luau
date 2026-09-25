-- Leaving a campaign mission once it is over. Its end screen (client/ui/victory_screen.luau) offers to go back to the
-- lobby, or, once it is won, on to the next mission in campaign.MISSIONS.
--
-- Going back to the lobby is each player's own business, asked through the CampaignChoice remote:
--
-- - the client fires `"lobby"`;
-- - the server answers `{ stage = "sending" }` once it is sending them, and `{ stage = "failed", message = ... }` when
--   it cannot, or the teleport failed however many times it was tried, after which they may ask again.
--
-- Going on to the next mission is everyone's, and is voted on, through the CampaignVote remote: the client fires `true`
-- to agree and `false` to take it back. Who may vote are the players still here on a winning team (`voters`), and it
-- is carried once more than half of them agree (`tally`); someone who leaves, or sets off for the lobby, is no longer
-- one of them, so whether it is carried is looked at again then too. How the vote stands is published on Workspace as
-- VOTE_ATTRIBUTE, a JSON object: `voters` and `agreed`, user ids, `needed`, how many it takes, and `passed`, once it
-- has been carried. Played alone there is one voter, so one press carries it. What happens next is told back over
-- CampaignChoice as for the lobby, to everyone being sent.
--
-- A vote carried sends every voter on together. When there is more than one of them and the next mission may be
-- played together (its `coop`, and there are no more of them than that), this server starts it for them as a co-op
-- lobby would (see lobby/server/launch.luau): it reserves a game server, leaves the match in the MemoryStore under that
-- server's id, and teleports them all there with the match as their teleport data too. Otherwise each is teleported to
-- the lobby place, with teleport data that asks the lobby to start the mission for them as they arrive
-- (`{ campaign_next = <mission id> }`, see lobby/server/init.server.luau), which the lobby does only if their progress
-- says it is open to them. Either way they are only sent once finishing this one has been saved for all of them
-- (missions.is_settled), or SAVE_WAIT_SECONDS have passed. If it cannot be done, everyone is told why and the vote
-- starts over.
--
-- Teleports do not work in Studio, so there it fails at once, and says so.

local HttpService = game:GetService "HttpService"
local MemoryStoreService = game:GetService "MemoryStoreService"
local Players = game:GetService "Players"
local ReplicatedStorage = game:GetService "ReplicatedStorage"
local RunService = game:GetService "RunService"
local TeleportService = game:GetService "TeleportService"
local Workspace = game:GetService "Workspace"

local campaign = require(ReplicatedStorage.Shared.campaign)
local game_modes = require(ReplicatedStorage.Shared.game_modes)
local game_phase = require(ReplicatedStorage.Shared.game_phase)
local places = require(ReplicatedStorage.Shared.places)

local players = require(script.Parent.players)
local missions = require(script.Parent.missions)

type Mission = campaign.Mission
type Match = game_modes.Match

type Pending = {
	place: number,
	options: TeleportOptions,
	tries: number,
}

local campaign_choice: RemoteEvent = ReplicatedStorage.Shared.CampaignChoice
local campaign_vote: RemoteEvent = ReplicatedStorage.Shared.CampaignVote

-- the Workspace attribute how the vote on the next mission stands is published as
local VOTE_ATTRIBUTE = "campaign_vote"
-- How many times a teleport is tried before the player is told it failed, and how long between.
local ATTEMPTS = 3
local RETRY_SECONDS = 2
-- How long players going on to the next mission wait for this one's being finished to be saved.
local SAVE_WAIT_SECONDS = 15
local STUDIO_MESSAGE = "Teleports don't work in Studio: leaving a mission only works on a live server"

-- players being sent, with what they were sent with, until they leave or it fails
local pending: { [Player]: Pending } = {}
-- who has agreed to go on to the next mission, by user id
local agreed: { [number]: boolean } = {}
-- whether the vote has been carried and everyone is being sent on
local advancing = false

local function tell(player: Player, stage: "sending" | "failed", message: string?)
	campaign_choice:FireClient(player, { stage = stage, message = message })
end

-- How many of `voters` (user ids) are among `agreeing`, and how many it takes to carry the vote: more than half.
local function tally(voters: { number }, agreeing: { [number]: boolean }): (number, number)
	local count = 0
	for _, user_id in voters do
		if agreeing[user_id] == true then
			count += 1
		end
	end
	return count, #voters // 2 + 1
end

-- The mission this game goes on to, or why it cannot go on to one.
local function next_of_game(): (Mission?, string?)
	local mission_id = campaign.current_mission()
	if mission_id == nil then
		return nil, "This isn't a campaign mission"
	end
	if game_phase.phase() ~= "ended" then
		return nil, "The mission isn't over yet"
	end
	if missions.result() ~= "won" then
		return nil, "Win this mission to go on to the next"
	end
	local next_mission = campaign.next_mission(mission_id)
	if next_mission == nil then
		return nil, "There is no next mission yet"
	end
	return next_mission, nil
end

-- Who votes on going on to the next mission, by user id: every player here on a winning team, but for `leaving`, who
-- is on their way out, and anyone already on their way to the lobby. Nobody when there is no next mission to go on to.
local function voters(leaving: Player?): { Player }
	local list: { Player } = {}
	if next_of_game() == nil then
		return list
	end
	local winners = game_phase.winners()
	for _, player in Players:GetPlayers() do
		local team_id = players.team_of(player)
		if player == leaving or team_id == nil or table.find(winners, team_id) == nil then
			continue
		end
		if pending[player] ~= nil and advancing == false then
			continue
		end
		table.insert(list, player)
	end
	table.sort(list, function(a: Player, b: Player): boolean
		return a.UserId < b.UserId
	end)
	return list
end

local function user_ids(list: { Player }): { number }
	local ids = {}
	for _, player in list do
		table.insert(ids, player.UserId)
	end
	return ids
end

local function publish(ids: { number })
	if #ids == 0 then
		Workspace:SetAttribute(VOTE_ATTRIBUTE, nil)
		return
	end
	local count, needed = tally(ids, agreed)
	local agreeing = {}
	for _, user_id in ids do
		if agreed[user_id] == true then
			table.insert(agreeing, user_id)
		end
	end
	Workspace:SetAttribute(
		VOTE_ATTRIBUTE,
		HttpService:JSONEncode({
			voters = ids,
			agreed = agreeing,
			needed = needed,
			passed = advancing and count >= needed,
		})
	)
end

-- The vote starts over: nobody has agreed, and it can be carried again.
local function reset_vote()
	advancing = false
	table.clear(agreed)
	publish(user_ids(voters()))
end

local function give_up(player: Player, message: string)
	pending[player] = nil
	tell(player, "failed", message)
	-- someone whose way on failed votes again, and someone whose way to the lobby failed is a voter again
	if advancing then
		reset_vote()
	else
		publish(user_ids(voters()))
	end
end

-- Sends `player` to wherever `waiting` says, trying ATTEMPTS times in all before giving up.
local function send(player: Player, waiting: Pending)
	while pending[player] == waiting and player.Parent ~= nil do
		waiting.tries += 1
		local sent, err = pcall(function()
			TeleportService:TeleportAsync(waiting.place, { player }, waiting.options)
		end)
		if sent then
			return
		end
		warn(`sending {player.Name} on failed (try {waiting.tries}): {err}`)
		if waiting.tries >= ATTEMPTS then
			give_up(player, "Couldn't send you on. Try again")
			return
		end
		task.wait(RETRY_SECONDS)
	end
end

-- Yields until finishing the mission has been saved for every one of `going`, or SAVE_WAIT_SECONDS have passed:
-- where they are going reads their progress, so it has to be saved first. Returns those of them still here.
local function wait_settled(going: { Player }): { Player }
	local deadline = os.clock() + SAVE_WAIT_SECONDS
	while os.clock() < deadline do
		local settled = true
		for _, player in going do
			if player.Parent ~= nil and missions.is_settled(player) == false then
				settled = false
			end
		end
		if settled then
			break
		end
		task.wait(0.25)
	end
	local here = {}
	for _, player in going do
		if player.Parent ~= nil then
			table.insert(here, player)
		end
	end
	return here
end

-- Sends `player` to the lobby with `data` as their teleport data.
local function to_lobby(player: Player, data: { [string]: any })
	local options = Instance.new "TeleportOptions"
	options:SetTeleportData(data)
	local waiting: Pending = { place = places.LOBBY, options = options, tries = 0 }
	pending[player] = waiting
	tell(player, "sending", nil)
	task.spawn(function()
		wait_settled({ player })
		send(player, waiting)
	end)
end

-- The match that plays `next_mission` for `going` together, all on the one side, as a co-op lobby's would.
local function coop_match(next_mission: Mission, going: { Player }): Match?
	local mode = game_modes.campaign_mode(next_mission.id)
	if mode == nil then
		return nil
	end
	local seats = {}
	for _, player in going do
		table.insert(seats, { user_id = player.UserId, name = player.DisplayName, side = 1 })
	end
	return {
		mode = mode.id,
		preset = next_mission.preset,
		seed = game_modes.DEFAULT_SEED,
		seats = seats,
		bonuses = {},
		ally_griefing = false,
		end_mode = game_modes.DEFAULT_END_MODE,
	}
end

-- Starts `next_mission` for `going` together on a game server reserved for it, or gives up on all of them and says why.
-- Yields.
local function launch_together(next_mission: Mission, going: { Player })
	local match = coop_match(next_mission, going)
	if match == nil then
		for _, player in going do
			give_up(player, "There is no next mission yet")
		end
		return
	end
	local reserved, code, server_id = pcall(function()
		return TeleportService:ReserveServer(places.GAME)
	end)
	if reserved == false then
		warn(`reserving a game server for the next mission failed: {code}`)
		for _, player in going do
			give_up(player, "Couldn't reserve a game server")
		end
		return
	end
	-- the teleport data carries the match too, so a failure here is not the end of it
	local encoded = game_modes.encode(match)
	local stored, store_err = pcall(function()
		MemoryStoreService:GetHashMap(game_modes.MATCH_STORE):SetAsync(server_id, encoded, game_modes.MATCH_TTL)
	end)
	if stored == false then
		warn(`storing the next mission's match failed, so the game will read it from the teleport data: {store_err}`)
	end
	local options = Instance.new "TeleportOptions"
	options.ReservedServerAccessCode = code
	options:SetTeleportData({ match = encoded })
	for _, player in going do
		pending[player] = { place = places.GAME, options = options, tries = 1 }
	end
	local sent, send_err = pcall(function()
		TeleportService:TeleportAsync(places.GAME, going, options)
	end)
	if sent == false then
		warn(`teleporting to the next mission failed: {send_err}`)
		for _, player in going do
			give_up(player, "Couldn't send everyone to the next mission")
		end
	end
end

-- The vote is carried: every voter is sent on to `next_mission`, together if it may be played that way.
local function advance(next_mission: Mission, going: { Player })
	advancing = true
	publish(user_ids(going))
	local refusal = if RunService:IsStudio()
		then STUDIO_MESSAGE
		elseif places.LOBBY == 0 or places.GAME == 0 then "The places aren't set up yet"
		else nil
	if refusal ~= nil then
		for _, player in going do
			tell(player, "failed", refusal)
		end
		reset_vote()
		return
	end
	local together = #going > 1 and next_mission.coop ~= nil and #going <= next_mission.coop
	if together == false then
		for _, player in going do
			to_lobby(player, { campaign_next = next_mission.id })
		end
		return
	end
	for _, player in going do
		tell(player, "sending", nil)
	end
	task.spawn(function()
		local here = wait_settled(going)
		if #here > 0 then
			launch_together(next_mission, here)
		end
	end)
end

-- Publishes how the vote stands, with `leaving` no longer a voter, and carries it if enough have agreed.
local function review(leaving: Player?)
	if advancing then
		return
	end
	local list = voters(leaving)
	local ids = user_ids(list)
	publish(ids)
	local next_mission = next_of_game()
	local count, needed = tally(ids, agreed)
	if next_mission ~= nil and #list > 0 and count >= needed then
		advance(next_mission, list)
	end
end

local function on_vote(player: Player, agree: unknown)
	if typeof(agree) ~= "boolean" or advancing or pending[player] ~= nil then
		return
	end
	local next_mission, reason = next_of_game()
	if next_mission == nil then
		tell(player, "failed", reason)
		return
	end
	if table.find(voters(), player) == nil then
		tell(player, "failed", "Win this mission to go on to the next")
		return
	end
	agreed[player.UserId] = if agree then true else nil
	review()
end

local function on_choice(player: Player, choice: unknown)
	-- going on is voted on, however it is asked for
	if choice == "next" then
		on_vote(player, true)
		return
	end
	if choice ~= "lobby" or pending[player] ~= nil or advancing then
		return
	end
	if campaign.current_mission() == nil then
		tell(player, "failed", "This isn't a campaign mission")
		return
	end
	if game_phase.phase() ~= "ended" then
		tell(player, "failed", "The mission isn't over yet")
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
	-- someone heading back is no longer a voter, and no longer agrees
	agreed[player.UserId] = nil
	to_lobby(player, {})
	review()
end

-- A teleport that was accepted can still fail on the way; it is tried again while it has tries left.
local function on_init_failed(player: Player, result: Enum.TeleportResult, message: string)
	local waiting = pending[player]
	if waiting == nil then
		return
	end
	warn(`{player.Name}'s teleport failed ({result.Name}, try {waiting.tries}): {message}`)
	if waiting.tries >= ATTEMPTS then
		give_up(player, `Couldn't send you on: {message}`)
		return
	end
	task.wait(RETRY_SECONDS)
	send(player, waiting)
end

local function watch_team(player: Player)
	player:GetAttributeChangedSignal("team"):Connect(function()
		review()
	end)
end

local function init()
	campaign_choice.OnServerEvent:Connect(on_choice)
	campaign_vote.OnServerEvent:Connect(on_vote)
	TeleportService.TeleportInitFailed:Connect(on_init_failed)
	-- the vote opens when the game ends, and who votes changes as players come, go and change teams
	game_phase.changed(function()
		-- a mission loaded after this one (missions.begin) is voted on afresh
		if game_phase.phase() ~= "ended" and next(pending) == nil then
			advancing = false
			table.clear(agreed)
		end
		review()
	end)
	Players.PlayerAdded:Connect(watch_team)
	for _, player in Players:GetPlayers() do
		watch_team(player)
	end
	Players.PlayerRemoving:Connect(function(player: Player)
		pending[player] = nil
		agreed[player.UserId] = nil
		review(player)
	end)
end

return table.freeze({
	VOTE_ATTRIBUTE = VOTE_ATTRIBUTE,
	tally = tally,
	init = init,
})
