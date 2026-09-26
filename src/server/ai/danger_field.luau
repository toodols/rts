--!strict
-- The danger field: how dangerous each part of the map is to a team, from where its enemies' weapons reach, as far as
-- it knows of them (census.luau). The AI (init.luau) keeps one for every team it plays, and reads it before it sends
-- anything anywhere: a builder only goes to
-- build, and a rezbot to raise a wreck, where the field is quiet, and an army only attacks where what it would face
-- is less than what it has.
--
-- The map is cut into square cells, CELL_STUDS across. Every armed enemy adds its worth (`unit_defs.power`) to every
-- cell its weapons can reach, and a little further for one that moves, since it may be somewhere else a moment later;
-- from the edge of its reach its share fades out over its margin. Only what can be turned on the ground counts, so the
-- danger is what a builder or a tank walking there would face; of the enemy's aircraft only how many are up is kept.
--
-- The field remembers. At every refresh a cell keeps what it had, faded by MEMORY, when that is more than what stands
-- there now, so a raid that has just moved on still leaves the ground it crossed marked for a little while.

local ReplicatedStorage = game:GetService "ReplicatedStorage"

local types = require(ReplicatedStorage.Shared.types)
local unit_defs = require(ReplicatedStorage.Shared.unit_defs)
local heightmap = require(ReplicatedStorage.Shared.heightmap)

type Entity = types.Entity

export type Field = {
	cells_x: number,
	cells_z: number,
	origin_x: number,
	origin_z: number,
	-- the danger to what is on the ground, cell by cell, x fastest
	ground: { number },
	-- what this refresh stamped, before it was merged with what the field remembers
	scratch: { number },
	-- how many of the enemy's aircraft are up
	enemy_air_count: number,
}

local CELL_STUDS = 16
-- What a cell keeps of its danger from one refresh to the next, when nothing stands over it any more.
local MEMORY = 0.8
-- How far past its weapons' reach something that moves is counted as a danger, and something that does not.
local MOBILE_MARGIN = 20
local STATIC_MARGIN = 4
-- An aircraft goes where it likes, quickly, so it threatens a good way round where it is.
local AIR_MARGIN = 40

local function blank(count: number): { number }
	return table.create(count, 0)
end

-- How many cells across and down a field of the map as it is now has, and where its corner is.
local function layout(): (number, number, number, number)
	local half_x, half_z = heightmap.half_extents()
	local cells_x = math.max(1, math.ceil(half_x * 2 / CELL_STUDS))
	local cells_z = math.max(1, math.ceil(half_z * 2 / CELL_STUDS))
	return cells_x, cells_z, -half_x, -half_z
end

-- A field as big as the map is now, with nothing in it yet.
local function new(): Field
	local cells_x, cells_z, origin_x, origin_z = layout()
	local count = cells_x * cells_z
	return {
		cells_x = cells_x,
		cells_z = cells_z,
		origin_x = origin_x,
		origin_z = origin_z,
		ground = blank(count),
		scratch = blank(count),
		enemy_air_count = 0,
	}
end

-- Whether the field was made for the map as it is now: a new map can be another size.
local function fits_map(field: Field): boolean
	local cells_x, cells_z, origin_x, origin_z = layout()
	return field.cells_x == cells_x
		and field.cells_z == cells_z
		and field.origin_x == origin_x
		and field.origin_z == origin_z
end

