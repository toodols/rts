--!strict
-- The grounds more than one of the generated maps is made of (see init.luau).

local ReplicatedStorage = game:GetService "ReplicatedStorage"

local map_types = require(ReplicatedStorage.Shared.map_types)

type Theme = map_types.Theme

local DEFAULT_WATER = Color3.fromRGB(38, 76, 108)

-- Green hills with rocky faces, as the highlands always were, but with grass on them now.
local TEMPERATE: Theme = {
	ground = Enum.Material.Grass,
	ground_patches = Enum.Material.LeafyGrass,
	slope = Enum.Material.Ground,
	cliff = Enum.Material.Rock,
	shore = Enum.Material.Sand,
	seabed = Enum.Material.Sand,
	high_ground = nil,
	high_from = nil,
	colors = {
		[Enum.Material.Grass] = Color3.fromRGB(96, 124, 64),
		[Enum.Material.LeafyGrass] = Color3.fromRGB(82, 110, 58),
		[Enum.Material.Ground] = Color3.fromRGB(110, 94, 70),
		[Enum.Material.Rock] = Color3.fromRGB(104, 100, 94),
	},
	water_color = DEFAULT_WATER,
	paint = nil,
}

-- Beaches and palms: pale sand, bright grass, basalt where it is steep.
local TROPICAL: Theme = {
	ground = Enum.Material.Grass,
	ground_patches = Enum.Material.LeafyGrass,
	slope = Enum.Material.Ground,
	cliff = Enum.Material.Basalt,
	shore = Enum.Material.Sand,
	seabed = Enum.Material.Sand,
	high_ground = nil,
	high_from = nil,
	colors = {
		[Enum.Material.Grass] = Color3.fromRGB(104, 142, 62),
		[Enum.Material.LeafyGrass] = Color3.fromRGB(78, 122, 52),
		[Enum.Material.Sand] = Color3.fromRGB(214, 196, 150),
		[Enum.Material.Basalt] = Color3.fromRGB(62, 58, 58),
	},
	water_color = Color3.fromRGB(34, 96, 118),
	paint = nil,
}

return table.freeze({
	DEFAULT_WATER = DEFAULT_WATER,
	TEMPERATE = TEMPERATE,
	TROPICAL = TROPICAL,
})
