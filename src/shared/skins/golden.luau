--!strict
-- For developers only: everything cast in gold, and tougher, longer-ranged and harder-hitting than it should be. It is
-- the one skin that changes the game, so no player can pick it (`skins.may_wear`); only the `skin` command puts it on.

local skin_types = require(script.Parent.types)

type Skin = skin_types.Skin

local skin: Skin = {
	name = "golden",
	display_name = "Golden",
	description = "Solid gold. 2x health, 1.5x range, 1.5x damage.",
	developer_only = true,
	stats = {
		health = 2,
		range = 1.5,
		damage = 1.5,
	},
	art = nil,
	paint = {
		color = Color3.fromRGB(255, 196, 56),
		material = Enum.Material.Metal,
		reflectance = 0.3,
		keep_team = true,
	},
	donut = nil,
}

return table.freeze(skin)
