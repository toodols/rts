--!strict
-- Finds a route for a unit to a destination and gives it back as the orders that drive it there: a chain of
-- `move` orders. It is pure apart from the caches below: it reads the ground and changes nothing, so whoever gives a
-- unit somewhere to go (a player's order, laid ahead of it as waypoints the player can see, a factory's rally, the
-- scavengers) decides when to use it. A unit follows the waypoints it has; only one held up on the way, by a building
-- put down across it since they were laid, looks for a way round from where it is (server/orders.luau). `route` is what
-- a move uses: it goes straight when the line is good (`has_straight_path`) and searches only when it is not.
--
-- Where a unit may stand is said once, here (`open_at`), and movement keeps it to the same ground a route is laid over.
--
-- The search is A* over the cells of the heightmap, eight ways, with the cost of a diagonal step the square root of
-- two. A cell is open to a unit when its movement class can stand on it (`passability`), the water over it is the right
-- depth for the def, and no building stands on it (`walls`); and a diagonal step needs both cells it squeezes between
-- to be open, so a route never cuts a corner. A unit on ground it cannot stand on, like one pushed onto it or one a
-- blueprint went down on, may cross more of it to get out, as movement lets it; once on open ground it keeps to it.
--
-- A route keeps clear of walls where it can, and squeezes past them where it cannot. A cell is tight for a unit when
-- it is nearer the nearest cell the unit cannot stand on (or the map's edge) than the unit's radius and WALL_MARGIN
-- allow; stepping into one costs TIGHT_PENALTY times over, so the search goes round by open ground unless that is a
-- good deal further, and only then through the gap. The route of cells is then pulled tight: from each point it goes
-- straight to the furthest later point it can see across ground that is not tight, so the orders are the few turns
-- the route really needs. Inside a squeeze, where no such line exists, it goes from point to point along the gap.
--
-- A destination on ground the unit cannot stand on is reached from the nearest ground it can: the search stops at
-- the first open cell it settles that is no further from it than the nearest open cell is (up to GOAL_SLACK cells),
-- on whichever side the unit comes to it from. For one inside a building, which is what something going to attack,
-- build, mend or reclaim it is sent to, that is its edge, and `complete` says it got there. A destination that cannot
-- be reached gets the route to the reachable cell that is nearest to it, and `complete` says it is not all the way
-- there. So does a search that is stopped by `max_expansions`, the most cells it will settle before giving up. Other
-- units are not part of it: only the ground and the buildings on it count.
--
-- Which cells are open to each kind of unit, and how far each is from the nearest that is not, is worked out once for
-- the whole map the first time a kind of unit asks, and kept; `refresh` works a region of it out again when the ground
-- there changes, as it does under a crater or a building. Kinds of unit that stand on the same ground share: the
-- same movement class and the same water limits.
--
-- A search keeps what it knows of each cell in tables kept from one search to the next (`begin_search`), so that it
-- costs the cells it looks at and not the size of the map.

local ReplicatedStorage = game:GetService "ReplicatedStorage"

local types = require(ReplicatedStorage.Shared.types)
local ground_levels = require(ReplicatedStorage.Shared.ground_levels)
local world_scale = require(ReplicatedStorage.Shared.world_scale)
local heightmap = require(ReplicatedStorage.Shared.heightmap)
local passability = require(ReplicatedStorage.Shared.passability)
local unit_defs = require(ReplicatedStorage.Shared.unit_defs)
local surface = require(ReplicatedStorage.Shared.surface)
local walls = require(ReplicatedStorage.Shared.walls)

type EntityDef = types.EntityDef
type Order = types.Order

export type Path = {
	-- move orders from where the unit is to where it is going; empty if it has nowhere to go
	orders: { Order },
	-- whether the last of them is the destination itself and not just the nearest place to it that could be reached
	complete: boolean,
}

type Heap = {
	nodes: { number },
	keys: { number },
	size: number,
}

type Point = {
	x: number,
	z: number,
}

-- What a kind of unit can stand on: `open` is a byte a cell, 1 where it can stand and 0 where it cannot, and
-- `clearance` a byte a cell, how many cells away the nearest one it cannot stand on is (0 for one it cannot stand on
-- itself, 1 beside one, and so on up to MAX_CLEARANCE), counting diagonals as one and the map's edge as a wall.
type Ground = {
	def: EntityDef,
	open: buffer,
	clearance: buffer,
}

-- The map's size in cells, taken from the heightmap by `reset` whenever a map is built, since maps are not all the
-- same size; none until a map is built.
local width = 0
local depth = 0
local CELL_STUDS = world_scale.CELL_STUDS
local DIAGONAL = math.sqrt(2)
-- Weighs the estimate a hair over its true size. Small enough that a route is never longer than the best by
-- more than a thousandth of itself.
local TIE_BREAK = 1.001
-- How much room, in studs, a unit likes to keep between its body and a wall, over and above its radius: enough that
-- being shoved by its neighbours, or running on a little past a waypoint, does not put it into one.
local WALL_MARGIN = 1.5
-- Stepping into a tight cell costs this many times what stepping into one with room does.
local TIGHT_PENALTY = 4
-- How far a search for one unit's own way may spread before it gives up, in cells settled, unless its caller says
-- otherwise: the way a player's order is laid (shared/order_routes), a factory's rally, and a unit held up looking for a
-- way round.
local MAX_EXPANSIONS = 8000
-- Clearance is counted no further than this many cells, which is room enough for the widest thing that walks.
local MAX_CLEARANCE = 4
-- The furthest, in cells, a destination on ground a unit cannot stand on is looked round for the nearest it can: more
-- than half the widest building.
local GOAL_SLACK = 16

local STEPS: { { number } } = {
	{ 1, 0, 1 },
	{ -1, 0, 1 },
	{ 0, 1, 1 },
	{ 0, -1, 1 },
	{ 1, 1, DIAGONAL },
	{ 1, -1, DIAGONAL },
	{ -1, 1, DIAGONAL },
	{ -1, -1, DIAGONAL },
}

-- Each kind of ground worked out so far, by `ground_key`, and by the def that asked for it.
local grounds: { [string]: Ground } = {}
local grounds_by_def: { [EntityDef]: Ground } = {}

-- What a search knows of each cell, numbered from 1, kept from one search to the next. A cell's cost so far and the
-- cell it was reached from mean something only while its stamp in `seen` is the search's own, and it is settled only
-- while its stamp in `settled` is; a new search takes a new stamp, and so starts with every cell unknown without
-- clearing anything.
local search_cells = 0
local cost_so_far: { number } = {}
local came_from: { number } = {}
local seen = buffer.create(0)
local settled = buffer.create(0)
local search_stamp = 0

-- A binary min-heap of cells by their estimated total cost. A cell can be in it more than once, at different
-- costs, and the search ignores all but the first time it comes out.
local function heap_push(heap: Heap, node: number, key: number)
	local at = heap.size + 1
	heap.size = at
	while at > 1 do
		local parent = at // 2
		if heap.keys[parent] <= key then
			break
		end
		heap.nodes[at] = heap.nodes[parent]
		heap.keys[at] = heap.keys[parent]
		at = parent
	end
	heap.nodes[at] = node
	heap.keys[at] = key
end

local function heap_pop(heap: Heap): number
	local top = heap.nodes[1]
	local last_node = heap.nodes[heap.size]
	local last_key = heap.keys[heap.size]
	heap.size -= 1
	local size = heap.size
	local at = 1
	while true do
		local child = at * 2
		if child > size then
			break
		end
		if child < size and heap.keys[child + 1] < heap.keys[child] then
			child += 1
		end
		if heap.keys[child] >= last_key then
			break
		end
		heap.nodes[at] = heap.nodes[child]
		heap.keys[at] = heap.keys[child]
		at = child
	end
	heap.nodes[at] = last_node
	heap.keys[at] = last_key
	return top
end

-- Whether cell (cx, cz), which is on the map, is open to `def`: its movement class can stand on it, by `slope_map`
-- (nil for one that can stand anywhere), no building stands on it unless `def` flies, and the water over it is the
-- right depth.
local function cell_open(def: EntityDef, slope_map: passability.PassabilityMap?, cx: number, cz: number): boolean
	if slope_map ~= nil and buffer.readu8(slope_map.cells, cz * width + cx) ~= 1 then
		return false
	end
	if def.air == nil and walls.blocked_cell(cx, cz) then
		return false
	end
	-- the ground over the cell is a blend of its corners, so no point in it is higher or lower than they are: the
	-- cell is open only if the water is right at all four
	local lowest_ground = math.huge
	local highest_ground = -math.huge
	for corner_z = cz, cz + 1 do
		for corner_x = cx, cx + 1 do
			local ground = heightmap.sample(corner_x, corner_z)
			lowest_ground = math.min(lowest_ground, ground)
			highest_ground = math.max(highest_ground, ground)
		end
	end
	return unit_defs.tolerates_water(
		def,
		math.max(0, ground_levels.WATER_LEVEL - highest_ground),
		math.max(0, ground_levels.WATER_LEVEL - lowest_ground)
	)
end

-- Kinds of unit that stand on the same ground share its maps. Buildings are no wall to what flies.
local function ground_key(def: EntityDef): string
	local footing = def.footing
	local flies = if def.air ~= nil then "air" else ""
	return `{footing.class or ""}|{footing.min_depth}|{footing.max_depth}|{flies}`
end

-- A cell's clearance, lowered to one more than that of whichever of the neighbours in `offsets` has least, if that is
-- less than it has. Off the map is a wall.
local function sweep_clearance(ground: Ground, cx: number, cz: number, offsets: { { number } }): number
	local at = cz * width + cx
	local best = buffer.readu8(ground.clearance, at)
	if best == 0 then
		return 0
	end
	for _, offset in offsets do
		local nx = cx + offset[1]
		local nz = cz + offset[2]
		local neighbour = if nx < 0
				or nx >= width
				or nz < 0
				or nz >= depth
			then 0
			else buffer.readu8(ground.clearance, nz * width + nx)
		if neighbour + 1 < best then
			best = neighbour + 1
		end
	end
	return best
end

-- The neighbours a cell is judged from on the way forward through the rows, and on the way back.
local BEHIND: { { number } } = { { -1, 0 }, { -1, -1 }, { 0, -1 }, { 1, -1 } }
local AHEAD: { { number } } = { { 1, 0 }, { 1, 1 }, { 0, 1 }, { -1, 1 } }

-- Works out which cells are open and how much room each has, over cells (from_x, from_z) to (to_x, to_z). The room is
-- right for every cell in that rectangle so long as every cell outside it already has its own right, which is so for
-- the whole map, and for a region that runs MAX_CLEARANCE further than any change to the ground.
local function fill(ground: Ground, from_x: number, from_z: number, to_x: number, to_z: number)
	local slope_map = passability.map_for(ground.def.footing.class)
	for cz = from_z, to_z do
		for cx = from_x, to_x do
			local at = cz * width + cx
			local open = cell_open(ground.def, slope_map, cx, cz)
			buffer.writeu8(ground.open, at, if open then 1 else 0)
			buffer.writeu8(ground.clearance, at, if open then MAX_CLEARANCE else 0)
		end
	end
	-- two sweeps, forward and back, each taking every cell's room from the neighbours it has already been through
	for cz = from_z, to_z do
		for cx = from_x, to_x do
			buffer.writeu8(ground.clearance, cz * width + cx, sweep_clearance(ground, cx, cz, BEHIND))
		end
	end
	for cz = to_z, from_z, -1 do
		for cx = to_x, from_x, -1 do
			buffer.writeu8(ground.clearance, cz * width + cx, sweep_clearance(ground, cx, cz, AHEAD))
		end
	end
end

-- The ground `def` stands on, worked out the first time anything of its kind asks.
local function ground_for(def: EntityDef): Ground
	local known = grounds_by_def[def]
	if known ~= nil then
		return known
	end
	local key = ground_key(def)
	local ground = grounds[key]
	if ground == nil then
		ground = { def = def, open = buffer.create(width * depth), clearance = buffer.create(width * depth) }
		fill(ground, 0, 0, width - 1, depth - 1)
		grounds[key] = ground
	end
	grounds_by_def[def] = ground
	return ground
end

-- Works out again the cells from (first_cx, first_cz) to (last_cx, last_cz), inclusive, for every kind of ground
-- worked out so far. Call it whenever the ground there changes, after `passability.refresh`, and whenever a building
-- there comes or goes, after `walls`.
local function refresh(first_cx: number, first_cz: number, last_cx: number, last_cz: number)
	-- a change reaches the room of cells up to MAX_CLEARANCE away
	local from_x = math.max(0, first_cx - MAX_CLEARANCE)
	local from_z = math.max(0, first_cz - MAX_CLEARANCE)
	local to_x = math.min(width - 1, last_cx + MAX_CLEARANCE)
	local to_z = math.min(depth - 1, last_cz + MAX_CLEARANCE)
	for _, ground in grounds do
		fill(ground, from_x, from_z, to_x, to_z)
	end
end

-- Forgets every kind of ground worked out so far, and takes the size of the map now, for a map just built. Each kind
-- is worked out again, from the new map, the first time something asks for it.
local function reset()
	width, depth = heightmap.cells()
	table.clear(grounds)
	table.clear(grounds_by_def)
end

-- How many cells of room `def` wants round it: its radius and WALL_MARGIN, from the middle of its cell.
local function room_wanted(def: EntityDef): number
	local cells = math.ceil((unit_defs.collider_radius(def) + WALL_MARGIN) / CELL_STUDS + 0.5)
	return math.clamp(cells, 1, MAX_CLEARANCE)
end

-- Whether a cell is on the map and open to the ground's unit.
local function is_open(ground: Ground, cx: number, cz: number): boolean
	if cx < 0 or cx >= width or cz < 0 or cz >= depth then
		return false
	end
	return buffer.readu8(ground.open, cz * width + cx) == 1
end

-- Whether `def` may stand at (x, z) in the world: the cell it is in is on the map and open to it (`cell_open`).
local function open_at(def: EntityDef, x: number, z: number): boolean
	local gx, gz = heightmap.world_to_grid(x, z)
	return is_open(ground_for(def), math.floor(gx), math.floor(gz))
end

-- Whether a cell has less room than `wanted`. Off the map has none.
local function is_tight(ground: Ground, wanted: number, cx: number, cz: number): boolean
	if cx < 0 or cx >= width or cz < 0 or cz >= depth then
		return true
	end
	return buffer.readu8(ground.clearance, cz * width + cx) < wanted
end

-- Whether the straight line from one point to another, in grid coordinates, crosses only cells `passes` lets through.
-- It visits every cell the line passes through, not counting the one it starts in; where it goes exactly through a
-- corner, both cells beside that corner have to pass as well. When `leaving`, for a line from ground the unit cannot
-- stand on, the cells before the first that passes do not have to. Given `arriving`, for a line to something inside a
-- wall, the line may end in cells that `arriving` lets through instead: once it is in one, it has come to the wall
-- round what it is going to, and every cell after has to be one too.
local function has_clear_line(
	passes: (number, number) -> boolean,
	from: Point,
	to: Point,
	leaving: boolean,
	arriving: ((number, number) -> boolean)?
): boolean
	local cx = math.floor(from.x)
	local cz = math.floor(from.z)
	local end_cx = math.floor(to.x)
	local end_cz = math.floor(to.z)
	local dx = to.x - from.x
	local dz = to.z - from.z
	local step_x = if dx > 0 then 1 elseif dx < 0 then -1 else 0
	local step_z = if dz > 0 then 1 elseif dz < 0 then -1 else 0

	-- how far along the line, as a fraction of it, the next cell edge across each axis is, and how much
	-- further along the one after that is
	local delta_x = if dx ~= 0 then math.abs(1 / dx) else math.huge
	local delta_z = if dz ~= 0 then math.abs(1 / dz) else math.huge
	local reach_x = math.huge
	if dx > 0 then
		reach_x = (cx + 1 - from.x) / dx
	elseif dx < 0 then
		reach_x = (from.x - cx) / -dx
	end
	local reach_z = math.huge
	if dz > 0 then
		reach_z = (cz + 1 - from.z) / dz
	elseif dz < 0 then
		reach_z = (from.z - cz) / -dz
	end

	local inside = false
	-- whether a cell beside a corner the line goes through lets it by
	local function beside(x: number, z: number): boolean
		return leaving or passes(x, z) or (arriving ~= nil and arriving(x, z))
	end
	for _ = 1, math.abs(end_cx - cx) + math.abs(end_cz - cz) + 1 do
		if cx == end_cx and cz == end_cz then
			return true
		end
		if math.abs(reach_x - reach_z) < 1e-9 then
			if beside(cx + step_x, cz) == false or beside(cx, cz + step_z) == false then
				return false
			end
			cx += step_x
			cz += step_z
			reach_x += delta_x
			reach_z += delta_z
		elseif reach_x < reach_z then
			cx += step_x
			reach_x += delta_x
		else
			cz += step_z
			reach_z += delta_z
		end
		if inside then
			if (arriving :: (number, number) -> boolean)(cx, cz) == false then
				return false
			end
		elseif passes(cx, cz) then
			leaving = false
		elseif leaving then
			continue
		elseif arriving ~= nil and arriving(cx, cz) then
			inside = true
		else
			return false
		end
	end
	return true
end

-- A point in grid coordinates, clamped into the map: one on the far edge is in the last cell, not one past it.
local function grid_point(position: Vector3): Point
	local gx, gz = heightmap.world_to_grid(position.X, position.Z)
	return { x = math.clamp(gx, 0, width - 1e-6), z = math.clamp(gz, 0, depth - 1e-6) }
end

-- Pulls a route tight. From each point it goes on to the furthest later point it can reach in a straight line over
-- open ground that is not tight, and drops the points between. From a point where it cannot reach even the next that
-- way, inside a squeeze, it goes on along the squeeze instead: to the furthest later point it can see over open
-- ground, so long as every point it passes over is in the squeeze as well.
local function pull_tight(
	open: (number, number) -> boolean,
	roomy: (number, number) -> boolean,
	tight: (Point) -> boolean,
	points: { Point }
): { Point }
	local kept: { Point } = {}
	local at = 1
	while at < #points do
		local leaving = open(math.floor(points[at].x), math.floor(points[at].z)) == false
		local furthest = at
		while furthest < #points and has_clear_line(roomy, points[at], points[furthest + 1], leaving) do
			furthest += 1
		end
		if furthest == at then
			furthest = at + 1
			while
				furthest < #points
				and tight(points[furthest])
				and has_clear_line(open, points[at], points[furthest + 1], leaving)
			do
				furthest += 1
			end
		end
		table.insert(kept, points[furthest])
		at = furthest
	end
	return kept
end

-- How far it is from a cell to the goal with nothing in the way: the octile distance, which is what the
-- eight-way steps make the shortest possible, so it never overestimates.
local function estimate(cx: number, cz: number, goal_cx: number, goal_cz: number): number
	local across = math.abs(cx - goal_cx)
	local down = math.abs(cz - goal_cz)
	return across + down + (DIAGONAL - 2) * math.min(across, down)
end

-- How far the nearest cell open to the ground's unit is from cell (cx, cz), by `estimate`, looking no further than
-- GOAL_SLACK cells away; 0 when there is none that near, so a search is for the cell itself.
local function nearest_open_distance(ground: Ground, cx: number, cz: number): number
	local best = math.huge
	for ring = 1, GOAL_SLACK do
		-- no cell in this ring or beyond is nearer than the ring is
		if ring >= best then
			break
		end
		for dz = -ring, ring do
			-- the top and bottom rows of the ring whole, and only its two ends of the rows between
			local stride = if dz == -ring or dz == ring then 1 else 2 * ring
			for dx = -ring, ring, stride do
				if is_open(ground, cx + dx, cz + dz) then
					best = math.min(best, estimate(cx + dx, cz + dz, cx, cz))
				end
			end
		end
	end
	return if best == math.huge then 0 else best
end

-- Starts a search: the tables sized to the map, a new stamp, and an empty heap.
local function begin_search(heap: Heap): number
	local cells = width * depth
	if cells ~= search_cells then
		search_cells = cells
		cost_so_far = table.create(cells, 0)
		came_from = table.create(cells, 0)
		seen = buffer.create(cells * 4)
		settled = buffer.create(cells * 4)
		search_stamp = 0
	end
	search_stamp += 1
	heap.size = 0
	return search_stamp
end

-- The heap a search keeps its cells in, kept from one search to the next like the tables.
local search_heap: Heap = { nodes = {}, keys = {}, size = 0 }

-- The orders that take `def` from `from` to `to`, and whether they get all the way there.
local function find_path(def: EntityDef, from: Vector3, to: Vector3, max_expansions: number?): Path
	if heightmap.in_bounds(from.X, from.Z) == false then
		return { orders = {}, complete = false }
	end
	local ground = ground_for(def)
	local wanted = room_wanted(def)
	local from_point = grid_point(from)
	local start_cx = math.floor(from_point.x)
	local start_cz = math.floor(from_point.z)

	local to_gx, to_gz = heightmap.world_to_grid(to.X, to.Z)
	local goal_cx = math.clamp(math.floor(to_gx), 0, width - 1)
	local goal_cz = math.clamp(math.floor(to_gz), 0, depth - 1)

	local function open(cx: number, cz: number): boolean
		return is_open(ground, cx, cz)
	end

	-- a goal the unit cannot stand on is reached from any open cell no further from it than the nearest one
	local slack = if open(goal_cx, goal_cz) then 0 else nearest_open_distance(ground, goal_cx, goal_cz)
	-- and one inside a building is all the way there once it is at the building's edge
	local walled_goal = def.air == nil and walls.blocked_cell(goal_cx, goal_cz)

	-- cells are numbered from 1 for the arrays below
	local heap = search_heap
	local stamp = begin_search(heap)
	local start = start_cz * width + start_cx + 1
	local goal = goal_cz * width + goal_cx + 1
	buffer.writeu32(seen, (start - 1) * 4, stamp)
	cost_so_far[start] = 0
	came_from[start] = 0
	heap_push(heap, start, estimate(start_cx, start_cz, goal_cx, goal_cz))

	-- the open cell that has come nearest to the goal, in case it cannot be reached
	local nearest = start
	local nearest_distance = estimate(start_cx, start_cz, goal_cx, goal_cz)
	local reached = false
	local last = start
	local expansions = 0

	while heap.size > 0 do
		if max_expansions ~= nil and expansions >= max_expansions then
			break
		end
		local current = heap_pop(heap)
		if buffer.readu32(settled, (current - 1) * 4) == stamp then
			continue
		end
		buffer.writeu32(settled, (current - 1) * 4, stamp)
		expansions += 1

		local cx = (current - 1) % width
		local cz = (current - 1) // width
		local here_open = open(cx, cz)
		if current == goal or (slack > 0 and here_open and estimate(cx, cz, goal_cx, goal_cz) <= slack + 1e-9) then
			reached = true
			last = current
			break
		end

		local cost = cost_so_far[current]
		for _, step in STEPS do
			local next_cx = cx + step[1]
			local next_cz = cz + step[2]
			if next_cx < 0 or next_cx >= width or next_cz < 0 or next_cz >= depth then
				continue
			end
			-- from open ground it keeps to open ground, and does not cut the corner of a cell that is closed; from
			-- ground it cannot stand on it may go anywhere, to get out
			local next_open = open(next_cx, next_cz)
			if here_open then
				if next_open == false then
					continue
				end
				if step[1] ~= 0 and step[2] ~= 0 and (open(next_cx, cz) == false or open(cx, next_cz) == false) then
					continue
				end
			end
			local next_cell = next_cz * width + next_cx + 1
			local step_cost = step[3]
			if next_open == false or is_tight(ground, wanted, next_cx, next_cz) then
				step_cost *= TIGHT_PENALTY
			end
			local next_cost = cost + step_cost
			local known = buffer.readu32(seen, (next_cell - 1) * 4) == stamp
			if known == false or next_cost < cost_so_far[next_cell] then
				buffer.writeu32(seen, (next_cell - 1) * 4, stamp)
				cost_so_far[next_cell] = next_cost
				came_from[next_cell] = current
				local to_go = estimate(next_cx, next_cz, goal_cx, goal_cz)
				if next_open and to_go < nearest_distance then
					nearest = next_cell
					nearest_distance = to_go
				end
				-- among equal totals, the cell nearer the goal comes first, so open ground is not searched
				-- in every direction at once
				heap_push(heap, next_cell, next_cost + to_go * TIE_BREAK)
			end
		end
	end

	-- the cells from the last one back to the start
	if reached == false then
		last = nearest
	end
	local cells: { number } = {}
	local cell = last
	while cell ~= 0 do
		table.insert(cells, cell)
		cell = came_from[cell]
	end
	-- they were gathered from the last back
	for low = 1, #cells // 2 do
		local high = #cells - low + 1
		cells[low], cells[high] = cells[high], cells[low]
	end

	-- the route as points in grid coordinates: where the unit is, the middle of each cell between, and the end
	local points: { Point } = { from_point }
	for at = 2, #cells - 1 do
		points[#points + 1] = { x = (cells[at] - 1) % width + 0.5, z = (cells[at] - 1) // width + 0.5 }
	end
	local in_map = heightmap.in_bounds(to.X, to.Z)
	local exact = reached and last == goal and in_map
	local complete = exact or (reached and walled_goal and in_map)
	if #cells > 1 or exact then
		if exact then
			points[#points + 1] = { x = to_gx, z = to_gz }
		else
			points[#points + 1] = { x = (last - 1) % width + 0.5, z = (last - 1) // width + 0.5 }
		end
	end

	local function roomy(cx: number, cz: number): boolean
		return open(cx, cz) and is_tight(ground, wanted, cx, cz) == false
	end
	local function tight(point: Point): boolean
		return is_tight(ground, wanted, math.floor(point.x), math.floor(point.z))
	end
	local orders: { Order } = {}
	for _, point in pull_tight(open, roomy, tight, points) do
		local x, z = heightmap.grid_to_world(point.x, point.z)
		table.insert(orders, { kind = "move", position = surface.position(def, x, z) })
	end
	return { orders = orders, complete = complete }
end

-- Whether `def` can get from `from` to `to` by going straight there, as a plain move order sends it: every cell the
-- line crosses is open to it, by the same test `find_path` uses, but for those it crosses getting off ground it cannot
-- stand on, if it starts on some, and, going to something inside a building, those of the building. It keeps clear of walls as a route does: the line has to cross only ground with room
-- for the unit, unless one of its ends is in a squeeze itself, when ground it can stand on at all will do. It costs
-- only the cells on the line, so ask it first, send the unit straight when it says yes, and search when it says no.
-- Like `find_path`, only the ground and the buildings on it count.
local function has_straight_path(def: EntityDef, from: Vector3, to: Vector3): boolean
	if heightmap.in_bounds(from.X, from.Z) == false or heightmap.in_bounds(to.X, to.Z) == false then
		return false
	end
	local ground = ground_for(def)
	local wanted = room_wanted(def)
	local from_point = grid_point(from)
	local to_point = grid_point(to)

	local function open(cx: number, cz: number): boolean
		return is_open(ground, cx, cz)
	end
	local function roomy(cx: number, cz: number): boolean
		return open(cx, cz) and is_tight(ground, wanted, cx, cz) == false
	end
	local leaving = open(math.floor(from_point.x), math.floor(from_point.z)) == false
	-- going to something inside a building, it only has to get to the building
	local arriving = if def.air == nil and walls.blocked_cell(math.floor(to_point.x), math.floor(to_point.z))
		then walls.blocked_cell
		else nil
	if has_clear_line(roomy, from_point, to_point, leaving, arriving) then
		return true
	end
	local squeezed = is_tight(ground, wanted, math.floor(from_point.x), math.floor(from_point.z))
		or is_tight(ground, wanted, math.floor(to_point.x), math.floor(to_point.z))
	return squeezed and has_clear_line(open, from_point, to_point, leaving, arriving)
end

-- Whether nothing blocks the straight line from `from` to `to` for `def`: every cell it crosses is ground it can stand
-- on, but for those it crosses getting off ground it cannot, if it starts on some. Unlike `has_straight_path` it does
-- not ask for room to spare, which is
-- only which way is better, so every leg of a route `find_path` gives passes it. What the server checks a route a
-- client sent against (`commands`).
local function has_open_line(def: EntityDef, from: Vector3, to: Vector3): boolean
	if heightmap.in_bounds(from.X, from.Z) == false or heightmap.in_bounds(to.X, to.Z) == false then
		return false
	end
	local ground = ground_for(def)
	local from_point = grid_point(from)
	local leaving = is_open(ground, math.floor(from_point.x), math.floor(from_point.z)) == false
	return has_clear_line(function(cx: number, cz: number): boolean
		return is_open(ground, cx, cz)
	end, from_point, grid_point(to), leaving)
end

-- The way `def` goes from `from` to `to`, and whether working it out took a search: one move straight there when it can
-- go straight (`has_straight_path`), which is nearly free and counts as getting all the way, and otherwise the route
-- `find_path` finds within `max_expansions`, which stops at the nearest place it can reach if it cannot reach `to`
-- (none at all if it gets nowhere). An aircraft flies over whatever is in the way, and always goes straight. Where a
-- search is wanted, `may_search` (if given) is asked first, and with its no there is no way (nil): what may only have so
-- many routes a step (server/paths.luau) asks this way.
local function plan(
	def: EntityDef,
	from: Vector3,
	to: Vector3,
	max_expansions: number?,
	may_search: (() -> boolean)?
): (Path?, boolean)
	local destination = surface.position(def, to.X, to.Z)
	if def.air ~= nil or has_straight_path(def, from, destination) then
		return { orders = { { kind = "move", position = destination } }, complete = true }, false
	end
	if may_search ~= nil and may_search() == false then
		return nil, false
	end
	return find_path(def, from, destination, max_expansions), true
end

-- The move orders that take `def` from `from` to `to` (`plan`), and whether working them out took a search. There is
-- always at least one order, so a move given this way always replaces what the unit was doing: straight at `to` when
-- the search got nowhere.
local function route(def: EntityDef, from: Vector3, to: Vector3, max_expansions: number?): ({ Order }, boolean)
	local path, searched = plan(def, from, to, max_expansions)
	local orders = (path :: Path).orders
	if #orders == 0 then
		return { { kind = "move", position = surface.position(def, to.X, to.Z) } }, searched
	end
	return orders, searched
end

-- The waypoints something of `def` at `from` walks through on its way to within `reach` of `to`, before the order that
-- takes it there walks the rest: none when it can go straight, and otherwise the route round what is in the way, up to
-- where `to` comes into reach. None either when `to` is in reach already, or comes into reach on the straight way to it,
-- however far round the way to `to` itself is: a builder at the foot of a cliff builds on top of it from where it
-- stands, and does not walk round to the ramp. The client works these out for every unit it gives an order to and sends
-- them with it, so that the way a unit goes is the line the player sees; the server only checks them (`commands`).
-- With `may_search` saying no to the search it would take (`plan`), nil.
local function waypoints_to(
	def: EntityDef,
	from: Vector3,
	to: Vector3,
	reach: number,
	max_expansions: number?,
	may_search: (() -> boolean)?
): { Vector3 }?
	local offset = Vector2.new(from.X - to.X, from.Z - to.Z)
	local distance = offset.Magnitude
	if distance <= reach then
		return {}
	end
	if reach > 0 then
		-- where the order, walking straight at `to`, stops
		local stop = offset * (reach / distance)
		if has_straight_path(def, from, Vector3.new(to.X + stop.X, to.Y, to.Z + stop.Y)) then
			return {}
		end
	end
	local path = plan(def, from, to, max_expansions, may_search)
	if path == nil then
		return nil
	end
	local points: { Vector3 } = {}
	for _, step in path.orders do
		if step.position ~= nil then
			table.insert(points, step.position)
		end
	end
	-- the last is where the order itself goes, and those before it that are already in reach are not needed
	table.remove(points)
	while #points > 0 and Vector2.new(points[#points].X - to.X, points[#points].Z - to.Z).Magnitude <= reach do
		table.remove(points)
	end
	return points
end

return table.freeze({
	MAX_EXPANSIONS = MAX_EXPANSIONS,
	open_at = open_at,
	find_path = find_path,
	has_straight_path = has_straight_path,
	has_open_line = has_open_line,
	plan = plan,
	route = route,
	waypoints_to = waypoints_to,
	refresh = refresh,
	reset = reset,
})
