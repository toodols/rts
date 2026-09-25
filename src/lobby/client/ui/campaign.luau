-- The campaign screen: the missions, each played alone with the Play button on its card (or, for one that may be
-- played together, with others from a co-op lobby its Co-op button makes, which opens as any lobby), and under each
-- the units it unlocks, each a link to its entry in the encyclopedia (encyclopedia.luau), where every unit is, with
-- whether it is unlocked yet. Reached from the browser, and left back to it.
--
-- What the player has unlocked and finished comes from their Player's attributes (see use_campaign), and how the start
-- of a mission is going from the lobby's state (protocol.MissionView). A request the server turns down, like any start
-- from Studio, is said under the missions until the next is asked.

local ReplicatedStorage = game:GetService "ReplicatedStorage"

local React = require(ReplicatedStorage.Packages.react)

local campaign = require(ReplicatedStorage.Shared.campaign)
local unit_defs = require(ReplicatedStorage.Shared.unit_defs)

local protocol = require(ReplicatedStorage.Lobby.protocol)

local use_campaign = require(ReplicatedStorage.LobbyClient.use_campaign)
local use_lobby = require(ReplicatedStorage.LobbyClient.use_lobby)
local controls = require(script.Parent.controls)
local encyclopedia = require(script.Parent.encyclopedia)

type Mission = campaign.Mission
type MissionView = protocol.MissionView

local ACTIONS = protocol.ACTIONS

-- Everything that can be locked: whatever something builds (campaign.is_lockable).
local LOCKABLE: { string } = {}
for name in unit_defs.defs do
	if campaign.is_lockable(name) then
		table.insert(LOCKABLE, name)
	end
end

-- How much of what can be locked `unlocks` has, and how much there is.
local function unlock_counts(unlocks: { [string]: boolean }): (number, number)
	local unlocked = 0
	for _, name in LOCKABLE do
		if unlocks[name] == true then
			unlocked += 1
		end
	end
	return unlocked, #LOCKABLE
end

-- How many missions `completed` has of all of them.
local function mission_counts(completed: { [string]: boolean }): (number, number)
	local done = 0
	for _, mission in campaign.MISSIONS do
		if completed[mission.id] == true then
			done += 1
		end
	end
	return done, #campaign.MISSIONS
end

-- What `mission` unlocks, for its card: a link to each one's encyclopedia entry, or its name alone for one with none.
local function Unlocks(props: { mission: Mission, open_entry: (name: string) -> (), LayoutOrder: number })
	local children: { [string]: any } = {
		Label = React.createElement("TextLabel", {
			[React.Tag] = "mission-unlocks-label",
			LayoutOrder = 0,
			Text = "UNLOCKS",
		}),
	}
	for index, name in props.mission.unlocks do
		if encyclopedia.has_entry(name) then
			children[name] = React.createElement(encyclopedia.EntryLink, {
				name = name,
				on_open = props.open_entry,
				LayoutOrder = index,
			})
		else
			local def = unit_defs.defs[name]
			children[name] = React.createElement("TextLabel", {
				[React.Tag] = "mission-unlocks-name",
				LayoutOrder = index,
				Text = if def ~= nil then def.display_name else name,
			})
		end
	end
	return React.createElement("Frame", {
		[React.Tag] = "mission-unlocks",
		LayoutOrder = props.LayoutOrder,
	}, children)
end

local function MissionCard(
	props: {
		mission: Mission,
		number: number,
		completed: boolean,
		open: boolean,
		-- another mission, or this one, is starting
		busy: boolean,
		-- this one is starting
		starting: boolean,
		on_play: () -> (),
		on_coop: () -> (),
		open_entry: (name: string) -> (),
		LayoutOrder: number,
	}
)
	local mission = props.mission
	local tag = "mission-card"
	if props.completed then
		tag ..= " completed"
	elseif props.open == false then
		tag ..= " closed"
	end
	local status = if props.completed then "COMPLETE" elseif props.open then "NEW" else "LOCKED"

	return React.createElement("Frame", {
		[React.Tag] = tag,
		LayoutOrder = props.LayoutOrder,
	}, {
		Number = React.createElement("TextLabel", {
			[React.Tag] = "mission-number readout",
			LayoutOrder = 1,
			Text = string.format("%02d", props.number),
		}),
		Details = React.createElement("Frame", {
			[React.Tag] = "mission-details",
			LayoutOrder = 2,
		}, {
			Head = React.createElement("Frame", {
				[React.Tag] = "mission-head",
				LayoutOrder = 1,
			}, {
				Title = React.createElement("TextLabel", {
					[React.Tag] = "mission-title heading",
					LayoutOrder = 1,
					Text = mission.label,
				}),
				Status = React.createElement("TextLabel", {
					[React.Tag] = if props.completed then "tag done" elseif props.open then "tag fresh" else "tag",
					LayoutOrder = 2,
					Text = status,
				}),
			}),
			Description = React.createElement("TextLabel", {
				[React.Tag] = "mission-description",
				LayoutOrder = 2,
				Text = mission.description,
			}),
			Unlocks = if #mission.unlocks > 0
				then React.createElement(Unlocks, {
					mission = mission,
					open_entry = props.open_entry,
					LayoutOrder = 3,
				})
				else nil,
			Buttons = React.createElement("Frame", {
				[React.Tag] = "mission-buttons",
				LayoutOrder = 4,
			}, {
				Play = React.createElement(controls.Button, {
					kind = "button",
					tag = "primary play",
					label = if props.starting then "Starting..." elseif props.completed then "Replay" else "Play",
					locked = props.open == false or props.busy,
					on_press = props.on_play,
					LayoutOrder = 1,
				}),
				Coop = if mission.coop ~= nil
					then React.createElement(controls.Button, {
						kind = "button",
						tag = "play",
						label = "Co-op",
						locked = props.open == false or props.busy,
						on_press = props.on_coop,
						LayoutOrder = 2,
					})
					else nil,
			}),
		}),
	})
