local ReplicatedStorage = game:GetService "ReplicatedStorage"

local React = require(ReplicatedStorage.Packages.react)

local unit_defs = require(ReplicatedStorage.Shared.unit_defs)

local input = require(ReplicatedStorage.Client.input)
local use_entities = require(ReplicatedStorage.Client.ui.use_entities)
local use_viewport = require(ReplicatedStorage.Client.ui.use_viewport)

type EntityView = use_entities.EntityView

local cancel_production: RemoteEvent = ReplicatedStorage.Shared.CancelProduction

local function Stat(props: { label: string, value: string, LayoutOrder: number, value_color: Color3? })
	return React.createElement("Frame", {
		[React.Tag] = "stat",
		LayoutOrder = props.LayoutOrder,
	}, {
		Label = React.createElement("TextLabel", {
			[React.Tag] = "stat-label",
			LayoutOrder = 1,
			-- Uppercased here because Roblox has no text-transform.
			Text = string.upper(props.label),
		}),
		Value = React.createElement("TextLabel", {
			[React.Tag] = "stat-value",
			LayoutOrder = 2,
			Text = props.value,
			TextColor3 = props.value_color,
		}),
	})
end

-- A factory's pending items. Clicking one cancels it.
local function Queue(props: { view: EntityView, LayoutOrder: number })
	local chips = {}
	for index, def_name in props.view.queue do
		local def = unit_defs.defs[def_name]
		chips[`Chip{index}`] = React.createElement("TextButton", {
			[React.Tag] = "queue-chip",
			LayoutOrder = index,
			Text = if def ~= nil then string.sub(def.display_name, 1, 2) else "?",
			[React.Event.Activated] = function()
				cancel_production:FireServer({ factory_id = props.view.id, index = index })
			end,
		})
	end

	return React.createElement("Frame", {
		[React.Tag] = "queue-strip",
		LayoutOrder = props.LayoutOrder,
	}, chips)
end

-- A rate in resource a second, signed: what is made is plus and what is spent is minus.
local function rate_text(rate: number): string
	if rate > 0 then
		return `+{string.format("%.1f", rate)}/s`
	elseif rate < 0 then
		return `-{string.format("%.1f", -rate)}/s`
	end
	return "0/s"
end

-- Why something is not working at full rate, or nil if it is.
local function stall_text(view: EntityView): string?
	if view.stalled == "energy" or view.need_energy then
		return "STALLED: low energy"
	elseif view.stalled == "metal" then
		return "STALLED: low metal"
	elseif view.stalled == "storage" then
		return "STALLED: metal storage full"
	end
	return nil
end

local function Single(props: { view: EntityView })
	local view = props.view
	local def = unit_defs.get(view.def_name)
	local is_blueprint = view.state == "blueprint"
	local fraction = if is_blueprint
		then math.clamp(view.build_progress / math.max(1, view.buildpower_cost), 0, 1)
		else math.clamp(view.health / math.max(1, view.max_health), 0, 1)

	local stats = {
		Team = React.createElement(Stat, {
			label = "Team",
			value = if view.team_name ~= nil
				then view.team_name
				elseif view.team == 0 then "Neutral"
				else `Team {view.team}`,
			value_color = view.team_color,
			LayoutOrder = 0,
		}),
		Health = React.createElement(Stat, {
			label = "Health",
			value = `{math.floor(view.health)} / {math.floor(view.max_health)}`,
			LayoutOrder = 1,
		}),
		Metal = React.createElement(Stat, {
			label = "Metal",
			value = tostring(def.metal_cost),
			LayoutOrder = 2,
		}),
		Energy = React.createElement(Stat, {
			label = "Energy",
			value = tostring(def.energy_cost),
			LayoutOrder = 3,
		}),
		Build = React.createElement(Stat, {
			label = "Buildpower",
			value = if def.buildpower ~= nil then tostring(def.buildpower) else "-",
			LayoutOrder = 4,
		}),
		Orders = React.createElement(Stat, {
			label = "Orders",
			value = tostring(view.order_count),
			LayoutOrder = 5,
		}),
		MetalRate = if view.metal_rate ~= nil
			then React.createElement(Stat, {
				label = "Metal / s",
				value = rate_text(view.metal_rate),
				LayoutOrder = 8,
			})
			else nil,
		EnergyRate = if view.energy_rate ~= nil
			then React.createElement(Stat, {
				label = "Energy / s",
				value = rate_text(view.energy_rate),
				LayoutOrder = 9,
			})
			else nil,
		Shield = if view.shield ~= nil
			then React.createElement(Stat, {
				label = "Shield",
				value = view.shield,
				LayoutOrder = 11,
			})
			else nil,
		Stall = if stall_text(view) ~= nil
			then React.createElement(Stat, {
				label = "Status",
				value = stall_text(view) :: string,
				LayoutOrder = 10,
			})
			else nil,
		Cargo = if view.cargo ~= nil
			then React.createElement(Stat, {
				label = "Cargo",
				value = view.cargo,
				LayoutOrder = 6,
			})
			else nil,
		Missiles = if view.missiles ~= nil
			then React.createElement(Stat, {
				label = "Missiles",
				value = view.missiles,
				LayoutOrder = 7,
			})
			else nil,
	}

	return React.createElement(React.Fragment, {}, {
		Title = React.createElement("Frame", {
			[React.Tag] = "selection-title",
			LayoutOrder = 1,
		}, {
			Accent = React.createElement("Frame", {
				[React.Tag] = "accent-bar",
				LayoutOrder = 1,
			}),
			Name = React.createElement("TextLabel", {
				[React.Tag] = "selection-name",
				LayoutOrder = 2,
				Text = view.display_name,
			}),
			State = React.createElement("TextLabel", {
				[React.Tag] = if is_blueprint then "badge badge-blueprint" else "badge",
				LayoutOrder = 3,
				Text = if is_blueprint then "BLUEPRINT" else "ACTIVE",
			}),
		}),
		Subtitle = if view.subtitle ~= nil
			then React.createElement("TextLabel", {
				[React.Tag] = "selection-subtitle",
				LayoutOrder = 2,
				Text = view.subtitle,
			})
			else nil,
		Track = React.createElement("Frame", {
			[React.Tag] = "progress-track",
			LayoutOrder = 3,
		}, {
			Fill = React.createElement("Frame", {
				[React.Tag] = if is_blueprint then "progress-fill blueprint-fill" else "progress-fill",
				Size = UDim2.new(fraction, 0, 1, 0),
			}),
		}),
		Stats = React.createElement("Frame", {
			[React.Tag] = "stat-list",
			LayoutOrder = 4,
		}, stats),
		Queue = if #view.queue > 0 then React.createElement(Queue, { view = view, LayoutOrder = 5 }) else nil,
	})
