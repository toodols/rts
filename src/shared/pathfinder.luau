-- Finds a route for a unit to a destination and gives it back as the orders that drive it there: a chain of
-- `move` orders. It is pure apart from the caches below: it reads the ground and changes nothing, so whoever gives a
-- unit somewhere to go (a player's order, laid ahead of it as waypoints the player can see, a factory's rally, the
-- scavengers) decides when to use it. Nothing works out a way while a unit walks: it follows the waypoints it has. `route` is what a move uses: it goes straight when the line is
-- good (`has_straight_path`) and searches only when it is not.
--
-- The search is A* over the cells of the heightmap, eight ways, with the cost of a diagonal step the square root of
-- two. A cell is open to a unit when its slope class can stand on it (`passability`) and the water over it is the
-- right depth for the def, and a diagonal step needs both cells it squeezes between to be open, so a route never
-- cuts a corner. The unit's own cell is always open, so one that has been pushed onto ground it cannot stand on can
-- still get out.
--
-- A route keeps clear of walls where it can, and squeezes past them where it cannot. A cell is tight for a unit when
-- it is nearer the nearest cell the unit cannot stand on (or the map's edge) than the unit's radius and WALL_MARGIN
-- allow; stepping into one costs TIGHT_PENALTY times over, so the search goes round by open ground unless that is a
-- good deal further, and only then through the gap. The route of cells is then pulled tight: from each point it goes
-- straight to the furthest later point it can see across ground that is not tight, so the orders are the few turns
-- the route really needs. Inside a squeeze, where no such line exists, it goes from point to point along the gap.
--
-- A destination that cannot be reached gets the route to the reachable cell that is nearest to it, and `complete`
-- says it is not all the way there. So does a search that is stopped by `max_expansions`, the most cells it will
-- settle before giving up. Other units and buildings are not part of it: only the ground counts.
--
-- Which cells are open to each kind of unit, and how far each is from the nearest that is not, is worked out once for
-- the whole map the first time a kind of unit asks, and kept; `refresh` works a region of it out again when the ground
-- there changes, as it does under a crater. Kinds of unit that stand on the same ground share: the same slope class
-- and the same water limits.

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

-- What a kind of unit can stand on: `open` is a byte a cell, 1 where it can stand and 0 where it cannot, and
-- `clearance` a byte a cell, how many cells away the nearest one it cannot stand on is (0 for one it cannot stand on
-- itself, 1 beside one, and so on up to MAX_CLEARANCE), counting diagonals as one and the map's edge as a wall.
type Ground = {
	def: EntityDef,
	open: buffer,
	clearance: buffer,
}

-- The map's size in cells, taken from the heightmap by `reset` whenever a map is built, since maps are not all the
-- same size.
local width = config.MAP_CELLS_X
local depth = config.MAP_CELLS_Z
local CELL_STUDS = config.CELL_STUDS
local DIAGONAL = math.sqrt(2)
-- Weighs the estimate a hair over its true size. Small enough that a route is never longer than the best by
-- more than a thousandth of itself.
local TIE_BREAK = 1.001
-- How much room, in studs, a unit likes to keep between its body and a wall, over and above its radius: enough that
-- being shoved by its neighbours, or running on a little past a waypoint, does not put it into one.
local WALL_MARGIN = 1.5
-- Stepping into a tight cell costs this many times what stepping into one with room does.
local TIGHT_PENALTY = 4
-- Clearance is counted no further than this many cells, which is room enough for the widest thing that walks.
local MAX_CLEARANCE = 4

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

-- Each kind of ground worked out so far, by `ground_key`.
local grounds: { [string]: Ground } = {}

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

-- Whether cell (cx, cz), which is on the map, is open to `def`: its slope class can stand on it, by `slope_map`
-- (nil for one that can stand anywhere), and the water over it is the right depth.
local function cell_open(def: EntityDef, slope_map: passability.PassabilityMap?, cx: number, cz: number): boolean
	if slope_map ~= nil and buffer.readu8(slope_map.cells, cz * width + cx) ~= 1 then
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
		math.max(0, config.WATER_LEVEL - highest_ground),
		math.max(0, config.WATER_LEVEL - lowest_ground)
	)
end

