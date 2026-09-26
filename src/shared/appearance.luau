--!strict
-- How an entity's model is painted for what it is: a blueprint, a wreck, or finished and in its team's colours.
-- The server paints the models it builds (instances.luau) and the clients paint the art they build themselves
-- (src/client/art.luau, and every picture and the lobby's scene through ClientShared.art_models), and all take it from
-- here so that they always agree: `team_tint` is the one way a team part is coloured.

local ReplicatedStorage = game:GetService "ReplicatedStorage"

local teams = require(ReplicatedStorage.Shared.teams)
local types = require(ReplicatedStorage.Shared.types)
local game_modes = require(ReplicatedStorage.Shared.game_modes)

local BLUEPRINT_TRANSPARENCY = 0
local BLUEPRINT_MATERIAL = Enum.Material.ForceField
local WRECK_COLOR = Color3.fromRGB(96, 88, 80)
local WRECK_TRANSPARENCY = 0.15
local WRECK_MATERIAL = Enum.Material.CorrodedMetal

-- No team's, like a rock's, and the scavengers'.
local NEUTRAL_COLOR = Color3.fromRGB(140, 140, 140)
local SCAVENGER_COLOR = Color3.fromRGB(160, 84, 214)
-- The players' teams', from team 1, a colour for every team the largest mode seats, each clear of the others, of the
-- neutral grey and of the scavengers' purple. Any team past them, like a mission's own, takes them round again.
local TEAM_PALETTE: { Color3 } = {
	Color3.fromRGB(86, 148, 224), -- blue
	Color3.fromRGB(214, 92, 84), -- red
	Color3.fromRGB(98, 180, 90), -- green
	Color3.fromRGB(226, 196, 74), -- yellow
	Color3.fromRGB(232, 138, 54), -- orange
	Color3.fromRGB(70, 196, 206), -- cyan
	Color3.fromRGB(226, 112, 176), -- pink
	Color3.fromRGB(228, 228, 228), -- white
	Color3.fromRGB(150, 100, 60), -- brown
	Color3.fromRGB(170, 214, 76), -- lime
}
assert(#TEAM_PALETTE >= game_modes.LARGEST_CAPACITY, "every team a mode seats needs a colour of its own")

local function team_color(team: types.TeamId): Color3
	if team == teams.SCAVENGER then
		return SCAVENGER_COLOR
	elseif teams.is_playable(team) == false then
		return NEUTRAL_COLOR
	end
	return TEAM_PALETTE[(team - 1) % #TEAM_PALETTE + 1]
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
