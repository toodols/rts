-- The danger field: how dangerous each part of the map is to a team, from where its enemies' weapons reach. The AI
-- (ai.luau) keeps one for every team it plays, and reads it before it sends anything anywhere: a builder only goes to
-- build, and a rezbot to raise a wreck, where the field is quiet, and an army only attacks where what it would face
-- is less than what it has.
--
-- The map is cut into square cells, CELL_STUDS across. Every armed enemy adds its worth (`unit_defs.power`) to every
-- cell its weapons can reach, and a little further for one that moves, since it may be somewhere else a moment later;
-- from the edge of its reach its share fades out over its margin. What can only shoot at aircraft goes on a layer of
-- its own, so the ground's danger is what a builder or a tank walking there would face.
--
-- The field remembers. At every refresh a cell keeps what it had, faded by MEMORY, when that is more than what stands
-- there now, so a raid that has just moved on still leaves the ground it crossed marked for a little while.

local ReplicatedStorage = game:GetService "ReplicatedStorage"

local types = require(ReplicatedStorage.Shared.types)
local unit_defs = require(ReplicatedStorage.Shared.unit_defs)
local heightmap = require(ReplicatedStorage.Shared.heightmap)

local state = require(script.Parent.state)
local alliances = require(script.Parent.alliances)

type Entity = types.Entity
type EntityDef = types.EntityDef
type TeamId = types.TeamId
type Weapon = types.Weapon

export type Field = {
	team: TeamId,
	cells_x: number,
	cells_z: number,
	origin_x: number,
	origin_z: number,
	-- the danger to what is on the ground, and to what flies, cell by cell, x fastest
	ground: { number },
	air: { number },
	-- what this refresh stamped, before it was merged with what the field remembers
	scratch_ground: { number },
	scratch_air: { number },
	-- the enemy's aircraft: how many are up, and what they are worth
	enemy_air_count: number,
	enemy_air_power: number,
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

-- A field for `team`, as big as the map is now, with nothing in it yet.
local function new(team: TeamId): Field
	local half_x, half_z = heightmap.half_extents()
	local cells_x = math.max(1, math.ceil(half_x * 2 / CELL_STUDS))
	local cells_z = math.max(1, math.ceil(half_z * 2 / CELL_STUDS))
	local count = cells_x * cells_z
	return {
		team = team,
		cells_x = cells_x,
		cells_z = cells_z,
		origin_x = -half_x,
		origin_z = -half_z,
		ground = blank(count),
		air = blank(count),
		scratch_ground = blank(count),
		scratch_air = blank(count),
		enemy_air_count = 0,
		enemy_air_power = 0,
	}
end

-- Whether the field was made for the map as it is now: a new map can be another size.
local function fits_map(field: Field): boolean
	local half_x, half_z = heightmap.half_extents()
	return field.origin_x == -half_x and field.origin_z == -half_z
end

-- How far `def` reaches with the weapons that can be turned on the ground, and with those that can be turned on
-- aircraft; nil for a layer it cannot hit. A weapon that fires only when told to, like a nuclear silo's, is left out:
-- it could reach anywhere, and is not what makes a place dangerous to walk through. So is an anti-nuke.
local function reaches_of(def: EntityDef): (number?, number?)
	local ground: number? = nil
	local air: number? = nil
	if def.weapons ~= nil then
		for _, weapon in def.weapons do
			if weapon.manual_fire == true or weapon.anti_nuke == true then
				continue
			end
			if weapon.target_layer ~= "air" then
				ground = math.max(ground or 0, weapon.range)
			end
			if weapon.target_layer ~= "ground" then
				air = math.max(air or 0, weapon.range)
			end
		end
	end
	-- a carrier with nothing of its own fights with its drones, as far out as it sends them
	if def.carrier ~= nil then
		ground = math.max(ground or 0, def.carrier.engage_range)
	end
	return ground, air
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

-- Works the field out again from where the enemy stands now, keeping what it remembers.
local function refresh(field: Field)
	local scratch_ground = field.scratch_ground
	local scratch_air = field.scratch_air
	local count = field.cells_x * field.cells_z
	for index = 1, count do
		scratch_ground[index] = 0
		scratch_air[index] = 0
	end

	local air_count = 0
	local air_power = 0
	for _, other in state.all() do
		if
			other.alive == false
			or other.state ~= "active"
			or other.team == 0
			or other.kind == "wreck"
			or other.kind == "reclaimable"
			or alliances.are_allied(field.team, other.team)
		then
			continue
		end
		local def = unit_defs.of(other)
		local worth = unit_defs.power(def)
		if unit_defs.is_air(def) then
			air_count += 1
			air_power += worth
		end
		local ground_reach, air_reach = reaches_of(def)
		if ground_reach == nil and air_reach == nil then
			continue
		end
		local margin = if unit_defs.is_air(def)
			then AIR_MARGIN
			elseif def.max_speed ~= nil then MOBILE_MARGIN
			else STATIC_MARGIN
		local x, z = other.position.X, other.position.Z
		if ground_reach ~= nil then
			stamp(field, scratch_ground, x, z, ground_reach, margin, worth)
		end
		if air_reach ~= nil then
			stamp(field, scratch_air, x, z, air_reach, margin, worth)
		end
	end

	local ground = field.ground
	local air = field.air
	for index = 1, count do
		ground[index] = math.max(scratch_ground[index], ground[index] * MEMORY)
		air[index] = math.max(scratch_air[index], air[index] * MEMORY)
	end
	field.enemy_air_count = air_count
	field.enemy_air_power = air_power
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

-- The danger to an aircraft over `position`.
local function air_at(field: Field, position: Vector3): number
	local index = index_at(field, position.X, position.Z)
	if index == nil then
		return 0
	end
	return field.air[index]
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
	reaches_of = reaches_of,
	at = at,
	air_at = air_at,
	peak_near = peak_near,
	peak_along = peak_along,
})
