-- The reclaimables a map starts with: groves of trees on its grass and fields of rocks on its stony ground, there for
-- anyone to reclaim, as BAR's maps come strewn with trees and metal rocks (see unit_defs/reclaimable.luau).
--
-- BAR's maps say where every one of their features is, but the pages the maps here were brought over from do not, so
-- every map has its reclaimables laid out from the seed. Like the geothermal vents, each one has a twin on the opposite
-- side of the middle of the map, so that neither side of a two-team map has more to reclaim than the other. They are
-- kept off the starts, the metal spots and the vents, and out of the water, and only put where a builder can reach.
--
-- Unlike the spots, they are entities, which the server alone lays out and the clients are sent like anything else.

local ReplicatedStorage = game:GetService "ReplicatedStorage"

local config = require(ReplicatedStorage.Shared.config)
local heightmap = require(ReplicatedStorage.Shared.heightmap)
local unit_defs = require(ReplicatedStorage.Shared.unit_defs)
local map_presets = require(ReplicatedStorage.Shared.map_presets)
local ground_paint = require(ReplicatedStorage.Shared.ground_paint)
local passability = require(ReplicatedStorage.Shared.passability)
local starts = require(ReplicatedStorage.Shared.starts)
local metal_spots = require(ReplicatedStorage.Shared.metal_spots)
local geo_spots = require(ReplicatedStorage.Shared.geo_spots)

local state = require(script.Parent.state)

-- On a map of the usual size, 192 cells a side, this many groves and rock fields, and loose rocks besides, each with
-- its twin. A bigger map has more, in proportion to its area, up to MAX_SCALE times as many.
local USUAL_AREA = (192 * config.CELL_STUDS) ^ 2
local MAX_SCALE = 3
local GROVES = 6
local TREES_PER_GROVE = { 5, 10 }
local GROVE_RADIUS = 18
local ROCK_FIELDS = 6
local ROCKS_PER_FIELD = { 3, 7 }
local ROCK_FIELD_RADIUS = 14
local LOOSE_ROCKS = 12
-- Which rocks a field is made of, the small ones most often.
local ROCK_MIX = { "small_rock", "small_rock", "small_rock", "rock", "rock", "large_rock" }

-- Kept this far from the map edge, from every start, from every metal spot and vent, and from each other.
local EDGE_MARGIN = 12
local START_CLEARANCE = 40
local SPOT_CLEARANCE = 7
-- and this much apart, edge to edge
local SPACING = 1
-- Tries for every one placed, before giving up on it.
local ATTEMPTS_EACH = 12

-- Ground a tree grows on, and ground a rock lies on.
local TREE_GROUND: { [Enum.Material]: boolean } = {
	[Enum.Material.Grass] = true,
	[Enum.Material.LeafyGrass] = true,
	[Enum.Material.Ground] = true,
	[Enum.Material.Mud] = true,
}
local ROCK_GROUND: { [Enum.Material]: boolean } = {
	[Enum.Material.Rock] = true,
	[Enum.Material.Slate] = true,
	[Enum.Material.Basalt] = true,
	[Enum.Material.Sandstone] = true,
	[Enum.Material.Limestone] = true,
	[Enum.Material.Ground] = true,
	[Enum.Material.Sand] = true,
	[Enum.Material.Salt] = true,
	[Enum.Material.Snow] = true,
	[Enum.Material.CrackedLava] = true,
	[Enum.Material.Grass] = true,
	[Enum.Material.LeafyGrass] = true,
}
-- The steepest ground a bot can climb, so that there is always something that can get to it to reclaim it.
local MAX_STEEPNESS = passability.steepness_limit(passability.max_slope "BOT2" :: number)
-- Decorrelates the layout from the terrain noise and the spots, which are seeded with the same number.
local SEED_OFFSET = 15485863

type Placed = { x: number, z: number, radius: number }

