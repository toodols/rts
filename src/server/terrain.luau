-- Renders the shared heightmap into Roblox terrain.
--
-- A heightmap cell is CELL_STUDS wide, which is exactly one terrain voxel, so cells and voxels map
-- one to one. Each voxel column is filled solid below the surface and given a fractional occupancy
-- at the surface so the ground reads as a smooth slope rather than a staircase. That one-to-one
-- mapping is what lets deformation rewrite only the voxels whose cells actually changed (`rewrite`).
--
-- Over the low ground lies a flat water part at `ground_levels.WATER_LEVEL`. It only draws the sea: what the
-- sea means is worked out from the heightmap, where ground below that level is under water, and each
-- def says how deep it may stand in it.
--
-- What each column is made of comes from the map preset's theme, painted by what can cross it (see
-- shared/ground_paint.luau, which the lobby's pictures of the maps are painted with too).

local ReplicatedStorage = game:GetService "ReplicatedStorage"
local Workspace = game:GetService "Workspace"

local ground_levels = require(ReplicatedStorage.Shared.ground_levels)
local world_scale = require(ReplicatedStorage.Shared.world_scale)
local heightmap = require(ReplicatedStorage.Shared.heightmap)
local map_state = require(ReplicatedStorage.Shared.map_state)
local map_types = require(ReplicatedStorage.Shared.map_types)
local passability = require(ReplicatedStorage.Shared.passability)
local ground_paint = require(ReplicatedStorage.Shared.ground_paint)

type Theme = map_types.Theme
type Painter = ground_paint.Painter

local CELL_STUDS = world_scale.CELL_STUDS
-- Voxels are written in blocks rather than all at once to keep any single WriteVoxels call small.
local CHUNK_CELLS = 32
-- Below the deepest the basins, and the craters dug into them, can go, and a multiple of the voxel size.
local FLOOR_HEIGHT = ground_levels.TERRAIN_FLOOR_HEIGHT

-- Measured, not documented: with occupancy taken as the filled fraction of the voxel from its
-- bottom, Roblox draws the surface half a voxel (2 studs) above where the heightmap says it is
-- (check_surface read +1.99 on average, 1.79 to 2.17 across the map). Writing occupancies for a
-- surface that much lower puts the rendered ground back on the heightmap, which is what every unit
-- and building is stood on.
local SURFACE_BIAS = CELL_STUDS / 2

local WATER_HEIGHT = ground_levels.WATER_LEVEL
local WATER_THICKNESS = 4
-- Wide enough that its own edge falls outside the fog, which ends at 3.1 map half-widths.
local WATER_SPAN_FACTOR = 4
-- A Part cannot be larger than this on any axis.
local MAX_PART_STUDS = 2048
local WATER_TRANSPARENCY = 0.35

-- Built by `render` from the map's theme; every rewrite after that paints with the same one.
local painter: Painter? = nil