end

-- What to say under the missions about the one being started, and whether it is something wrong.
local function status_of(mission: MissionView?, refused: string?, asking: string?): (string, boolean)
	if refused ~= nil then
		return refused, true
	end
	if asking ~= nil then
		return "Asking the server...", false
	end
	if mission == nil then
		return "", false
	end
	local found = campaign.get(mission.id)
	local label = if found ~= nil then found.label else mission.id
	if mission.stage == "starting" then
		return `Starting {label}: reserving a server...`, false
	elseif mission.stage == "teleporting" then
		return `Teleporting to {label}...`, false
	end
	return mission.reason or `{label} couldn't be started`, true
end

local function Campaign(props: {
	mission: MissionView?,
	on_back: () -> (),
	open_entry: (name: string) -> (),
})
	local progress = use_campaign.use_campaign()
	-- why the last Play was turned down, until the next
	local refused, set_refused = React.useState(nil :: string?)
	-- the mission a Play was pressed for, until the server answers
	local asking, set_asking = React.useState(nil :: string?)

	local mission = props.mission
	local starting_id: string? = asking
	if mission ~= nil and mission.stage ~= "failed" then
		starting_id = mission.id
	end

	local function play(mission_id: string)
		set_refused(nil)
		set_asking(mission_id)
		task.spawn(function()
			local ok, message = use_lobby.request(ACTIONS.play_mission, mission_id)
			set_asking(nil)
			if ok == false then
				set_refused(message or "The mission couldn't be started")
			end
		end)
	end

	-- a co-op lobby opens as the lobby it is once the server has made it
	local function coop(mission_id: string)
		set_refused(nil)
		set_asking(mission_id)
		task.spawn(function()
			local ok, message = use_lobby.request(ACTIONS.create_mission, mission_id)
			set_asking(nil)
			if ok == false then
				set_refused(message or "The co-op lobby couldn't be made")
			end
		end)
	end

	local cards: { [string]: any } = {}
	for index, entry in campaign.MISSIONS do
		cards[entry.id] = React.createElement(MissionCard, {
			mission = entry,
			number = index,
			completed = progress.completed[entry.id] == true,
			open = protocol.is_mission_open(progress.completed, entry.id),
			busy = starting_id ~= nil,
			starting = starting_id == entry.id,
			on_play = function()
				play(entry.id)
			end,
			on_coop = function()
				coop(entry.id)
			end,
			open_entry = props.open_entry,
			LayoutOrder = index,
		})
	end

	local done, missions = mission_counts(progress.completed)
	local unlocked, lockable = unlock_counts(progress.unlocks)
	local status, warning = status_of(mission, refused, asking)

	return React.createElement("Frame", {
		[React.Tag] = "campaign",
	}, {
		Missions = React.createElement("Frame", {
			[React.Tag] = "missions panel",
			LayoutOrder = 1,
		}, {
			Rail = React.createElement("Frame", {
				[React.Tag] = "rail",
				LayoutOrder = 1,
			}),
			Title = React.createElement("Frame", {
				[React.Tag] = "title-row",
				LayoutOrder = 2,
			}, {
				Accent = React.createElement("Frame", {
					[React.Tag] = "accent-bar",
					LayoutOrder = 1,
				}),
				Name = React.createElement("TextLabel", {
					[React.Tag] = "heading",
					LayoutOrder = 2,
					Text = "Missions",
				}),
				Count = React.createElement("TextLabel", {
					[React.Tag] = "badge",
					LayoutOrder = 3,
					Text = `{done}/{missions}`,
				}),
				Unlocked = React.createElement("TextLabel", {
					[React.Tag] = "badge",
					LayoutOrder = 4,
					Text = `{unlocked}/{lockable} UNLOCKED`,
				}),
			}),
			List = React.createElement("ScrollingFrame", {
				[React.Tag] = "mission-list",
				LayoutOrder = 3,
			}, cards),
			Actions = React.createElement("Frame", {
				[React.Tag] = "campaign-actions",
				LayoutOrder = 4,
			}, {
				Back = React.createElement(controls.Button, {
					kind = "button",
					label = "Back",
					on_press = props.on_back,
					LayoutOrder = 1,
				}),
				Status = React.createElement("TextLabel", {
					[React.Tag] = if warning then "campaign-status grow warning" else "campaign-status grow",
					LayoutOrder = 2,
					Text = status,
				}),
			}),
		}),
	})
end

return table.freeze({
	Campaign = Campaign,
	unlock_counts = unlock_counts,
	mission_counts = mission_counts,
})