-- Whether something of `def_name` can lie at (x, z): on the right ground, dry, not too steep, and clear of everything
-- it has to keep off.
local function fits(def_name: string, x: number, z: number, paint: ground_paint.Painter, placed: { Placed }): boolean
	local half_x, half_z = heightmap.half_extents()
	if math.abs(x) > half_x - EDGE_MARGIN or math.abs(z) > half_z - EDGE_MARGIN then
		return false
	end
	local height = heightmap.height_at(x, z)
	if height < config.WATER_LEVEL + 0.5 then
		return false
	end
	local gx, gz = heightmap.world_to_grid(x, z)
	local steepness = passability.cell_steepness(math.floor(gx), math.floor(gz))
	if steepness > MAX_STEEPNESS then
		return false
	end
	local ground = paint(x, z, height, steepness)
	local allowed = if def_name == "tree" then TREE_GROUND else ROCK_GROUND
	if allowed[ground] ~= true then
		return false
	end

	local here = Vector2.new(x, z)
	local radius = unit_defs.collider_radius(unit_defs.get(def_name))
	for slot = 1, config.START_SLOTS do
		if (here - starts.center(slot)).Magnitude < START_CLEARANCE then
			return false
		end
	end
	for _, spot in metal_spots.all() do
		if (here - Vector2.new(spot.center.X, spot.center.Z)).Magnitude < SPOT_CLEARANCE then
			return false
		end
	end
	for _, spot in geo_spots.all() do
		if (here - Vector2.new(spot.center.X, spot.center.Z)).Magnitude < SPOT_CLEARANCE then
			return false
		end
	end
	for _, other in placed do
		if (here - Vector2.new(other.x, other.z)).Magnitude < radius + other.radius + SPACING then
			return false
		end
	end
	return true
end

local function put(def_name: string, x: number, z: number, facing: number)
	local def = unit_defs.get(def_name)
	local position = Vector3.new(x, unit_defs.surface_height(def, x, z) + unit_defs.collider_height(def) / 2, z)
	state.create_reclaimable(def_name, position, facing)
end

-- Lays out the reclaimables of the map as it is now. Must be called once the map is built, on an empty world.
local function scatter()
	local preset = map_presets.get(heightmap.get_preset())
	local seed = heightmap.get_seed()
	local paint = ground_paint.make_painter(preset.theme, seed)
	local random = Random.new(seed + SEED_OFFSET)
	local half_x, half_z = heightmap.half_extents()
	local scale = math.min(MAX_SCALE, (half_x * 2) * (half_z * 2) / USUAL_AREA)
	local placed: { Placed } = {}

	-- One of `def_name` somewhere within `radius` of (cx, cz), and its twin across the middle, if there is room for
	-- both.
	local function place_pair(def_name: string, cx: number, cz: number, radius: number): boolean
		for _ = 1, ATTEMPTS_EACH do
			local angle = random:NextNumber(0, math.pi * 2)
			local distance = radius * math.sqrt(random:NextNumber())
			local x = cx + math.cos(angle) * distance
			local z = cz + math.sin(angle) * distance
			-- one right in the middle would be its own twin
			local size = unit_defs.collider_radius(unit_defs.get(def_name))
			if x * x + z * z < (size + SPACING) ^ 2 then
				continue
			end
			if fits(def_name, x, z, paint, placed) == false or fits(def_name, -x, -z, paint, placed) == false then
				continue
			end
			local facing = random:NextNumber(0, math.pi * 2)
			put(def_name, x, z, facing)
			put(def_name, -x, -z, facing + math.pi)
			table.insert(placed, { x = x, z = z, radius = size })
			table.insert(placed, { x = -x, z = -z, radius = size })
			return true
		end
		return false
	end

	local function clusters(count: number, radius: number, per: { number }, pick: () -> string)
		for _ = 1, math.round(count * scale) do
			local cx = random:NextNumber(-half_x, half_x)
			local cz = random:NextNumber(-half_z, half_z)
			for _ = 1, random:NextInteger(per[1], per[2]) do
				place_pair(pick(), cx, cz, radius)
			end
		end
	end

	clusters(GROVES, GROVE_RADIUS, TREES_PER_GROVE, function()
		return "tree"
	end)
	clusters(ROCK_FIELDS, ROCK_FIELD_RADIUS, ROCKS_PER_FIELD, function()
		return ROCK_MIX[random:NextInteger(1, #ROCK_MIX)]
	end)
	for _ = 1, math.round(LOOSE_ROCKS * scale) do
		place_pair(ROCK_MIX[random:NextInteger(1, #ROCK_MIX)], 0, 0, math.max(half_x, half_z))
	end
end

-- Takes every reclaimable off the map, for a test that wants the world to hold only what it makes.
local function clear()
	state.flush()
	for _, entity in state.all() do
		if entity.kind == "reclaimable" then
			state.mark_dead(entity)
		end
	end
end

return table.freeze({
	scatter = scatter,
	clear = clear,
})
