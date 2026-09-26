--!strict
-- The HUD's palette for what Luau colours itself (order markers, rings, beams, glows, the unlock cards' effects, the
-- placement ghost, the start boxes, the disintegrator's sweep): the
-- very colours the stylesheets draw in, read from the theme's own tokens (theme.scss, compiled with the stylesheets
-- by build_stylesheets.bat from stylesheets/_theme.scss), so there is one place a colour is set.

local ReplicatedStorage = game:GetService "ReplicatedStorage"

local rarity = require(ReplicatedStorage.Shared.rarity)

type TierTag = rarity.TierTag

local theme: StyleSheet = require(ReplicatedStorage.ClientShared.theme_stylesheet) :: any

local function token(name: string): Color3
	local value = theme:GetAttribute(name)
	assert(typeof(value) == "Color3", `the theme has no colour {name}`)
	return value
end

local TIER_COLORS: { [TierTag]: Color3 } = table.freeze({
	common = token "TierCommon",
	uncommon = token "TierUncommon",
	rare = token "TierRare",
	epic = token "TierEpic",
	legendary = token "TierLegendary",
	mythic = token "TierMythic",
})

-- How bright `color` looks, from 0 to 1 (its luma).
local function luminance(color: Color3): number
	return 0.299 * color.R + 0.587 * color.G + 0.114 * color.B
end

-- `color` as a grey as bright as it looks, times `shade`.
local function greyed(color: Color3, shade: number): Color3
	local grey = math.clamp(luminance(color) * shade, 0, 1)
	return Color3.new(grey, grey, grey)
end

-- The colour a tier's cards are framed in.
local function tier_color(tag: TierTag): Color3
	return TIER_COLORS[tag]
end

return table.freeze({
	text = token "Text",
	metal = token "Metal",
	energy = token "Energy",
	buildpower = token "Buildpower",
	gain = token "Gain",
	danger = token "Danger",
	caution = token "Caution",
	accent = token "Accent",
	resurrect = token "Resurrect",
	fight = token "Fight",
	emp = token "Emp",
	disintegrator = token "Disintegrator",
	guard = token "Guard",
	tier_color = tier_color,
	luminance = luminance,
	greyed = greyed,
})
