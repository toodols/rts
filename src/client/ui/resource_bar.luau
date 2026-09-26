local ReplicatedStorage = game:GetService "ReplicatedStorage"
local TweenService = game:GetService "TweenService"

local React = require(ReplicatedStorage.Packages.react)

local entity_attrs = require(ReplicatedStorage.Shared.entity_attrs)
local teams = require(ReplicatedStorage.Shared.teams)

local world = require(ReplicatedStorage.Client.world)
local use_entities = require(ReplicatedStorage.Client.ui.use_entities)
local use_viewport = require(ReplicatedStorage.Client.ui.use_viewport)
local wind_block = require(ReplicatedStorage.Client.ui.wind_block)
local tide_block = require(ReplicatedStorage.Client.ui.tide_block)
local scavenger_block = require(ReplicatedStorage.Client.ui.scavenger_block)
local use_team_resources = require(ReplicatedStorage.Client.ui.use_team_resources)

local format = require(ReplicatedStorage.ClientShared.format)

-- Under a few percent of storage the readout is called out as stalling, because that is the point
-- where construction starts being throttled.
local STALL_FRACTION = 0.02

-- The stalling pulse is driven here rather than in the stylesheet: Roblox style transitions ignore
-- TweenInfo's repeat count and reverse flag, so they can't loop.
local PULSE = TweenInfo.new(0.6, Enum.EasingStyle.Sine, Enum.EasingDirection.InOut, -1, true)
local PULSE_TRANSPARENCY = 0.65

-- The team of the first selected thing on a real team, whose resources a spectator is shown.
local function selected_team(ids: { number }): number?
	for _, id in ids do
		local model = world.get(id)
		local team = if model ~= nil then entity_attrs.team(model) else nil
		if team ~= nil and team ~= teams.NEUTRAL then
			return team
		end
	end
	return nil
end

local function Resource(props: {
	label: string,
	amount: number,
	capacity: number,
	revenue: number,
	expense: number,
	tone: string,
	LayoutOrder: number,
})
	local fraction = math.clamp(props.amount / math.max(1, props.capacity), 0, 1)
	local stalling = fraction <= STALL_FRACTION
	local amount_ref = React.useRef(nil :: TextLabel?)

	React.useEffect(function()
		local label = amount_ref.current
		if label == nil or not stalling then
			return
		end
		local pulse = TweenService:Create(label, PULSE, { TextTransparency = PULSE_TRANSPARENCY })
		pulse:Play()
		return function()
			pulse:Cancel()
			label.TextTransparency = 0
		end
	end, { stalling })

	return React.createElement("Frame", {
		[React.Tag] = "resource",
		LayoutOrder = props.LayoutOrder,
	}, {
		Head = React.createElement("Frame", {
			[React.Tag] = "resource-head",
			LayoutOrder = 1,
		}, {
			Chip = React.createElement("Frame", {
				[React.Tag] = `resource-chip {props.tone}-chip`,
				LayoutOrder = 1,
			}),
			Label = React.createElement("TextLabel", {
				[React.Tag] = "resource-name",
				LayoutOrder = 2,
				Text = props.label,
			}),
			Amount = React.createElement("TextLabel", {
				[React.Tag] = if stalling then "resource-amount stalling" else "resource-amount",
				ref = amount_ref,
				LayoutOrder = 3,
				Text = format.amount(props.amount),
			}),
			Capacity = React.createElement("TextLabel", {
				[React.Tag] = "resource-income faint",
				LayoutOrder = 4,
				Text = `/{format.amount(props.capacity)}`,
			}),
		}),
		Track = React.createElement("Frame", {
			[React.Tag] = "resource-track",
			LayoutOrder = 2,
		}, {
			Fill = React.createElement("Frame", {
				[React.Tag] = `resource-fill {props.tone}-fill`,
				-- set inline rather than in SCSS: Roblox's Size covers both axes at once
				Size = UDim2.fromScale(fraction, 1),
			}),
		}),
		Flow = React.createElement("Frame", {
			[React.Tag] = "resource-flow",
			LayoutOrder = 3,
		}, {
			Revenue = React.createElement("TextLabel", {
				[React.Tag] = "resource-revenue grow",
				LayoutOrder = 1,
				Text = string.format("+%.0f/s", props.revenue),
			}),
			Expense = React.createElement("TextLabel", {
				[React.Tag] = "resource-expense",
				LayoutOrder = 2,
				Text = string.format("-%.0f/s", props.expense),
			}),
		}),
	})
end

local function ResourceBar()
	local own = use_team_resources.use_team_resources()
	local ui_scale = use_viewport.use_ui_scale()
	-- nil while the scavengers gamemode is off, when there is nothing more to show
	local difficulty = scavenger_block.use_difficulty()
	-- a spectator has no resources of their own, and is shown those of the team of what they have selected, if anything
	local spectating = use_entities.use_spectating()
	local selected = use_entities.use_selection()
	local watched = if spectating then selected_team(selected) else nil
	local watched_resources = use_team_resources.use_watched_resources(watched or teams.NEUTRAL)
	if spectating and watched == nil then
		return nil
	end
	local team = if watched ~= nil then watched_resources else own

	return React.createElement("Frame", {
		-- the bar is wider with the difficulty in it, so the readouts keep the room they had
		[React.Tag] = if difficulty ~= nil then "resource-bar panel with-scavengers" else "resource-bar panel",
	}, {
		Scale = React.createElement("UIScale", { Scale = ui_scale }),
		Metal = React.createElement(Resource, {
			label = "METAL",
			amount = team.metal,
			capacity = team.metal_capacity,
			revenue = team.metal_revenue,
			expense = team.metal_expense,
			tone = "metal",
			LayoutOrder = 1,
		}),
		Divider = React.createElement("Frame", {
			[React.Tag] = "resource-divider",
			LayoutOrder = 2,
		}),
		Energy = React.createElement(Resource, {
			label = "ENERGY",
			amount = team.energy,
			capacity = team.energy_capacity,
			revenue = team.energy_revenue,
			expense = team.energy_expense,
			tone = "energy",
			LayoutOrder = 3,
		}),
		WindDivider = React.createElement("Frame", {
			[React.Tag] = "resource-divider",
			LayoutOrder = 4,
		}),
		Wind = React.createElement(wind_block.WindBlock, { LayoutOrder = 5 }),
		Tide = React.createElement(tide_block.TideBlock, { LayoutOrder = 6 }),
		ScavengerDivider = if difficulty ~= nil
			then React.createElement("Frame", {
				[React.Tag] = "resource-divider",
				LayoutOrder = 7,
			})
			else nil,
		Scavengers = if difficulty ~= nil
			then React.createElement(scavenger_block.ScavengerBlock, { LayoutOrder = 8, difficulty = difficulty })
			else nil,
	})
end

return table.freeze({
	ResourceBar = ResourceBar,
})
