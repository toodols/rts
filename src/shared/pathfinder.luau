-- Finds a route for a unit to a destination and gives it back as the orders that drive it there: a chain of
-- `move` orders, which the order system walks through without slowing at every waypoint. It is pure: it reads
-- the ground and changes nothing, so an AI decides when to use it, and gives the result to `orders.issue`.
--
-- The search is A* over the cells of the heightmap, eight ways, with the cost of a diagonal step the square
-- root of two. A cell is open to a unit when its slope class can stand on it (`passability`) and the water over
-- it is the right depth for the def, and a diagonal step needs both cells it squeezes between to be open, so a
-- route never cuts a corner. The unit's own cell is always open, so one that has been pushed onto ground it
-- cannot stand on can still get out. The route of cells is then pulled tight: from each waypoint the search
-- looks ahead to the furthest point it can see in a straight line across open cells and goes there directly,
-- so the orders are the few turns the route really needs and not one for every cell.
--
-- A destination that cannot be reached gets the route to the reachable cell that is nearest to it, and
-- `complete` says it is not all the way there. So does a search that is stopped by `max_expansions`, the most
-- cells it will settle before giving up: a goal with no route otherwise searches every cell that can be reached,
-- which on a big map takes long enough to stall a step, and it is for the caller to say how long it can spare. Only the ground counts: other units and buildings are not
-- avoided, and how wide the unit is does not matter, exactly as in `movement`.

local ReplicatedStorage = game:GetService "ReplicatedStorage"

local types = require(ReplicatedStorage.Shared.types)
local config = require(ReplicatedStorage.Shared.config)
local heightmap = require(ReplicatedStorage.Shared.heightmap)
local passability = require(ReplicatedStorage.Shared.passability)
local unit_defs = require(ReplicatedStorage.Shared.unit_defs)

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

local WIDTH = config.MAP_CELLS_X
local DEPTH = config.MAP_CELLS_Z
local DIAGONAL = math.sqrt(2)
-- Weighs the estimate a hair over its true size. Small enough that a route is never longer than the best by
-- more than a thousandth of itself.
local TIE_BREAK = 1.001

-- What is known about a cell so far, kept for the length of one search.
local UNKNOWN = 0
local OPEN = 1
local BLOCKED = 2

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

-- A function that says whether a cell is open to `def`, working each cell out once. The cell the unit starts in
-- is open whatever the ground there is like.
local function make_open_test(def: EntityDef, start_cx: number, start_cz: number): (number, number) -> boolean
	local slope_map = passability.map_for(def.slope_class)
	local known = buffer.create(WIDTH * DEPTH)
	buffer.writeu8(known, start_cz * WIDTH + start_cx, OPEN)

	return function(cx: number, cz: number): boolean
		if cx < 0 or cx >= WIDTH or cz < 0 or cz >= DEPTH then
			return false
		end
		local at = cz * WIDTH + cx
		local cached = buffer.readu8(known, at)
		if cached ~= UNKNOWN then
			return cached == OPEN
		end

		local open = slope_map == nil or buffer.readu8(slope_map.cells, at) == 1
		if open then
			-- the ground over the cell is a blend of its corners, so no point in it is higher or lower than
			-- they are: the cell is open only if the water is right at all four
			local lowest_ground = math.huge
			local highest_ground = -math.huge
			for corner_z = cz, cz + 1 do
				for corner_x = cx, cx + 1 do
					local ground = heightmap.sample(corner_x, corner_z)
					lowest_ground = math.min(lowest_ground, ground)
					highest_ground = math.max(highest_ground, ground)
				end
			end
			open = unit_defs.tolerates_water(
				def,
				math.max(0, config.WATER_LEVEL - highest_ground),
				math.max(0, config.WATER_LEVEL - lowest_ground)
			)
		end
		buffer.writeu8(known, at, if open then OPEN else BLOCKED)
		return open
	end
end

-- Whether the straight line from one point to another, in grid coordinates, crosses only open cells. It visits
-- every cell the line passes through; where it goes exactly through a corner, both cells beside that corner
-- have to be open as well.
local function has_clear_line(is_open: (number, number) -> boolean, from: Point, to: Point): boolean
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

	for _ = 1, math.abs(end_cx - cx) + math.abs(end_cz - cz) + 1 do
		if cx == end_cx and cz == end_cz then
			return true
		end
		if math.abs(reach_x - reach_z) < 1e-9 then
			if is_open(cx + step_x, cz) == false or is_open(cx, cz + step_z) == false then
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
		if is_open(cx, cz) == false then
			return false
		end
	end
	return true
end

