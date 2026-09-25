local ReplicatedStorage = game:GetService "ReplicatedStorage"

local React = require(ReplicatedStorage.Packages.react)

local art = require(ReplicatedStorage.Shared.art)
local types = require(ReplicatedStorage.Shared.types)
local unit_defs = require(ReplicatedStorage.Shared.unit_defs)
local unit_facts = require(ReplicatedStorage.Shared.unit_facts)

local input = require(ReplicatedStorage.Client.input)
local tutorial = require(ReplicatedStorage.Client.tutorial)
local art_icon = require(ReplicatedStorage.Client.ui.art_icon)
local tooltip = require(ReplicatedStorage.Client.ui.tooltip)
local unit_icon = require(ReplicatedStorage.Client.ui.unit_icon)
local use_entities = require(ReplicatedStorage.Client.ui.use_entities)
local use_mission = require(ReplicatedStorage.Client.ui.use_mission)
local use_tutorial = require(ReplicatedStorage.Client.ui.use_tutorial)
local use_viewport = require(ReplicatedStorage.Client.ui.use_viewport)

type EntityView = use_entities.EntityView
type FlowSource = use_entities.FlowSource
type Gauge = use_entities.Gauge
type Content = tooltip.Content

local ArtIcon = art_icon.ArtIcon
local WithTooltip = tooltip.WithTooltip
local UnitIcon = unit_icon.UnitIcon

-- How numbers and weapons are put into words, shared with the lobby's encyclopedia (Shared.unit_facts).
local figure = unit_facts.figure
local studs = unit_facts.studs
local weapon_kind = unit_facts.weapon_kind
local weapon_dps = unit_facts.weapon_dps
local MANUAL_WEAPON = unit_facts.MANUAL_WEAPON

local cancel_production: RemoteEvent = ReplicatedStorage.Shared.CancelProduction

-- Past this many a gauge is drawn as a meter rather than one pip each.
local MAX_PIPS = 12

-- Rich text is on for every label, so user-made text such as a team name has to be escaped before it goes in.
local function escape(text: string): string
	return (
		string.gsub(text, "[<>&\"']", {
			["<"] = "&lt;",
			[">"] = "&gt;",
			["&"] = "&amp;",
			['"'] = "&quot;",
			["'"] = "&apos;",
		})
	)
end

-- A factory's pending items, each a picture of what it makes (or its first letters, for a def with no art). Clicking
-- one cancels it.
local function Queue(props: { view: EntityView, LayoutOrder: number })
	local chips = {}
	for index, def_name in props.view.queue do
		local def = unit_defs.defs[def_name]
		local pictured = def ~= nil and art.has(def_name)
		chips[`Chip{index}`] = React.createElement("TextButton", {
			[React.Tag] = "queue-chip",
			LayoutOrder = index,
			Text = if pictured then "" elseif def ~= nil then string.sub(def.display_name, 1, 2) else "?",
			[React.Event.Activated] = function()
				cancel_production:FireServer({ factory_id = props.view.id, index = index })
			end,
		}, {
			Icon = if pictured
				then React.createElement(UnitIcon, {
					def_name = def_name,
					team = props.view.team_color,
					tag = "queue-chip-icon",
				})
				else nil,
		})
	end

	return React.createElement("Frame", {
		[React.Tag] = "queue-strip",
		LayoutOrder = props.LayoutOrder,
	}, chips)
end

-- A rate's magnitude, signed: what is made is plus and what is spent is minus.
local function rate_text(rate: number): string
	if rate > 0 then
		return `+{string.format("%.1f", rate)}`
	elseif rate < 0 then
		return `-{string.format("%.1f", -rate)}`
	end
	return "0.0"
end

-- What something has earned in battle, "3 KILLS · XP 0.25", or nil until it has earned any.
local function veterancy_text(view: EntityView): string?
	if view.state == "blueprint" or (view.kills == 0 and view.experience == 0) then
		return nil
	end
	local kills = if view.kills == 1 then "1 KILL" else `{view.kills} KILLS`
	return `{kills} · XP {string.format("%.2f", view.experience)}`
end

