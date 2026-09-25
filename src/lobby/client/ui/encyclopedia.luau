-- The lobby's Encyclopedia tab: every unit and building a player can have, a card each, filed the way the defs are
-- (shared/unit_defs: bots, vehicles, hovercraft, ships and aircraft by tier, the experimentals, then the factories,
-- the economy and the defences), cheapest first within each, the cards flowing across as many to a row as fit. A
-- search box and a chip per kind narrow them.
--
-- Each card wears its tier, as an unlock's card does on the end screen (Client.ui.unlock_reveal's `tier_of`, from what
-- it costs): a picture of it (unit_thumbnail.luau), its name, what it is, its tier, what it costs, how tough it is and
-- the damage it does a second, and whether the campaign has it locked for this player. Clicking one opens its entry in
-- a panel beside the grid, which narrows to make room: a header with the thing itself large and turning, its tier, what
-- sort of thing it is and its headline figures, then its tips (shared/unit_descriptions), everything its def says about
-- it, a card for each weapon, and links to the entries it is built by, builds, launches or upgrades. Every number is
-- read off the def, which has BAR's numbers, and put into words the way the HUD does (Shared.unit_facts), so the lobby
-- and a game never disagree.
--
-- Another screen opens an entry by handing `focus` a def name with a fresh `nonce` (the campaign's missions link to what
-- they unlock), and so does a link in an entry: the grid clears its filters, opens that entry and scrolls its card into
-- view.

local ReplicatedStorage = game:GetService "ReplicatedStorage"
local RunService = game:GetService "RunService"

local React = require(ReplicatedStorage.Packages.react)

local campaign = require(ReplicatedStorage.Shared.campaign)
local types = require(ReplicatedStorage.Shared.types)
local unit_defs = require(ReplicatedStorage.Shared.unit_defs)
local unit_descriptions = require(ReplicatedStorage.Shared.unit_descriptions)
local unit_facts = require(ReplicatedStorage.Shared.unit_facts)
local air_t1 = require(ReplicatedStorage.Shared.unit_defs.air_t1)
local air_t2 = require(ReplicatedStorage.Shared.unit_defs.air_t2)
local bot_t1 = require(ReplicatedStorage.Shared.unit_defs.bot_t1)
local bot_t2 = require(ReplicatedStorage.Shared.unit_defs.bot_t2)
local building = require(ReplicatedStorage.Shared.unit_defs.building)
local defense = require(ReplicatedStorage.Shared.unit_defs.defense)
local factory = require(ReplicatedStorage.Shared.unit_defs.factory)
local hover_t1 = require(ReplicatedStorage.Shared.unit_defs.hover_t1)
local ship_t1 = require(ReplicatedStorage.Shared.unit_defs.ship_t1)
local t3 = require(ReplicatedStorage.Shared.unit_defs.t3)
local vehicle_t1 = require(ReplicatedStorage.Shared.unit_defs.vehicle_t1)
local vehicle_t2 = require(ReplicatedStorage.Shared.unit_defs.vehicle_t2)

local art_icon = require(ReplicatedStorage.Client.ui.art_icon)
local unlock_reveal = require(ReplicatedStorage.Client.ui.unlock_reveal)

local use_campaign = require(ReplicatedStorage.LobbyClient.use_campaign)
local controls = require(script.Parent.controls)
local unit_thumbnail = require(script.Parent.unit_thumbnail)

type EntityDef = types.EntityDef
type Row = unit_facts.Row
type Tier = unlock_reveal.Tier

local ArtIcon = art_icon.ArtIcon
local UnitThumbnail = unit_thumbnail.UnitThumbnail

-- How fast an open entry's picture turns, in radians a second.
local HERO_SPIN = 0.35
-- How far under the grid's top a card jumped to is left, as a share of the grid's height.
local JUMP_MARGIN = 0.04

-- An entry to open, from another screen or from a link in an entry. `nonce` is new each time, so asking for the same
-- entry twice scrolls to it again.
export type Focus = { name: string, nonce: number }

type Category =
	"all"
	| "bots"
	| "vehicles"
	| "hover"
	| "ships"
	| "aircraft"
	| "experimental"
	| "factories"
	| "economy"
	| "defences"

-- A heading in the list and the defs under it, cheapest first.
type Section = {
	key: string,
	category: Category,
	label: string,
	names: { string },
}

-- The kinds along the top, in order, and what each chip says.
local CATEGORIES: { { id: Category, label: string } } = {
	{ id = "all", label = "ALL" },
	{ id = "bots", label = "BOTS" },
	{ id = "vehicles", label = "VEHICLES" },
	{ id = "hover", label = "HOVER" },
	{ id = "ships", label = "SHIPS" },
	{ id = "aircraft", label = "AIRCRAFT" },
	{ id = "experimental", label = "EXPERIMENTAL" },
	{ id = "factories", label = "FACTORIES" },
	{ id = "economy", label = "ECONOMY" },
	{ id = "defences", label = "DEFENCES" },
}

