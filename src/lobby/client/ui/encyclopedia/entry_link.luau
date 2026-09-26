--!strict
-- A link to an encyclopedia entry, from another entry or another screen: a small tile of its picture, edged in its
-- tier's colour, with its name under it, which opens it.

local ReplicatedStorage = game:GetService "ReplicatedStorage"

local React = require(ReplicatedStorage.Packages.react)

local appearance = require(ReplicatedStorage.Shared.appearance)
local rarity = require(ReplicatedStorage.Shared.rarity)
local unit_defs = require(ReplicatedStorage.Shared.unit_defs)

local unit_picture = require(ReplicatedStorage.ClientShared.unit_picture)

local UnitPicture = unit_picture.UnitPicture

-- An element's properties: strict mode cannot type a table of them that mixes tags, properties and handlers.
type Props = { [any]: any }

-- Every picture in the encyclopedia is of one of the player's own, in their side's colours.
local TEAM = appearance.team_color(1)

-- A link to the entry for `name`. A `locked` one's picture is greyed, as its card is.
local function EntryLink(props: {
	name: string,
	locked: boolean?,
	on_open: (name: string) -> (),
	LayoutOrder: number,
})
	local def = unit_defs.defs[props.name]
	local display_name = if def ~= nil then def.display_name else props.name
	local tier = rarity.tier_of(props.name)
	return React.createElement(
		"TextButton",
		{
			[React.Tag] = if props.locked == true then `entry-link {tier.tag} locked` else `entry-link {tier.tag}`,
			LayoutOrder = props.LayoutOrder,
			Text = "",
			AutoButtonColor = false,
			[React.Event.Activated] = function()
				props.on_open(props.name)
			end,
		} :: Props,
		{
			Picture = React.createElement(UnitPicture, {
				framing = "card",
				team = TEAM,
				def_name = props.name,
				tag = "entry-link-picture",
				fallback = string.sub(display_name, 1, 2),
				locked = props.locked,
				LayoutOrder = 1,
			}),
			Name = React.createElement("TextLabel", {
				[React.Tag] = "entry-link-name",
				LayoutOrder = 2,
				Text = display_name,
			}),
		}
	)
end

return table.freeze({
	TEAM = TEAM,
	EntryLink = EntryLink,
})
