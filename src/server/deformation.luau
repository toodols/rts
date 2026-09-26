-- Explosions press craters into the ground, softly: see shared/craters.luau for how deep and how wide.
--
-- The heightmap is edited at once, so everything the simulation stands on agrees with it from then on, and what can be
-- walked over it is worked out again once a step (`flush`, shared/ground.luau); the voxels that draw it and the
-- clients that keep their own copy of it are told once the step is over, in one go (server/outbox.luau), so a barrage
-- of shells is one rewrite and one message and not hundreds.
--
-- Every edit sent to a client is labelled with the map generation it was made to (see shared/map_state.luau), so
-- one that arrives after the map has been replaced is dropped rather than laid onto the new ground.
--
-- Buildings do not sink or float: the ground under their footprints is left as it is. Units and wrecks
-- that stand where the ground has moved are set back down on it.

local ReplicatedStorage = game:GetService "ReplicatedStorage"
local ServerScriptService = game:GetService "ServerScriptService"

local types = require(ReplicatedStorage.Shared.types)
local craters = require(ReplicatedStorage.Shared.craters)
local world_scale = require(ReplicatedStorage.Shared.world_scale)
local heightmap = require(ReplicatedStorage.Shared.heightmap)
local map_state = require(ReplicatedStorage.Shared.map_state)
local ground = require(ReplicatedStorage.Shared.ground)
local decode = require(ReplicatedStorage.Shared.decode)
local unit_defs = require(ReplicatedStorage.Shared.unit_defs)
local surface = require(ReplicatedStorage.Shared.surface)

local remotes = require(ServerScriptService.ServerShared.remotes)

local state = require(script.Parent.state)
local outbox = require(script.Parent.outbox)
local placement = require(script.Parent.placement)
local spatial = require(script.Parent.spatial)
local snapshot = require(script.Parent.snapshot)
local passability = require(ReplicatedStorage.Shared.passability)
local pathfinder = require(ReplicatedStorage.Shared.pathfinder)

type Entity = types.Entity

local terrain_deformed: RemoteEvent = ReplicatedStorage.Shared.TerrainDeformed

-- How often a player may ask for the edits made to the map: once a map is plenty, and a few more let a client that
-- builds maps quickly in turn ask about each.
local ASK_RATE = { per_second = 0.5, burst = 3 }

-- The samples edited since the last flush, by sample index.
local pending: { [number]: boolean } = {}

-- Presses a crater into the ground where an explosion of `damage` and blast `radius` went off at `at`.
-- One that goes off well above the ground, like a shell bursting on an aircraft, leaves it alone.
local function crater(at: Vector3, radius: number, damage: number)
	local depth = craters.DEFORM_MAX_DEPTH
		* (1 - math.exp(-((damage / craters.DEFORM_DAMAGE_SCALE) ^ craters.DEFORM_DAMAGE_POWER)))
	if depth < craters.DEFORM_MIN_DEPTH or heightmap.in_bounds(at.X, at.Z) == false then
		return
	end
	local reach = math.max(radius, craters.DEFORM_MIN_RADIUS)
	if at.Y - heightmap.height_at(at.X, at.Z) > reach then
		return
	end

	-- a sample within a cell of a building's footprint helps hold up the ground it stands on
	local footprints: { { center: Vector3, half: Vector2 } } = {}
	-- the crater's rim reaches past its bowl, and a building's footprint past its collider by less than a cell a side
	spatial.each_near(at.X, at.Z, reach * craters.DEFORM_RIM_REACH + world_scale.CELL_STUDS * 2, function(other: Entity)
		if other.kind == "building" then
			table.insert(footprints, { center = other.position, half = placement.half_extents_for(other) })
		end
	end)
	local function under_a_building(x: number, z: number): boolean
		for _, footprint in footprints do
			if
				math.abs(x - footprint.center.X) <= footprint.half.X + world_scale.CELL_STUDS
				and math.abs(z - footprint.center.Z) <= footprint.half.Y + world_scale.CELL_STUDS
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
		local def = entity.def
		if def.air ~= nil then
			continue
		end
		local position = entity.position
		if position.X < min_x or position.X > max_x or position.Z < min_z or position.Z > max_z then
			continue
		end
		local height = surface.height(def, position.X, position.Z) + unit_defs.collider_height(def) / 2
		if math.abs(height - position.Y) > 1e-3 then
			entity.position = Vector3.new(position.X, height, position.Z)
		end
	end