local function write_chunk(cell_x: number, cell_z: number, cells_x: number, cells_z: number)
	local low_x, low_z = heightmap.grid_to_world(cell_x, cell_z)
	local origin_x = low_x
	local origin_z = low_z

	-- tall enough to cover the whole terrain range with room to spare
	local _, highest = heightmap.height_bounds()
	local top = highest + CELL_STUDS * 2
	local voxels_y = math.ceil((top - FLOOR_HEIGHT) / CELL_STUDS)

	local region = Region3.new(
		Vector3.new(origin_x, FLOOR_HEIGHT, origin_z),
		Vector3.new(
			origin_x + cells_x * CELL_STUDS,
			FLOOR_HEIGHT + voxels_y * CELL_STUDS,
			origin_z + cells_z * CELL_STUDS
		)
	):ExpandToGrid(CELL_STUDS)

	-- the surface and material of each column, worked out once rather than for every voxel up it
	local paint = painter :: Painter
	local surfaces = table.create(cells_x)
	local column_materials = table.create(cells_x)
	for x = 1, cells_x do
		surfaces[x] = table.create(cells_z)
		column_materials[x] = table.create(cells_z)
		-- sample the terrain at the centre of this voxel column
		local world_x = origin_x + (x - 0.5) * CELL_STUDS
		for z = 1, cells_z do
			local world_z = origin_z + (z - 0.5) * CELL_STUDS
			local surface = heightmap.height_at(world_x, world_z)
			local steepness = passability.cell_steepness(cell_x + x - 1, cell_z + z - 1)
			surfaces[x][z] = surface
			column_materials[x][z] = paint(world_x, world_z, surface, steepness)
		end
	end

	local materials = {}
	local occupancies = {}

	for x = 1, cells_x do
		materials[x] = {}
		occupancies[x] = {}
		for y = 1, voxels_y do
			materials[x][y] = {}
			occupancies[x][y] = {}
			local voxel_bottom = FLOOR_HEIGHT + (y - 1) * CELL_STUDS
			for z = 1, cells_z do
				-- how much of this voxel is below the surface, 0 to 1
				local occupancy = math.clamp((surfaces[x][z] - SURFACE_BIAS - voxel_bottom) / CELL_STUDS, 0, 1)
				materials[x][y][z] = if occupancy <= 0 then Enum.Material.Air else column_materials[x][z]
				occupancies[x][y][z] = occupancy
			end
		end
	end

	Workspace.Terrain:WriteVoxels(region, CELL_STUDS, materials, occupancies)
end

-- The sea the map sits in: a flat block of water whose top is the sea level, everywhere, so the water is never terrain.
-- It is a few parts side by side where one cannot reach far enough, since a part is at most MAX_PART_STUDS across,
-- and rebuilt from scratch, so that re-rendering the map cannot leave any of the last one's behind. Raycasts pass
-- straight through it, so clicking past the shore still finds nothing rather than ordering a unit out to sea.
local function render_water(theme: Theme)
	local previous = Workspace:FindFirstChild "Water"
	if previous ~= nil then
		previous:Destroy()
	end
	local folder = Instance.new "Folder"
	folder.Name = "Water"

	local half_x, half_z = heightmap.half_extents()
	local span_x = half_x * 2 * WATER_SPAN_FACTOR
	local span_z = half_z * 2 * WATER_SPAN_FACTOR
	local tiles_x = math.ceil(span_x / MAX_PART_STUDS)
	local tiles_z = math.ceil(span_z / MAX_PART_STUDS)
	local tile_x = span_x / tiles_x
	local tile_z = span_z / tiles_z

	for ix = 1, tiles_x do
		for iz = 1, tiles_z do
			local water = Instance.new "Part"
			water.Name = "Water"
			water.Anchored = true
			water.Locked = true
			water.CanCollide = false
			water.CanQuery = false
			water.CanTouch = false
			water.CastShadow = false
			water.Size = Vector3.new(tile_x, WATER_THICKNESS, tile_z)
			-- hung below the surface height so that the face you see is exactly WATER_HEIGHT
			water.CFrame = CFrame.new(
				-span_x / 2 + (ix - 0.5) * tile_x,
				WATER_HEIGHT - WATER_THICKNESS / 2,
				-span_z / 2 + (iz - 0.5) * tile_z
			)
			water.Material = Enum.Material.Water
			water.Color = theme.water_color
			water.Transparency = WATER_TRANSPARENCY
			water.Reflectance = 0.15
			water.TopSurface = Enum.SurfaceType.Smooth
			water.BottomSurface = Enum.SurfaceType.Smooth
			water.Parent = folder
		end
	end
	folder.Parent = Workspace
end

-- What the simulation stands things on is `heightmap.height_at`; what the player sees is the mesh
-- Roblox builds out of the occupancies written above. They are meant to be the same surface, and a
-- unit is only three studs tall, so a disagreement of a stud or two is the difference between
-- standing on the ground and wading through it. Measure it rather than trust it.
local SURFACE_SAMPLES = 8
local SURFACE_TOLERANCE = 0.5
local PROBE_HEIGHT = 64

