-- What covers the screen once the game has ended (see shared/game_phase.luau): VICTORY for a player whose team is among
-- the winners, DEFEAT for one whose team is not, and GAME OVER for someone who only watched, with the server's line on
-- how it was won beneath. It is the same for every way a game ends, against the scavengers or each other.
--
-- Under that is what every team did over the game (server/match_stats.luau): the damage it dealt and what that was
-- worth, what it killed and lost, and the metal it made. When more than one player played, the one whose damage was
-- worth the most is named the MVP.
--
-- A campaign mission's end also offers the way out (see server/campaign_exit.luau): back to the lobby, and, once it is
-- won, on to the next mission, if there is one. Either asks the server over the CampaignChoice remote,
-- and what it answers, that the player is on their way or why they are not, is shown under the buttons.
--
-- A campaign mission won that unlocks something first reveals it (unlock_reveal.luau), under the result, and only
-- then offers the way out.

local HttpService = game:GetService "HttpService"
local Players = game:GetService "Players"
local ReplicatedStorage = game:GetService "ReplicatedStorage"
local Workspace = game:GetService "Workspace"

local React = require(ReplicatedStorage.Packages.react)

local game_phase = require(ReplicatedStorage.Shared.game_phase)
local campaign = require(ReplicatedStorage.Shared.campaign)

local unlock_reveal = require(ReplicatedStorage.Client.ui.unlock_reveal)

local UnlockReveal = unlock_reveal.UnlockReveal
local UnlockVignette = unlock_reveal.UnlockVignette

local local_player = Players.LocalPlayer
local campaign_choice: RemoteEvent = ReplicatedStorage.Shared.CampaignChoice

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

-- the Workspace attribute server/match_stats.luau publishes the stats as
local STATS_ATTRIBUTE = "match_stats"

-- The stats' columns, after the team's name: what each is headed and which figure it shows.
local COLUMNS: { { heading: string, key: string } } = {
	{ heading = "DAMAGE", key = "damage" },
	{ heading = "DESTROYED", key = "destroyed" },
	{ heading = "KILLS", key = "kills" },
	{ heading = "LOST", key = "lost" },
	{ heading = "METAL", key = "metal" },
}
type Choice = "lobby" | "next"

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

-- Redraws whenever the phase, or who won, changes.
local function use_ending(): boolean
	local _, bump = React.useState(0)
	React.useEffect(function()
		local connections = game_phase.changed(function()
			bump(function(count: number): number
				return count + 1
			end)
		end)
		return function()
			for _, connection in connections do
				connection:Disconnect()
			end
		end
	end, {})
	return game_phase.phase() == "ended"
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

-- What the server last said about the player's choice, and a way to ask for one.
local function use_choice(): (ChoiceStatus, (choice: Choice) -> ())
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
	return status, choose
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

-- The way out of a campaign mission: back to the lobby, and on to the next mission for someone who won it, if the
-- campaign has one.
local function CampaignChoices(props: { mission_id: string, won: boolean })
	local status, choose = use_choice()
	local next_mission = campaign.next_mission(props.mission_id)
	local idle = status.stage ~= "sending"
	local message = if status.stage == "sending" and status.choice ~= nil
		then SENDING[status.choice]
		else status.message

	local buttons: { [string]: any } = {
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
			text = `Next mission: {next_mission.label}`,
			primary = true,
			enabled = idle,
			order = 2,
			on_click = function()
				choose "next"
			end,
		})
	end

	return React.createElement(React.Fragment, nil, {
		Choices = React.createElement("Frame", {
			[React.Tag] = "victory-choices",
			LayoutOrder = 5,
		}, buttons),
		Status = if message ~= nil
			then React.createElement("TextLabel", {
				[React.Tag] = if status.stage == "failed" then "victory-status failed" else "victory-status",
				LayoutOrder = 6,
				Text = message,
			})
			else nil,
	})
end

-- The screen once the game has ended. A campaign mission won that unlocks something reveals what it unlocks
-- (unlock_reveal.luau) between the result and the way out, which only appears once every card is open.
local function Ending()
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

	return React.createElement("Frame", {
		[React.Tag] = `victory-screen {result}`,
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
				Campaign = if mission_id ~= nil and choices_shown
					then React.createElement(CampaignChoices, { mission_id = mission_id, won = result == "victory" })
					else nil,
			}),
		}),
	})
end

local function VictoryScreen()
	if use_ending() == false then
		return nil
	end
	return React.createElement(Ending)
end

return table.freeze({
	VictoryScreen = VictoryScreen,
})
