--!strict
-- One of the HUD's own 3D pictures (Shared.ui_art: keys, a mouse, a cursor, the flat order and weapon icons), a
-- ModelViewport seen from above or from the front.
--
-- Parts of it can be lit by their art group (`lit`: a key held down, a mouse button clicked), pushed down by their
-- group (`pressed`, by `press_depth` studs: a key held down sinks the way a real one does), the whole of it greyed
-- (`muted`: a tick not done yet) or made to glow (`glow`: a tick once it is), and it can be made to shake and flash red
-- (`shake`: bumped each time it should, when what was pressed does not work). Only the bright parts of a piece light or
-- glow: a key's dark glyph stays dark on its lit cap, so it can still be read.
-- A `flat` picture (the "vector" icons, icon_*) is unlit, so each part shows exactly its own colour.
-- While its art is missing it shows `fallback` as text instead.

local ReplicatedStorage = game:GetService "ReplicatedStorage"

local React = require(ReplicatedStorage.Packages.react)

local model_viewport = require(ReplicatedStorage.ClientShared.model_viewport)
local palette = require(ReplicatedStorage.ClientShared.palette)

local ModelViewport = model_viewport.ModelViewport

type Original = model_viewport.Original
type View = model_viewport.View

export type Facing = "above" | "front"

-- "above" looks at keys lying flat from ahead of them (+Z) and above, down 50 degrees; "front" looks straight at
-- something standing up and facing +Z.
local ABOVE_PITCH = math.rad(50)
local VIEWS: { [Facing]: View } = {
	above = { direction = Vector3.new(0, math.sin(ABOVE_PITCH), math.cos(ABOVE_PITCH)), fit = 0.9 },
	front = { direction = Vector3.new(0, 0, 1), fit = 0.9 },
}
-- A part at least this bright is a face that lights; anything darker is a glyph or a rim, and keeps its colour.
local BRIGHT = 0.3
-- A muted picture's greys, as bright as the colours they replace by this much.
local MUTED_SHADE = 0.9
-- How far a pressed group sinks, in studs of the model, unless the picture says: most of a keycap's height.
local PRESS_DEPTH = 0.35

-- A stable key for a set of lit groups.
local function set_key(set: { [string]: boolean }?): string
	if set == nil then
		return ""
	end
	local names = {}
	for name, on in set do
		if on then
			table.insert(names, name)
		end
	end
	table.sort(names)
	return table.concat(names, ",")
end

local function ArtIcon(props: {
	name: string,
	view: Facing?,
	lit: { [string]: boolean }?,
	lit_color: Color3?,
	pressed: { [string]: boolean }?,
	press_depth: number?,
	muted: boolean?,
	glow: boolean?,
	shake: number?,
	fallback: string?,
	flat: boolean?,
	tag: string,
	LayoutOrder: number?,
	children: any?,
})
	local facing: Facing = props.view or "above"
	local function paint(parts: { [BasePart]: Original })
		local lit = props.lit or {}
		local pressed = props.pressed or {}
		local depth = props.press_depth or PRESS_DEPTH
		for part, original in parts do
			local bright = palette.luminance(original.color) >= BRIGHT
			part.CFrame = if pressed[part.Name] == true
				then original.cframe - Vector3.new(0, depth, 0)
				else original.cframe
			if lit[part.Name] == true and bright then
				part.Color = props.lit_color or palette.accent
				part.Material = Enum.Material.Neon
			elseif props.muted == true then
				part.Color = palette.greyed(original.color, MUTED_SHADE)
				part.Material = original.material
			else
				part.Color = original.color
				part.Material = if props.glow == true and bright then Enum.Material.Neon else original.material
			end
		end
	end

	return React.createElement(ModelViewport, {
		name = props.name,
		view = VIEWS[facing],
		flat = props.flat,
		paint = paint,
		paint_key = `{set_key(props.lit)}|{set_key(props.pressed)}|{props.lit_color}|{props.press_depth}|{props.muted}|{props.glow}`,
		shake = props.shake,
		fallback = React.createElement("TextLabel", {
			[React.Tag] = `{props.tag} art-fallback`,
			LayoutOrder = props.LayoutOrder,
			Text = props.fallback or "",
		}, props.children),
		tag = props.tag,
		LayoutOrder = props.LayoutOrder,
		children = props.children,
	})
end

return table.freeze({
	ArtIcon = ArtIcon,
})
