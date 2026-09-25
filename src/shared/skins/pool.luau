-- A pool party: every unit wears a pool float round its waist, an aircraft round its fuselage, and a ship hangs small
-- ones down its sides: a striped ring, an iced donut or a lifebuoy in its team's colour, or now and then a rubber
-- ducky. Only a look (client/donuts.luau draws it, and server/donuts.luau keeps what happens to it, so every player
-- sees the same): it pops when what wears it is shot, shakes on a fast plane and in the end flies off it, floats up
-- off something that stays deep under the water a while, and a new one inflates once nothing has knocked it off for a
-- while.

local ReplicatedStorage = game:GetService "ReplicatedStorage"

local types = require(ReplicatedStorage.Shared.types)

type Skin = types.Skin

local skin: Skin = {
	name = "pool",
	display_name = "Pool",
	description = "A pool donut on every unit.",
	developer_only = false,
	stats = nil,
	art = nil,
	paint = nil,
	attachments = {
		{
			kind = "donut",
			kinds = { "unit" },
			donut = {
				regen_seconds = 30,
				shake_speed = 0.75,
				fly_off_seconds = 3,
				-- its waist this far under the surface, give or take: past the knees of a commander wading out
				submerge_depth = 1.5,
				submerge_seconds = 2,
				float_seconds = 12,
				-- tools/model_pipeline/generators: each a ring 1 out, its tube 0.42 across either way
				-- (pool_float_common), so every one fits a unit alike
				variants = {
					{ art = "pool_donut", hole = 0.58, weight = 4 },
					{ art = "pool_donut_iced", hole = 0.58, weight = 3 },
					{ art = "pool_lifebuoy", hole = 0.58, weight = 2 },
					{ art = "rubber_ducky", hole = 0.58, weight = 1 },
				},
				hug = 0.6,
				waist = 0.3,
				-- snug round the fuselage at its waist, a quarter of the way on from its middle to its nose
				fuselage_hug = 1.15,
				nose = 0.625,
				-- lifebuoys along the rail, a couple to four a side
				side_hole = 0.16,
				side_height = 0.4,
				side_drop = 0.75,
				side_spacing = 1.3,
				side_span = 0.6,
			},
		},
	},
}

return table.freeze(skin)
