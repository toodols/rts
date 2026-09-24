-- The campaign screen: the missions on the left, each played alone with the Play button on its card (or, for one that
-- may be played together, with others from a co-op lobby its Co-op button makes, which opens as any lobby), and on the right
-- everything a player can unlock, lit if they have and dimmed with a lock if not, grouped by what builds it. Reached
-- from the browser, and left back to it.
--
-- What the player has unlocked and finished comes from their Player's attributes (see use_campaign), and how the start
-- of a mission is going from the lobby's state (protocol.MissionView). A request the server turns down, like any start
-- from Studio, is said under the missions until the next is asked.

local ReplicatedStorage = game:GetService "ReplicatedStorage"

local React = require(ReplicatedStorage.Packages.react)

local campaign = require(ReplicatedStorage.Shared.campaign)
local types = require(ReplicatedStorage.Shared.types)
local unit_defs = require(ReplicatedStorage.Shared.unit_defs)

local protocol = require(ReplicatedStorage.Lobby.protocol)

local use_campaign = require(ReplicatedStorage.LobbyClient.use_campaign)
local use_lobby = require(ReplicatedStorage.LobbyClient.use_lobby)
local controls = require(script.Parent.controls)

type Mission = campaign.Mission
type EntityDef = types.EntityDef
type MissionView = protocol.MissionView

-- A heading on the unlocks panel and the defs under it.
type UnlockGroup = {
	key: string,
	label: string,
	names: { string },
}

local ACTIONS = protocol.ACTIONS

-- Cheapest first, the way a build menu goes from the first things built to the last.
local function by_cost(a: EntityDef, b: EntityDef): boolean
	if a.metal_cost ~= b.metal_cost then
		return a.metal_cost < b.metal_cost
	end
	return a.display_name < b.display_name
end

local function names_of(defs: { EntityDef }): { string }
	table.sort(defs, by_cost)
	local names: { string } = {}
	for _, def in defs do
		table.insert(names, def.name)
	end
	return names
end

-- Everything that can be locked, grouped: the factories, then the units each factory makes (the cheapest factory
-- first, and a unit two of them make under the first), then the defences and the rest of the buildings, and last any
-- unit no factory makes.
local function build_groups(): { UnlockGroup }
	local factories: { EntityDef } = {}
	for _, def in unit_defs.defs do
		if def.kind == "building" and def.build_options ~= nil then
			table.insert(factories, def)
		end
	end
	table.sort(factories, by_cost)

	local placed: { [string]: boolean } = {}
	local groups: { UnlockGroup } = {}
	local lockable_factories: { EntityDef } = {}
	for _, factory in factories do
		if campaign.is_lockable(factory.name) then
			table.insert(lockable_factories, factory)
			placed[factory.name] = true
		end
	end
	table.insert(groups, { key = "factories", label = "FACTORIES", names = names_of(lockable_factories) })

	for _, factory in factories do
		local made: { EntityDef } = {}
		for _, option in factory.build_options :: { string } do
			local def = unit_defs.defs[option]
			if def ~= nil and def.kind == "unit" and placed[option] == nil and campaign.is_lockable(option) then
				table.insert(made, def)
				placed[option] = true
			end
		end
		if #made > 0 then
			table.insert(groups, {
				key = factory.name,
				label = `FROM THE {string.upper(factory.display_name)}`,
				names = names_of(made),
			})
		end
	end

	local defences: { EntityDef } = {}
	local buildings: { EntityDef } = {}
	local units: { EntityDef } = {}
	for name, def in unit_defs.defs do
		if placed[name] ~= nil or campaign.is_lockable(name) == false then
			continue
		end
		if def.kind ~= "building" then
			table.insert(units, def)
		elseif def.weapons ~= nil or def.shield ~= nil then
			table.insert(defences, def)
		else
			table.insert(buildings, def)
		end
	end
	table.insert(groups, { key = "defences", label = "DEFENCES", names = names_of(defences) })
	table.insert(groups, { key = "buildings", label = "ECONOMY AND UTILITY", names = names_of(buildings) })
	table.insert(groups, { key = "units", label = "OTHER UNITS", names = names_of(units) })

	local kept: { UnlockGroup } = {}
	for _, group in groups do
		if #group.names > 0 then
			table.insert(kept, group)
		end
	end
	return kept
end

local GROUPS: { UnlockGroup } = build_groups()