-- The list's headings, in order: each is one of shared/unit_defs's modules, so a def is filed where it is written.
-- The reclaimables, the campaign's props and the scavengers' boss are no one's to build, and have no entry.
local SECTION_GROUPS: { { group: { [string]: EntityDef }, key: string, category: Category, label: string } } = {
	{ group = bot_t1, key = "bot_t1", category = "bots", label = "BOTS · TIER 1" },
	{ group = bot_t2, key = "bot_t2", category = "bots", label = "BOTS · TIER 2" },
	{ group = vehicle_t1, key = "vehicle_t1", category = "vehicles", label = "VEHICLES · TIER 1" },
	{ group = vehicle_t2, key = "vehicle_t2", category = "vehicles", label = "VEHICLES · TIER 2" },
	{ group = hover_t1, key = "hover_t1", category = "hover", label = "HOVERCRAFT" },
	{ group = ship_t1, key = "ship_t1", category = "ships", label = "SHIPS" },
	{ group = air_t1, key = "air_t1", category = "aircraft", label = "AIRCRAFT · TIER 1" },
	{ group = air_t2, key = "air_t2", category = "aircraft", label = "AIRCRAFT · TIER 2" },
	{ group = t3, key = "t3", category = "experimental", label = "EXPERIMENTAL" },
	{ group = factory, key = "factory", category = "factories", label = "FACTORIES" },
	{ group = building, key = "building", category = "economy", label = "ECONOMY" },
	{ group = defense, key = "defense", category = "defences", label = "DEFENCES" },
}

-- Whether `def` gets an entry: what can be built (and so locked), a commander, and a carrier's drone.
local function listed(def: EntityDef): boolean
	if def.kind ~= "unit" and def.kind ~= "building" then
		return false
	end
	return campaign.is_lockable(def.name) or def.nametag == true or def.drone == true
end

-- Cheapest first, the way a build menu goes from the first things built to the last.
local function by_cost(a: EntityDef, b: EntityDef): boolean
	if a.metal_cost ~= b.metal_cost then
		return a.metal_cost < b.metal_cost
	end
	return a.display_name < b.display_name
end

local function build_sections(): { Section }
	local sections: { Section } = {}
	for _, entry in SECTION_GROUPS do
		local defs: { EntityDef } = {}
		for name in entry.group do
			local def = unit_defs.defs[name]
			if def ~= nil and listed(def) then
				table.insert(defs, def)
			end
		end
		table.sort(defs, by_cost)
		local names: { string } = {}
		for _, def in defs do
			table.insert(names, def.name)
		end
		if #names > 0 then
			table.insert(sections, { key = entry.key, category = entry.category, label = entry.label, names = names })
		end
	end
	return sections
end

local SECTIONS: { Section } = build_sections()

-- Every def with an entry, and how many there are.
local HAS_ENTRY: { [string]: boolean } = {}
local ENTRY_COUNT = 0
for _, section in SECTIONS do
	for _, name in section.names do
		HAS_ENTRY[name] = true
		ENTRY_COUNT += 1
	end
end

-- What builds each def, and what launches each drone, both cheapest first: the other way round from what a def says.
local BUILT_BY: { [string]: { string } } = {}
local LAUNCHED_BY: { [string]: { string } } = {}
do
	local all: { EntityDef } = {}
	for name in HAS_ENTRY do
		table.insert(all, unit_defs.defs[name])
	end
	table.sort(all, by_cost)
	for _, def in all do
		for _, option in def.build_options or {} do
			BUILT_BY[option] = BUILT_BY[option] or {}
			table.insert(BUILT_BY[option], def.name)
		end
		if def.carrier ~= nil then
			LAUNCHED_BY[def.carrier.drone] = LAUNCHED_BY[def.carrier.drone] or {}
			table.insert(LAUNCHED_BY[def.carrier.drone], def.name)
		end
	end
end

-- What a search is matched against: the name, the def's own name spelled out, and the subtitle, all lower case.
local function search_text(def: EntityDef): string
	return string.lower(`{def.display_name} {string.gsub(def.name, "_", " ")} {def.subtitle or ""}`)
end

local SEARCH_TEXT: { [string]: string } = {}
for name in HAS_ENTRY do
	SEARCH_TEXT[name] = search_text(unit_defs.defs[name])
end