-- Adds `worth` to every cell of `cells` within `reach` of (x, z), fading to nothing over `margin` beyond it.
local function stamp(
	field: Field,
	cells: { number },
	x: number,
	z: number,
	reach: number,
	margin: number,
	worth: number
)
	local outer = reach + margin
	local first_x = math.max(0, math.floor((x - outer - field.origin_x) / CELL_STUDS))
	local last_x = math.min(field.cells_x - 1, math.floor((x + outer - field.origin_x) / CELL_STUDS))
	local first_z = math.max(0, math.floor((z - outer - field.origin_z) / CELL_STUDS))
	local last_z = math.min(field.cells_z - 1, math.floor((z + outer - field.origin_z) / CELL_STUDS))
	for cz = first_z, last_z do
		local center_z = field.origin_z + (cz + 0.5) * CELL_STUDS
		local row = cz * field.cells_x
		for cx = first_x, last_x do
			local center_x = field.origin_x + (cx + 0.5) * CELL_STUDS
			local distance = math.sqrt((center_x - x) ^ 2 + (center_z - z) ^ 2)
			if distance <= reach then
				cells[row + cx + 1] += worth
			elseif distance < outer then
				cells[row + cx + 1] += worth * (1 - (distance - reach) / margin)
			end
		end
	end
end

-- Works the field out again from where `enemies`, everything of the enemy's it knows of, stand now, keeping what it
-- remembers.
local function refresh(field: Field, enemies: { Entity })
	local scratch = field.scratch
	local count = field.cells_x * field.cells_z
	for index = 1, count do
		scratch[index] = 0
	end

	local air_count = 0
	for _, other in enemies do
		local def = other.def
		if unit_defs.is_air(def) then
			air_count += 1
		end
		local ground_reach = unit_defs.reaches(def)
		if ground_reach == nil then
			continue
		end
		local margin = if unit_defs.is_air(def)
			then AIR_MARGIN
			elseif def.max_speed ~= nil then MOBILE_MARGIN
			else STATIC_MARGIN
		stamp(field, scratch, other.position.X, other.position.Z, ground_reach, margin, unit_defs.power(def))
	end

	local ground = field.ground
	for index = 1, count do
		ground[index] = math.max(scratch[index], ground[index] * MEMORY)
	end
	field.enemy_air_count = air_count
end

local function index_at(field: Field, x: number, z: number): number?
	local cx = math.floor((x - field.origin_x) / CELL_STUDS)
	local cz = math.floor((z - field.origin_z) / CELL_STUDS)
	if cx < 0 or cz < 0 or cx >= field.cells_x or cz >= field.cells_z then
		return nil
	end
	return cz * field.cells_x + cx + 1
end

-- The danger to something on the ground at `position`.
local function at(field: Field, position: Vector3): number
	local index = index_at(field, position.X, position.Z)
	if index == nil then
		return 0
	end
	return field.ground[index]
end

-- The most danger anywhere within `radius` of `position`, on the ground.
local function peak_near(field: Field, position: Vector3, radius: number): number
	local peak = 0
	local steps = math.ceil(radius / CELL_STUDS)
	for dz = -steps, steps do
		for dx = -steps, steps do
			local x = position.X + dx * CELL_STUDS
			local z = position.Z + dz * CELL_STUDS
			if (dx * dx + dz * dz) * CELL_STUDS * CELL_STUDS > radius * radius + CELL_STUDS * CELL_STUDS then
				continue
			end
			local index = index_at(field, x, z)
			if index ~= nil then
				peak = math.max(peak, field.ground[index])
			end
		end
	end
	return peak
end

-- The most danger on the ground anywhere along the straight line from `from` to `to`.
local function peak_along(field: Field, from: Vector3, to: Vector3): number
	local offset = Vector2.new(to.X - from.X, to.Z - from.Z)
	local samples = math.max(1, math.ceil(offset.Magnitude / (CELL_STUDS / 2)))
	local peak = 0
	for sample = 0, samples do
		local t = sample / samples
		local index = index_at(field, from.X + offset.X * t, from.Z + offset.Y * t)
		if index ~= nil then
			peak = math.max(peak, field.ground[index])
		end
	end
	return peak
end

return table.freeze({
	CELL_STUDS = CELL_STUDS,
	new = new,
	fits_map = fits_map,
	refresh = refresh,
	at = at,
	peak_near = peak_near,
	peak_along = peak_along,
})
