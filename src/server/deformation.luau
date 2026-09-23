-- Explosions press craters into the ground, softly: see `config.DEFORM_*` for how deep and how wide.
--
-- The heightmap is edited at once, so everything the simulation stands on agrees with it from then on, but
-- the voxels that draw it and the clients that keep their own copy of it are told once a tick, in one go, so
-- a barrage of shells is one rewrite and one message and not hundreds.
--
-- Every edit sent to a client is labelled with the map generation it was made to (see shared/map_state.luau), so
-- one that arrives after the map has been replaced is dropped rather than laid onto the new ground.
--
-- Buildings do not sink or float: the ground under their footprints is left as it is. Units and wrecks
-- that stand where the ground has moved are set back down on it.

local ReplicatedStorage = game:GetService "ReplicatedStorage"

local config = require(ReplicatedStorage.Shared.config)
local heightmap = require(ReplicatedStorage.Shared.heightmap)
local map_state = require(ReplicatedStorage.Shared.map_state)
local passability = require(ReplicatedStorage.Shared.passability)
local pathfinder = require(ReplicatedStorage.Shared.pathfinder)
local unit_defs = require(ReplicatedStorage.Shared.unit_defs)

local state = require(script.Parent.state)
local terrain = require(script.Parent.terrain)
local placement = require(script.Parent.placement)

local terrain_deformed: RemoteEvent = ReplicatedStorage.Shared.TerrainDeformed

-- The samples edited since the last flush, by sample index.
local pending: { [number]: boolean } = {}

-- Presses a crater into the ground where an explosion of `damage` and blast `radius` went off at `at`.
-- One that goes off well above the ground, like a shell bursting on an aircraft, leaves it alone.
local function crater(at: Vector3, radius: number, damage: number)
	local depth = config.DEFORM_MAX_DEPTH * (1 - math.exp(-damage / config.DEFORM_DAMAGE_SCALE))
	if depth < config.DEFORM_MIN_DEPTH or heightmap.in_bounds(at.X, at.Z) == false then
		return
	end
	local reach = math.max(radius, config.DEFORM_MIN_RADIUS)
	if at.Y - heightmap.height_at(at.X, at.Z) > reach then
		return
	end

	-- a sample within a cell of a building's footprint helps hold up the ground it stands on
	local footprints: { { center: Vector3, half: Vector2 } } = {}
	for _, other in state.all() do
		if other.alive and other.kind == "building" then
			table.insert(footprints, { center = other.position, half = placement.half_extents_for(other) })
		end
	end
	local function under_a_building(x: number, z: number): boolean
		for _, footprint in footprints do
			if
				math.abs(x - footprint.center.X) <= footprint.half.X + config.CELL_STUDS
				and math.abs(z - footprint.center.Z) <= footprint.half.Y + config.CELL_STUDS
			then
				return true
			end
		end
		return false
	end

	local changes = heightmap.deform(at.X, at.Z, reach, depth, under_a_building)
	for at_index = 1, #changes - 1, 2 do
		pending[changes[at_index]] = true
	end
end

-- Sets units and wrecks that stand in the box back down on the ground, wherever it now is.
local function reseat(min_x: number, min_z: number, max_x: number, max_z: number)
	for _, entity in state.all() do
		if entity.alive == false or entity.kind == "building" then
			continue
		end
		local def = unit_defs.get(entity.def_name)
		if def.air ~= nil then
			continue
		end
		local position = entity.position
		if position.X < min_x or position.X > max_x or position.Z < min_z or position.Z > max_z then
			continue
		end
		local height = unit_defs.surface_height(def, position.X, position.Z) + unit_defs.collider_height(def) / 2
		if math.abs(height - position.Y) > 1e-3 then
			entity.position = Vector3.new(position.X, height, position.Z)
		end
	end
end

-- Draws and tells everyone about the ground that has been edited since the last time.
local function flush()
	if next(pending) == nil then
		return
	end

	local first_x = math.huge
	local first_z = math.huge
	local last_x = -math.huge
	local last_z = -math.huge
	local changes = {}
	for index in pending do
		local cell_x = (index - 1) % heightmap.samples_across()
		local cell_z = (index - 1) // heightmap.samples_across()
		first_x = math.min(first_x, cell_x)
		first_z = math.min(first_z, cell_z)
		last_x = math.max(last_x, cell_x)
		last_z = math.max(last_z, cell_z)
		table.insert(changes, index)
		table.insert(changes, heightmap.sample(cell_x, cell_z))
	end
	table.clear(pending)

	-- a sample moves the surface over the four cells around it
	terrain.rewrite(first_x - 1, first_z - 1, last_x, last_z)
	passability.refresh(first_x - 1, first_z - 1, last_x, last_z)
	pathfinder.refresh(first_x - 1, first_z - 1, last_x, last_z)
	terrain_deformed:FireAllClients(map_state.generation(), changes)

	local min_x, min_z = heightmap.grid_to_world(first_x - 1, first_z - 1)
	local max_x, max_z = heightmap.grid_to_world(last_x + 1, last_z + 1)
	reseat(min_x, min_z, max_x, max_z)
end

local function init()
	-- a client asks once it has built a map, and is sent every edit made to it so far; one that asks about a map that
	-- has already been replaced is told nothing, since it will ask again once it has built the new one
	terrain_deformed.OnServerEvent:Connect(function(player: Player, generation: unknown)
		if generation ~= map_state.generation() then
			return
		end
		local edits = heightmap.edited_heights()
		if #edits > 0 then
			terrain_deformed:FireClient(player, generation, edits)
		end
	end)
end

-- Forgets the edits waiting to be drawn, which were made to a map that is being replaced.
local function discard_pending()
	table.clear(pending)
end

return table.freeze({
	init = init,
	crater = crater,
	flush = flush,
	discard_pending = discard_pending,
})