-- The damage a second of all of `def`'s weapons together, or nil if it has none that does damage. An EMP weapon's
-- damage only stuns and an anti-nuke only shoots down missiles, so neither counts; each still has its own card.
local function damage_dps(def: EntityDef): number?
	local total: number? = nil
	for _, weapon in (def.weapons or {}) :: { types.Weapon } do
		if weapon.paralyze_time == nil and weapon.anti_nuke ~= true then
			total = (total or 0) + unit_facts.weapon_dps(weapon)
		end
	end
	return total
end

-- A link to another entry: its name, which opens it.
local function EntryLink(props: { name: string, on_open: (name: string) -> (), LayoutOrder: number })
	local def = unit_defs.defs[props.name]
	return React.createElement("TextButton", {
		[React.Tag] = "entry-link",
		LayoutOrder = props.LayoutOrder,
		Text = if def ~= nil then def.display_name else props.name,
		AutoButtonColor = false,
		[React.Event.Activated] = function()
			props.on_open(props.name)
		end,
	})
end

-- A caption over a part of an open entry, with a rule running out after it.
local function Heading(props: { text: string, tone: string?, LayoutOrder: number })
	return React.createElement("Frame", {
		[React.Tag] = "entry-heading",
		LayoutOrder = props.LayoutOrder,
	}, {
		Text = React.createElement("TextLabel", {
			[React.Tag] = if props.tone ~= nil then `entry-heading-text {props.tone}` else "entry-heading-text",
			LayoutOrder = 1,
			Text = props.text,
		}),
		Rule = React.createElement("Frame", {
			[React.Tag] = "entry-rule",
			LayoutOrder = 2,
		}),
	})
end

-- Facts as a grid of cells, each its label over its value.
local function StatGrid(props: { rows: { Row }, LayoutOrder: number })
	local cells: { [string]: any } = {}
	for index, row in props.rows do
		cells[`Stat{index}`] = React.createElement("Frame", {
			[React.Tag] = "stat-cell",
			LayoutOrder = index,
		}, {
			Label = React.createElement("TextLabel", {
				[React.Tag] = "stat-label",
				LayoutOrder = 1,
				Text = row.label,
			}),
			Value = React.createElement("TextLabel", {
				[React.Tag] = if row.tag ~= nil then `stat-value {row.tag}` else "stat-value",
				LayoutOrder = 2,
				Text = row.value,
			}),
		})
	end
	return React.createElement("Frame", {
		[React.Tag] = "stat-grid",
		LayoutOrder = props.LayoutOrder,
	}, cells)
end

-- A row of links under a caption: what builds this, what it builds, and so on.
local function LinkRow(props: {
	label: string,
	names: { string },
	on_open: (name: string) -> (),
	LayoutOrder: number,
})
	local links: { [string]: any } = {
		Label = React.createElement("TextLabel", {
			[React.Tag] = "entry-links-label",
			LayoutOrder = 0,
			Text = props.label,
		}),
	}
	local order = 0
	for _, name in props.names do
		if HAS_ENTRY[name] ~= true then
			continue
		end
		order += 1
		links[name] = React.createElement(EntryLink, { name = name, on_open = props.on_open, LayoutOrder = order })
	end
	if order == 0 then
		return nil
	end
	return React.createElement("Frame", {
		[React.Tag] = "entry-links",
		LayoutOrder = props.LayoutOrder,
	}, links)
end

-- One weapon: its icon, name and what it does that no number says, its damage a second and range large, and every
-- other fact about it in a grid below. `text` is a line on what it does, for the disintegrator.
local function WeaponCard(props: {
	name: string,
	slot: string,
	icon: string,
	dps: string?,
	range: string,
	notes: { string },
	text: string?,
	rows: { Row },
	LayoutOrder: number,
})
	local notes: { [string]: any } = {}
	for index, note in props.notes do
		notes[`Note{index}`] = React.createElement("TextLabel", {
			[React.Tag] = "tag",
			LayoutOrder = 10 + index,
			Text = string.upper(note),
		})
	end
	local head: { [string]: any } = {
		Icon = React.createElement(ArtIcon, {
			name = props.icon,
			view = "front",
			flat = true,
			fallback = props.slot,
			tag = "weapon-icon",
			LayoutOrder = 1,
		}),
		Name = React.createElement("TextLabel", {
			[React.Tag] = "weapon-name",
			LayoutOrder = 2,
			Text = props.name,
		}),
		Notes = React.createElement("Frame", {
			[React.Tag] = "weapon-notes grow",
			LayoutOrder = 3,
		}, notes),
		Dps = if props.dps ~= nil
			then React.createElement("TextLabel", {
				[React.Tag] = "weapon-figure weapon",
				LayoutOrder = 4,
				Text = `{props.dps} <font size="10">DPS</font>`,
				RichText = true,
			})
			else nil,
		Range = React.createElement("TextLabel", {
			[React.Tag] = "weapon-figure",
			LayoutOrder = 5,
			Text = `{props.range} <font size="10">RANGE</font>`,
			RichText = true,
		}),
	}
	return React.createElement("Frame", {
		[React.Tag] = "weapon-card",
		LayoutOrder = props.LayoutOrder,
	}, {
		Head = React.createElement("Frame", {
			[React.Tag] = "weapon-head",
			LayoutOrder = 1,
		}, head),
		Text = if props.text ~= nil
			then React.createElement("TextLabel", {
				[React.Tag] = "entry-text",
				LayoutOrder = 2,
				Text = props.text,
			})
			else nil,
		Stats = React.createElement(StatGrid, { rows = props.rows, LayoutOrder = 3 }),
	})