local function check_surface()
	local params = RaycastParams.new()
	params.FilterType = Enum.RaycastFilterType.Include
	params.FilterDescendantsInstances = { Workspace.Terrain }
	params.IgnoreWater = true

	local half_x, half_z = heightmap.half_extents()
	local total = 0
	local samples = 0
	local lowest = math.huge
	local highest = -math.huge

	-- an even spread over the interior of the map, skipping the edges where the mesh falls away
	for ix = 1, SURFACE_SAMPLES do
		for iz = 1, SURFACE_SAMPLES do
			local x = -half_x + (ix / (SURFACE_SAMPLES + 1)) * half_x * 2
			local z = -half_z + (iz / (SURFACE_SAMPLES + 1)) * half_z * 2
			local expected = heightmap.height_at(x, z)
			local from = Vector3.new(x, expected + PROBE_HEIGHT, z)
			local hit = Workspace:Raycast(from, Vector3.new(0, -PROBE_HEIGHT * 2, 0), params)
			if hit ~= nil then
				local delta = hit.Position.Y - expected
				total += delta
				samples += 1
				lowest = math.min(lowest, delta)
				highest = math.max(highest, delta)
			end
		end
	end

	if samples == 0 then
		warn "terrain surface check: nothing under the probes, so the terrain did not render"
		return
	end

	local mean = total / samples
	if math.abs(mean) <= SURFACE_TOLERANCE then
		return
	end
	warn(
		`terrain renders {string.format("%.2f", mean)} studs above the heightmap on average `
			.. `(from {string.format("%.2f", lowest)} to {string.format("%.2f", highest)}, {samples} samples). `
			.. "Everything the simulation places stands on the heightmap, so units look sunk by that much."
	)
end

-- How much of the map is under water, as a fraction, so a level that floods all of it or none of it is
-- easy to spot.
local function report_flooding()
	local wet = 0
	local samples = 0
	local cells_x, cells_z = heightmap.cells()
	for cz = 0, cells_z do
		for cx = 0, cells_x do
			local x, z = heightmap.grid_to_world(cx, cz)
			samples += 1
			if heightmap.water_depth(x, z) > 0 then
				wet += 1
			end
		end
	end
	print(`{string.format("%.0f", wet / samples * 100)}% of the map is under water`)
end

-- The theme's own colours for its materials. Only the ones it names are changed.
local function color_materials(theme: Theme)
	for material, color in theme.colors do
		Workspace.Terrain:SetMaterialColor(material, color)
	end
end

local function render()
	local theme = map_state.preset().theme
	painter = ground_paint.make_painter(theme, (map_state.get() :: map_state.MapState).seed)
	Workspace.Terrain:Clear()
	color_materials(theme)
	render_water(theme)
	report_flooding()
	local map_cells_x, map_cells_z = heightmap.cells()
	for cell_z = 0, map_cells_z - 1, CHUNK_CELLS do
		for cell_x = 0, map_cells_x - 1, CHUNK_CELLS do
			local cells_x = math.min(CHUNK_CELLS, map_cells_x - cell_x)
			local cells_z = math.min(CHUNK_CELLS, map_cells_z - cell_z)
			write_chunk(cell_x, cell_z, cells_x, cells_z)
		end
		-- yield between rows so a large map does not stall the first server frame
		task.wait()
	end

	check_surface()
end

-- Rewrites the voxels of the cells from (first_x, first_z) to (last_x, last_z), inclusive, after the ground
-- under them has been edited. Nothing else is touched.
local function rewrite(first_x: number, first_z: number, last_x: number, last_z: number)
	local from_x = math.max(0, first_x)
	local from_z = math.max(0, first_z)
	local map_cells_x, map_cells_z = heightmap.cells()
	local to_x = math.min(map_cells_x - 1, last_x)
	local to_z = math.min(map_cells_z - 1, last_z)
	for cell_z = from_z, to_z, CHUNK_CELLS do
		for cell_x = from_x, to_x, CHUNK_CELLS do
			write_chunk(
				cell_x,
				cell_z,
				math.min(CHUNK_CELLS, to_x - cell_x + 1),
				math.min(CHUNK_CELLS, to_z - cell_z + 1)
			)
		end
	end
end

return table.freeze({
	render = render,
	rewrite = rewrite,
})
