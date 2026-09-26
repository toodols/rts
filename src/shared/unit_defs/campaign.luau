--!strict
local ReplicatedStorage = game:GetService "ReplicatedStorage"

local types = require(ReplicatedStorage.Shared.types)

local footing = require(script.Parent.footing)

type EntityDef = types.EntityDef

-- What only the campaign's missions put down (see shared/campaign.luau and server/missions). Nothing builds these,
-- so none is ever locked or in anyone's build options.
local defs: { [string]: EntityDef } = {
	-- The rock that fills the tutorial's pass. It belongs to nobody (team 0) and is a building, and so a wall to
	-- everything that walks (server/obstacles.luau): nothing gets by while it stands. It cannot be
	-- reclaimed, and nothing hurts it but a commander's disintegrator, which destroys it in one shot. It leaves nothing
	-- behind. Not from BAR.
	--
	-- 44 studs across, 28 high and 36 through, as its art is: it is put down turned a quarter turn, so that it is 44
	-- across the pass and 36 along it.
	-- bar: none (the tutorial's own)
	tutorial_boulder = {
		name = "tutorial_boulder",
		display_name = "Boulder",
		subtitle = "Impassable rock",
		kind = "building",
		category = "campaign",
		collider = { shape = "box", width = 44, height = 28, length = 36 },
		metal_cost = 0,
		energy_cost = 0,
		buildpower_cost = 1,
		footing = footing.LAND,
		reclaim_while_standing = false,
		damage_immunity = "all_but_manual_weapon",
		color = Color3.fromRGB(118, 110, 100),
	},
}

return table.freeze(defs)
