--!strict
local ReplicatedStorage = game:GetService "ReplicatedStorage"

local types = require(ReplicatedStorage.Shared.types)

local conversions = require(script.Parent.conversions)
local footing = require(script.Parent.footing)

local capsule = conversions.capsule

type EntityDef = types.EntityDef

-- The reclaimables: rocks and trees lying about the map, belonging to nobody, there to be reclaimed for the metal or
-- energy in them (see `types.EntityKind`). Their `metal_cost` and `energy_cost` are what reclaiming one pays out, and
-- their `buildpower_cost` is the buildpower that takes, BAR's `reclaimTime`, which when a feature does not give one
-- the engine makes (metal + energy) * 6 (FeatureDefHandler.cpp). Nothing harms one (`damage_immunity`), so it has no
-- health.
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
		category = "scenery",
		collider = capsule(width, 16, width),
		footing = footing.LAND,
		metal_cost = metal,
		energy_cost = 0,
		buildpower_cost = metal * 6,
		damage_immunity = "all",
		-- every rock is the same art, stretched to its own collider, so that the thousands on a map are all one mesh
		feature = { art = "rock", shadowless = true, ground = "any" },
		color = Color3.fromRGB(112, 106, 98),
	}
end

local defs: { [string]: EntityDef } = {
	-- bar: none (map features, features/rocks30.lua)
	small_rock = rock("small_rock", 4),
	rock = rock("rock", 12),
	large_rock = rock("large_rock", 24),

	-- bar: none (a map feature, features/enginetrees_override.lua)
	tree = {
		name = "tree",
		display_name = "Tree",
		subtitle = "Reclaim for energy",
		kind = "reclaimable",
		category = "scenery",
		-- 20 x 60 x 20 elmos
		collider = capsule(20, 60, 20),
		footing = footing.LAND,
		metal_cost = 0,
		energy_cost = 250,
		buildpower_cost = 1500,
		damage_immunity = "all",
		feature = { art = "tree", ground = "soil" },
		color = Color3.fromRGB(70, 104, 52),
	},

	-- a fern or a clump of mushrooms, as BAR's maps strew them, which hold 50 energy
	-- bar: none (a map feature)
	shrub = {
		name = "shrub",
		display_name = "Shrub",
		subtitle = "Reclaim for energy",
		kind = "reclaimable",
		category = "scenery",
		collider = capsule(24, 16, 24),
		footing = footing.LAND,
		metal_cost = 0,
		energy_cost = 50,
		buildpower_cost = 300,
		damage_immunity = "all",
		feature = { art = "shrub", shadowless = true, ground = "any" },
		color = Color3.fromRGB(88, 120, 56),
	},
}

return table.freeze(defs)
