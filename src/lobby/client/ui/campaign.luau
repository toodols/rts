--!strict
-- The campaign screen: the missions, each played alone with the Play button on its card (or, for one that may be
-- played together, with others from a co-op lobby its Co-op button makes, which opens as any lobby), and under each
-- the units it unlocks; a mission with a hard mode has a second part for it, with buttons of its own and what it
-- unlocks besides, shown once the mission has been finished. What is not unlocked yet is greyed. Each unit shown is a
-- link to its entry in the encyclopedia (encyclopedia/), where every unit is, with whether it is unlocked yet. Reached
-- from the browser, and left back to it.
--
-- What the player has unlocked and finished comes from their Player's attributes (ClientShared.campaign_standing), and how the start
-- of a mission is going from the lobby's state (protocol.MissionView). A request the server turns down, like any start
-- from Studio, is said under the missions until the next is asked.

local ReplicatedStorage = game:GetService "ReplicatedStorage"

local React = require(ReplicatedStorage.Packages.react)

local campaign = require(ReplicatedStorage.Shared.campaign)
local def_catalog = require(ReplicatedStorage.Shared.def_catalog)
local unit_defs = require(ReplicatedStorage.Shared.unit_defs)

local campaign_standing = require(ReplicatedStorage.ClientShared.campaign_standing)

local protocol = require(ReplicatedStorage.Lobby.protocol)

local use_lobby = require(ReplicatedStorage.LobbyClient.use_lobby)
local controls = require(script.Parent.controls)
local encyclopedia = require(script.Parent.encyclopedia)

type Mission = campaign.Mission
type MissionView = protocol.MissionView

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

