--!strict
-- An open encyclopedia entry: a header with the thing itself large and turning, its tier, what sort of thing it is and
-- its headline figures, then its tips (shared/unit_descriptions), everything its def says about it, a card for each
-- weapon, and links to the entries it is built by, builds, launches or upgrades. Every figure is read off the def and
-- put into words the way the HUD does (Shared.unit_facts), so the lobby and a game never disagree. A locked one keeps
-- its figures to itself: it says only what it is and which mission unlocks it.

local ReplicatedStorage = game:GetService "ReplicatedStorage"

local React = require(ReplicatedStorage.Packages.react)

local campaign = require(ReplicatedStorage.Shared.campaign)
local keybinds = require(ReplicatedStorage.Shared.keybinds)
local def_catalog = require(ReplicatedStorage.Shared.def_catalog)
local rarity = require(ReplicatedStorage.Shared.rarity)
local types = require(ReplicatedStorage.Shared.types)
local unit_descriptions = require(ReplicatedStorage.Shared.unit_descriptions)
local unit_facts = require(ReplicatedStorage.Shared.unit_facts)
local unit_defs = require(ReplicatedStorage.Shared.unit_defs)

local art_icon = require(ReplicatedStorage.ClientShared.art_icon)
local keybind_state = require(ReplicatedStorage.ClientShared.keybind_state)
local unit_picture = require(ReplicatedStorage.ClientShared.unit_picture)

local entry_link = require(script.Parent.entry_link)

type EntityDef = types.EntityDef
type Row = unit_facts.Row
type Tier = rarity.Tier

local ArtIcon = art_icon.ArtIcon
local UnitPicture = unit_picture.UnitPicture
local EntryLink = entry_link.EntryLink

-- How fast an open entry's picture turns, in radians a second.
local HERO_SPIN = 0.35

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
	unlocks: { [string]: boolean },
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
		if def_catalog.has_entry(name) == false then
			continue
		end
		order += 1
		links[name] = React.createElement(EntryLink, {
			name = name,
			locked = campaign.is_unlocked(props.unlocks, name) == false,
			on_open = props.on_open,
			LayoutOrder = order,
		})
	end
	if order == 0 then
		return nil
	end
	return React.createElement("Frame", {
		[React.Tag] = "entry-links",
		LayoutOrder = props.LayoutOrder,
	}, links)
end

-- Every row but the headline figures, which a weapon card shows large on its head instead.
local function without_headline(rows: { Row }): { Row }
	local rest: { Row } = {}
	for _, row in rows do
		if row.headline ~= true then
			table.insert(rest, row)
		end
	end
	return rest
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
			})
			else nil,
		Range = React.createElement("TextLabel", {
			[React.Tag] = "weapon-figure",
			LayoutOrder = 5,
			Text = `{props.range} <font size="10">RANGE</font>`,
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
local function Hero(props: { def: EntityDef, tier: Tier, locked: boolean, LayoutOrder: number })
	local def = props.def
	local tier = props.tier
	local text = unit_descriptions.text_of(def)

	local kinds: { [string]: any } = {}
	for index, kind in unit_facts.kinds(def) do
		kinds[`Role{index}`] = React.createElement("TextLabel", {
			[React.Tag] = "hero-role",
			LayoutOrder = index,
			Text = kind,
		})
	end

	local figures: { [string]: any } = {}
	local order = 0
	local function figure(label: string, value: string, tone: string?)
		order += 1
		figures[`Figure{order}`] =
			React.createElement(HeroFigure, { label = label, value = value, tone = tone, LayoutOrder = order })
	end
	local mission = def_catalog.unlocked_by(def.name)
	if props.locked and mission ~= nil then
		figure("UNLOCKED BY", string.upper(mission))
	elseif props.locked then
		figure("STATUS", "LOCKED")
	else
		figure("METAL", unit_facts.figure(def.metal_cost), "metal")
		figure("ENERGY", unit_facts.figure(def.energy_cost), "energy")
		if def.health ~= nil then
			figure("HEALTH", unit_facts.figure(def.health))
		end
		local dps = unit_facts.damage_dps(def)
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
		if def.builder ~= nil then
			figure("BUILDPOWER", unit_facts.figure(def.builder.buildpower), "buildpower")
		end
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
			Picture = React.createElement(UnitPicture, {
				framing = "card",
				team = entry_link.TEAM,
				def_name = def.name,
				tag = "hero-picture",
				spin = HERO_SPIN,
				fallback = def.display_name,
				locked = props.locked,
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
		}, kinds),
		Text = if props.locked == false and text ~= nil
			then React.createElement("TextLabel", {
				[React.Tag] = "entry-text",
				LayoutOrder = 3,
				Text = text,
			})
			else nil,
		Figures = React.createElement("Frame", {
			[React.Tag] = figures_tag,
			LayoutOrder = 4,
		}, figures),
	})
