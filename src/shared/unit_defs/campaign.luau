local ReplicatedStorage = game:GetService "ReplicatedStorage"

local types = require(ReplicatedStorage.Shared.types)

type EntityDef = types.EntityDef

-- What only the campaign's missions put down (see shared/campaign.luau and server/missions.luau). Nothing builds these,
-- so none is ever locked or in anyone's build options.
local defs: { [string]: EntityDef } = {
	-- The rock that fills the tutorial's pass. It belongs to nobody (team 0) and stands like a building, and the ground
	-- under it is a wall to everything that walks (server/obstacles.luau), so nothing gets by while it stands. It cannot
	-- be reclaimed, and nothing hurts it but a commander's disintegrator, which destroys it in one shot (combat's
	-- DGUN_ONLY). It leaves nothing behind. Not from BAR.
	--
	-- 44 studs across, 28 high and 36 through, as its art is: it is put down turned a quarter turn, so that it is 44
	-- across the pass and 36 along it.
	tutorial_boulder = {
		name = "tutorial_boulder",
		display_name = "Boulder",
		subtitle = "Impassable rock",
		kind = "building",
		collider = { shape = "box", width = 44, height = 28, length = 36 },
		metal_cost = 0,
		energy_cost = 0,
		buildpower_cost = 1,
		health = 30000,
		buildpower = nil,
		acceleration = nil,
		max_speed = nil,
		reclaiming = false,
		repairing = false,
		resurrecting = false,
		assisting = false,
		max_water_depth = 0,
		build_options = nil,
		weapons = nil,
		reclaimable = false,
		color = Color3.fromRGB(118, 110, 100),
	},
}

return table.freeze(defs)
