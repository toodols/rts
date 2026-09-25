-- What covers the screen once the game has ended (see shared/game_phase.luau): VICTORY for a player whose team is among
-- the winners, DEFEAT for one whose team is not, and GAME OVER for someone who only watched, with the server's line on
-- how it was won beneath. It is the same for every way a game ends, against the scavengers or each other.
--
-- Under that is what every team did over the game (server/match_stats.luau): the damage it dealt and what that was
-- worth, what it killed and lost, and the metal it made. When more than one player played, the one whose damage was
-- worth the most is named the MVP.
--
-- A campaign mission's end also offers the way out (see server/campaign_exit.luau): back to the lobby, and, once it is
-- won, on to the next mission, if there is one. Going back asks the server over the CampaignChoice remote; going on is
-- a vote, over the CampaignVote remote, carried once more than half of the winners still here agree. Played together,
-- the button to go on is a vote the player can take back, and under it is everyone's headshot, lit with a tick once
-- they have agreed; played alone, one press goes on. What the server answers, that the player is on their way or why
-- they are not, is shown under the buttons.
--
-- Any end can be put away to play on (the world keeps going after the end, see server/init.server.luau), which leaves
-- a small button at the top of the screen that brings it back.
--
-- A campaign mission won that unlocks something first reveals it (unlock_reveal.luau), under the result, and only
-- then offers the way out.

local HttpService = game:GetService "HttpService"
local Players = game:GetService "Players"
local ReplicatedStorage = game:GetService "ReplicatedStorage"
local Workspace = game:GetService "Workspace"

local React = require(ReplicatedStorage.Packages.react)

local config = require(ReplicatedStorage.Shared.config)
local game_phase = require(ReplicatedStorage.Shared.game_phase)
local campaign = require(ReplicatedStorage.Shared.campaign)

local unlock_reveal = require(ReplicatedStorage.Client.ui.unlock_reveal)
local scavenger_block = require(ReplicatedStorage.Client.ui.scavenger_block)
local wave_block = require(ReplicatedStorage.Client.ui.wave_block)

local UnlockReveal = unlock_reveal.UnlockReveal
local UnlockVignette = unlock_reveal.UnlockVignette

local local_player = Players.LocalPlayer
local campaign_choice: RemoteEvent = ReplicatedStorage.Shared.CampaignChoice
local campaign_vote: RemoteEvent = ReplicatedStorage.Shared.CampaignVote

type Outcome = "victory" | "defeat" | "over"

-- One team's line of the stats, as server/match_stats.luau publishes it.
type TeamStats = {
	team: number,
	name: string,
	player: boolean,
	won: boolean,
	damage: number,
	destroyed: number,
	kills: number,
	lost: number,
	metal: number,
}

-- how long after the game ends the screen comes up, so the last of it can be seen blowing up first
local END_SCREEN_DELAY = config.END_SCREEN_DELAY_SECONDS

-- the Workspace attribute server/match_stats.luau publishes the stats as
local STATS_ATTRIBUTE = "match_stats"
-- the Workspace attribute server/campaign_exit.luau publishes how the vote on going on stands as
local VOTE_ATTRIBUTE = "campaign_vote"

-- The stats' columns, after the team's name: what each is headed and which figure it shows.
local COLUMNS: { { heading: string, key: string } } = {
	{ heading = "DAMAGE", key = "damage" },
	{ heading = "DESTROYED", key = "destroyed" },
	{ heading = "KILLS", key = "kills" },
	{ heading = "LOST", key = "lost" },
	{ heading = "METAL", key = "metal" },
}
type Choice = "lobby" | "next"

-- How the vote on going on to the next mission stands, as server/campaign_exit.luau publishes it: who votes and who of
-- them has agreed, by user id, how many it takes, and whether it has been carried.
type Vote = {
	voters: { number },
	agreed: { number },
	needed: number,
	passed: boolean,
}

-- Where a choice has got: nothing asked yet, on the way, or refused or failed and why.
type ChoiceStatus = {
	stage: "idle" | "sending" | "failed",
	choice: Choice?,
	message: string?,
}

local function outcome(): Outcome
	local team = local_player:GetAttribute "team"
	if local_player:GetAttribute "spectator" == true or typeof(team) ~= "number" then
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
}

-- Whether the game has ended long enough ago for the screen to be up. Redraws whenever the phase, or who won, changes,
-- and once the wait after it ended is over.
local function use_ending(): boolean
	local _, bump = React.useState(0)
	local redraw = React.useCallback(function()
		bump(function(count: number): number
			return count + 1
		end)
	end, {})
	React.useEffect(function()
		local connections = game_phase.changed(redraw)
		return function()
			for _, connection in connections do
				connection:Disconnect()
			end
		end
	end, {})
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
	local raw, set_raw = React.useState(Workspace:GetAttribute(STATS_ATTRIBUTE))
	React.useEffect(function()
		local connection = Workspace:GetAttributeChangedSignal(STATS_ATTRIBUTE):Connect(function()
			set_raw(Workspace:GetAttribute(STATS_ATTRIBUTE))
		end)
		return function()
			connection:Disconnect()
		end
	end, {})
	return React.useMemo(function(): { TeamStats }?
		if typeof(raw) ~= "string" then
			return nil
		end
		local ok, decoded = pcall(HttpService.JSONDecode, HttpService, raw)
		return if ok and typeof(decoded) == "table" and #decoded > 0 then decoded else nil
	end, { raw })