end

-- What sort of thing `def` is, in a word or two each, for the chips under an open entry's name. Only what the def
-- says outright.
local function roles_of(def: EntityDef): { string }
	local roles: { string } = {}
	local function add(role: string)
		table.insert(roles, role)
	end
	if def.nametag == true then
		add "COMMANDER"
	end
	if def.drone == true then
		add "DRONE"
	end
	if def.air ~= nil then
		add "AIRCRAFT"
	elseif def.waterline ~= nil then
		add "SUBMARINE"
	elseif def.min_water_depth ~= nil then
		add(if def.kind == "building" then "ON WATER" else "SHIP")
	elseif def.hover == true then
		add "HOVER"
	elseif def.kind == "building" then
		add "BUILDING"
	end
	if unit_defs.is_factory(def) then
		add "FACTORY"
	elseif def.buildpower ~= nil then
		add "BUILDER"
	end
	local anti_air, anti_nuke, emp = false, false, false
	for _, weapon in (def.weapons or {}) :: { types.Weapon } do
		anti_air = anti_air or weapon.anti_air == true
		anti_nuke = anti_nuke or weapon.anti_nuke == true
		emp = emp or weapon.paralyze_time ~= nil
	end
	if anti_nuke then
		add "ANTI-NUKE"
	elseif anti_air then
		add "ANTI-AIR"
	end
	if emp then
		add "EMP"
	end
	if def.transport ~= nil then
		add "TRANSPORT"
	end
	if def.carrier ~= nil then
		add "CARRIER"
	end
	if def.shield ~= nil then
		add "SHIELD"
	end
	if def.stealth == true then
		add "STEALTH"
	end
	return roles
end

-- A big figure under a caption, on an open entry's header.
local function HeroFigure(props: { label: string, value: string, tone: string?, LayoutOrder: number })
	return React.createElement("Frame", {
		[React.Tag] = "hero-figure",
		LayoutOrder = props.LayoutOrder,
	}, {
		Label = React.createElement("TextLabel", {
			[React.Tag] = "hero-figure-label",
			LayoutOrder = 1,
			Text = props.label,
		}),
		Value = React.createElement("TextLabel", {
			[React.Tag] = if props.tone ~= nil then `hero-figure-value {props.tone}` else "hero-figure-value",
			LayoutOrder = 2,
			Text = props.value,
		}),
	})
end