-- Who it belongs to, at the end of the title: a swatch and the name, both in the team's colour.
local function TeamTag(props: { view: EntityView, LayoutOrder: number })
	local view = props.view
	local name = if view.team_name ~= nil then view.team_name else `Team {view.team}`
	local color = view.team_color
	return React.createElement("Frame", {
		[React.Tag] = "team-tag",
		LayoutOrder = props.LayoutOrder,
	}, {
		-- The swatch is white and tinted by a gradient, since a style rule's colour would win over one set here.
		Swatch = React.createElement("Frame", {
			[React.Tag] = if color ~= nil then "team-swatch" else "team-swatch team-swatch-neutral",
			LayoutOrder = 1,
		}, {
			Tint = if color ~= nil
				then React.createElement("UIGradient", { Color = ColorSequence.new(color) })
				else nil,
		}),
		Name = React.createElement("TextLabel", {
			[React.Tag] = "team-name",
			LayoutOrder = 2,
			Text = if color ~= nil
				then `<font color="#{color:ToHex()}">{escape(string.upper(name))}</font>`
				else escape(string.upper(name)),
		}),
	})
end

-- The top line: the name, a badge for a state worth pointing out (a blueprint, a wreck; something simply up and
-- running has none), and whose it is at the end. Hovering it shows `tooltip`, what there is to know about the thing
-- that does not change as it goes about its business.
local function Title(props: {
	name: string,
	badge: string?,
	badge_tag: string?,
	team: EntityView?,
	tooltip: (() -> Content)?,
	LayoutOrder: number,
})
	local children = {
		Accent = React.createElement("Frame", {
			[React.Tag] = "accent-bar",
			LayoutOrder = 1,
		}),
		Name = React.createElement("TextLabel", {
			[React.Tag] = "selection-name",
			LayoutOrder = 2,
			Text = props.name,
		}),
		Badge = if props.badge ~= nil
			then React.createElement("TextLabel", {
				[React.Tag] = if props.badge_tag ~= nil then `badge {props.badge_tag}` else "badge",
				LayoutOrder = 3,
				Text = props.badge,
			})
			else nil,
		Team = if props.team ~= nil then React.createElement(TeamTag, { view = props.team, LayoutOrder = 4 }) else nil,
	}
	if props.tooltip ~= nil then
		return React.createElement(WithTooltip, {
			tag = "selection-title",
			LayoutOrder = props.LayoutOrder,
			content = props.tooltip,
		}, children)
	end
	return React.createElement("Frame", {
		[React.Tag] = "selection-title",
		LayoutOrder = props.LayoutOrder,
	}, children)
end

-- The line under the title: what it is in plain words, and at the end what it has earned in battle, if anything.
local function Subtitle(props: { text: string?, veterancy: string?, LayoutOrder: number })
	if props.text == nil and props.veterancy == nil then
		return nil
	end
	return React.createElement("Frame", {
		[React.Tag] = "subtitle-row",
		LayoutOrder = props.LayoutOrder,
	}, {
		Text = React.createElement("TextLabel", {
			[React.Tag] = "selection-subtitle",
			LayoutOrder = 1,
			Text = props.text or "",
		}),
		Veterancy = if props.veterancy ~= nil
			then React.createElement("TextLabel", {
				[React.Tag] = "veterancy",
				LayoutOrder = 2,
				Text = props.veterancy,
			})
			else nil,
	})
end

-- A thick bar with its numbers stamped on it. `tone` picks the fill's colour.
local function Vitals(props: { fraction: number, tone: string, label: string, LayoutOrder: number })
	return React.createElement("Frame", {
		[React.Tag] = "vitals-track",
		LayoutOrder = props.LayoutOrder,
	}, {
		Fill = React.createElement("Frame", {
			[React.Tag] = `vitals-fill {props.tone}`,
			Size = UDim2.new(math.clamp(props.fraction, 0, 1), 0, 1, 0),
		}),
		Label = React.createElement("TextLabel", {
			[React.Tag] = "vitals-label",
			Text = props.label,
		}),
	})
end

-- Health goes from green through amber to red as it runs down.
local function health_tone(fraction: number): string
	return if fraction > 0.6
		then "vitals-fill-good"
		elseif fraction > 0.3 then "vitals-fill-worn"
		else "vitals-fill-critical"
end

