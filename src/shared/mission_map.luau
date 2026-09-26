--!strict
-- The map a campaign mission is played on, as its mission sees it (shared/campaign.luau). The map's preset is the one
-- place its geometry is said: it names the places a mission refers to (map_types' `points`): PLAYER_START, where the
-- player's commander goes down, and ENEMY_START, where the mission's enemy is. A mission played on a map that names no
-- PLAYER_START, one of the usual maps, has its players choose their starts as in any game (`player_start`). What a
-- mission asks of the ground as it is built, where the player's ground ends in a brink, is measured here from those
-- same places, on both sides alike.

local ReplicatedStorage = game:GetService "ReplicatedStorage"

local heightmap = require(ReplicatedStorage.Shared.heightmap)
local map_presets = require(ReplicatedStorage.Shared.map_presets)
local map_state = require(ReplicatedStorage.Shared.map_state)

type Preset = map_presets.Preset

local PLAYER_START = "player_start"
local ENEMY_START = "enemy_start"
-- Going from the player's start towards the enemy's, the brink is where the ground first falls more steeply than this
-- (rise over run, about 40 degrees), looked for every BRINK_STEP studs.
local BRINK_STEEPNESS = 0.85
local BRINK_STEP = 0.5

local function point_of(preset: Preset, name: string): Vector2
	local points = preset.points
	local found = if points ~= nil then points[name] else nil
	assert(found ~= nil, `map "{preset.name}" names no point "{name}"`)
	return found
end

-- The place `name` on the map `preset`, in world (x, z). A mission only names places its map has.
local function point(preset: string, name: string): Vector2
	return point_of(map_presets.get(preset), name)
end

-- Where the player's commander goes down on the map `preset`: its PLAYER_START, or nil for a map that names none, whose
-- players choose their starts.
local function player_start(preset: string): Vector2?
	local points = map_presets.get(preset).points
	return if points ~= nil then points[PLAYER_START] else nil
end

-- The place `name` on the map this side has built.
local function here(name: string): Vector2
	return point_of(map_state.preset(), name)
end

-- The x of the brink of the player's ground at `z`, on the map being played as it is built: going east from the
-- player's start towards the enemy's, where the ground first starts to fall away steeply, which is as far east as
-- anything on the high ground can stand there. The enemy's start's x where it never does.
local function brink_x(z: number): number
	local from = here(PLAYER_START)
	local to = here(ENEMY_START)
	local x = from.X
	while x < to.X do
		if heightmap.height_at(x, z) - heightmap.height_at(x + BRINK_STEP, z) > BRINK_STEEPNESS * BRINK_STEP then
			return x
		end
		x += BRINK_STEP
	end
	return to.X
end

-- Whether `x` at `z` is on the player's high ground, west of the brink (`brink_x`).
local function above_brink(x: number, z: number): boolean
	return x < brink_x(z)
end

return table.freeze({
	PLAYER_START = PLAYER_START,
	ENEMY_START = ENEMY_START,
	point = point,
	player_start = player_start,
	here = here,
	brink_x = brink_x,
	above_brink = above_brink,
})
