--!native
-- A flat (X, Z) grid of circles, for asking "what is near here" of thousands of things a tick without
-- testing all of them.
--
-- It is a handful of flat per-field arrays filled by a counting sort - count entries per cell,
-- prefix-sum the counts, drop each entry's index into one flat array - so rebuilding it allocates
-- nothing, and whoever reads it reads plain numbers rather than fields off entity tables. Only the
-- cells in use are ever touched, so empty stretches of map cost nothing.
--
-- Callers keep any extra per-entry fields they need in their own arrays, indexed by what `add` returns.

export type Grid = {
	-- cell width in studs, and cells per side before the coordinates wrap round - wrapping only ever
	-- puts far-off entries into the same cell as near ones, which costs a distance check, never a miss
	size: number,
	side: number,
	count: number,
	xs: { number },
	zs: { number },
	rs: { number },
	cell: { number },
	-- entries per cell while sorting, then each cell's fill cursor
	counts: { number },
	-- each cell's entries are order[starts[c]] up to order[stops[c] - 1]; both zero for an empty cell
	starts: { number },
	stops: { number },
	order: { number },
	-- the cells holding anything, so a rebuild touches only those and not every cell there is
	used: { number },
	used_count: number,
}

local function new(size: number, side: number): Grid
	return {
		size = size,
		side = side,
		count = 0,
		xs = {},
		zs = {},
		rs = {},
		cell = {},
		counts = table.create(side * side, 0),
		starts = table.create(side * side, 0),
		stops = table.create(side * side, 0),
		order = {},
		used = {},
		used_count = 0,
	}
end

-- Empties it for refilling. Nothing is freed; the arrays are overwritten as entries are added again.
local function clear(grid: Grid)
	grid.count = 0
end

-- Adds a circle and returns its index, which is also where any of the caller's own fields for it go.
local function add(grid: Grid, x: number, z: number, radius: number): number
	local k = grid.count + 1
	grid.count = k
	grid.xs[k] = x
	grid.zs[k] = z
	grid.rs[k] = radius
	return k
end

-- Which cell index (x, z) falls in, from the cell's integer coordinates.
local function cell_index(grid: Grid, gx: number, gz: number): number
	local side = grid.side
	return (gz % side) * side + (gx % side) + 1
end

-- Lays entries out by cell, after everything has been added and before anything is read. How cells are
-- laid out relative to each other doesn't matter, only that each cell's entries are contiguous.
local function sort(grid: Grid)
	local size, side = grid.size, grid.side
	local xs, zs, cell, counts, starts, stops, order, used =
		grid.xs, grid.zs, grid.cell, grid.counts, grid.starts, grid.stops, grid.order, grid.used
	for u = 1, grid.used_count do
		local c = used[u]
		counts[c] = 0
		starts[c] = 0
		stops[c] = 0
	end
	local used_count = 0
	for k = 1, grid.count do
		local c = (math.floor(zs[k] / size) % side) * side + (math.floor(xs[k] / size) % side) + 1
		cell[k] = c
		if counts[c] == 0 then
			used_count += 1
			used[used_count] = c
		end
		counts[c] += 1
	end
	grid.used_count = used_count
	local sum = 1
	for u = 1, used_count do
		local c = used[u]
		starts[c] = sum
		sum += counts[c]
		stops[c] = sum
		counts[c] = starts[c]
	end
	for k = 1, grid.count do
		local c = cell[k]
		order[counts[c]] = k
		counts[c] += 1
	end
end

return table.freeze({
	new = new,
	clear = clear,
	add = add,
	cell_index = cell_index,
	sort = sort,
})