end

local function Many(props: { views: { EntityView } })
	-- collapse the selection into "3 x Grunt" style counts
	local counts: { [string]: number } = {}
	local order: { string } = {}
	for _, view in props.views do
		if counts[view.display_name] == nil then
			counts[view.display_name] = 0
			table.insert(order, view.display_name)
		end
		counts[view.display_name] += 1
	end

	local rows = {}
	for index, name in order do
		rows[`Row{index}`] = React.createElement(Stat, {
			label = name,
			value = `x{counts[name]}`,
			LayoutOrder = index,
		})
	end

	return React.createElement(React.Fragment, {}, {
		Title = React.createElement("Frame", {
			[React.Tag] = "selection-title",
			LayoutOrder = 1,
		}, {
			Accent = React.createElement("Frame", {
				[React.Tag] = "accent-bar",
				LayoutOrder = 1,
			}),
			Name = React.createElement("TextLabel", {
				[React.Tag] = "selection-name",
				LayoutOrder = 2,
				Text = "SELECTION",
			}),
			Count = React.createElement("TextLabel", {
				[React.Tag] = "badge badge-count",
				LayoutOrder = 3,
				Text = tostring(#props.views),
			}),
		}),
		Rows = React.createElement("Frame", {
			[React.Tag] = "stat-list",
			LayoutOrder = 2,
		}, rows),
	})
end

-- The entity the cursor is over, if any.
local function use_hovered(): number?
	local hovered, set_hovered = React.useState(nil :: number?)
	React.useEffect(function()
		return input.subscribe_hover(function(id: number?)
			set_hovered(id)
		end)
	end, {})
	return hovered
end

local function SelectionPanel()
	local selected = use_entities.use_selection()
	local hovered = use_hovered()
	-- Whatever the cursor is over is what the panel describes, whoever it belongs to, so an enemy can be
	-- identified without selecting it. It is only what is shown: the selection is untouched, and it is what
	-- orders go to. With the cursor over nothing the panel goes back to the selection.
	local ids = React.useMemo(function()
		if hovered ~= nil then
			return { hovered }
		end
		return selected
	end, { hovered, selected })
	local views = use_entities.use_views(ids)
	local ui_scale = use_viewport.use_ui_scale()

	if #views == 0 then
		return nil
	end

	return React.createElement("Frame", {
		[React.Tag] = "selection-panel panel",
		LayoutOrder = 1,
	}, {
		Scale = React.createElement("UIScale", { Scale = ui_scale }),
		Rail = React.createElement("Frame", {
			[React.Tag] = "rail",
		}),
		Content = if #views == 1
			then React.createElement(Single, { view = views[1] })
			else React.createElement(Many, { views = views }),
	})
end

return table.freeze({
	SelectionPanel = SelectionPanel,
})
