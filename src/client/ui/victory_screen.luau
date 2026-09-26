-- What covers the screen once the game has ended (see shared/game_phase.luau): VICTORY for a player whose team is among
-- the winners, DEFEAT for one whose team is not, and GAME OVER for someone who only watched, with the server's line on
-- how it was won beneath. It is the same for every way a game ends, against the scavengers or each other.
--
-- Under that is what every team did over the game (server/match_stats.luau): the damage it dealt and what that was
-- worth, what it killed and lost, and the metal it made. When more than one player played, the one whose damage was
-- worth the most is named the MVP.
--
-- A campaign mission's end also offers the way out (see server/campaign_exit.luau): back to the lobby, and, once it is
-- won, on to the next mission, if there is one, or once it is lost, a retry. Going back asks the server over the
-- CampaignChoice remote; going on or retrying is a vote, over the CampaignVote remote, carried once more than half of
-- the players who may vote agree. Played together, the button is a vote the player can take back, and under it is
-- everyone's headshot, lit with a tick once they have agreed; played alone, one press does it. What the server answers,
-- that the player is on their way or why they are not, is shown under the buttons.
--
-- Any end can be put away to play on (the world keeps going after the end, see server/init.server.luau), which leaves
-- a small button at the top of the screen that brings it back.
--
-- A campaign mission won that unlocks something first reveals it (unlock_reveal.luau), under the result, and only
-- then offers the way out.

local Players = game:GetService "Players"
local ReplicatedStorage = game:GetService "ReplicatedStorage"
local Workspace = game:GetService "Workspace"

local React = require(ReplicatedStorage.Packages.react)

local game_phase = require(ReplicatedStorage.Shared.game_phase)
local seating = require(ReplicatedStorage.Shared.seating)
local campaign = require(ReplicatedStorage.Shared.campaign)
local campaign_progress = require(ReplicatedStorage.Shared.campaign_progress)
local mission_state = require(ReplicatedStorage.Shared.mission_state)
local match_report = require(ReplicatedStorage.Shared.match_report)

local unlock_reveal = require(ReplicatedStorage.Client.ui.unlock_reveal)
local scavenger_block = require(ReplicatedStorage.Client.ui.scavenger_block)

local format = require(ReplicatedStorage.ClientShared.format)
local campaign_standing = require(ReplicatedStorage.ClientShared.campaign_standing)
local use_store = require(ReplicatedStorage.ClientShared.use_store)

local UnlockReveal = unlock_reveal.UnlockReveal
local UnlockVignette = unlock_reveal.UnlockVignette

local local_player = Players.LocalPlayer

