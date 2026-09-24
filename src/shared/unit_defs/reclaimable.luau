local ReplicatedStorage = game:GetService "ReplicatedStorage"

local types = require(ReplicatedStorage.Shared.types)

local conversions = require(script.Parent.conversions)

local capsule = conversions.capsule

type EntityDef = types.EntityDef

-- The reclaimables: rocks and trees lying about the map, belonging to nobody, there to be reclaimed for the metal or
-- energy in them (see `types.EntityKind`). Their `metal_cost` and `energy_cost` are what reclaiming one pays out, and
-- their `buildpower_cost` is the buildpower that takes, BAR's `reclaimTime`, which when a feature does not give one
-- the engine makes (metal + energy) * 6 (FeatureDefHandler.cpp). No weapon harms one, so its health is only there
-- because every def has one.
--
-- On a BAR map every one holds what that feature holds in BAR, which the map says (`Preset.reclaimables`), and these are
-- only what it is drawn as: a rock for anything with metal in it, a tree for energy, and a shrub for a little energy,
-- like BAR's ferns and mushrooms. Laid out from the seed, they hold what they say here.
--
-- The rocks are three of BAR's features/rocks30.lua, whose rock number i holds 9 + i metal on a footprint of
-- floor(i / 8) + 1 squares of 16 elmos, 16 elmos high. The tree is features/enginetrees_override.lua's.

local function rock(name: string, number: number): EntityDef
	local metal = 9 + number
	local width = (number // 8 + 1) * 16
	return {
		name = name,
		display_name = "Rock",
		subtitle = "Reclaim for metal",
		kind = "reclaimable",
		collider = capsule(width, 16, width),
		metal_cost = metal,
		energy_cost = 0,
		buildpower_cost = metal * 6,
		health = 1,
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
		color = Color3.fromRGB(112, 106, 98),
	}
end

local defs: { [string]: EntityDef } = {
	small_rock = rock("small_rock", 4),
	rock = rock("rock", 12),
	large_rock = rock("large_rock", 24),

	tree = {
		name = "tree",
		display_name = "Tree",
		subtitle = "Reclaim for energy",
		kind = "reclaimable",
		-- 20 x 60 x 20 elmos
		collider = capsule(20, 60, 20),
		metal_cost = 0,
		energy_cost = 250,
		buildpower_cost = 1500,
		health = 1,
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
		color = Color3.fromRGB(70, 104, 52),
	},

	-- a fern or a clump of mushrooms, as BAR's maps strew them, which hold 50 energy
	shrub = {
		name = "shrub",
		display_name = "Shrub",
		subtitle = "Reclaim for energy",
		kind = "reclaimable",
		collider = capsule(24, 16, 24),
		metal_cost = 0,
		energy_cost = 50,
		buildpower_cost = 300,
		health = 1,
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
		color = Color3.fromRGB(88, 120, 56),
	},
}

return table.freeze(defs)