-- The top of an open entry: the thing itself, large and turning, across a stage in its tier's colours, with its tier
-- stamped in the corner and its name and what it is along the bottom; under that what sort of thing it is, what its
-- numbers do not say, and its headline figures, a tile each across the width.
local function Hero(props: { def: EntityDef, tier: Tier, LayoutOrder: number })
	local def = props.def
	local description = unit_descriptions[def.name]
	local tier = props.tier

	local roles: { [string]: any } = {}
	for index, role in roles_of(def) do
		roles[`Role{index}`] = React.createElement("TextLabel", {
			[React.Tag] = "hero-role",
			LayoutOrder = index,
			Text = role,
		})
	end

	local figures: { [string]: any } = {}
	local order = 0
	local function figure(label: string, value: string, tone: string?)
		order += 1
		figures[`Figure{order}`] =
			React.createElement(HeroFigure, { label = label, value = value, tone = tone, LayoutOrder = order })
	end
	figure("METAL", unit_facts.figure(def.metal_cost), "metal")
	figure("ENERGY", unit_facts.figure(def.energy_cost), "energy")
	figure("HEALTH", unit_facts.figure(def.health))
	local dps = damage_dps(def)
	if dps ~= nil then
		figure("DPS", unit_facts.figure(dps), "weapon")
	end
	local range = unit_defs.display_range(def)
	if range ~= nil then
		figure("RANGE", unit_facts.figure(range))
	end
	if def.max_speed ~= nil and def.max_speed > 0 then
		figure("SPEED", unit_facts.figure(def.max_speed))
	end
	if def.buildpower ~= nil then
		figure("BUILDPOWER", unit_facts.figure(def.buildpower), "buildpower")
	end

	-- five or six tiles go three across, so none is left alone on a row of its own
	local figures_tag = if order == 5 or order == 6 then "hero-figures three" else "hero-figures"

	return React.createElement("Frame", {
		[React.Tag] = "entry-hero",
		LayoutOrder = props.LayoutOrder,
	}, {
		Stage = React.createElement("Frame", {
			[React.Tag] = `hero-stage {tier.tag}`,
			LayoutOrder = 1,
		}, {
			Picture = React.createElement(UnitThumbnail, {
				def_name = def.name,
				tag = "hero-picture",
				spin = HERO_SPIN,
				fallback = def.display_name,
			}),
			Banner = React.createElement("TextLabel", {
				[React.Tag] = `hero-banner {tier.tag}`,
				Text = tier.label,
			}),
			Plate = React.createElement("Frame", {
				[React.Tag] = "hero-plate",
			}, {
				Name = React.createElement("TextLabel", {
					[React.Tag] = "hero-name",
					LayoutOrder = 1,
					Text = string.upper(def.display_name),
				}),
				Subtitle = if def.subtitle ~= nil
					then React.createElement("TextLabel", {
						[React.Tag] = `hero-subtitle {tier.tag}`,
						LayoutOrder = 2,
						Text = def.subtitle,
					})
					else nil,
			}),
		}),
		Roles = React.createElement("Frame", {
			[React.Tag] = "hero-roles",
			LayoutOrder = 2,
		}, roles),
		Text = if description ~= nil and description.text ~= nil
			then React.createElement("TextLabel", {
				[React.Tag] = "entry-text",
				LayoutOrder = 3,
				Text = description.text,
			})
			else nil,
		Figures = React.createElement("Frame", {
			[React.Tag] = figures_tag,
			LayoutOrder = 4,
		}, figures),
	})
end

-- Everything about an open entry: its header, then its tips, its stats, a card for each weapon, and what it is
-- related to.
local function EntryBody(props: { def: EntityDef, tier: Tier, on_open: (name: string) -> () })
	local def = props.def
	local description = unit_descriptions[def.name]
	local children: { [string]: any } = {}
	local order = 0
	local function next_order(): number
		order += 1
		return order
	end

	children.Hero = React.createElement(Hero, { def = def, tier = props.tier, LayoutOrder = next_order() })

	if description ~= nil and description.tips ~= nil and #description.tips > 0 then
		children.TipsHeading =
			React.createElement(Heading, { text = "TIPS", tone = "accent", LayoutOrder = next_order() })
		for index, tip in description.tips do
			children[`Tip{index}`] = React.createElement("TextLabel", {
				[React.Tag] = "entry-tip",
				LayoutOrder = next_order(),
				Text = `›  {tip}`,
			})
		end
	end

	children.StatsHeading = React.createElement(Heading, { text = "STATS", LayoutOrder = next_order() })
	children.Stats = React.createElement(StatGrid, { rows = unit_facts.def_rows(def), LayoutOrder = next_order() })

	local weapons = def.weapons or {}
	local manual = def.manual_weapon
	if #weapons > 0 or manual ~= nil then
		local count = #weapons + (if manual ~= nil then 1 else 0)
		children.WeaponsHeading = React.createElement(Heading, {
			text = if count > 1 then `WEAPONS · {count}` else "WEAPON",
			tone = "weapon",
			LayoutOrder = next_order(),
		})
	end
	for index, weapon in weapons do
		local name, slot, icon = unit_facts.weapon_kind(weapon)
		local rows, notes = unit_facts.weapon_rows(weapon)
		-- the damage a second and the range are on the card's head, so the grid leaves them out
		local rest: { Row } = {}
		for position, row in rows do
			if position ~= 1 and row.label ~= "Range" then
				table.insert(rest, row)
			end
		end
		children[`Weapon{index}`] = React.createElement(WeaponCard, {
			name = name,
			slot = slot,
			icon = icon,
			dps = unit_facts.figure(unit_facts.weapon_dps(weapon)),
			range = unit_facts.figure(weapon.range),
			notes = notes,
			rows = rest,
			LayoutOrder = next_order(),
		})
	end
	if manual ~= nil then
		local rest: { Row } = {}
		for _, row in unit_facts.manual_weapon_rows(manual) do
			if row.label ~= "Range" then
				table.insert(rest, row)
			end
		end
		children.Manual = React.createElement(WeaponCard, {
			name = unit_facts.MANUAL_WEAPON.name,
			slot = unit_facts.MANUAL_WEAPON.slot,
			icon = unit_facts.MANUAL_WEAPON.icon,
			range = unit_facts.figure(manual.range),
			notes = { "Manual fire" },
			text = unit_facts.MANUAL_WEAPON.text,
			rows = rest,
			LayoutOrder = next_order(),
		})
	end

	local links: { { label: string, names: { string }? } } = {
		{ label = "BUILT BY", names = BUILT_BY[def.name] },
		{ label = "BUILDS", names = def.build_options },
		{ label = "UPGRADES", names = def.upgrades },
		{ label = "DRONE", names = if def.carrier ~= nil then { def.carrier.drone } else nil },
		{ label = "LAUNCHED BY", names = LAUNCHED_BY[def.name] },
	}
	local any_links = false
	for _, link in links do
		if link.names ~= nil and #link.names > 0 then
			any_links = true
		end
	end
	if any_links then
		children.LinksHeading = React.createElement(Heading, { text = "RELATED", LayoutOrder = next_order() })
	end
	for index, link in links do
		if link.names ~= nil and #link.names > 0 then
			children[`Links{index}`] = React.createElement(LinkRow, {
				label = link.label,
				names = link.names,
				on_open = props.on_open,
				LayoutOrder = next_order(),
			})
		end
	end

	return React.createElement("Frame", {
		[React.Tag] = "entry-body",
	}, children)
