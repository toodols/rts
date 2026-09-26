--!strict
-- What a skin is (shared/skins): what it does to the numbers of what wears it, how it repaints it, and the pool donut
-- one may put on it. Only `stats` touches the sim; the rest is only drawn.

local ReplicatedStorage = game:GetService "ReplicatedStorage"

local types = require(ReplicatedStorage.Shared.types)

type EntityKind = types.EntityKind

-- What a skin does to the numbers of whatever wears it, each as a multiplier; one left out is 1. A skin with none is
-- only a look. `range` stretches every weapon's reach, and a lobbed shell is fired faster to match, so it lands there.
export type SkinStats = {
	health: number?,
	damage: number?,
	range: number?,
}

-- How a skin repaints the art of what wears it: every piece that does not glow is `color` in `material`. With
-- `keep_team`, the team-coloured pieces keep their team colour, so whose it is still reads.
export type SkinPaint = {
	color: Color3,
	material: Enum.Material,
	reflectance: number?,
	keep_team: boolean?,
}

-- One kind of pool float (DonutSettings.variants): the art it is drawn in (shared/art), lying flat about its own middle,
-- the radius of its hole in that art's units, and how often it turns up against the others.
export type DonutVariant = {
	art: string,
	hole: number,
	weight: number,
}

-- A pool donut, an inflatable swim ring worn round the waist (client/donuts.luau); an aircraft wears it round its
-- fuselage, its hole facing the nose, and a ship hangs a row of small ones down each side of its hull instead. Which
-- of `variants` a unit wears is its own, from its entity id, and the same for every player. It pops when what wears it
-- is hit, and on an aircraft it shakes above `shake_speed` (a fraction of its top speed) and flies off after
-- `fly_off_seconds` of that. On something that has been under the water, deeper than `submerge_depth` studs, for
-- `submerge_seconds`, it comes off and floats up to lie on the surface for `float_seconds`. Once nothing has knocked it
-- off for `regen_seconds`, and what wears it is out of the water, a new one inflates. It is only a look: none of it
-- touches the sim.
export type DonutSettings = {
	-- the kinds of entity that wear one
	kinds: { EntityKind },
	regen_seconds: number,
	shake_speed: number,
	fly_off_seconds: number,
	submerge_depth: number,
	submerge_seconds: number,
	float_seconds: number,
	variants: { DonutVariant },
	-- how wide its hole is against the radius of what wears it (its collider), so it is as big as the unit is
	hug: number,
	-- how far up the body it is worn, from the bottom of the body (0) to its top (1): its waist
	waist: number,
	-- on an aircraft: how wide its hole is against the fuselage's half thickness, and how far along the fuselage it is
	-- worn, from its tail (0) to its nose (1)
	fuselage_hug: number,
	nose: number,
	-- on a ship: how wide each one's hole is against the hull's width, how far up the body they hang (as `waist`) and
	-- then how many of their own widths lower than that (though never with their middles under its bottom, the
	-- waterline), how far apart their middles are against how wide each is, and how much of the hull's length is room
	-- for more of them
	side_hole: number,
	side_height: number,
	side_drop: number,
	side_spacing: number,
	side_span: number,
}

-- Another look for the same units (shared/skins). A skin may give a def other art altogether (`art`, def name to the
-- name of the art to draw instead), repaint it (`paint`), put a pool donut on it (`donut`), and, for a developer's
-- skin only, change its numbers (`stats`).
export type Skin = {
	name: string,
	display_name: string,
	description: string,
	-- only a developer may put it on, which any skin with `stats` has to be
	developer_only: boolean,
	stats: SkinStats?,
	art: { [string]: string }?,
	paint: SkinPaint?,
	donut: DonutSettings?,
}

return table.freeze({})
