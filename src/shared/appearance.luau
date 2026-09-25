-- How an entity's model is painted for what it is: a blueprint, a wreck, or finished and in its team's colours.
-- The server paints the models it builds (instances.luau) and the client paints the art it builds itself
-- (src/client/art.luau), and both take it from here so that the two always agree.

local ReplicatedStorage = game:GetService "ReplicatedStorage"

local config = require(ReplicatedStorage.Shared.config)
local types = require(ReplicatedStorage.Shared.types)

local BLUEPRINT_TRANSPARENCY = 0
local BLUEPRINT_MATERIAL = Enum.Material.ForceField
local WRECK_COLOR = Color3.fromRGB(96, 88, 80)
local WRECK_TRANSPARENCY = 0.15
local WRECK_MATERIAL = Enum.Material.CorrodedMetal

local TEAM_COLORS: { [number]: Color3 } = {
	[0] = Color3.fromRGB(140, 140, 140),
	[1] = Color3.fromRGB(86, 148, 224),
	[2] = Color3.fromRGB(214, 92, 84),
	[config.SCAVENGER_TEAM] = Color3.fromRGB(160, 84, 214),
}

local function team_color(team: types.TeamId): Color3
	local color = TEAM_COLORS[team]
	if color == nil then
		return TEAM_COLORS[0]
	end
	return color
end

-- What a blueprint's every part is tinted: its team's colour, leaning a little toward the def's own.
local function blueprint_tint(def_color: Color3, team: Color3): Color3
	return team:Lerp(def_color, 0.35)
end

-- What a finished model's team parts are tinted: the def's own colour, leaning toward its team's.
local function team_tint(def_color: Color3, team: Color3): Color3
	return def_color:Lerp(team, 0.45)
end

return table.freeze({
	BLUEPRINT_TRANSPARENCY = BLUEPRINT_TRANSPARENCY,
	BLUEPRINT_MATERIAL = BLUEPRINT_MATERIAL,
	WRECK_COLOR = WRECK_COLOR,
	WRECK_TRANSPARENCY = WRECK_TRANSPARENCY,
	WRECK_MATERIAL = WRECK_MATERIAL,
	team_color = team_color,
	blueprint_tint = blueprint_tint,
	team_tint = team_tint,
})
