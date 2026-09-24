-- Units as they are, with nothing on them.

local ReplicatedStorage = game:GetService "ReplicatedStorage"

local types = require(ReplicatedStorage.Shared.types)

type Skin = types.Skin

local skin: Skin = {
	name = "default",
	display_name = "Default",
	description = "No skin.",
	developer_only = false,
	stats = nil,
	art = nil,
	paint = nil,
	attachments = {},
}

return table.freeze(skin)