-- One resource's tile: a figure in big type under the resource's name, with a line of small print under that. What
-- holds something back lights its tile's edge in red with why.
local function ResourceTile(props: {
	resource: "metal" | "energy",
	value: string,
	unit: string?,
	tone: string,
	caption: string?,
	stall: string?,
	tooltip: (() -> Content)?,
	LayoutOrder: number,
})
	local tag = if props.stall ~= nil
		then `resource-tile {props.resource}-tile tile-stalled`
		else `resource-tile {props.resource}-tile`
	local children = {
		Rail = React.createElement("Frame", {
			[React.Tag] = `tile-rail {props.resource}-rail`,
		}),
		Head = React.createElement("Frame", {
			[React.Tag] = "tile-head",
			LayoutOrder = 1,
		}, {
			Chip = React.createElement("Frame", {
				[React.Tag] = `resource-chip {props.resource}-chip`,
				LayoutOrder = 1,
			}),
			Name = React.createElement("TextLabel", {
				[React.Tag] = `tile-name {props.resource}`,
				LayoutOrder = 2,
				Text = string.upper(props.resource),
			}),
			Stall = if props.stall ~= nil
				then React.createElement("TextLabel", {
					[React.Tag] = "tile-stall",
					LayoutOrder = 3,
					Text = props.stall,
				})
				else nil,
		}),
		Rate = React.createElement("Frame", {
			[React.Tag] = "tile-rate",
			LayoutOrder = 2,
		}, {
			Value = React.createElement("TextLabel", {
				[React.Tag] = `tile-rate-value {props.tone}`,
				LayoutOrder = 1,
				Text = props.value,
			}),
			Unit = if props.unit ~= nil
				then React.createElement("TextLabel", {
					[React.Tag] = `tile-rate-unit {props.tone}`,
					LayoutOrder = 2,
					Text = props.unit,
				})
				else nil,
		}),
		Caption = if props.caption ~= nil
			then React.createElement("TextLabel", {
				[React.Tag] = "tile-cost",
				LayoutOrder = 3,
				Text = props.caption,
			})
			else nil,
	}
	if props.tooltip ~= nil then
		return React.createElement(WithTooltip, {
			tag = tag,
			LayoutOrder = props.LayoutOrder,
			content = props.tooltip,
		}, children)
	end
	return React.createElement("Frame", {
		[React.Tag] = tag,
		LayoutOrder = props.LayoutOrder,
	}, children)
end

local function rate_tone(rate: number): string
	return if math.abs(rate) < 0.05 then "tile-rate-idle" elseif rate > 0 then "tile-rate-gain" else "tile-rate-loss"
end

-- What a resource tile says when it is hovered: where its rate comes from, a row a source, and what, if anything, is
-- holding it back.
local function rate_tooltip(
	resource: "metal" | "energy",
	rate: number?,
	stall: string?,
	sources: { FlowSource }
): Content
	local rows: { tooltip.Row } = {}
	for _, source in sources do
		local amount = if resource == "metal" then source.metal else source.energy
		if math.abs(amount) >= 0.05 then
			table.insert(rows, {
				label = source.label,
				value = `{rate_text(amount)}/s`,
				tag = if amount > 0 then "gain" else "loss",
			})
		end
	end
	if #rows > 1 and rate ~= nil then
		table.insert(rows, {
			label = "Net",
			value = `{rate_text(rate)}/s`,
			tag = if rate >= 0 then "gain" else "loss",
			divider = true,
		})
	end
	local text = if #rows > 0 then nil elseif rate == nil or math.abs(rate) < 0.05 then "Idle" else `{rate_text(rate)}/s`
	local notes = {}
	if stall == "FULL" then
		table.insert(notes, "Storage full")
	elseif stall ~= nil then
		table.insert(notes, `Low {resource}: slowed`)
	end
	return {
		kicker = "ECONOMY",
		title = string.upper(resource),
		tone = if stall ~= nil then "danger" else resource,
		text = text,
		rows = rows,
		notes = notes,
	}
end