-- What a mission unlocks, `names`, for its card: a link to each one's encyclopedia entry, or its name alone for one
-- with none, greyed while the player has not unlocked it (`unlocks`).
local function Unlocks(props: {
	names: { string },
	unlocks: { [string]: boolean },
	open_entry: (name: string) -> (),
	LayoutOrder: number,
})
	local children: { [string]: any } = {
		Label = React.createElement("TextLabel", {
			[React.Tag] = "mission-unlocks-label",
			LayoutOrder = 0,
			Text = "UNLOCKS",
		}),
	}
	for index, name in props.names do
		local locked = campaign.is_unlocked(props.unlocks, name) == false
		if def_catalog.has_entry(name) then
			children[name] = React.createElement(encyclopedia.EntryLink, {
				name = name,
				locked = locked,
				on_open = props.open_entry,
				LayoutOrder = index,
			})
		else
			local def = unit_defs.defs[name]
			children[name] = React.createElement("TextLabel", {
				[React.Tag] = if locked then "mission-unlocks-name locked" else "mission-unlocks-name",
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

-- The Play button, and beside it Co-op for a mission that can be played together.
local function PlayButtons(
	props: {
		mission: Mission,
		-- whether it may be played, whether it has been finished, whether this one is starting
		open: boolean,
		completed: boolean,
		starting: boolean,
		busy: boolean,
		on_play: () -> (),
		on_coop: () -> (),
		LayoutOrder: number,
	}
)
	return React.createElement("Frame", {
		[React.Tag] = "mission-buttons",
		LayoutOrder = props.LayoutOrder,
	}, {
		Play = React.createElement(controls.Button, {
			kind = "button",
			tag = "primary play",
			label = if props.starting then "Starting..." elseif props.completed then "Replay" else "Play",
			locked = props.open == false or props.busy,
			on_press = props.on_play,
			LayoutOrder = 1,
		}),
		Coop = if props.mission.coop ~= nil
			then React.createElement(controls.Button, {
				kind = "button",
				tag = "play",
				label = "Co-op",
				locked = props.open == false or props.busy,
				on_press = props.on_coop,
				LayoutOrder = 2,
			})
			else nil,
	})
end

-- The tag saying how a mission, or its hard mode, stands.
local function Status(props: { completed: boolean, open: boolean, LayoutOrder: number })
	return React.createElement("TextLabel", {
		[React.Tag] = if props.completed then "tag done" elseif props.open then "tag fresh" else "tag",
		LayoutOrder = props.LayoutOrder,
		Text = if props.completed then "COMPLETE" elseif props.open then "NEW" else "LOCKED",
	})
end

local function MissionCard(
	props: {
		mission: Mission,
		number: number,
		completed: boolean,
		open: boolean,
		-- its hard mode's, for one that has one
		hard_completed: boolean,
		hard_open: boolean,
		-- what the player has unlocked
		unlocks: { [string]: boolean },
		-- another mission, or this one, is starting
		busy: boolean,
		-- this one is starting, and this one's hard mode
		starting: boolean,
		starting_hard: boolean,
		on_play: (hard: boolean) -> (),
		on_coop: (hard: boolean) -> (),
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
	local hard_unlocks = mission.hard_mode_unlocks or {}

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
				Status = React.createElement(Status, {
					completed = props.completed,
					open = props.open,
					LayoutOrder = 2,
				}),
			}),
			Description = React.createElement("TextLabel", {
				[React.Tag] = "mission-description",
				LayoutOrder = 2,
				Text = mission.description,
			}),
			Unlocks = if #mission.unlocks > 0
				then React.createElement(Unlocks, {
					names = mission.unlocks,
					unlocks = props.unlocks,
					open_entry = props.open_entry,
					LayoutOrder = 3,
				})
				else nil,
			Buttons = React.createElement(PlayButtons, {
				mission = mission,
				open = props.open,
				completed = props.completed,
				starting = props.starting,
				busy = props.busy,
				on_play = function()
					props.on_play(false)
				end,
				on_coop = function()
					props.on_coop(false)
				end,
				LayoutOrder = 4,
			}),
			-- only once the mission has been finished
			Hard = if mission.hard_mode and props.hard_open
				then React.createElement("Frame", {
					[React.Tag] = "mission-hard",
					LayoutOrder = 5,
				}, {
					Head = React.createElement("Frame", {
						[React.Tag] = "mission-head",
						LayoutOrder = 1,
					}, {
						Title = React.createElement("TextLabel", {
							[React.Tag] = "mission-hard-title heading",
							LayoutOrder = 1,
							Text = "Hard mode",
						}),
						Status = React.createElement(Status, {
							completed = props.hard_completed,
							open = props.hard_open,
							LayoutOrder = 2,
						}),
					}),
					Description = if mission.hard_mode_description ~= nil
						then React.createElement("TextLabel", {
							[React.Tag] = "mission-description",
							LayoutOrder = 2,
							Text = mission.hard_mode_description,
						})
						else nil,
					Unlocks = if #hard_unlocks > 0
						then React.createElement(Unlocks, {
							names = hard_unlocks,
							unlocks = props.unlocks,
							open_entry = props.open_entry,
							LayoutOrder = 3,
						})
						else nil,
					Buttons = React.createElement(PlayButtons, {
						mission = mission,
						open = props.hard_open,
						completed = props.hard_completed,
						starting = props.starting_hard,
						busy = props.busy,
						on_play = function()
							props.on_play(true)
						end,
						on_coop = function()
							props.on_coop(true)
						end,
						LayoutOrder = 4,
					}),
				})
				else nil,
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
	local found, hard = campaign.parse_key(mission.id)
	local label = if found == nil then mission.id elseif hard then `{found.label} (Hard)` else found.label
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
	local progress = campaign_standing.use_standing()
	-- why the last Play was turned down, until the next
	local refused: string?, set_refused = React.useState(nil :: string?)
	-- the mission a Play was pressed for, until the server answers
	local asking: string?, set_asking = React.useState(nil :: string?)

	local mission = props.mission
	local starting_id: string? = asking
	if mission ~= nil and mission.stage ~= "failed" then
		starting_id = mission.id
	end

	local function play(mission_id: string)
		set_refused(nil)
		set_asking(mission_id)
		task.spawn(function()
			local ok, message = use_lobby.request("play_mission", mission_id)
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
			local ok, message = use_lobby.request("create_mission", mission_id)
			set_asking(nil)
			if ok == false then
				set_refused(message or "The co-op lobby couldn't be made")
			end
		end)
	end

	local cards: { [string]: any } = {}
	for index, entry in campaign.MISSIONS do
		local hard_key = campaign.key(entry.id, true)
		cards[entry.id] = React.createElement(MissionCard, {
			mission = entry,
			number = index,
			completed = progress.completed[entry.id] == true,
			open = campaign.is_open(progress.completed, entry.id),
			hard_completed = progress.completed[hard_key] == true,
			hard_open = entry.hard_mode and campaign.is_open(progress.completed, hard_key),
			unlocks = progress.unlocks,
			busy = starting_id ~= nil,
			starting = starting_id == entry.id,
			starting_hard = starting_id == hard_key,
			on_play = function(hard: boolean)
				play(campaign.key(entry.id, hard))
			end,
			on_coop = function(hard: boolean)
				coop(campaign.key(entry.id, hard))
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