-- What this player had unlocked before the game ended, so that a win reveals only what is new to them. It follows
-- their unlocks until then (`init`): the server ends the game before it publishes what winning unlocked
-- (server/missions' `win`), so what it publishes after is left out, until a game is playing again.
local unlocked_before: { [string]: boolean } = {}

local campaign_choice: RemoteEvent = ReplicatedStorage.Shared.CampaignChoice
local campaign_vote: RemoteEvent = ReplicatedStorage.Shared.CampaignVote

type Outcome = "victory" | "defeat" | "over"

type TeamStats = match_report.TeamStats

-- how long after the game ends the screen comes up, so the last of it can be seen blowing up first
local END_SCREEN_DELAY = 5

-- The stats' columns, after the team's name: what each is headed and which figure it shows.
local COLUMNS: { { heading: string, key: string } } = {
	{ heading = "DAMAGE", key = "damage" },
	{ heading = "DESTROYED", key = "destroyed" },
	{ heading = "KILLS", key = "kills" },
	{ heading = "LOST", key = "lost" },
	{ heading = "METAL", key = "metal" },
}
type Choice = "lobby" | "next" | "retry"

type Vote = mission_state.Vote

-- Where a choice has got: nothing asked yet, on the way, or refused or failed and why.
type ChoiceStatus = {
	stage: "idle" | "sending" | "failed",
	choice: Choice?,
	message: string?,
}

local function outcome(): Outcome
	local team = seating.team_of(local_player)
	if seating.is_spectator(local_player) or team == nil then
		return "over"
	end
	return if table.find(game_phase.winners(), team) ~= nil then "victory" else "defeat"
end

local TITLES: { [Outcome]: string } = {
	victory = "VICTORY",
	defeat = "DEFEAT",
	over = "GAME OVER",
}

local SENDING: { [Choice]: string } = {
	lobby = "Heading back to the lobby...",
	next = "Heading to the next mission...",
	retry = "Restarting the mission...",
}

-- Whether the game has ended long enough ago for the screen to be up. Redraws whenever the phase, or who won, changes,
-- and once the wait after it ended is over.
local function use_ending(): boolean
	use_store.use_changes(game_phase.changed)
	-- the end the wait has run out for, which the timer settles even should the server's clock say it is a hair early
	local waited_for, set_waited_for = React.useState(nil :: number?)
	local ended_at = if game_phase.phase() == "ended" then game_phase.ended_at() or 0 else nil
	local wait = if ended_at ~= nil then ended_at + END_SCREEN_DELAY - Workspace:GetServerTimeNow() else 0
	React.useEffect(function(): (() -> ())?
		if ended_at == nil or wait <= 0 then
			return nil
		end
		local thread = task.delay(wait, set_waited_for, ended_at)
		return function()
			task.cancel(thread)
		end
	end, { ended_at })
	return ended_at ~= nil and (wait <= 0 or waited_for == ended_at)
end

-- The stats the server published once the game ended, redrawn when they arrive; nil until they have.
local function use_stats(): { TeamStats }?
	return use_store.use_store(match_report.read, match_report.changed)
end

-- How the vote on going on stands, redrawn as it changes; nil while there is none.
local function use_vote(): Vote?
	return use_store.use_store(mission_state.vote, mission_state.subscribe_vote)
end

-- Everyone's headshot that has been fetched, by user id, kept for as long as the game is: they do not change.
local headshots: { [number]: string } = {}

-- The headshots of `user_ids`, as each arrives; one not fetched yet, or that could not be, is missing.
local function use_headshots(user_ids: { number }): { [number]: string }
	local _, bump = React.useState(0)
	local key = table.concat(user_ids, ",")
	React.useEffect(function(): (() -> ())?
		local live = true
		for _, user_id in user_ids do
			if headshots[user_id] ~= nil then
				continue
			end
			task.spawn(function()
				local ok, image = pcall(
					Players.GetUserThumbnailAsync,
					Players,
					user_id,
					Enum.ThumbnailType.HeadShot,
					Enum.ThumbnailSize.Size60x60
				)
				if ok and typeof(image) == "string" then
					headshots[user_id] = image
					if live then
						bump(function(count: number): number
							return count + 1
						end)
					end
				end
			end)
		end
		return function()
			live = false
		end
	end, { key })
	return headshots
end

-- The player whose damage was worth the most, when more than one played; nil otherwise, or if nobody did any.
local function mvp_of(rows: { TeamStats }): TeamStats?
	local best: TeamStats? = nil
	local playing = 0
	for _, row in rows do
		if row.player ~= true then
			continue
		end
		playing += 1
		if
			best == nil
			or row.destroyed > best.destroyed
			or (row.destroyed == best.destroyed and row.damage > best.damage)
		then
			best = row
		end
	end
	return if playing >= 2 and best ~= nil and best.destroyed > 0 then best else nil
end

local function StatsRow(props: { cells: { string }, tag: string, order: number })
	local cells: { [string]: any } = {}
	for index, text in props.cells do
		cells[`Cell{index}`] = React.createElement("TextLabel", {
			[React.Tag] = if index == 1 then "victory-stat name" else "victory-stat",
			LayoutOrder = index,
			Text = text,
		})
	end
	return React.createElement("Frame", {
		[React.Tag] = props.tag,
		LayoutOrder = props.order,
	}, cells)
end

-- What every team did, a row each under a row of headings: the player's own team lit, the winners in the win's colour,
-- and the MVP beneath when there is one.
local function Stats(props: { rows: { TeamStats }, LayoutOrder: number })
	local own_team = seating.team_of(local_player)
	local mvp = mvp_of(props.rows)
	local headings = { "TEAM" }
	for _, column in COLUMNS do
		table.insert(headings, column.heading)
	end
	local children: { [string]: any } = {
		Headings = React.createElement(StatsRow, { cells = headings, tag = "victory-stats-row headings", order = 0 }),
	}
	for index, row in props.rows do
		local cells = { if mvp == row then `★ {format.escape(row.name)}` else format.escape(row.name) }
		for _, column in COLUMNS do
			table.insert(cells, format.tally((row :: any)[column.key]))
		end
		local tag = "victory-stats-row"
		if row.won then
			tag ..= " won"
		end
		if row.team == own_team then
			tag ..= " own"
		end
		children[`Team{row.team}`] = React.createElement(StatsRow, { cells = cells, tag = tag, order = index })
	end

	return React.createElement("Frame", {
		[React.Tag] = "victory-stats",
		LayoutOrder = props.LayoutOrder,
	}, {
		Table = React.createElement("Frame", {
			[React.Tag] = "victory-stats-table",
			LayoutOrder = 1,
		}, children),
		Mvp = if mvp ~= nil
			then React.createElement("TextLabel", {
				[React.Tag] = "victory-mvp",
				LayoutOrder = 2,
				Text = `MVP  ★  {format.escape(mvp.name)}  —  {format.tally(mvp.destroyed)} metal destroyed`,
			})
			else nil,
	})
end

-- What the server last said about the player's choice, a way to ask to go back to the lobby, and a way to vote on going
-- on or retrying (`kind`): `alone`, agreeing is going, so it is shown as on its way; together, it waits on the others.
local function use_choice(): (ChoiceStatus, (choice: Choice) -> (), (agree: boolean, alone: boolean, kind: Choice) -> ())
	local status, set_status = React.useState({ stage = "idle", choice = nil, message = nil } :: ChoiceStatus)
	React.useEffect(function()
		local connection = campaign_choice.OnClientEvent:Connect(function(reply: any)
			if typeof(reply) ~= "table" then
				return
			end
			set_status(function(previous: ChoiceStatus): ChoiceStatus
				return {
					stage = if reply.stage == "sending" then "sending" else "failed",
					choice = previous.choice,
					message = if typeof(reply.message) == "string" then reply.message else nil,
				}
			end)
		end)
		return function()
			connection:Disconnect()
		end
	end, {})
	local choose = React.useCallback(function(choice: Choice)
		set_status({ stage = "sending", choice = choice, message = nil })
		campaign_choice:FireServer(choice)
	end, {})
	local vote = React.useCallback(function(agree: boolean, alone: boolean, kind: Choice)
		set_status({ stage = if alone and agree then "sending" else "idle", choice = kind, message = nil })
		campaign_vote:FireServer(agree)
	end, {})
	return status, choose, vote
end

local function ChoiceButton(props: {
	text: string,
	primary: boolean,
	enabled: boolean,
	order: number,
	on_click: () -> (),
})
	local tag = if props.primary then "victory-button primary" else "victory-button"
	-- the label is a child of its own: the gradient on the button's face would tint the button's own text to match it
	return React.createElement("TextButton", {
		[React.Tag] = if props.enabled then tag else `{tag} disabled`,
		LayoutOrder = props.order,
		Text = "",
		AutoButtonColor = false,
		Interactable = props.enabled,
		[React.Event.Activated] = props.on_click,
	}, {
		Label = React.createElement("TextLabel", {
			[React.Tag] = "victory-button-label",
			Text = props.text,
		}),
	})
end

-- The button that puts the screen away to play on.
local function ContinueButton(props: { on_continue: () -> () })
	return React.createElement(ChoiceButton, {
		text = "Continue playing",
		primary = false,
		enabled = true,
		order = 0,
		on_click = props.on_continue,
	})
end

-- Who votes on going on, a headshot each, in the order the server lists them: lit and ticked once they have agreed,
-- dimmed until then, and how many have agreed of how many it takes beside them.
local function Voters(props: { vote: Vote, LayoutOrder: number })
	local images = use_headshots(props.vote.voters)
	local children: { [string]: any } = {}
	for index, user_id in props.vote.voters do
		local agreed = table.find(props.vote.agreed, user_id) ~= nil
		children[`Voter{user_id}`] = React.createElement("ImageLabel", {
			[React.Tag] = if agreed then "victory-voter agreed" else "victory-voter",
			LayoutOrder = index,
			Image = images[user_id] or "",
			ImageTransparency = if agreed then 0 else 0.65,
		}, {
			Tick = if agreed
				then React.createElement("TextLabel", {
					[React.Tag] = "victory-voter-tick",
					Text = "✓",
				})
				else nil,
		})
	end
	children.Count = React.createElement("TextLabel", {
		[React.Tag] = "victory-vote-count",
		LayoutOrder = #props.vote.voters + 1,
		Text = `{#props.vote.agreed}/{props.vote.needed}`,
	})
	return React.createElement("Frame", {
		[React.Tag] = "victory-voters",
		LayoutOrder = props.LayoutOrder,
	}, children)
end

-- The way out of a campaign mission: playing on, back to the lobby, and on to the next mission for someone who won it,
-- if the campaign has one, or a retry for someone who lost it, which played together is a vote.
local function CampaignChoices(props: { mission_id: string, won: boolean, on_continue: () -> () })
	local status, choose, vote_for = use_choice()
	local vote = use_vote()
	local next_mission = campaign.next_mission(props.mission_id)
	local idle = status.stage ~= "sending" and (vote == nil or vote.passed == false)
	local together = vote ~= nil and #vote.voters > 1
	local agreed = vote ~= nil and table.find(vote.agreed, local_player.UserId) ~= nil
	local message = if status.stage == "sending" and status.choice ~= nil
		then SENDING[status.choice]
		else status.message

	local buttons: { [string]: any } = {
		Continue = React.createElement(ContinueButton, { on_continue = props.on_continue }),
		Lobby = React.createElement(ChoiceButton, {
			text = "Back to lobby",
			primary = props.won and next_mission == nil,
			enabled = idle,
			order = 1,
			on_click = function()
				choose "lobby"
			end,
		}),
	}
	if props.won and next_mission ~= nil then
		-- from a hard mode it is played in hard mode too, if it has one (server/campaign_exit.luau)
		local next_label = if mission_state.hard() and next_mission.hard_mode
			then `{next_mission.label} (Hard)`
			else next_mission.label
		buttons.Next = React.createElement(ChoiceButton, {
			text = if together and agreed then "Withdraw vote" else `Next mission: {next_label}`,
			primary = together == false or agreed == false,
			enabled = idle,
			order = 2,
			on_click = function()
				vote_for(agreed == false, together == false, "next")
			end,
		})
	elseif props.won == false then
		buttons.Retry = React.createElement(ChoiceButton, {
			text = if together and agreed then "Withdraw vote" else "Retry",
			primary = together == false or agreed == false,
			enabled = idle,
			order = 2,
			on_click = function()
				vote_for(agreed == false, together == false, "retry")
			end,
		})
	end

	return React.createElement(React.Fragment, nil, {
		Choices = React.createElement("Frame", {
			[React.Tag] = "victory-choices",
			LayoutOrder = 5,
		}, buttons),
		Voters = if together and (next_mission ~= nil or props.won == false)
			then React.createElement(Voters, { vote = vote :: Vote, LayoutOrder = 6 })
			else nil,
		Status = if message ~= nil
			then React.createElement("TextLabel", {
				[React.Tag] = if status.stage == "failed" then "victory-status failed" else "victory-status",
				LayoutOrder = 7,
				Text = message,
			})
			else nil,
	})
end

-- The screen once the game has ended, hidden while it is put away to play on (kept, so that nothing on it starts over
-- when it is brought back). A campaign mission won that unlocks something new to the player reveals it
-- (unlock_reveal.luau) between the result and the way out, which only appears once every card is open.
local function Ending(props: { hidden: boolean, on_continue: () -> () })
	local result = outcome()
	local mission_id = mission_state.mission()
	local mission = if mission_id ~= nil then campaign.get(mission_id) else nil
	-- only what the player had not unlocked already
	local won_unlocks: { string } = {}
	if result == "victory" and mission ~= nil then
		for _, name in campaign.unlocks_for(mission, mission_state.hard()) do
			if unlocked_before[name] ~= true then
				table.insert(won_unlocks, name)
			end
		end
	end
	local unlocks = if #won_unlocks > 0 then won_unlocks else nil
	local revealed, set_revealed = React.useState(false)
	local on_revealed = React.useCallback(function()
		set_revealed(true)
	end, {})
	local choices_shown = unlocks == nil or revealed
	local stats = use_stats()

	local choices = nil
	if choices_shown and mission_id ~= nil then
		choices = React.createElement(CampaignChoices, {
			mission_id = mission_id,
			won = result == "victory",
			on_continue = props.on_continue,
		})
	elseif choices_shown then
		choices = React.createElement("Frame", {
			[React.Tag] = "victory-choices",
			LayoutOrder = 5,
		}, {
			Continue = React.createElement(ContinueButton, { on_continue = props.on_continue }),
		})
	end

	return React.createElement("Frame", {
		[React.Tag] = `victory-screen {result}`,
		Visible = props.hidden == false,
	}, {
		Vignette = if unlocks ~= nil then React.createElement(UnlockVignette) else nil,
		Layout = React.createElement("Frame", {
			[React.Tag] = "victory-layout",
		}, {
			Plate = React.createElement("Frame", {
				[React.Tag] = "victory-plate",
			}, {
				Title = React.createElement("TextLabel", {
					[React.Tag] = "victory-title",
					LayoutOrder = 1,
					Text = TITLES[result],
				}),
				Reason = React.createElement("TextLabel", {
					[React.Tag] = "victory-reason",
					LayoutOrder = 2,
					Text = game_phase.end_reason() or "",
				}),
				Unlocks = if unlocks ~= nil
					then React.createElement(UnlockReveal, {
						def_names = unlocks,
						on_done = on_revealed,
						LayoutOrder = 3,
					})
					else nil,
				Stats = if stats ~= nil then React.createElement(Stats, { rows = stats, LayoutOrder = 4 }) else nil,
				Choices = choices,
			}),
		}),
	})
end

-- The end screen, or, while it is put away to play on, the button beside the resource bar that brings it back, which
-- sits further out when the bar is wider for the scavengers' difficulty. Which end it was put
-- away for is kept, so the next game to end (a mission loaded after this one) shows its own.
local function VictoryScreen()
	local ending = use_ending()
	local put_away_for, set_put_away_for = React.useState(nil :: number?)
	local scavengers = scavenger_block.use_difficulty() ~= nil
	if ending == false then
		return nil
	end
	local ended_at = game_phase.ended_at() or 0
	local hidden = put_away_for == ended_at
	return React.createElement(React.Fragment, nil, {
		Screen = React.createElement(Ending, {
			hidden = hidden,
			on_continue = function()
				set_put_away_for(ended_at)
			end,
		}),
		Reopen = if hidden
			then React.createElement("TextButton", {
				[React.Tag] = if scavengers
					then `victory-reopen {outcome()} with-scavengers`
					else `victory-reopen {outcome()}`,
				Text = "",
				AutoButtonColor = false,
				[React.Event.Activated] = function()
					set_put_away_for(nil)
				end,
			}, {
				Label = React.createElement("TextLabel", {
					[React.Tag] = "victory-reopen-label",
					Text = `{TITLES[outcome()]}  ·  RESULTS`,
				}),
			})
			else nil,
	})
end

-- Follows what the player has unlocked until the game ends (`unlocked_before`).
local function init()
	local function note_unlocks()
		if game_phase.phase() ~= "ended" then
			unlocked_before = campaign_progress.unlocks_of(local_player)
		end
	end
	note_unlocks()
	campaign_standing.subscribe(note_unlocks)
	game_phase.changed(note_unlocks)
end

return table.freeze({
	init = init,
	VictoryScreen = VictoryScreen,
})