-- What it is making or spending right now, a tile for each resource it is, and none for one it is not. Nil when it
-- is doing neither, and then there is nothing to show.
local function Economy(props: { view: EntityView, LayoutOrder: number })
	local view = props.view
	local metal_stall = if view.stalled == "metal" then "SHORT" elseif view.stalled == "storage" then "FULL" else nil
	local energy_stall = if view.stalled == "energy" or view.need_energy then "SHORT" else nil
	local metal = view.metal_rate
	local energy = view.energy_rate
	local show_metal = metal ~= nil or metal_stall ~= nil
	local show_energy = energy ~= nil or energy_stall ~= nil
	if not show_metal and not show_energy then
		return nil
	end

	return React.createElement("Frame", {
		[React.Tag] = "economy-row",
		LayoutOrder = props.LayoutOrder,
	}, {
		Metal = if show_metal
			then React.createElement(ResourceTile, {
				resource = "metal",
				value = if metal ~= nil then rate_text(metal) else "0.0",
				unit = "/s",
				tone = rate_tone(metal or 0),
				stall = metal_stall,
				tooltip = function()
					return rate_tooltip("metal", metal, metal_stall, view.flow_sources)
				end,
				LayoutOrder = 1,
			})
			else nil,
		Energy = if show_energy
			then React.createElement(ResourceTile, {
				resource = "energy",
				value = if energy ~= nil then rate_text(energy) else "0.0",
				unit = "/s",
				tone = rate_tone(energy or 0),
				stall = energy_stall,
				tooltip = function()
					return rate_tooltip("energy", energy, energy_stall, view.flow_sources)
				end,
				LayoutOrder = 2,
			})
			else nil,
	})
end

-- What there is to know about a unit or building that does not change as it goes: what it costs, how tough and how
-- quick it is. Shown over its title.
local function unit_tooltip(view: EntityView, def: types.EntityDef): Content
	local rows: { tooltip.Row } = {
		{ label = "Health", value = tostring(math.floor(view.max_health)) },
		{ label = "Metal cost", value = tostring(def.metal_cost), tag = "metal" },
		{ label = "Energy cost", value = tostring(def.energy_cost), tag = "energy" },
		{ label = "Buildpower cost", value = tostring(def.buildpower_cost), tag = "buildpower" },
	}
	if def.max_speed ~= nil and def.max_speed > 0 then
		table.insert(rows, { label = "Speed", value = `{studs(def.max_speed)}/s` })
	end
	if def.transport ~= nil then
		table.insert(rows, { label = "Carries", value = `{def.transport.capacity} {def.transport.carries}` })
	end
	if view.order_count > 0 then
		table.insert(rows, { label = "Orders queued", value = tostring(view.order_count) })
	end
	return {
		kicker = if def.kind == "building" then "BUILDING" else "UNIT",
		title = string.upper(def.display_name),
		tone = "plain",
		text = def.subtitle,
		rows = rows,
	}
end

-- A labelled gauge: a pip for each of a few, a meter for more, and the count on the right.
local function GaugeRow(props: { label: string, gauge: Gauge, tone: string, LayoutOrder: number })
	local gauge = props.gauge
	local body
	if gauge.most <= MAX_PIPS then
		local pips = {}
		for index = 1, gauge.most do
			pips[`Pip{index}`] = React.createElement("Frame", {
				[React.Tag] = if index <= gauge.value then `pip pip-full {props.tone}-pip` else "pip",
				LayoutOrder = index,
			})
		end
		body = React.createElement("Frame", {
			[React.Tag] = "pip-row",
			LayoutOrder = 2,
		}, pips)
	else
		body = React.createElement("Frame", {
			[React.Tag] = "gauge-track",
			LayoutOrder = 2,
		}, {
			Fill = React.createElement("Frame", {
				[React.Tag] = `gauge-fill {props.tone}-fill`,
				Size = UDim2.new(math.clamp(gauge.value / math.max(1, gauge.most), 0, 1), 0, 1, 0),
			}),
		})
	end

	return React.createElement("Frame", {
		[React.Tag] = "gauge-row",
		LayoutOrder = props.LayoutOrder,
	}, {
		Label = React.createElement("TextLabel", {
			[React.Tag] = "gauge-label",
			LayoutOrder = 1,
			Text = props.label,
		}),
		Body = body,
		Value = React.createElement("TextLabel", {
			[React.Tag] = "gauge-value",
			LayoutOrder = 3,
			Text = `{math.floor(gauge.value)}/{math.floor(gauge.most)}`,
		}),
	})
end