-- Kinds of unit that stand on the same ground share its maps.
local function ground_key(def: EntityDef): string
	return `{def.slope_class or ""}|{def.min_water_depth or 0}|{def.max_water_depth}`
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
	local slope_map = passability.map_for(ground.def.slope_class)
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
	local key = ground_key(def)
	local ground = grounds[key]
	if ground == nil then
		ground = { def = def, open = buffer.create(width * depth), clearance = buffer.create(width * depth) }
		fill(ground, 0, 0, width - 1, depth - 1)
		grounds[key] = ground
	end
	return ground
end

-- Works out again the cells from (first_cx, first_cz) to (last_cx, last_cz), inclusive, for every kind of ground
-- worked out so far. Call it whenever the ground there changes, after `passability.refresh`.
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
end

-- How many cells of room `def` wants round it: its radius and WALL_MARGIN, from the middle of its cell.
local function room_wanted(def: EntityDef): number
	local cells = math.ceil((unit_defs.collider_radius(def) + WALL_MARGIN) / CELL_STUDS + 0.5)
	return math.clamp(cells, 1, MAX_CLEARANCE)
end

-- Whether a cell is on the map and open to the ground's unit; `start` is a cell that counts as open whatever it is,
-- the one a unit is in, as a number from 0 (-1 for none).
local function is_open(ground: Ground, start: number, cx: number, cz: number): boolean
	if cx < 0 or cx >= width or cz < 0 or cz >= depth then
		return false
	end
	local at = cz * width + cx
	return at == start or buffer.readu8(ground.open, at) == 1
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
-- corner, both cells beside that corner have to pass as well.
local function has_clear_line(passes: (number, number) -> boolean, from: Point, to: Point): boolean
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
			if passes(cx + step_x, cz) == false or passes(cx, cz + step_z) == false then
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
		if passes(cx, cz) == false then
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
		local furthest = at
		while furthest < #points and has_clear_line(roomy, points[at], points[furthest + 1]) do
			furthest += 1
		end
		if furthest == at then
			furthest = at + 1
			while
				furthest < #points
				and tight(points[furthest])
				and has_clear_line(open, points[at], points[furthest + 1])
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
	local start_at = start_cz * width + start_cx

	local to_gx, to_gz = heightmap.world_to_grid(to.X, to.Z)
	local goal_cx = math.clamp(math.floor(to_gx), 0, width - 1)
	local goal_cz = math.clamp(math.floor(to_gz), 0, depth - 1)

	local function open(cx: number, cz: number): boolean
		return is_open(ground, start_at, cx, cz)
	end

	-- cells are numbered from 1 for the arrays below
	local start = start_at + 1
	local goal = goal_cz * width + goal_cx + 1
	local cost_so_far = table.create(width * depth, math.huge)
	local came_from = table.create(width * depth, 0)
	local closed = buffer.create(width * depth)

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

		local cx = (current - 1) % width
		local cz = (current - 1) // width
		local cost = cost_so_far[current]
		for _, step in STEPS do
			local next_cx = cx + step[1]
			local next_cz = cz + step[2]
			if open(next_cx, next_cz) == false then
				continue
			end
			-- a diagonal step may not cut the corner of a cell that is closed
			if step[1] ~= 0 and step[2] ~= 0 and (open(next_cx, cz) == false or open(cx, next_cz) == false) then
				continue
			end
			local next_cell = next_cz * width + next_cx + 1
			local step_cost = step[3]
			if is_tight(ground, wanted, next_cx, next_cz) then
				step_cost *= TIGHT_PENALTY
			end
			local next_cost = cost + step_cost
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
	local points: { Point } = { from_point }
	for at = 2, #cells - 1 do
		points[#points + 1] = { x = (cells[at] - 1) % width + 0.5, z = (cells[at] - 1) // width + 0.5 }
	end
	local complete = reached and heightmap.in_bounds(to.X, to.Z)
	if #cells > 1 or reached then
		if complete then
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
		table.insert(orders, { kind = "move", position = unit_defs.surface_position(def, x, z) })
	end
	return { orders = orders, complete = complete }
end

-- Whether `def` can get from `from` to `to` by going straight there, as a plain move order sends it: every cell the
-- line crosses is open to it, by the same test `find_path` uses, and the cell it starts in counts as open. It keeps
-- clear of walls as a route does: the line has to cross only ground with room for the unit, unless one of its ends is
-- in a squeeze itself, when ground it can stand on at all will do. It costs only the cells on the line, so ask it
-- first, send the unit straight when it says yes, and search when it says no. Like `find_path`, only the ground
-- counts.
local function has_straight_path(def: EntityDef, from: Vector3, to: Vector3): boolean
	if heightmap.in_bounds(from.X, from.Z) == false or heightmap.in_bounds(to.X, to.Z) == false then
		return false
	end
	local ground = ground_for(def)
	local wanted = room_wanted(def)
	local from_point = grid_point(from)
	local to_point = grid_point(to)
	local start = math.floor(from_point.z) * width + math.floor(from_point.x)

	local function open(cx: number, cz: number): boolean
		return is_open(ground, start, cx, cz)
	end
	local function roomy(cx: number, cz: number): boolean
		return open(cx, cz) and is_tight(ground, wanted, cx, cz) == false
	end
	if has_clear_line(roomy, from_point, to_point) then
		return true
	end
	local squeezed = is_tight(ground, wanted, math.floor(from_point.x), math.floor(from_point.z))
		or is_tight(ground, wanted, math.floor(to_point.x), math.floor(to_point.z))
	return squeezed and has_clear_line(open, from_point, to_point)
end

-- Whether nothing blocks the straight line from `from` to `to` for `def`: every cell it crosses is ground it can stand
-- on, and the cell it starts in counts as that. Unlike `has_straight_path` it does not ask for room to spare, which is
-- only which way is better, so every leg of a route `find_path` gives passes it. What the server checks a route a
-- client sent against (`commands`).
local function has_open_line(def: EntityDef, from: Vector3, to: Vector3): boolean
	if heightmap.in_bounds(from.X, from.Z) == false or heightmap.in_bounds(to.X, to.Z) == false then
		return false
	end
	local ground = ground_for(def)
	local from_point = grid_point(from)
	local start = math.floor(from_point.z) * width + math.floor(from_point.x)
	return has_clear_line(function(cx: number, cz: number): boolean
		return is_open(ground, start, cx, cz)
	end, from_point, grid_point(to))
end

-- The move orders that take `def` from `from` to `to`, and whether working them out took a search: one move straight
-- there when it can go straight (`has_straight_path`), which is nearly free, and otherwise the route `find_path`
-- finds within `max_expansions`, which stops at the nearest place it can reach if it cannot reach `to`. An aircraft
-- flies over whatever is in the way, and always goes straight. There is always at least one order, so a move given
-- this way always replaces what the unit was doing.
local function route(def: EntityDef, from: Vector3, to: Vector3, max_expansions: number?): ({ Order }, boolean)
	local destination = unit_defs.surface_position(def, to.X, to.Z)
	local straight: { Order } = { { kind = "move", position = destination } }
	if def.air ~= nil or has_straight_path(def, from, destination) then
		return straight, false
	end
	local path = find_path(def, from, destination, max_expansions)
	if #path.orders == 0 then
		return straight, true
	end
	return path.orders, true
end

-- The waypoints something of `def` at `from` walks through on its way to within `reach` of `to`, before the order that
-- takes it there walks the rest: none when it can go straight, and otherwise the route round what is in the way, up to
-- where `to` comes into reach. None either when `to` is in reach already, or comes into reach on the straight way to it,
-- however far round the way to `to` itself is: a builder at the foot of a cliff builds on top of it from where it
-- stands, and does not walk round to the ramp. The client works these out for every unit it gives an order to and sends
-- them with it, so that the way a unit goes is the line the player sees; the server only checks them (`commands`).
local function waypoints_to(
	def: EntityDef,
	from: Vector3,
	to: Vector3,
	reach: number,
	max_expansions: number?
): { Vector3 }
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
	local steps = route(def, from, to, max_expansions)
	local points: { Vector3 } = {}
	for _, step in steps do
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
	find_path = find_path,
	has_straight_path = has_straight_path,
	has_open_line = has_open_line,
	route = route,
	waypoints_to = waypoints_to,
	refresh = refresh,
	reset = reset,
})