local LOCKABLE_COUNT = 0
for _, group in GROUPS do
	LOCKABLE_COUNT += #group.names
end

-- How much of what can be locked `unlocks` has, and how much there is.
local function unlock_counts(unlocks: { [string]: boolean }): (number, number)
	local unlocked = 0
	for _, group in GROUPS do
		for _, name in group.names do
			if unlocks[name] == true then
				unlocked += 1
			end
		end
	end
	return unlocked, LOCKABLE_COUNT
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

-- The names of the defs `mission` unlocks, for its card.
local function unlocks_line(mission: Mission): string?
	if #mission.unlocks == 0 then
		return nil
	end
	local names: { string } = {}
	for _, name in mission.unlocks do
		local def = unit_defs.defs[name]
		table.insert(names, if def ~= nil then def.display_name else name)
	end
	return `Unlocks {table.concat(names, ", ")}`
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
	local unlocks = unlocks_line(mission)

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
			Unlocks = if unlocks ~= nil
				then React.createElement("TextLabel", {
					[React.Tag] = "mission-unlocks",
					LayoutOrder = 3,
					Text = unlocks,
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

-- One thing that can be unlocked: its name and what it is, lit if it is unlocked and dimmed under a lock if not.
local function UnlockTile(props: { name: string, unlocked: boolean, LayoutOrder: number })
	local def = unit_defs.defs[props.name]
	return React.createElement("Frame", {
		[React.Tag] = if props.unlocked then "unlock unlocked" else "unlock locked",
		LayoutOrder = props.LayoutOrder,
	}, {
		Names = React.createElement("Frame", {
			[React.Tag] = "unlock-names",
			LayoutOrder = 1,
		}, {
			Name = React.createElement("TextLabel", {
				[React.Tag] = "unlock-name",
				LayoutOrder = 1,
				Text = def.display_name,
			}),
			Subtitle = if def.subtitle ~= nil
				then React.createElement("TextLabel", {
					[React.Tag] = "unlock-subtitle",
					LayoutOrder = 2,
					Text = def.subtitle,
				})
				else nil,
		}),
		Lock = if props.unlocked
			then nil
			else React.createElement("TextLabel", {
				[React.Tag] = "unlock-lock",
				LayoutOrder = 2,
				Text = "LOCKED",
			}),
	})
end

local function UnlockGroupView(props: {
	group: UnlockGroup,
	unlocks: { [string]: boolean },
	LayoutOrder: number,
})
	local tiles: { [string]: any } = {}
	local unlocked = 0
	for index, name in props.group.names do
		local has = props.unlocks[name] == true
		if has then
			unlocked += 1
		end
		tiles[name] = React.createElement(UnlockTile, {
			name = name,
			unlocked = has,
			LayoutOrder = index,
		})
	end

	return React.createElement("Frame", {
		[React.Tag] = "unlock-group",
		LayoutOrder = props.LayoutOrder,
	}, {
		Head = React.createElement("Frame", {
			[React.Tag] = "side-head",
			LayoutOrder = 1,
		}, {
			Label = React.createElement("TextLabel", {
				[React.Tag] = "group-label",
				LayoutOrder = 1,
				Text = props.group.label,
			}),
			Count = React.createElement("TextLabel", {
				[React.Tag] = "side-count",
				LayoutOrder = 2,
				Text = `{unlocked}/{#props.group.names}`,
			}),
		}),
		Tiles = React.createElement("Frame", {
			[React.Tag] = "unlock-grid",
			LayoutOrder = 2,
		}, tiles),
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
			LayoutOrder = index,
		})
	end

	local groups: { [string]: any } = {}
	for index, group in GROUPS do
		groups[group.key] = React.createElement(UnlockGroupView, {
			group = group,
			unlocks = progress.unlocks,
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
		Unlocks = React.createElement("Frame", {
			[React.Tag] = "unlocks panel",
			LayoutOrder = 2,
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
					Text = "Unlocks",
				}),
				Count = React.createElement("TextLabel", {
					[React.Tag] = "badge",
					LayoutOrder = 3,
					Text = `{unlocked}/{lockable}`,
				}),
			}),
			Groups = React.createElement("ScrollingFrame", {
				[React.Tag] = "unlock-groups",
				LayoutOrder = 4,
			}, groups),
		}),
	})
end

return table.freeze({
	Campaign = Campaign,
	unlock_counts = unlock_counts,
	mission_counts = mission_counts,
})
