--!strict
-- Leaving a campaign mission once it is over. Its end screen (client/ui/victory_screen.luau) offers to go back to the
-- lobby, and, once it is won, on to the next mission in campaign.MISSIONS, or, once it is lost, to try it again.
--
-- Going back to the lobby is each player's own business, asked through the CampaignChoice remote:
--
-- - the client fires `"lobby"`;
-- - the server answers `{ stage = "sending" }` once it is sending them, and `{ stage = "failed", message = ... }` when
--   it cannot, or the teleport failed however many times it was tried (server_shared/teleports.luau), after which they
--   may ask again.
--
-- It waits first until finishing the mission has been saved for them (missions' `completed`), or SAVE_WAIT_SECONDS
-- have passed, since the lobby reads what they have finished. A teleport does not work in Studio, so there it fails at
-- once, and says so.
--
-- Going on to the next mission, or trying a lost one again, is everyone's, and is voted on, through the CampaignVote
-- remote: the client fires `true` to agree and `false` to take it back. The vote is a state machine (Stage):
--
-- - no vote while no mission has ended;
-- - "open" once one has: on going on to the next mission once it is won, if there is one, or on trying it again once
--   it is lost (`kind`). Who votes are the players here on a winning team, or once it is lost those on the players'
--   teams, but for anyone on their way to the lobby (`voters`); it is carried once more than half of them agree
--   (`tally`). Someone who leaves, or sets off for the lobby, is no longer a voter, so whether it is carried is looked
--   at again then too;
-- - "carried": everyone who voted is told they are being sent on, and going on to the next mission waits until
--   finishing this one has been saved for all of them, as going to the lobby does;
-- - "sending": the mission is loaded here, for everyone, as the mission_load command does (maps.load): no teleport, so
--   it works in Studio too. What the mission just won unlocks is the players' at once (server/unlocks.luau), so the
--   next is played with it. Once it begins there is no vote again until it has ended; if it cannot be loaded,
--   everyone is told why and the vote is open again, nobody agreeing.
--
-- How the vote stands is published (shared/mission_state.luau): which it is, who votes and who of them has agreed, how
-- many it takes, and once it has been carried. Played alone there is one voter, so one press carries it.

local ReplicatedStorage = game:GetService "ReplicatedStorage"
local ServerScriptService = game:GetService "ServerScriptService"

local campaign = require(ReplicatedStorage.Shared.campaign)
local places = require(ReplicatedStorage.Shared.places)
local mission_state = require(ReplicatedStorage.Shared.mission_state)
local decode = require(ReplicatedStorage.Shared.decode)

local remotes = require(ServerScriptService.ServerShared.remotes)
local teleports = require(ServerScriptService.ServerShared.teleports)

local players = require(script.Parent.players)
local missions = require(script.Parent.missions)
local maps = require(script.Parent.maps)

type Mission = campaign.Mission
type VoteKind = mission_state.VoteKind

export type Stage = "open" | "carried" | "sending"

-- The vote, while there is one: what it is on and the mission it plays, and whether in its hard mode, how far it has
-- got, who has agreed, by user id, and once it is carried, who is being sent on.
type Vote = {
	kind: VoteKind,
	mission: Mission,
	hard: boolean,
	stage: Stage,
	agreed: { [number]: boolean },
	going: { Player },
}

local campaign_choice: RemoteEvent = ReplicatedStorage.Shared.CampaignChoice
local campaign_vote: RemoteEvent = ReplicatedStorage.Shared.CampaignVote

-- How long leaving waits for the mission's being finished to be saved.
local SAVE_WAIT_SECONDS = 15
local CHOICE = decode.one_of({ "lobby", "next", "retry" })
local CHOICE_RATE: remotes.Rate = { per_second = 2, burst = 4 }

-- the vote, while there is one
local vote: Vote? = nil
-- the players setting off for the lobby, from when they ask until they are gone or it fails
local leaving: { [Player]: boolean } = {}

local function tell(player: Player, stage: "sending" | "failed", message: string?)
	remotes.tell(campaign_choice, player, { stage = stage, message = message })
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

-- The mission being played, once it is over, or why there is none to leave.
local function finished_mission(): (Mission?, string?)
	local mission_id = missions.mission()
	if mission_id == nil then
		return nil, "This isn't a campaign mission"
	end
	if missions.result() == nil then
		return nil, "The mission isn't over yet"
	end
	return campaign.get(mission_id) :: Mission, nil
end

-- The vote the game has just ended on, or why there is none: once it is won, going on to the next mission, if there
-- is one; once it is lost, trying this one again. Trying again, or going on from a hard mode to a mission that has one,
-- is in hard mode too.
local function vote_of_game(): (Vote?, string?)
	local here, reason = finished_mission()
	if here == nil then
		return nil, reason
	end
	local hard = missions.hard()
	if missions.result() == "lost" then
		return { kind = "retry", mission = here, hard = hard, stage = "open", agreed = {}, going = {} }, nil
	end
	local next_mission = campaign.next_mission(here.id)
	if next_mission == nil then
		return nil, "There is no next mission yet"
	end
	local next_hard = hard and next_mission.hard_mode
	return { kind = "next", mission = next_mission, hard = next_hard, stage = "open", agreed = {}, going = {} }, nil
end

-- Who votes on `open`, in user id order: every player here on a winning team, or once the mission is lost every
-- player here on a team (the enemy's is the only winner then), but for `going_out`, who is on their way out, and
-- anyone on their way to the lobby.
local function voters(open: Vote, going_out: Player?): { Player }
	local list: { Player } = {}
	local winners = missions.winners()
	for _, player in players.seated() do
		if player == going_out or leaving[player] == true then
			continue
		end
		if (table.find(winners, players.team_of(player) :: number) ~= nil) ~= (open.kind == "next") then
			continue
		end
		table.insert(list, player)
	end
	return list
end

local function user_ids(list: { Player }): { number }
	local ids = {}
	for _, player in list do
		table.insert(ids, player.UserId)
	end
	return ids
end

-- Publishes how `current` stands, `list` being who votes on it.
local function publish(current: Vote?, list: { Player })
	if current == nil or #list == 0 then
		mission_state.publish_vote(nil)
		return
	end
	local ids = user_ids(list)
	local _, needed = tally(ids, current.agreed)
	local agreeing = {}
	for _, user_id in ids do
		if current.agreed[user_id] == true then
			table.insert(agreeing, user_id)
		end
	end
	mission_state.publish_vote({
		kind = current.kind,
		voters = ids,
		agreed = agreeing,
		needed = needed,
		passed = current.stage ~= "open",
	})
end

-- Calls `ready` once finishing the mission has been saved for every one of `going`, or SAVE_WAIT_SECONDS have passed:
-- where they are going reads their progress, or forgets what is being saved, so it has to be saved first.
local function when_saved(going: { Player }, ready: () -> ())
	local function all_saved(): boolean
		for _, player in going do
			if player.Parent ~= nil and missions.is_settled(player) == false then
				return false
			end
		end
		return true
	end
	if all_saved() then
		ready()
		return
	end
	local done = false
	local stop_listening: () -> ()
	local function go()
		if done then
			return
		end
		done = true
		stop_listening()
		ready()
	end
	stop_listening = missions.completed(go)
	task.delay(SAVE_WAIT_SECONDS, go)
end

-- The vote is open again, nobody agreeing, for `failed` to have been what became of it.
local function reopen(failed: Vote)
	if vote ~= failed then
		return
	end
	failed.stage = "open"
	table.clear(failed.agreed)
	table.clear(failed.going)
	publish(failed, voters(failed))
end

-- `carried` is being sent: its mission is played here, from the start, for everyone.
local function send(carried: Vote)
	if vote ~= carried then
		return
	end
	carried.stage = "sending"
	task.spawn(function()
		local ok, err = maps.load({ mission = carried.mission.id, hard = carried.hard })
		if ok then
			return
		end
		for _, player in carried.going do
			if player.Parent ~= nil then
				tell(player, "failed", `Couldn't start the mission: {err}`)
			end
		end
		reopen(carried)
	end)
end

-- `open` is carried by `list`: they are told they are going, and are sent once this mission's being finished has
-- been saved for them, if they are going on to the next.
local function carry(open: Vote, list: { Player })
	open.stage = "carried"
	open.going = list
	publish(open, list)
	for _, player in list do
		tell(player, "sending", nil)
	end
	if open.kind == "next" then
		when_saved(list, function()
			send(open)
		end)
	else
		send(open)
	end
end

-- Publishes how the vote stands, with `going_out` no longer a voter, and carries it if enough have agreed.
local function review(going_out: Player?)
	local current = vote
	if current == nil or current.stage ~= "open" then
		return
	end
	local list = voters(current, going_out)
	publish(current, list)
	local count, needed = tally(user_ids(list), current.agreed)
	if #list > 0 and count >= needed then
		carry(current, list)
	end
end

local function on_vote(player: Player, agree: boolean)
	local current = vote
	if current == nil then
		local _, reason = vote_of_game()
		tell(player, "failed", reason)
		return
	end
	if current.stage ~= "open" then
		return
	end
	if table.find(voters(current), player) == nil then
		tell(player, "failed", "This vote isn't yours")
		return
	end
	if agree then
		current.agreed[player.UserId] = true
	else
		current.agreed[player.UserId] = nil
	end
	review()
end

-- `player` is not going to the lobby after all, and why: they are a voter again.
local function stay(player: Player, reason: string)
	leaving[player] = nil
	tell(player, "failed", reason)
	review()
end

-- Sends `player` to the lobby, once finishing the mission has been saved for them.
local function to_lobby(player: Player)
	leaving[player] = true
	tell(player, "sending", nil)
	local current = vote
	if current ~= nil then
		-- someone heading back is no longer a voter, and no longer agrees
		current.agreed[player.UserId] = nil
	end
	when_saved({ player }, function()
		if player.Parent == nil then
			return
		end
		local options = Instance.new "TeleportOptions"
		local sent = teleports.send({ player }, places.LOBBY, options, function(gone: Player, reason: string)
			stay(gone, `Couldn't send you on: {reason}`)
		end)
		if sent == false then
			stay(player, "Couldn't send you on. Try again")
		end
	end)
end

local function on_choice(player: Player, choice: string)
	-- going on, or trying again, is voted on, however it is asked for
	if choice ~= "lobby" then
		on_vote(player, true)
		return
	end
	local current = vote
	if leaving[player] == true or (current ~= nil and current.stage ~= "open") then
		return
	end
	local _, reason = finished_mission()
	if reason ~= nil then
		tell(player, "failed", reason)
		return
	end
	local refused = teleports.refusal(places.LOBBY)
	if refused ~= nil then
		tell(player, "failed", refused)
		return
	end
	to_lobby(player)
	review()
end

-- The mission has begun or ended: a mission ended opens its vote, and one begun ends whatever vote there was.
local function on_mission_changed()
	if missions.result() == nil then
		vote = nil
		mission_state.publish_vote(nil)
		return
	end
	if vote == nil then
		vote = vote_of_game()
		review()
	end
end

local function init()
	remotes.listen(campaign_choice, { args = { CHOICE }, rate = CHOICE_RATE }, on_choice)
	remotes.listen(campaign_vote, { args = { decode.boolean }, rate = CHOICE_RATE }, on_vote)
	missions.changed(on_mission_changed)
	-- who votes changes as players change teams
	players.on_team_changed(function()
		review()
	end)
end

-- A player leaving: they no longer vote, and are no longer being sent on.
local function player_removing(player: Player)
	leaving[player] = nil
	local current = vote
	if current ~= nil then
		current.agreed[player.UserId] = nil
	end
	review(player)
end

-- How far the vote has got, if there is one: for a test.
local function stage(): Stage?
	local current = vote
	return if current ~= nil then current.stage else nil
end

return table.freeze({
	tally = tally,
	init = init,
	stage = stage,
	player_removing = player_removing,
})
