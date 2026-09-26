--!strict
-- Units as they are, with nothing on them.

local skin_types = require(script.Parent.types)

type Skin = skin_types.Skin

local skin: Skin = {
	name = "default",
	display_name = "Default",
	description = "No skin.",
	developer_only = false,
	stats = nil,
	art = nil,
	paint = nil,
	donut = nil,
}

return table.freeze(skin)