end

-- Works out again what can be walked where the ground has been edited since the last time, sets what stands there back
-- down on it, and hands the edits to be drawn and sent once the step is over (`outbox`).
local function flush()
	if next(pending) == nil then
		return
	end
	local changes = {}
	for index in pending do
		table.insert(changes, index)
		table.insert(
			changes,
			heightmap.sample((index - 1) % heightmap.samples_across(), (index - 1) // heightmap.samples_across())
		)
	end
	table.clear(pending)

	local first_x, first_z, last_x, last_z = ground.edited_cells(changes)
	ground.refresh(first_x, first_z, last_x, last_z)
	outbox.ground_edited(changes, first_x, first_z, last_x, last_z)

	local min_x, min_z = heightmap.grid_to_world(first_x, first_z)
	local max_x, max_z = heightmap.grid_to_world(last_x + 1, last_z + 1)
	reseat(min_x, min_z, max_x, max_z)
end

-- The generation of the map each player was last sent every edit made to, so that asking again for the same map is
-- answered with nothing: they have it all, and what is made from now on reaches them as it is made.
local answered: { [Player]: number } = {}

local function init()
	-- a client asks once it has built a map, and is sent every edit made to it so far, once; one that asks about a map
	-- that has already been replaced is told nothing, since it will ask again once it has built the new one
	remotes.listen(
		terrain_deformed,
		{ args = { decode.integer }, rate = ASK_RATE },
		function(player: Player, generation: number)
			if generation ~= map_state.generation() or answered[player] == generation then
				return
			end
			answered[player] = generation
			local edits = heightmap.edited_heights()
			if #edits > 0 then
				remotes.tell(terrain_deformed, player, generation, edits)
			end
		end
	)
end

-- Forgets `player`, who has left.
local function forget_player(player: Player)
	answered[player] = nil
end

-- Forgets the edits waiting to be drawn, which were made to a map that is being replaced.
local function discard_pending()
	table.clear(pending)
end

-- The ground is kept as the edits made to it, on the map it was generated as, which a game can only be put back onto.
-- Once it is back, with the walls on it (obstacles.luau), what can be walked is worked out again all over, and what
-- moved is drawn and sent as any crater is.
local restored_changes: { number } = {}
snapshot.keep("ground", function()
	local map = map_state.get()
	return {
		preset = if map ~= nil then map.preset else nil,
		seed = if map ~= nil then map.seed else nil,
		edits = heightmap.kept_edits(),
		pending = pending,
	}
end, function(saved)
	local map = map_state.get()
	assert(
		map ~= nil and map.preset == saved.preset and map.seed == saved.seed,
		`a game kept on {saved.preset} ({saved.seed}) can only be put back on that map`
	)
	restored_changes = heightmap.put_back_edits(saved.edits)
	pending = saved.pending
end)
snapshot.rebuild("ground", function()
	local cells_x, cells_z = heightmap.cells()
	passability.refresh(0, 0, cells_x - 1, cells_z - 1)
	pathfinder.reset()
	local changes = restored_changes
	restored_changes = {}
	if #changes > 0 then
		local first_x, first_z, last_x, last_z = ground.edited_cells(changes)
		outbox.ground_edited(changes, first_x, first_z, last_x, last_z)
	end
end)

return table.freeze({
	init = init,
	forget_player = forget_player,
	crater = crater,
	flush = flush,
	discard_pending = discard_pending,
})