end

-- How the vote on going on stands, redrawn as it changes; nil while there is none.
local function use_vote(): Vote?
	local raw, set_raw = React.useState(Workspace:GetAttribute(VOTE_ATTRIBUTE))
	React.useEffect(function()
		local connection = Workspace:GetAttributeChangedSignal(VOTE_ATTRIBUTE):Connect(function()
			set_raw(Workspace:GetAttribute(VOTE_ATTRIBUTE))
		end)
		return function()
			connection:Disconnect()
		end
	end, {})
	return React.useMemo(function(): Vote?
		if typeof(raw) ~= "string" then
			return nil
		end
		local ok, decoded = pcall(HttpService.JSONDecode, HttpService, raw)
		if ok == false or typeof(decoded) ~= "table" or typeof(decoded.voters) ~= "table" then
			return nil
		end
		return {
			voters = decoded.voters,
			agreed = if typeof(decoded.agreed) == "table" then decoded.agreed else {},
			needed = if typeof(decoded.needed) == "number" then decoded.needed else #decoded.voters // 2 + 1,
			passed = decoded.passed == true,
		}
	end, { raw })
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

-- A figure short enough for its column: 950, 12,400, 125k, 1.2M.
local function figure(value: number): string
	if value >= 1e6 then
		return `{string.format("%.1f", value / 1e6)}M`
	elseif value >= 1e5 then
		return `{math.floor(value / 1e3 + 0.5)}k`
	end
	local digits = tostring(math.floor(value + 0.5))
	return (string.reverse((string.gsub(string.reverse(digits), "(%d%d%d)(%d)", "%1,%2"))))
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
	local own_team = local_player:GetAttribute "team"
	local mvp = mvp_of(props.rows)
	local headings = { "TEAM" }
	for _, column in COLUMNS do
		table.insert(headings, column.heading)
	end
	local children: { [string]: any } = {
		Headings = React.createElement(StatsRow, { cells = headings, tag = "victory-stats-row headings", order = 0 }),
	}
	for index, row in props.rows do
		local cells = { if mvp == row then `★ {row.name}` else row.name }
		for _, column in COLUMNS do
			table.insert(cells, figure((row :: any)[column.key]))
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
				Text = `MVP  ★  {mvp.name}  —  {figure(mvp.destroyed)} metal destroyed`,
			})
			else nil,
	})
end

-- What the server last said about the player's choice, a way to ask to go back to the lobby, and a way to vote on going
-- on: `alone`, agreeing is going, so it is shown as on its way; together, it waits on the others.
local function use_choice(): (ChoiceStatus, (choice: Choice) -> (), (agree: boolean, alone: boolean) -> ())
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
	local vote = React.useCallback(function(agree: boolean, alone: boolean)
		set_status({ stage = if alone and agree then "sending" else "idle", choice = "next", message = nil })
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
-- if the campaign has one, which played together is a vote.
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
			primary = props.won == false or next_mission == nil,
			enabled = idle,
			order = 1,
			on_click = function()
				choose "lobby"
			end,
		}),
	}
	if props.won and next_mission ~= nil then
		buttons.Next = React.createElement(ChoiceButton, {
			text = if together and agreed then "Withdraw vote" else `Next mission: {next_mission.label}`,
			primary = together == false or agreed == false,
			enabled = idle,
			order = 2,
			on_click = function()
				vote_for(agreed == false, together == false)
			end,
		})
	end

	return React.createElement(React.Fragment, nil, {
		Choices = React.createElement("Frame", {
			[React.Tag] = "victory-choices",
			LayoutOrder = 5,
		}, buttons),
		Voters = if together and next_mission ~= nil
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
-- when it is brought back). A campaign mission won that unlocks something reveals what it unlocks (unlock_reveal.luau)
-- between the result and the way out, which only appears once every card is open.
local function Ending(props: { hidden: boolean, on_continue: () -> () })
	local result = outcome()
	local mission_id = campaign.current_mission()
	local mission = if mission_id ~= nil then campaign.get(mission_id) else nil
	local unlocks = if result == "victory" and mission ~= nil and #mission.unlocks > 0 then mission.unlocks else nil
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
-- sits further out when the bar is wider for the scavengers' difficulty or a mission's waves. Which end it was put
-- away for is kept, so the next game to end (a mission loaded after this one) shows its own.
local function VictoryScreen()
	local ending = use_ending()
	local put_away_for, set_put_away_for = React.useState(nil :: number?)
	-- the bar is as wide with the waves in it as with the difficulty
	local difficulty = scavenger_block.use_difficulty()
	local waves = wave_block.use_waves()
	local scavengers = difficulty ~= nil or waves ~= nil
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

return table.freeze({
	VictoryScreen = VictoryScreen,
})