end

-- Everything about an open entry: its header, then its tips, its stats, a card for each weapon, and what it is
-- related to. A locked one has only its header and what it is related to.
local function EntryBody(props: {
	def: EntityDef,
	tier: Tier,
	locked: boolean,
	unlocks: { [string]: boolean },
	on_open: (name: string) -> (),
})
	local def = props.def
	local tips = unit_descriptions.tips_of(def.name)
	-- the keys a tip names are the player's own
	local bindings = keybind_state.use_bindings()
	local children: { [string]: any } = {}
	local order = 0
	local function next_order(): number
		order += 1
		return order
	end

	children.Hero =
		React.createElement(Hero, { def = def, tier = props.tier, locked = props.locked, LayoutOrder = next_order() })

	-- nothing more of a locked one is told until it is unlocked
	if props.locked == false and tips ~= nil and #tips > 0 then
		children.TipsHeading =
			React.createElement(Heading, { text = "TIPS", tone = "accent", LayoutOrder = next_order() })
		for index, tip in tips do
			children[`Tip{index}`] = React.createElement("TextLabel", {
				[React.Tag] = "entry-tip",
				LayoutOrder = next_order(),
				Text = `›  {keybinds.fill(tip, bindings)}`,
			})
		end
	end

	if props.locked == false then
		children.StatsHeading = React.createElement(Heading, { text = "STATS", LayoutOrder = next_order() })
		children.Stats = React.createElement(StatGrid, { rows = unit_facts.def_rows(def), LayoutOrder = next_order() })
	end

	local weapons: { types.Weapon } = if props.locked then {} else def.weapons or {}
	local manual = if props.locked then nil else def.manual_weapon
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
		children[`Weapon{index}`] = React.createElement(WeaponCard, {
			name = name,
			slot = slot,
			icon = icon,
			dps = unit_facts.figure(unit_facts.weapon_dps(weapon)),
			range = unit_facts.figure(weapon.range),
			notes = notes,
			rows = without_headline(rows),
			LayoutOrder = next_order(),
		})
	end
	if manual ~= nil then
		children.Manual = React.createElement(WeaponCard, {
			name = unit_facts.MANUAL_WEAPON.name,
			slot = unit_facts.MANUAL_WEAPON.slot,
			icon = unit_facts.MANUAL_WEAPON.icon,
			range = unit_facts.figure(manual.range),
			notes = { "Manual fire" },
			text = unit_facts.MANUAL_WEAPON.text,
			rows = without_headline(unit_facts.manual_weapon_rows(manual)),
			LayoutOrder = next_order(),
		})
	end

	local links: { { label: string, names: { string }? } } = {
		{ label = "BUILT BY", names = def_catalog.built_by(def.name) },
		{ label = "BUILDS", names = if def.builder ~= nil then def.builder.options else nil },
		{ label = "UPGRADES", names = def.upgrades },
		{ label = "DRONE", names = if def.carrier ~= nil then { def.carrier.drone } else nil },
		{ label = "LAUNCHED BY", names = def_catalog.launched_by(def.name) },
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
		local names = link.names
		if names ~= nil and #names > 0 then
			children[`Links{index}`] = React.createElement(LinkRow, {
				label = link.label,
				names = names,
				unlocks = props.unlocks,
				on_open = props.on_open,
				LayoutOrder = next_order(),
			})
		end
	end

	return React.createElement("Frame", {
		[React.Tag] = "entry-body",
	}, children)
end

return table.freeze({
	EntryBody = EntryBody,
})