end

-- Rich text colours for a card's stat lines: the theme's metal, energy and fight colours (default/_theme.scss).
local METAL_HEX = "#C4CEDC"
local ENERGY_HEX = "#FFE640"
local FIGHT_HEX = "#FF8A40"

-- One unit in the grid, as an unlock's card is on the end screen: framed and shaded in its tier's colour, its picture
-- large, its name, what it is and its tier, and what it costs, how tough it is and the damage it does a second. A
-- locked one is dimmed with the lock stamped over its picture; the one open in the detail panel is lit.
local function UnitCard(props: {
	name: string,
	selected: boolean,
	locked: boolean,
	on_select: (name: string) -> (),
	card_ref: (name: string, instance: Instance?) -> (),
	LayoutOrder: number,
})
	local def = unit_defs.defs[props.name]
	local tier = unlock_reveal.tier_of(props.name)
	local dps = damage_dps(def)
	local tag = `unit-card {tier.tag}`
	if props.selected then
		tag ..= " selected"
	end
	if props.locked then
		tag ..= " locked"
	end
	local costs = `<font color="{METAL_HEX}">{unit_facts.figure(def.metal_cost)}</font> M   `
		.. `<font color="{ENERGY_HEX}">{unit_facts.figure(def.energy_cost)}</font> E`
	local fight = `{unit_facts.figure(def.health)} HP   `
		.. (if dps ~= nil then `<font color="{FIGHT_HEX}">{unit_facts.figure(dps)}</font> DPS` else "— DPS")
	return React.createElement("TextButton", {
		[React.Tag] = tag,
		LayoutOrder = props.LayoutOrder,
		Text = "",
		AutoButtonColor = false,
		ref = function(instance: Instance?)
			props.card_ref(props.name, instance)
		end,
		[React.Event.Activated] = function()
			props.on_select(props.name)
		end,
	}, {
		Tier = React.createElement("TextLabel", {
			[React.Tag] = `unit-card-tier {tier.tag}`,
			LayoutOrder = 1,
			Text = tier.label,
		}),
		Art = React.createElement("Frame", {
			[React.Tag] = "unit-card-art",
			LayoutOrder = 2,
		}, {
			Picture = React.createElement(UnitThumbnail, {
				def_name = props.name,
				tag = "unit-card-picture",
				fallback = string.sub(def.display_name, 1, 2),
			}),
			Lock = if props.locked
				then React.createElement("TextLabel", {
					[React.Tag] = "unit-card-lock",
					Text = "LOCKED",
				})
				else nil,
		}),
		Name = React.createElement("TextLabel", {
			[React.Tag] = "unit-card-name",
			LayoutOrder = 3,
			Text = def.display_name,
		}),
		Subtitle = React.createElement("TextLabel", {
			[React.Tag] = "unit-card-subtitle",
			LayoutOrder = 4,
			Text = def.subtitle or "",
		}),
		Costs = React.createElement("TextLabel", {
			[React.Tag] = "unit-card-stats",
			LayoutOrder = 5,
			Text = costs,
			RichText = true,
		}),
		Fight = React.createElement("TextLabel", {
			[React.Tag] = "unit-card-stats",
			LayoutOrder = 6,
			Text = fight,
			RichText = true,
		}),
	})
end

