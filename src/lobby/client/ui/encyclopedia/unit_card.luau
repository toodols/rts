--!strict
-- The encyclopedia's grid: a heading for each section of the catalog (Shared.def_catalog) and a card for each def in
-- it, flowing across as many to a row as fit.

local ReplicatedStorage = game:GetService "ReplicatedStorage"

local React = require(ReplicatedStorage.Packages.react)

local campaign = require(ReplicatedStorage.Shared.campaign)
local def_catalog = require(ReplicatedStorage.Shared.def_catalog)
local rarity = require(ReplicatedStorage.Shared.rarity)
local unit_defs = require(ReplicatedStorage.Shared.unit_defs)
local unit_facts = require(ReplicatedStorage.Shared.unit_facts)

local palette = require(ReplicatedStorage.ClientShared.palette)
local unit_picture = require(ReplicatedStorage.ClientShared.unit_picture)

local entry_link = require(script.Parent.entry_link)

type Section = def_catalog.Section

local UnitPicture = unit_picture.UnitPicture

-- An element's properties: strict mode cannot type a table of them that mixes tags, properties and handlers.
type Props = { [any]: any }

-- Rich text colours for a card's stat lines: the theme's metal, energy and fight colours.
local METAL_HEX = `#{palette.metal:ToHex()}`
local ENERGY_HEX = `#{palette.energy:ToHex()}`
local FIGHT_HEX = `#{palette.fight:ToHex()}`

-- One unit in the grid, as an unlock's card is on the end screen: framed and shaded in its tier's colour (Shared.rarity,
-- from what it costs), its picture large, its name, what it is and its tier, and what it costs, how tough it is and
-- the damage it does a second. A locked one is dimmed, its picture greyed with the lock stamped over it, and in place
-- of its figures the mission that unlocks it; the one open in the detail panel is lit.
local function UnitCard(props: {
	name: string,
	selected: boolean,
	locked: boolean,
	on_select: (name: string) -> (),
	card_ref: (name: string, instance: Instance?) -> (),
	LayoutOrder: number,
})
	local def = unit_defs.defs[props.name]
	local tier = rarity.tier_of(props.name)
	local dps = unit_facts.damage_dps(def)
	local tag = `unit-card {tier.tag}`
	if props.selected then
		tag ..= " selected"
	end
	if props.locked then
		tag ..= " locked"
	end
	local costs = `<font color="{METAL_HEX}">{unit_facts.figure(def.metal_cost)}</font> M   `
		.. `<font color="{ENERGY_HEX}">{unit_facts.figure(def.energy_cost)}</font> E`
	local fight = (if def.health ~= nil then `{unit_facts.figure(def.health)} HP   ` else "")
		.. (if dps ~= nil then `<font color="{FIGHT_HEX}">{unit_facts.figure(dps)}</font> DPS` else "— DPS")
	if props.locked then
		costs = def_catalog.unlocked_by(props.name) or ""
		fight = ""
	end
	return React.createElement(
		"TextButton",
		{
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
		} :: Props,
		{
			Tier = React.createElement("TextLabel", {
				[React.Tag] = `unit-card-tier {tier.tag}`,
				LayoutOrder = 1,
				Text = tier.label,
			}),
			Art = React.createElement("Frame", {
				[React.Tag] = "unit-card-art",
				LayoutOrder = 2,
			}, {
				Picture = React.createElement(UnitPicture, {
					framing = "card",
					team = entry_link.TEAM,
					def_name = props.name,
					tag = "unit-card-picture",
					fallback = string.sub(def.display_name, 1, 2),
					locked = props.locked,
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
		}
	)
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

return table.freeze({
	SectionView = SectionView,
})