-- One row of what something carries: a slot with its icon (Shared.ui_art), or a short code for what it is while the
-- icon is not there or for what has none, its name, and its headline figure on the right. The rest is in the tooltip
-- it shows when hovered.
local function LoadoutRow(props: {
	tone: "weapon" | "build" | "manual",
	slot: string,
	icon: string?,
	name: string,
	value: string,
	unit: string,
	tooltip: () -> Content,
	LayoutOrder: number,
})
	return React.createElement(WithTooltip, {
		tag = `loadout-row loadout-{props.tone}`,
		LayoutOrder = props.LayoutOrder,
		content = props.tooltip,
	}, {
		Slot = React.createElement("Frame", {
			[React.Tag] = `loadout-slot slot-{props.tone}`,
			LayoutOrder = 1,
		}, {
			Icon = if props.icon ~= nil
				then React.createElement(ArtIcon, {
					name = props.icon,
					view = "front",
					flat = true,
					fallback = props.slot,
					tag = "loadout-slot-icon",
				})
				else React.createElement("TextLabel", {
					[React.Tag] = "loadout-slot-code",
					Text = props.slot,
				}),
		}),
		Name = React.createElement("TextLabel", {
			[React.Tag] = "loadout-name",
			LayoutOrder = 2,
			Text = props.name,
		}),
		Figure = React.createElement("Frame", {
			[React.Tag] = "loadout-figure",
			LayoutOrder = 3,
		}, {
			Value = React.createElement("TextLabel", {
				[React.Tag] = `loadout-value value-{props.tone}`,
				LayoutOrder = 1,
				Text = props.value,
			}),
			Unit = React.createElement("TextLabel", {
				[React.Tag] = "loadout-unit",
				LayoutOrder = 2,
				Text = props.unit,
			}),
		}),
	})
end

-- A caption over a group of loadout rows, with a rule running out after it in the group's colour.
local function LoadoutHeading(props: { text: string, tone: string, LayoutOrder: number })
	return React.createElement("Frame", {
		[React.Tag] = "loadout-heading",
		LayoutOrder = props.LayoutOrder,
	}, {
		Text = React.createElement("TextLabel", {
			[React.Tag] = `loadout-heading-text heading-{props.tone}`,
			LayoutOrder = 1,
			Text = props.text,
		}),
		Rule = React.createElement("Frame", {
			[React.Tag] = `loadout-rule rule-{props.tone}`,
			LayoutOrder = 2,
		}),
	})
end

-- Everything about a weapon, for its tooltip.
local function weapon_tooltip(weapon: types.Weapon, index: number, count: number): Content
	local rows, notes = unit_facts.weapon_rows(weapon)
	return {
		kicker = if count > 1 then `WEAPON {index} OF {count}` else "WEAPON",
		title = weapon_kind(weapon),
		tone = "weapon",
		rows = rows,
		notes = notes,
	}
end

-- What building takes and what it reaches, and which of a builder's jobs it does, for its tooltip.
local function build_tooltip(def: types.EntityDef): Content
	return {
		kicker = "BUILDER",
		title = "BUILDPOWER",
		tone = "build",
		rows = unit_facts.build_rows(def),
	}
end