-- A heading and its cards, flowing across as many to a row as the width holds.
local function SectionView(props: {
	section: Section,
	names: { string },
	selected: string?,
	unlocks: { [string]: boolean },
	on_select: (name: string) -> (),
	card_ref: (name: string, instance: Instance?) -> (),
	LayoutOrder: number,
})
	local cards: { [string]: any } = {}
	for index, name in props.names do
		cards[name] = React.createElement(UnitCard, {
			name = name,
			selected = props.selected == name,
			locked = campaign.is_unlocked(props.unlocks, name) == false,
			on_select = props.on_select,
			card_ref = props.card_ref,
			LayoutOrder = index,
		})
	end
	return React.createElement("Frame", {
		[React.Tag] = "section",
		LayoutOrder = props.LayoutOrder,
	}, {
		Head = React.createElement("Frame", {
			[React.Tag] = "section-head",
			LayoutOrder = 1,
		}, {
			Accent = React.createElement("Frame", {
				[React.Tag] = "accent-bar",
				LayoutOrder = 1,
			}),
			Label = React.createElement("TextLabel", {
				[React.Tag] = "section-label heading",
				LayoutOrder = 2,
				Text = props.section.label,
			}),
			Count = React.createElement("TextLabel", {
				[React.Tag] = "badge",
				LayoutOrder = 3,
				Text = tostring(#props.names),
			}),
		}),
		Cards = React.createElement("Frame", {
			[React.Tag] = "card-grid",
			LayoutOrder = 2,
		}, cards),
	})
end

-- The open entry, in a panel beside the grid: a bar to close it, and the entry, scrolling on its own. It is keyed by
-- the def, so opening another starts it from the top.
local function Detail(props: { name: string, on_open: (name: string) -> (), on_close: () -> () })
	local def = unit_defs.defs[props.name]
	local tier = unlock_reveal.tier_of(props.name)
	return React.createElement("Frame", {
		[React.Tag] = `encyclopedia-detail {tier.tag}`,
	}, {
		Bar = React.createElement("Frame", {
			[React.Tag] = "detail-bar",
			LayoutOrder = 1,
		}, {
			Accent = React.createElement("Frame", {
				[React.Tag] = "accent-bar",
				LayoutOrder = 1,
			}),
			Title = React.createElement("TextLabel", {
				[React.Tag] = "detail-title heading",
				LayoutOrder = 2,
				Text = "ENTRY",
			}),
			Close = React.createElement(controls.Button, {
				kind = "button",
				tag = "detail-close",
				label = "Close",
				on_press = props.on_close,
				LayoutOrder = 3,
			}),
		}),
		[`Scroll_{props.name}`] = React.createElement("ScrollingFrame", {
			[React.Tag] = "detail-scroll",
			LayoutOrder = 2,
			CanvasSize = UDim2.new(),
			AutomaticCanvasSize = Enum.AutomaticSize.Y,
			ScrollingDirection = Enum.ScrollingDirection.Y,
		}, {
			Body = React.createElement(EntryBody, { def = def, tier = tier, on_open = props.on_open }),
		}),
	})
end

local function Encyclopedia(props: { focus: Focus? })
	local progress = use_campaign.use_campaign()
	local query, set_query = React.useState ""
	local category: Category, set_category = React.useState("all" :: Category)
	-- the entry open in the detail panel
	local selected: string?, set_selected = React.useState(nil :: string?)
	-- the card to bring into view once it is laid out
	local jump, set_jump = React.useState(nil :: Focus?)
	local list_ref = React.useRef(nil :: ScrollingFrame?)
	local search_ref = React.useRef(nil :: TextBox?)
	local cards = React.useRef({} :: { [string]: Instance })

	local function card_ref(name: string, instance: Instance?)
		cards.current[name] = instance :: any
	end

	-- Opens `name` in the detail panel and brings its card into view, clearing whatever would hide it.
	local function focus(name: string)
		if HAS_ENTRY[name] ~= true then
			return
		end
		set_query ""
		if search_ref.current ~= nil then
			search_ref.current.Text = ""
		end
		set_category "all"
		set_selected(name)
		set_jump({ name = name, nonce = os.clock() })
	end

	React.useEffect(function()
		if props.focus ~= nil then
			focus(props.focus.name)
		end
	end, { props.focus })

	-- Scrolls the card asked for to near the top of the grid once it has been laid out (the grid narrows as the detail
	-- panel opens, which moves it). The shell is scaled to fit the screen, and whether the canvas's offset is in the
	-- scaled pixels or the shell's own has proved hard to say, so rather than assume, it moves by what is left to go,
	-- sees how far that really moved the card, and corrects by that ratio, until the card is there or the canvas can go
	-- no further.
	React.useEffect(function(): (() -> ())?
		if jump == nil then
			return nil
		end
		local thread = task.spawn(function()
			RunService.Heartbeat:Wait()
			RunService.Heartbeat:Wait()
			-- canvas offset per screen pixel
			local ratio = 1
			for _ = 1, 4 do
				local list = list_ref.current
				local card = cards.current[jump.name]
				if list == nil or card == nil or not card:IsA "GuiObject" then
					return
				end
				-- a little under the top, so the row above shows the card is not the first
				local left = card.AbsolutePosition.Y - list.AbsolutePosition.Y - JUMP_MARGIN * list.AbsoluteSize.Y
				if math.abs(left) < 1 then
					return
				end
				local before = list.CanvasPosition.Y
				list.CanvasPosition = Vector2.new(0, math.max(0, before + left * ratio))
				local applied = list.CanvasPosition.Y - before
				if math.abs(applied) < 0.5 then
					return
				end
				RunService.Heartbeat:Wait()
				local moved = (card.AbsolutePosition.Y - list.AbsolutePosition.Y - JUMP_MARGIN * list.AbsoluteSize.Y)
				moved = left - moved
				if math.abs(moved) >= 1 then
					ratio = applied / moved
				end
			end
		end)
		return function()
			if coroutine.status(thread) ~= "dead" then
				task.cancel(thread)
			end
		end
	end, { jump })

	-- A card clicked opens its entry, or closes it if it is the one open.
	local function choose(name: string)
		set_selected(function(current: string?): string?
			return if current == name then nil else name
		end)
	end

	local needle = string.lower(query)
	local shown = 0
	local sections: { [string]: any } = {}
	for index, section in SECTIONS do
		if category ~= "all" and section.category ~= category then
			continue
		end
		local names: { string } = {}
		for _, name in section.names do
			if needle == "" or string.find(SEARCH_TEXT[name], needle, 1, true) ~= nil then
				table.insert(names, name)
			end
		end
		if #names == 0 then
			continue
		end
		shown += #names
		sections[section.key] = React.createElement(SectionView, {
			section = section,
			names = names,
			selected = selected,
			unlocks = progress.unlocks,
			on_select = choose,
			card_ref = card_ref,
			LayoutOrder = index,
		})
	end
	if shown == 0 then
		sections.Empty = React.createElement("TextLabel", {
			[React.Tag] = "empty",
			LayoutOrder = 0,
			Text = "Nothing matches.",
		})
	end

	local chips: { [string]: any } = {}
	for index, entry in CATEGORIES do
		chips[entry.id] = React.createElement(controls.Button, {
			kind = "chip",
			tag = if entry.id == category then "filter active" else "filter",
			label = entry.label,
			on_press = function()
				set_category(entry.id)
			end,
			LayoutOrder = index,
		})
	end

	return React.createElement("Frame", {
		[React.Tag] = "encyclopedia panel",
	}, {
		Rail = React.createElement("Frame", {
			[React.Tag] = "rail",
			LayoutOrder = 1,
		}),
		Toolbar = React.createElement("Frame", {
			[React.Tag] = "encyclopedia-toolbar",
			LayoutOrder = 2,
		}, {
			Search = React.createElement("TextBox", {
				[React.Tag] = "encyclopedia-search",
				LayoutOrder = 1,
				Text = "",
				PlaceholderText = "Search",
				PlaceholderColor3 = Color3.fromRGB(146, 166, 188),
				ClearTextOnFocus = false,
				ref = search_ref,
				[React.Change.Text] = function(box: TextBox)
					set_query(box.Text)
				end,
			}),
			Filters = React.createElement("Frame", {
				[React.Tag] = "encyclopedia-filters grow",
				LayoutOrder = 2,
			}, chips),
			Count = React.createElement("TextLabel", {
				[React.Tag] = "badge",
				LayoutOrder = 3,
				Text = if shown == ENTRY_COUNT then tostring(ENTRY_COUNT) else `{shown}/{ENTRY_COUNT}`,
			}),
		}),
		Content = React.createElement("Frame", {
			[React.Tag] = "encyclopedia-content",
			LayoutOrder = 3,
		}, {
			List = React.createElement("ScrollingFrame", {
				[React.Tag] = "encyclopedia-list",
				LayoutOrder = 1,
				CanvasSize = UDim2.new(),
				AutomaticCanvasSize = Enum.AutomaticSize.Y,
				ScrollingDirection = Enum.ScrollingDirection.Y,
				ref = list_ref,
			}, sections),
			Detail = if selected ~= nil
				then React.createElement(Detail, {
					name = selected,
					on_open = focus,
					on_close = function()
						set_selected(nil)
					end,
				})
				else nil,
		}),
	})
end

return table.freeze({
	Encyclopedia = Encyclopedia,
	EntryLink = EntryLink,
	has_entry = function(name: string): boolean
		return HAS_ENTRY[name] == true
	end,
})
