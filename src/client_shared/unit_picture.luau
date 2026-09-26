--!strict
-- A still or slowly turning picture of a def's own art (a ModelViewport): the build menu's options and a factory's
-- queue, the tutorial's cards and an unlock's card in a match, and the encyclopedia's cards in the lobby. Given a
-- `team`, its team parts are in that side's colours. A `locked` one is drained to grey.
--
-- A "card" picture looks from ahead and to the right, a little from above, framed close round the model's box; a
-- "field" one looks down on it from above and ahead, as the camera sees it on the field, framed round its sphere.
--
-- A def with no art, or none that could be built, shows a flat icon for what it does instead (its first weapon's, a
-- builder's repair icon, or the guard icon for what only stands in the way), and `fallback` as text while that icon is
-- missing too.

local ReplicatedStorage = game:GetService "ReplicatedStorage"

local React = require(ReplicatedStorage.Packages.react)

local unit_defs = require(ReplicatedStorage.Shared.unit_defs)
local unit_facts = require(ReplicatedStorage.Shared.unit_facts)

local art_icon = require(ReplicatedStorage.ClientShared.art_icon)
local model_viewport = require(ReplicatedStorage.ClientShared.model_viewport)
local palette = require(ReplicatedStorage.ClientShared.palette)

local ArtIcon = art_icon.ArtIcon
local ModelViewport = model_viewport.ModelViewport

type Original = model_viewport.Original
type View = model_viewport.View

export type Framing = "card" | "field"

local CARD_YAW = math.rad(35)
local CARD_PITCH = math.rad(28)
local VIEWS: { [Framing]: View } = {
	card = {
		direction = Vector3.new(
			math.sin(CARD_YAW) * math.cos(CARD_PITCH),
			math.sin(CARD_PITCH),
			math.cos(CARD_YAW) * math.cos(CARD_PITCH)
		),
		fit = 0.92,
	},
	field = { direction = Vector3.new(0.35, 1, 0.9).Unit, fit = 1, round = true },
}
-- A locked picture: its colours drained to grey and darkened by this much.
local LOCKED_SHADE = 0.55

-- The icon for what a def does.
local function icon_of(def_name: string): string
	local def = unit_defs.get(def_name)
	local weapons = def.weapons
	if weapons ~= nil and #weapons > 0 then
		local _name, _slot, icon = unit_facts.weapon_kind(weapons[1])
		return icon
	elseif def.builder ~= nil then
		return "icon_repair"
	end
	return "icon_guard"
end

local function UnitPicture(
	props: {
		def_name: string,
		framing: Framing,
		team: Color3?,
		locked: boolean?,
		spin: number?,
		foot: number?,
		fallback: string?,
		-- what the picture is multiplied by, to darken it
		tint: Color3?,
		tag: string,
		LayoutOrder: number?,
		-- placed by its middle
		Position: any?,
	}
)
	local locked = props.locked == true
	local function paint(parts: { [BasePart]: Original })
		for part, original in parts do
			part.Color = if locked then palette.greyed(original.color, LOCKED_SHADE) else original.color
			part.Material = if locked then Enum.Material.SmoothPlastic else original.material
		end
	end

	return React.createElement(ModelViewport, {
		name = props.def_name,
		team = props.team,
		view = VIEWS[props.framing],
		spin = props.spin,
		foot = props.foot,
		paint = paint,
		paint_key = tostring(locked),
		fallback = React.createElement("Frame", {
			[React.Tag] = `{props.tag} icon-fallback`,
			LayoutOrder = props.LayoutOrder,
			AnchorPoint = if props.Position ~= nil then Vector2.new(0.5, 0.5) else nil,
			Position = props.Position,
		}, {
			Icon = React.createElement(ArtIcon, {
				name = icon_of(props.def_name),
				view = "front",
				flat = true,
				muted = locked,
				fallback = props.fallback,
				tag = "picture-icon",
			}),
		}),
		tag = if locked then `{props.tag} locked-icon` else props.tag,
		LayoutOrder = props.LayoutOrder,
		AnchorPoint = if props.Position ~= nil then Vector2.new(0.5, 0.5) else nil,
		Position = props.Position,
		ImageColor3 = props.tint,
	})
end

return table.freeze({
	UnitPicture = UnitPicture,
})
