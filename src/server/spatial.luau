--!strict
--!native
-- Where everything on the map is, for asking "what is near here" of thousands of things a tick without testing all of
-- them. It is the one index the simulation asks: what a shot or a line of sight meets (`colliders`), what a weapon
-- could pick as its target (`targets`), what a moving unit is pushed apart from (`separation`), and what the game's
-- own players (the AI, the scavengers, a mission's waves) look for when they decide (`presence`). Each is filled from
-- one walk of the world, and what each holds is said once, here.
--
-- The step marks it stale where things have moved (`invalidate`: at the top of the tick, once movement is done, and
-- once what transports carry has been hung from them), and so does anything joining or leaving the world
-- (`state.world_version`), between steps too; an index is only filled again when something asks it, so a tick in which
-- nothing looks costs nothing. The targets are the exception: they are filled at the top of the tick (`begin_tick`) and
-- held for the whole of it, so that a fight order's "is there anything to shoot" and the shot the unit then takes this
-- same tick search the same candidates, and one cached pick serves both (targeting's pick_target_cache).
--
-- Colliders, targets and separation all sit in flat grids (server/flat_grid.luau). Small things and big ones sit in
-- separate grids, so that a search through a crowd of small units only allows for small colliders' widths there.

local ReplicatedStorage = game:GetService "ReplicatedStorage"

local types = require(ReplicatedStorage.Shared.types)
local unit_defs = require(ReplicatedStorage.Shared.unit_defs)
local teams = require(ReplicatedStorage.Shared.teams)
local geometry = require(ReplicatedStorage.Shared.geometry)

local state = require(script.Parent.state)
local flat_grid = require(script.Parent.flat_grid)
local alliances = require(script.Parent.alliances)

type Entity = types.Entity
type EntityId = types.EntityId

-- The widest collider a "small" thing has.
local SMALL_RADIUS = 4

local widest_collider = 0
local widest_mover = 0
local widest_grounded = 0
for _, def in unit_defs.defs do
	local radius = unit_defs.collider_radius(def)
	widest_collider = math.max(widest_collider, radius)
	if def.air == nil then
		widest_grounded = math.max(widest_grounded, radius)
		if unit_defs.moves(def) then
			widest_mover = math.max(widest_mover, radius)
		end
	end
end

-- Colliders --------------------------------------------------------------------------------------------------------

-- A grid of colliders, with each one's height and half its height by its index in the grid.
export type Layer = {
	grid: flat_grid.Grid,
	-- the widest collider this layer can hold
	widest: number,
	ys: { number },
	half_heights: { number },
	entities: { Entity },
	-- whether it stands in the way of a line of fire: finished, and not wholly under the water, which puts it under
	-- every line as well
	blocks: { boolean },
}

local function new_layer(cell: number, side: number, widest: number): Layer
	return {
		grid = flat_grid.new(cell, side),
		widest = widest,
		ys = {},
		half_heights = {},
		entities = {},
		blocks = {},
	}
end

-- Solid things on the ground and in the water, small and large; wrecks, which a shell flies through and a hitscan shot
-- or a blast can still strike; and aircraft, which as in BAR have no collider, so a shot passes through any but the
-- one it is aimed at and only a blast reaches the rest. What hangs from a transport is up with the aircraft, and is
-- treated as they are. A reclaimable is struck by nothing and hurt by no blast, so it is in none of them, but in a
-- layer of its own for what looks for something to reclaim.
local small = new_layer(8, 256, SMALL_RADIUS)
local large = new_layer(24, 64, widest_collider)
local wrecks = new_layer(24, 64, widest_collider)
local aircraft = new_layer(24, 64, widest_collider)
local reclaimables = new_layer(24, 64, widest_collider)
local LAYERS = table.freeze({ small = small, large = large, wrecks = wrecks, aircraft = aircraft })
-- the colliders, in the order a blast looks through them
local IN_ORDER: { Layer } = { small, large, wrecks, aircraft }
-- everything, for a search by position alone
local EVERYTHING: { Layer } = { small, large, wrecks, aircraft, reclaimables }

local function layer_add(layer: Layer, entity: Entity, blocks: boolean)
	local def = entity.def
	local position = entity.position
	local k = flat_grid.add(layer.grid, position.X, position.Z, unit_defs.collider_radius(def))
	layer.ys[k] = position.Y
	layer.half_heights[k] = unit_defs.collider_height(def) / 2
	layer.entities[k] = entity
	layer.blocks[k] = blocks
end

local colliders_stale = true
-- the world's membership (`state.world_version`) the colliders were filled for
local colliders_version = -1

-- Whether the colliders have to be filled again: things have moved, or something has joined or left the world, since
-- they last were.
local function colliders_outdated(): boolean
	return colliders_stale or colliders_version ~= state.world_version()
end

local function fill_colliders()
	colliders_stale = false
	colliders_version = state.world_version()
	for _, layer in EVERYTHING do
		flat_grid.clear(layer.grid)
	end
	for _, entity in state.all() do
		if entity.alive == false then
			continue
		end
		if entity.kind == "reclaimable" then
			layer_add(reclaimables, entity, false)
		elseif entity.kind == "wreck" then
			layer_add(wrecks, entity, false)
		elseif unit_defs.is_air(entity.def) then
			layer_add(aircraft, entity, false)
		else
			local def = entity.def
			local blocks = entity.state == "active" and unit_defs.submerged(def, entity.position) == false
			layer_add(if unit_defs.collider_radius(def) <= SMALL_RADIUS then small else large, entity, blocks)
		end
	end
	for _, cargo in state.carried() do
		layer_add(aircraft, cargo, false)
	end
	for _, layer in EVERYTHING do
		flat_grid.sort(layer.grid)
	end
end

-- The collider layers, filled for where things stand now.
local function colliders(): typeof(LAYERS)
	if colliders_outdated() then
		fill_colliders()
	end
	return LAYERS
end

-- Calls `visit(entity, k)` with every living entry of `layer` in a cell within `reach` of (x, z) on either axis. `k`
-- indexes the layer's arrays, for a caller that wants the numbers without the def lookups. A visit that returns true
-- ends the search there.
local function each_in(layer: Layer, x: number, z: number, reach: number, visit: (Entity, number) -> boolean?)
	local grid = layer.grid
	local size = grid.size
	local order, starts, stops, entities = grid.order, grid.starts, grid.stops, layer.entities
	for gx = math.floor((x - reach) / size), math.floor((x + reach) / size) do
		for gz = math.floor((z - reach) / size), math.floor((z + reach) / size) do
			local c = flat_grid.cell_index(grid, gx, gz)
			local first = starts[c]
			if first == 0 then
				continue
			end
			for s = first, stops[c] - 1 do
				local k = order[s]
				local entity = entities[k]
				if entity.alive and visit(entity, k) == true then
					return
				end
			end
		end
	end
end

-- Half a cell's diagonal, as a share of its width: a hair over the square root of a half, so that nothing on the edge
-- is missed to rounding.
local HALF_DIAGONAL = 0.7072
-- How much above or below something a line can pass and still touch it.
local HEIGHT_SLACK = 0.5

-- The nearest thing in `layer` the line from `from` to `to` touches, nearer than `best_t` along it (0 at `from`, 1 at
-- `to`), other than the two `ignored`, and only what stands in the way of a line of fire if `blockers_only`: its
-- position along the line, and the thing itself. Only the cells near the line are visited: one counts as near if the
-- line passes within half its diagonal plus the widest collider the layer holds.
local function nearest_on_segment(
	layer: Layer,
	from: Vector3,
	to: Vector3,
	ignored_a: EntityId,
	ignored_b: EntityId,
	best_t: number,
	blockers_only: boolean
): (number, Entity?)
	local grid = layer.grid
	local size = grid.size
	local xs, zs, rs, order, starts, stops = grid.xs, grid.zs, grid.rs, grid.order, grid.starts, grid.stops
	local ys, half_heights, entities, blocks = layer.ys, layer.half_heights, layer.entities, layer.blocks
	local pad = layer.widest
	local reach = size * HALF_DIAGONAL + pad
	local ax, ay, az = from.X, from.Y, from.Z
	local dx, dy, dz = to.X - ax, to.Y - ay, to.Z - az
	local length_squared = dx * dx + dz * dz
	local best: Entity? = nil
	for gx = math.floor((math.min(ax, to.X) - pad) / size), math.floor((math.max(ax, to.X) + pad) / size) do
		for gz = math.floor((math.min(az, to.Z) - pad) / size), math.floor((math.max(az, to.Z) + pad) / size) do
			local c = flat_grid.cell_index(grid, gx, gz)
			local first = starts[c]
			if first == 0 then
				continue
			end
			-- skip a cell the line passes too far from for anything in it to touch
			local cx = (gx + 0.5) * size - ax
			local cz = (gz + 0.5) * size - az
			local tc = if length_squared > 1e-6 then math.clamp((cx * dx + cz * dz) / length_squared, 0, 1) else 0
			local ocx, ocz = cx - dx * tc, cz - dz * tc
			if ocx * ocx + ocz * ocz > reach * reach then
				continue
			end
			for s = first, stops[c] - 1 do
				local k = order[s]
				if blockers_only and blocks[k] == false then
					continue
				end
				local entity = entities[k]
				local id = entity.id
				if id == ignored_a or id == ignored_b then
					continue
				end
				local ox, oz = xs[k] - ax, zs[k] - az
				local t = if length_squared > 1e-6 then math.clamp((ox * dx + oz * dz) / length_squared, 0, 1) else 0
				if t >= best_t then
					continue
				end
				local sx, sz = ox - dx * t, oz - dz * t
				local radius = rs[k]
				if sx * sx + sz * sz > radius * radius then
					continue
				end
				if math.abs(ay + dy * t - ys[k]) > half_heights[k] + HEIGHT_SLACK then
					continue
				end
				-- something can die after the index is filled, part way through the tick
				if entity.alive == false then
					continue
				end
				best = entity
				best_t = t
			end
		end
	end
	return best_t, best
end

-- The first thing standing in the way of a line of fire from `from` to `to`, other than the two `ignored`, if any.
local function first_blocker(from: Vector3, to: Vector3, ignored_a: EntityId, ignored_b: EntityId): Entity?
	local layers = colliders()
	local best_t, nearest = nearest_on_segment(layers.small, from, to, ignored_a, ignored_b, math.huge, true)
	local _, bigger = nearest_on_segment(layers.large, from, to, ignored_a, ignored_b, best_t, true)
	return bigger or nearest
end

-- The first wreck the line from `from` to `to` touches, other than the two `ignored`, if any.
local function first_wreck(from: Vector3, to: Vector3, ignored_a: EntityId, ignored_b: EntityId): Entity?
	local _, nearest = nearest_on_segment(colliders().wrecks, from, to, ignored_a, ignored_b, math.huge, false)
	return nearest
end

-- Every collider that could be within `reach` of (x, z) or of any point within `reach` of it, passed to `visit` with
-- its radius and half its height: a blast reaching `reach` looks through each layer as far as that plus the widest
-- collider the layer holds. A reach so wide that walking the small things' grid would visit more than MAX_BLAST_CELLS
-- of its cells each way buys nothing by walking it, and visits every collider there is instead, the same ones.
local MAX_BLAST_CELLS = 24
local function each_collider_near(x: number, z: number, reach: number, visit: (Entity, number, number) -> ())
	if colliders_outdated() then
		fill_colliders()
	end
	if (reach + widest_collider) / small.grid.size > MAX_BLAST_CELLS then
		for _, layer in IN_ORDER do
			local entities, rs, half_heights = layer.entities, layer.grid.rs, layer.half_heights
			for k = 1, layer.grid.count do
				local other = entities[k]
				if other.alive then
					visit(other, rs[k], half_heights[k])
				end
			end
		end
		return
	end
	for _, layer in IN_ORDER do
		local rs, half_heights = layer.grid.rs, layer.half_heights
		each_in(layer, x, z, reach + layer.widest, function(other: Entity, k: number): boolean?
			visit(other, rs[k], half_heights[k])
			return nil
		end)
	end
end

-- Calls `visit` with everything living in the world, hanging from no transport, that could be within `radius` of (x, z)
-- (its middle, give or take its own collider): what a builder looks for work in, or a transport for something to lift.
local function each_near(x: number, z: number, radius: number, visit: (Entity) -> ())
	if colliders_outdated() then
		fill_colliders()
	end
	for _, layer in EVERYTHING do
		each_in(layer, x, z, radius + layer.widest, function(other: Entity): boolean?
			if state.carrier_of(other.id) == nil then
				visit(other)
			end
			return nil
		end)
	end
end

-- Targets ----------------------------------------------------------------------------------------------------------

-- A flat (X, Z) grid of everything a weapon could possibly pick, living and not remains, bucketed again in each
-- cell by alliance root (alliances.root_of): two things can only be enemies if their roots differ, so a search for a
-- shooter's targets skips straight past its own root's bucket in every cell it visits. The cell is small next to
-- typical weapon ranges on purpose: a search visits whole cells, and everything in the overshoot past its reach is
-- visited and rejected.
local TARGET_CELL = 64
-- Past this many rings out from the searcher, the grid visits more empty cells than it saves, so a search just walks
-- everything.
local TARGET_GRID_MAX_RINGS = 16

type TargetCell = { [number]: { Entity } }
local target_grid: { [number]: { [number]: TargetCell } } = {}
-- The alliance roots of everything on the map that could be anyone's enemy, and how many there are: with only one
-- anywhere, nothing could possibly be an enemy of anything.
local present_roots: { [number]: boolean } = {}
local present_root_count = 0

-- Whether a weapon could possibly pick `entity`: living, and not remains lying about.
local function targetable(entity: Entity): boolean
	return entity.alive and unit_defs.is_remains(entity.def) == false
end

local function add_target(entity: Entity)
	if targetable(entity) == false then
		return
	end
	local cx, cz = math.floor(entity.position.X / TARGET_CELL), math.floor(entity.position.Z / TARGET_CELL)
	local column = target_grid[cx]
	if column == nil then
		column = {}
		target_grid[cx] = column
	end
	local cell = column[cz]
	if cell == nil then
		cell = {}
		column[cz] = cell
	end
	local root = alliances.root_of(entity.team)
	local bucket = cell[root]
	if bucket == nil then
		bucket = {}
		cell[root] = bucket
	end
	table.insert(bucket, entity)
	-- neutral scenery is nobody's enemy, so it never makes a shooter think an enemy might be out there
	if entity.team ~= teams.NEUTRAL and present_roots[root] == nil then
		present_roots[root] = true
		present_root_count += 1
	end
end

local function fill_targets()
	table.clear(target_grid)
	table.clear(present_roots)
	present_root_count = 0
	for _, entity in state.all() do
		add_target(entity)
	end
	for _, cargo in state.carried() do
		add_target(cargo)
	end
end

-- Whether anything on the map could possibly be an enemy of something of `team`'s: something living, not a wreck, of
-- another alliance root.
local function any_enemy_of(team: types.TeamId): boolean
	if present_root_count > 1 then
		return true
	end
	if present_root_count == 0 then
		return false
	end
	return present_roots[alliances.root_of(team)] == nil
end

-- Calls `visit` with everything living that could possibly be within `radius` of (x, z), and is not of the alliance root
-- `except_root` (`alliances.root_of`; nil to leave no side out). A visit that returns true ends the search there.
local function each_target(x: number, z: number, radius: number, except_root: number?, visit: (Entity) -> boolean?)
	local rings = math.ceil(radius / TARGET_CELL)
	if rings > TARGET_GRID_MAX_RINGS then
		for _, group in { state.all(), state.carried() } do
			for _, entity in group do
				if targetable(entity) and alliances.root_of(entity.team) ~= except_root then
					if visit(entity) == true then
						return
					end
				end
			end
		end
		return
	end
	local cx, cz = math.floor(x / TARGET_CELL), math.floor(z / TARGET_CELL)
	local radius_squared = radius * radius
	for gx = cx - rings, cx + rings do
		local column = target_grid[gx]
		-- how far (x, z) is from this column of cells along X, zero if it is inside it
		local cell_min_x = gx * TARGET_CELL
		local dx = math.max(cell_min_x - x, 0, x - (cell_min_x + TARGET_CELL))
		if column ~= nil and dx * dx <= radius_squared then
			for gz = cz - rings, cz + rings do
				local cell = column[gz]
				local cell_min_z = gz * TARGET_CELL
				local dz = math.max(cell_min_z - z, 0, z - (cell_min_z + TARGET_CELL))
				-- a cell whose nearest point is out past the radius has nothing in it that could be in reach
				if cell ~= nil and dx * dx + dz * dz <= radius_squared then
					for root, bucket in cell do
						if root ~= except_root then
							for _, entity in bucket do
								if visit(entity) == true then
									return
								end
							end
						end
					end
				end
			end
		end
	end
end

-- Separation --------------------------------------------------------------------------------------------------------

-- What pushes a moving unit away from it: everything standing on the ground or the water, units and buildings alike,
-- blueprints included, since a builder is as real an obstacle as another unit. Aircraft are left out: as in BAR, planes
-- fly through one another rather than jostling for space. Wrecks and reclaimables are left out too: BAR does not
-- collide units against them, and with dozens lying round after a fight every unit near a battlefield would be pushing
-- against them all for the rest of the match.
--
-- A 3x3 scan of cells only finds every real neighbour if a cell is at least as wide as the furthest two colliders can
-- interact (their radii plus the padding). Movers are all small, but buildings are not, and one cell size for both
-- would pack a crowd of movers many to a cell, each checking all of them. So movers sit in cells sized to two of the
-- widest mover, and everything else in cells sized to the widest mover plus the widest anything. Only movers ever ask.
-- The padding is how far past their two radii units still push each other apart.
local PAD = 0.5

local mover_grid = flat_grid.new(2 * widest_mover + PAD, 256)
local other_grid = flat_grid.new(widest_mover + widest_grounded + PAD, 128)
-- Where each mover sits in mover_grid, by id, and who is in each slot of other_grid.
local mover_slot: { [EntityId]: number } = {}
local other_ids: { EntityId } = {}

local separation_stale = true

-- Whether `entity` moves about itself, and so is pushed apart from what it runs into.
local function is_mobile(entity: Entity): boolean
	return entity.kind == "unit" and entity.state == "active" and unit_defs.moves(entity.def)
end

local function fill_separation()
	separation_stale = false
	flat_grid.clear(mover_grid)
	flat_grid.clear(other_grid)
	table.clear(mover_slot)
	table.clear(other_ids)
	for _, entity in state.all() do
		if entity.alive == false or unit_defs.is_remains(entity.def) or unit_defs.is_air(entity.def) then
			continue
		end
		local radius = unit_defs.collider_radius(entity.def)
		local position = entity.position
		if is_mobile(entity) then
			mover_slot[entity.id] = flat_grid.add(mover_grid, position.X, position.Z, radius)
		else
			other_ids[flat_grid.add(other_grid, position.X, position.Z, radius)] = entity.id
		end
	end
	flat_grid.sort(mover_grid)
	flat_grid.sort(other_grid)
end

-- Adds to (px, pz) the push from every entry of `grid` overlapping a collider of `radius` at (x, z), skipping entry
-- `self` (0 for none) and the entry whose id in `ids` is `passes` (nil for none). The push is away from each, scaled by
-- how deep the overlap is so that lightly touching units barely react.
local function push_from(
	grid: flat_grid.Grid,
	x: number,
	z: number,
	radius: number,
	id: EntityId,
	self: number,
	ids: { EntityId }?,
	passes: EntityId?,
	px: number,
	pz: number
): (number, number)
	local size = grid.size
	local xs, zs, rs, order, starts, stops = grid.xs, grid.zs, grid.rs, grid.order, grid.starts, grid.stops
	local cx, cz = math.floor(x / size), math.floor(z / size)
	for dz = -1, 1 do
		for dx = -1, 1 do
			local c = flat_grid.cell_index(grid, cx + dx, cz + dz)
			for s = starts[c], stops[c] - 1 do
				local k = order[s]
				if k == self or (ids ~= nil and ids[k] == passes) then
					continue
				end
				local ox, oz = x - xs[k], z - zs[k]
				local minimum = radius + rs[k] + PAD
				local distance_squared = ox * ox + oz * oz
				if distance_squared >= minimum * minimum then
					continue
				end
				if distance_squared < 1e-6 then
					-- exactly co-located: shove apart along an arbitrary but stable axis
					local angle = id * 2.399963
					px += math.cos(angle)
					pz += math.sin(angle)
					continue
				end
				local distance = math.sqrt(distance_squared)
				local scale = (minimum - distance) / (minimum * distance)
				px += ox * scale
				pz += oz * scale
			end
		end
	end
	return px, pz
end

-- The push on the mover `entity` from everything overlapping it, judged from where everything stood when the index was
-- filled, save `passes`, which it goes through (the lab it is driving out of). Nothing for what is not a mover on the
-- ground.
local function separation(entity: Entity, passes: EntityId?): Vector3
	if separation_stale then
		fill_separation()
	end
	local k = mover_slot[entity.id]
	if k == nil then
		return Vector3.zero
	end
	local x, z, radius = mover_grid.xs[k], mover_grid.zs[k], mover_grid.rs[k]
	local px, pz = push_from(mover_grid, x, z, radius, entity.id, k, nil, nil, 0, 0)
	px, pz = push_from(other_grid, x, z, radius, entity.id, 0, if passes ~= nil then other_ids else nil, passes, px, pz)
	return Vector3.new(px, 0, pz)
end

-- Presence ----------------------------------------------------------------------------------------------------------

-- Everything standing on the map (`state.is_present`: living, and not a wreck or a rock), for what the game's own
-- players ask when they decide what to do: the nearest enemy of one of the scavengers' units, what an AI sees, the
-- player's thing nearest a mission's wave. They decide at the top of the step, before the targets are filled for it, so
-- this is an index of its own, filled again when first asked after things have moved or joined or left the world, and
-- right whenever it is asked. It is a coarse grid of PRESENCE_CELL studs, of only the cells anything is in, so that a
-- search outward from a point for the nearest of something (`nearest`) visits only as many cells as it has to.
local PRESENCE_CELL = 64

local presence_grid: { [number]: { [number]: { Entity } } } = {}
-- the cells anything is in lie within these, by cell
local presence_bounds = { min_x = 0, max_x = -1, min_z = 0, max_z = -1 }
local presence_stale = true
local presence_version = -1

local function fill_presence()
	presence_stale = false
	presence_version = state.world_version()
	table.clear(presence_grid)
	local bounds = presence_bounds
	bounds.min_x, bounds.max_x, bounds.min_z, bounds.max_z = math.huge, -math.huge, math.huge, -math.huge
	for _, entity in state.all() do
		if state.is_present(entity) == false then
			continue
		end
		local cx = math.floor(entity.position.X / PRESENCE_CELL)
		local cz = math.floor(entity.position.Z / PRESENCE_CELL)
		local column = presence_grid[cx]
		if column == nil then
			column = {}
			presence_grid[cx] = column
		end
		local cell = column[cz]
		if cell == nil then
			cell = {}
			column[cz] = cell
		end
		table.insert(cell, entity)
		bounds.min_x = math.min(bounds.min_x, cx)
		bounds.max_x = math.max(bounds.max_x, cx)
		bounds.min_z = math.min(bounds.min_z, cz)
		bounds.max_z = math.max(bounds.max_z, cz)
	end
end

local function refresh_presence()
	if presence_stale or presence_version ~= state.world_version() then
		fill_presence()
	end
end

-- Calls `visit` with each living thing in the cell (cx, cz), if anything is in it, until one returns true; returns
-- whether one did.
local function visit_cell(cx: number, cz: number, visit: (Entity) -> boolean?): boolean
	local column = presence_grid[cx]
	local cell = if column ~= nil then column[cz] else nil
	if cell == nil then
		return false
	end
	for _, entity in cell do
		if entity.alive and visit(entity) == true then
			return true
		end
	end
	return false
end

-- Calls `visit` with each living thing in the cells `ring` cells out from (cx, cz) on either axis, until one returns
-- true; returns whether one did.
local function visit_ring(cx: number, cz: number, ring: number, visit: (Entity) -> boolean?): boolean
	if ring == 0 then
		return visit_cell(cx, cz, visit)
	end
	for gx = cx - ring, cx + ring do
		if visit_cell(gx, cz - ring, visit) or visit_cell(gx, cz + ring, visit) then
			return true
		end
	end
	for gz = cz - ring + 1, cz + ring - 1 do
		if visit_cell(cx - ring, gz, visit) or visit_cell(cx + ring, gz, visit) then
			return true
		end
	end
	return false
end

-- How many rings out from the cell (cx, cz) the cells anything is in go.
local function rings_to_bounds(cx: number, cz: number): number
	local bounds = presence_bounds
	if bounds.max_x < bounds.min_x then
		return -1
	end
	return math.max(cx - bounds.min_x, bounds.max_x - cx, cz - bounds.min_z, bounds.max_z - cz, 0)
end

-- Of what stands on the map within `within` of `from` (`geometry.distance_2d`), the nearest that `accept` takes (it is
-- given the thing and how far it is), and of those as near, the one with the least id. `within` can be math.huge.
local function nearest(from: Vector3, within: number, accept: (Entity, number) -> boolean): Entity?
	refresh_presence()
	local cx = math.floor(from.X / PRESENCE_CELL)
	local cz = math.floor(from.Z / PRESENCE_CELL)
	local best: Entity? = nil
	local best_distance = within
	local function consider(entity: Entity): boolean?
		local distance = geometry.distance_2d(from, entity.position)
		local closer = distance < best_distance
			or (distance == best_distance and (best == nil or entity.id < (best :: Entity).id))
		if closer and accept(entity, distance) then
			best = entity
			best_distance = distance
		end
		return nil
	end
	for ring = 0, rings_to_bounds(cx, cz) do
		-- a cell `ring` out is at least `ring - 1` cells' width off, and nothing further can be nearer than the best
		if (ring - 1) * PRESENCE_CELL > best_distance + 1 then
			break
		end
		visit_ring(cx, cz, ring, consider)
	end
	return best
end

-- Calls `visit` with each thing that stands on the map within `radius` of `from` (`geometry.distance_2d`), and how far
-- it is, until one returns true. They come in no order a caller may count on.
local function each_present(from: Vector3, radius: number, visit: (Entity, number) -> boolean?)
	refresh_presence()
	local cx = math.floor(from.X / PRESENCE_CELL)
	local cz = math.floor(from.Z / PRESENCE_CELL)
	local rings = math.min(rings_to_bounds(cx, cz), math.ceil(radius / PRESENCE_CELL) + 1)
	for ring = 0, rings do
		local stopped = visit_ring(cx, cz, ring, function(entity: Entity): boolean?
			local distance = geometry.distance_2d(from, entity.position)
			if distance <= radius then
				return visit(entity, distance)
			end
			return nil
		end)
		if stopped then
			return
		end
	end
end

-- Refilling --------------------------------------------------------------------------------------------------------

-- Things have moved: every index is filled again the next time it is asked.
local function invalidate()
	colliders_stale = true
	separation_stale = true
	presence_stale = true
end

-- The top of the tick: the targets are filled for the whole of it, and everything else when next asked.
local function begin_tick()
	invalidate()
	fill_targets()
end

return table.freeze({
	SMALL_RADIUS = SMALL_RADIUS,
	begin_tick = begin_tick,
	invalidate = invalidate,
	colliders = colliders,
	each_in = each_in,
	first_blocker = first_blocker,
	first_wreck = first_wreck,
	each_collider_near = each_collider_near,
	each_near = each_near,
	any_enemy_of = any_enemy_of,
	each_target = each_target,
	TARGET_CELL = TARGET_CELL,
	is_mobile = is_mobile,
	separation = separation,
	nearest = nearest,
	each_present = each_present,
})