-- What it builds with and what it fights with: a row each, the detail in their tooltips.
local function Loadout(props: { def: types.EntityDef, LayoutOrder: number })
	local def = props.def
	local weapons = def.weapons or {}
	local manual = def.manual_weapon
	if def.buildpower == nil and #weapons == 0 and manual == nil then
		return nil
	end

	local rows = {}
	local order = 0
	local function next_order(): number
		order += 1
		return order
	end

	local buildpower = def.buildpower
	if buildpower ~= nil then
		rows.Build = React.createElement(LoadoutRow, {
			tone = "build",
			slot = "BLD",
			name = "BUILDPOWER",
			value = tostring(buildpower),
			unit = "PER SEC",
			tooltip = function()
				return build_tooltip(def)
			end,
			LayoutOrder = next_order(),
		})
	end

	if #weapons > 0 or manual ~= nil then
		rows.WeaponsHeading = React.createElement(LoadoutHeading, {
			text = "WEAPONS",
			tone = "weapon",
			LayoutOrder = next_order(),
		})
	end
	for index, weapon in weapons do
		local name, slot, icon = weapon_kind(weapon)
		rows[`Weapon{index}`] = React.createElement(LoadoutRow, {
			tone = "weapon",
			slot = slot,
			icon = icon,
			name = name,
			value = figure(weapon_dps(weapon)),
			unit = "DPS",
			tooltip = function()
				return weapon_tooltip(weapon, index, #weapons)
			end,
			LayoutOrder = next_order(),
		})
	end
	if manual ~= nil then
		rows.Manual = React.createElement(LoadoutRow, {
			tone = "manual",
			slot = MANUAL_WEAPON.slot,
			icon = MANUAL_WEAPON.icon,
			name = MANUAL_WEAPON.name,
			value = figure(manual.energy_per_shot),
			unit = "E/SHOT",
			tooltip = function(): Content
				return {
					kicker = "MANUAL WEAPON",
					title = MANUAL_WEAPON.name,
					tone = "weapon",
					text = MANUAL_WEAPON.text,
					rows = unit_facts.manual_weapon_rows(manual),
				}
			end,
			LayoutOrder = next_order(),
		})
	end

	return React.createElement("Frame", {
		[React.Tag] = "loadout",
		LayoutOrder = props.LayoutOrder,
	}, rows)
end

-- Something alive: a unit or a building, finished or still a blueprint. A `simple` one (the tutorial's) shows only
-- what it is called, whose it is, how healthy it is and what it is making, with `economy` what it makes and spends,
-- and with `weapons` what it fights with.
local function Live(props: {
	view: EntityView,
	def: types.EntityDef,
	simple: boolean,
	economy: boolean,
	weapons: boolean,
})
	local view = props.view
	local def = props.def
	local is_blueprint = view.state == "blueprint"

	local vitals_fraction = if is_blueprint
		then view.build_progress / math.max(1, view.buildpower_cost)
		else view.health / math.max(1, view.max_health)
	local vitals = React.createElement(Vitals, {
		fraction = vitals_fraction,
		tone = if is_blueprint then "vitals-fill-blueprint" else health_tone(vitals_fraction),
		label = if is_blueprint
			then `BUILDING  {math.floor(math.clamp(vitals_fraction, 0, 1) * 100)}%`
			else `{math.floor(view.health)} / {math.floor(view.max_health)}`,
		LayoutOrder = 4,
	})

	if props.simple then
		return React.createElement(React.Fragment, {}, {
			Title = React.createElement(Title, {
				name = view.display_name,
				badge = if is_blueprint then "BLUEPRINT" else nil,
				badge_tag = if is_blueprint then "badge-blueprint" else nil,
				team = view,
				LayoutOrder = 1,
			}),
			Vitals = vitals,
			Economy = if props.economy then React.createElement(Economy, { view = view, LayoutOrder = 5 }) else nil,
			Loadout = if props.weapons then React.createElement(Loadout, { def = def, LayoutOrder = 8 }) else nil,
			-- what a factory is making is always shown: the tutorial has the player make units
			Queue = if #view.queue > 0 then React.createElement(Queue, { view = view, LayoutOrder = 10 }) else nil,
		})
	end

	local gauges = {
		Shield = if view.shield ~= nil
			then React.createElement(GaugeRow, {
				label = "SHIELD",
				gauge = view.shield,
				tone = "shield",
				LayoutOrder = 1,
			})
			else nil,
		Missiles = if view.missiles ~= nil
			then React.createElement(GaugeRow, {
				label = "MISSILES",
				gauge = view.missiles,
				tone = "missile",
				LayoutOrder = 2,
			})
			else nil,
		Cargo = if view.cargo ~= nil
			then React.createElement(GaugeRow, {
				label = "CARGO",
				gauge = view.cargo,
				tone = "cargo",
				LayoutOrder = 3,
			})
			else nil,
	}

	return React.createElement(React.Fragment, {}, {
		Title = React.createElement(Title, {
			name = view.display_name,
			badge = if is_blueprint then "BLUEPRINT" else nil,
			badge_tag = if is_blueprint then "badge-blueprint" else nil,
			team = view,
			tooltip = function()
				return unit_tooltip(view, def)
			end,
			LayoutOrder = 1,
		}),
		Subtitle = React.createElement(Subtitle, {
			text = view.subtitle,
			veterancy = veterancy_text(view),
			LayoutOrder = 2,
		}),
		Vitals = vitals,
		Economy = React.createElement(Economy, { view = view, LayoutOrder = 5 }),
		Gauges = if next(gauges) ~= nil
			then React.createElement("Frame", {
				[React.Tag] = "gauge-list",
				LayoutOrder = 7,
			}, gauges)
			else nil,
		Loadout = React.createElement(Loadout, { def = def, LayoutOrder = 8 }),
		Queue = if #view.queue > 0 then React.createElement(Queue, { view = view, LayoutOrder = 10 }) else nil,
	})
end

-- Something left lying about: a wreck or a rock or tree. Nobody's, doing nothing, and there to be reclaimed, so it
-- shows what is left in it and how far reclaiming it has got, and for a wreck that can be raised, how far that has.
-- A `simple` one (the tutorial's) shows only its name, and a wreck's health.
local function Remnant(props: { view: EntityView, def: types.EntityDef, simple: boolean })
	local view = props.view
	local def = props.def
	local is_wreck = view.kind == "wreck"
	local raisable = is_wreck and (def.kind == "unit" or def.kind == "building")

	local reclaim_total = view.reclaim_total or 0
	local reclaimed = if reclaim_total > 0 then 1 - (view.reclaim_left or reclaim_total) / reclaim_total else 0
	local metal = view.metal_left or 0
	local energy = view.energy_left or 0
	-- a wreck holds only metal, and a rock or tree whichever it holds; one that holds neither still says so in metal
	local show_energy = energy > 0
	local show_metal = metal > 0 or not show_energy
	local resurrected = view.resurrect_progress or 0

	if props.simple then
		return React.createElement(React.Fragment, {}, {
			Title = React.createElement(Title, {
				name = if is_wreck then `{view.display_name} Wreck` else view.display_name,
				badge = if is_wreck then "WRECK" else "FEATURE",
				badge_tag = "badge-remnant",
				LayoutOrder = 1,
			}),
			Vitals = if is_wreck
				then React.createElement(Vitals, {
					fraction = view.health / math.max(1, view.max_health),
					tone = "vitals-fill-wreck",
					label = `{math.floor(view.health)} / {math.floor(view.max_health)}`,
					LayoutOrder = 3,
				})
				else nil,
		})
	end

	return React.createElement(React.Fragment, {}, {
		Title = React.createElement(Title, {
			name = if is_wreck then `{view.display_name} Wreck` else view.display_name,
			badge = if is_wreck then "WRECK" else "FEATURE",
			badge_tag = "badge-remnant",
			tooltip = function(): Content
				local rows: { tooltip.Row } = {}
				if metal > 0 then
					table.insert(rows, { label = "Metal left", value = figure(metal), tag = "metal" })
				end
				if energy > 0 then
					table.insert(rows, { label = "Energy left", value = figure(energy), tag = "energy" })
				end
				if view.reclaim_left ~= nil then
					table.insert(rows, { label = "Buildpower to reclaim", value = figure(view.reclaim_left) })
				end
				if raisable then
					table.insert(rows, { label = "Buildpower to resurrect", value = figure(def.buildpower_cost) })
				end
				return {
					kicker = if is_wreck then "WRECK" else "FEATURE",
					title = string.upper(if is_wreck then `{view.display_name} wreck` else view.display_name),
					tone = "plain",
					rows = rows,
				}
			end,
			LayoutOrder = 1,
		}),
		Subtitle = React.createElement(Subtitle, {
			text = if raisable then "Reclaim or resurrect" elseif is_wreck then "Reclaim for metal" else view.subtitle,
			LayoutOrder = 2,
		}),
		-- a wreck can be shot to pieces, so how much it has left matters; a rock or tree takes no harm
		Vitals = if is_wreck
			then React.createElement(Vitals, {
				fraction = view.health / math.max(1, view.max_health),
				tone = "vitals-fill-wreck",
				label = `{math.floor(view.health)} / {math.floor(view.max_health)}`,
				LayoutOrder = 3,
			})
			else nil,
		Yield = React.createElement("Frame", {
			[React.Tag] = "economy-row",
			LayoutOrder = 4,
		}, {
			Metal = if show_metal
				then React.createElement(ResourceTile, {
					resource = "metal",
					value = figure(metal),
					tone = "tile-rate-metal",
					caption = "TO RECLAIM",
					LayoutOrder = 1,
				})
				else nil,
			Energy = if show_energy
				then React.createElement(ResourceTile, {
					resource = "energy",
					value = figure(energy),
					tone = "tile-rate-energy",
					caption = "TO RECLAIM",
					LayoutOrder = 2,
				})
				else nil,
		}),
		Progress = React.createElement("Frame", {
			[React.Tag] = "gauge-list",
			LayoutOrder = 5,
		}, {
			Reclaimed = React.createElement(GaugeRow, {
				label = "RECLAIMED",
				gauge = { value = math.round(reclaimed * 100), most = 100 },
				tone = "reclaim",
				LayoutOrder = 1,
			}),
			Resurrected = if raisable and resurrected > 0
				then React.createElement(GaugeRow, {
					label = "RAISED",
					gauge = { value = math.round(resurrected * 100), most = 100 },
					tone = "resurrect",
					LayoutOrder = 2,
				})
				else nil,
		}),
	})
end

local function Single(props: { view: EntityView, simple: boolean, economy: boolean, weapons: boolean })
	local view = props.view
	local def = unit_defs.get(view.def_name)
	if view.kind == "wreck" or view.kind == "reclaimable" then
		return React.createElement(Remnant, { view = view, def = def, simple = props.simple })
	end
	return React.createElement(Live, {
		view = view,
		def = def,
		simple = props.simple,
		economy = props.economy,
		weapons = props.weapons,
	})
end

local function Many(props: { views: { EntityView } })
	-- collapse the selection into a tile per kind, with how many of it
	local counts: { [string]: number } = {}
	local order: { string } = {}
	for _, view in props.views do
		if counts[view.display_name] == nil then
			counts[view.display_name] = 0
			table.insert(order, view.display_name)
		end
		counts[view.display_name] += 1
	end

	local tiles = {}
	for index, name in order do
		tiles[`Tile{index}`] = React.createElement("Frame", {
			[React.Tag] = "group-tile",
			LayoutOrder = index,
		}, {
			Count = React.createElement("TextLabel", {
				[React.Tag] = "group-count",
				LayoutOrder = 1,
				Text = `×{counts[name]}`,
			}),
			Name = React.createElement("TextLabel", {
				[React.Tag] = "group-name",
				LayoutOrder = 2,
				Text = string.upper(name),
			}),
		})
	end

	return React.createElement(React.Fragment, {}, {
		Title = React.createElement(Title, {
			name = "SELECTION",
			badge = tostring(#props.views),
			badge_tag = "badge-count",
			LayoutOrder = 1,
		}),
		Tiles = React.createElement("Frame", {
			[React.Tag] = "group-grid",
			LayoutOrder = 2,
		}, tiles),
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
	-- What the panel showed when the cursor came onto it, held while the cursor stays there. The world is still under
	-- the panel, and without this whatever stood behind it would take the panel over just as a section was clicked.
	local held, set_held = React.useState(nil :: { number }?)
	-- Whatever the cursor is over is what the panel describes, whoever it belongs to, so an enemy can be
	-- identified without selecting it. It is only what is shown: the selection is untouched, and it is what
	-- orders go to. With the cursor over nothing the panel goes back to the selection.
	local ids = React.useMemo(function()
		if hovered ~= nil then
			return { hovered }
		end
		return selected
	end, { hovered, selected })
	local shown = held or ids
	local views = use_entities.use_views(shown)
	local ui_scale = use_viewport.use_ui_scale()
	-- the tutorial pares the panel down to a name, a team and a health bar, and brings weapons back once it has had
	-- units made
	local simple = use_mission.use_mission() == "tutorial"
	use_tutorial.use_tutorial()
	local weapons = simple == false or tutorial.shown "weapons"
	-- and what things make and spend, once the metal and energy bar is up
	local economy = simple == false or tutorial.shown "economy"
	-- what was held is gone, say it died, and with it the panel the cursor was on, which then never hears it leave
	React.useEffect(function()
		if held ~= nil and #views == 0 then
			set_held(nil)
		end
	end, { held, #views } :: { any })

	if #views == 0 then
		return nil
	end

	return React.createElement("Frame", {
		[React.Tag] = "selection-panel panel",
		LayoutOrder = 1,
		[React.Event.MouseEnter] = function()
			set_held(shown)
		end,
		[React.Event.MouseLeave] = function()
			set_held(nil)
		end,
	}, {
		Scale = React.createElement("UIScale", { Scale = ui_scale }),
		Rail = React.createElement("Frame", {
			[React.Tag] = "rail",
		}),
		Content = if #views == 1
			then React.createElement(Single, { view = views[1], simple = simple, economy = economy, weapons = weapons })
			else React.createElement(Many, { views = views }),
	})
end

return table.freeze({
	SelectionPanel = SelectionPanel,
})