-- Pulls a route tight. From each point it goes on to the furthest later point that can be seen from it in a
-- straight line, and drops all the points between.
local function pull_tight(is_open: (number, number) -> boolean, points: { Point }): { Point }
	local kept: { Point } = {}
	local at = 1
	while at < #points do
		local furthest = at + 1
		while furthest < #points and has_clear_line(is_open, points[at], points[furthest + 1]) do
			furthest += 1
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

-- The orders that take `def` from `from` to `to`, and whether they get all the way there.
local function find_path(def: EntityDef, from: Vector3, to: Vector3, max_expansions: number?): Path
	local from_gx, from_gz = heightmap.world_to_grid(from.X, from.Z)
	local start_cx = math.floor(from_gx)
	local start_cz = math.floor(from_gz)
	if heightmap.in_bounds(from.X, from.Z) == false then
		return { orders = {}, complete = false }
	end
	start_cx = math.min(start_cx, WIDTH - 1)
	start_cz = math.min(start_cz, DEPTH - 1)

	local to_gx, to_gz = heightmap.world_to_grid(to.X, to.Z)
	local goal_cx = math.clamp(math.floor(to_gx), 0, WIDTH - 1)
	local goal_cz = math.clamp(math.floor(to_gz), 0, DEPTH - 1)

	local is_open = make_open_test(def, start_cx, start_cz)

	-- cells are numbered from 1 for the arrays below
	local start = start_cz * WIDTH + start_cx + 1
	local goal = goal_cz * WIDTH + goal_cx + 1
	local cost_so_far = table.create(WIDTH * DEPTH, math.huge)
	local came_from = table.create(WIDTH * DEPTH, 0)
	local closed = buffer.create(WIDTH * DEPTH)

	local heap: Heap = { nodes = {}, keys = {}, size = 0 }
	cost_so_far[start] = 0
	heap_push(heap, start, estimate(start_cx, start_cz, goal_cx, goal_cz))

	-- the cell that has come nearest to the goal, in case it cannot be reached
	local nearest = start
	local nearest_distance = estimate(start_cx, start_cz, goal_cx, goal_cz)
	local reached = false
	local expansions = 0

	while heap.size > 0 do
		if max_expansions ~= nil and expansions >= max_expansions then
			break
		end
		local current = heap_pop(heap)
		if buffer.readu8(closed, current - 1) == 1 then
			continue
		end
		buffer.writeu8(closed, current - 1, 1)
		expansions += 1
		if current == goal then
			reached = true
			break
		end

		local cx = (current - 1) % WIDTH
		local cz = (current - 1) // WIDTH
		local cost = cost_so_far[current]
		for _, step in STEPS do
			local next_cx = cx + step[1]
			local next_cz = cz + step[2]
			if is_open(next_cx, next_cz) == false then
				continue
			end
			-- a diagonal step may not cut the corner of a cell that is closed
			if step[1] ~= 0 and step[2] ~= 0 and (is_open(next_cx, cz) == false or is_open(cx, next_cz) == false) then
				continue
			end
			local next_cell = next_cz * WIDTH + next_cx + 1
			local next_cost = cost + step[3]
			if next_cost < cost_so_far[next_cell] then
				cost_so_far[next_cell] = next_cost
				came_from[next_cell] = current
				local to_go = estimate(next_cx, next_cz, goal_cx, goal_cz)
				if to_go < nearest_distance then
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
	local last = if reached then goal else nearest
	local cells: { number } = {}
	local cell = last
	while cell ~= 0 do
		table.insert(cells, 1, cell)
		cell = came_from[cell]
	end

	-- the route as points in grid coordinates: where the unit is, the middle of each cell between, and the end
	local points: { Point } = { { x = from_gx, z = from_gz } }
	for at = 2, #cells - 1 do
		points[#points + 1] = { x = (cells[at] - 1) % WIDTH + 0.5, z = (cells[at] - 1) // WIDTH + 0.5 }
	end
	local complete = reached and heightmap.in_bounds(to.X, to.Z)
	if #cells > 1 or reached then
		if complete then
			points[#points + 1] = { x = to_gx, z = to_gz }
		else
			points[#points + 1] = { x = (last - 1) % WIDTH + 0.5, z = (last - 1) // WIDTH + 0.5 }
		end
	end

	local orders: { Order } = {}
	for _, point in pull_tight(is_open, points) do
		local x, z = heightmap.grid_to_world(point.x, point.z)
		table.insert(orders, { kind = "move", position = unit_defs.surface_position(def, x, z) })
	end
	return { orders = orders, complete = complete }
end

return table.freeze({
	find_path = find_path,
})
