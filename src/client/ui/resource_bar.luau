local ReplicatedStorage = game:GetService "ReplicatedStorage"
local TweenService = game:GetService "TweenService"

local React = require(ReplicatedStorage.Packages.react)

local use_viewport = require(ReplicatedStorage.Client.ui.use_viewport)
local wind_block = require(ReplicatedStorage.Client.ui.wind_block)
local scavenger_block = require(ReplicatedStorage.Client.ui.scavenger_block)

type TeamState = {
	metal: number,
	energy: number,
	metal_capacity: number,
	energy_capacity: number,
	metal_income: number,
	energy_income: number,
	metal_revenue: number,
	metal_expense: number,
	energy_revenue: number,
	energy_expense: number,
}

local team_updated: RemoteEvent = ReplicatedStorage.Shared.TeamUpdated

local EMPTY: TeamState = {
	metal = 0,
	energy = 0,
	metal_capacity = 1,
	energy_capacity = 1,
	metal_income = 0,
	energy_income = 0,
	metal_revenue = 0,
	metal_expense = 0,
	energy_revenue = 0,
	energy_expense = 0,
}

-- Under a few percent of storage the readout is called out as stalling, because that is the point
-- where construction starts being throttled.
local STALL_FRACTION = 0.02

-- The stalling pulse is driven here rather than in the stylesheet: Roblox style transitions ignore
-- TweenInfo's repeat count and reverse flag, so they can't loop.
local PULSE = TweenInfo.new(0.6, Enum.EasingStyle.Sine, Enum.EasingDirection.InOut, -1, true)
local PULSE_TRANSPARENCY = 0.65

local function format_amount(value: number): string
	if value >= 10000 then
		return string.format("%.1fk", value / 1000)
	end
	return string.format("%d", math.floor(value))
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
				Text = format_amount(props.amount),
			}),
			Capacity = React.createElement("TextLabel", {
				[React.Tag] = "resource-income faint",
				LayoutOrder = 4,
				Text = `/{format_amount(props.capacity)}`,
			}),
		}),
		Track = React.createElement("Frame", {
			[React.Tag] = "resource-track",
			LayoutOrder = 2,
		}, {
			Fill = React.createElement("Frame", {
				[React.Tag] = `resource-fill {props.tone}-fill`,
				-- set inline rather than in SCSS: Roblox's Size covers both axes at once
				Size = UDim2.new(fraction, 0, 1, 0),
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
	local team, set_team = React.useState(EMPTY)
	local ui_scale = use_viewport.use_ui_scale()
	-- nil while the scavengers gamemode is off, when there is nothing more to show
	local difficulty = scavenger_block.use_difficulty()

	React.useEffect(function()
		local connection = team_updated.OnClientEvent:Connect(function(next_state: TeamState)
			set_team(next_state)
		end)
		return function()
			connection:Disconnect()
		end
	end, {})

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
		ScavengerDivider = if difficulty ~= nil
			then React.createElement("Frame", {
				[React.Tag] = "resource-divider",
				LayoutOrder = 6,
			})
			else nil,
		Scavengers = if difficulty ~= nil
			then React.createElement(scavenger_block.ScavengerBlock, { LayoutOrder = 7, difficulty = difficulty })
			else nil,
	})
end

return table.freeze({
	ResourceBar = ResourceBar,
})
