--!strict
-- Where a brain puts what it builds. Anything of the economy's goes up beside another of its kind, so wind turbines
-- stand in a block, fusion reactors in another and construction turrets in a third (`cluster_site`); a defence and an
-- extractor go where they are needed, the first free place on rings round it (`ring_site`). Nothing goes up anywhere
-- dangerous, on a metal spot but an extractor, in front of a lab's doorway, or where a builder of its own gave up a
-- little while ago for something standing there it could not clear (`site_clear`, `given_up`).

local ReplicatedStorage = game:GetService "ReplicatedStorage"
local ServerScriptService = game:GetService "ServerScriptService"

local types = require(ReplicatedStorage.Shared.types)
local unit_defs = require(ReplicatedStorage.Shared.unit_defs)
local heightmap = require(ReplicatedStorage.Shared.heightmap)
local geometry = require(ReplicatedStorage.Shared.geometry)
local spots = require(ReplicatedStorage.Shared.spots)

local placement = require(ServerScriptService.Server.placement)
local rng = require(ServerScriptService.Server.rng)

local danger_field = require(script.Parent.danger_field)
local brains = require(script.Parent.brains)
local catalog = require(script.Parent.catalog)
local censuses = require(script.Parent.census)

type EntityId = types.EntityId
type Brain = brains.Brain
type Census = censuses.Census

-- A building to put up, and where.
export type Task = {
	def_name: string,
	position: Vector3,
	facing: number,
}

-- Siting. Buildings go RING_STEP apart on rings round where they are wanted, no further than MAX_SITE_TRIES places
-- being looked at a time. Nothing is built within SPOT_CLEARANCE of a metal spot but an extractor, nor in the lane in
-- front of a lab's doorway (census.lane_of).
local RING_STEP = 6
local MAX_SITE_TRIES = 90
local SPOT_CLEARANCE = 3
-- A new block of the economy starts this far behind home, away from the enemy, and is looked for this far round there.
local ECONOMY_OFFSET = 22
local CLUSTER_SEARCH_RADIUS = 80
-- A block's members are looked at, nearest home first, this many at most.
local CLUSTER_ANCHORS = 20
-- Two places this near each other are the same spot: an extractor on a metal spot, or one built over another.
local SAME_SPOT = 1

-- Whether a builder of `brain`'s gave up on building at `position` a little while ago, for something standing there it
-- could not clear (errands.luau's `give_up_lost_build`), and it is not to be tried again yet.
local function given_up(brain: Brain, position: Vector3): boolean
	local now = brains.now()
	for _, site in brain.bad_sites do
		if now < site.expires and geometry.distance_2d(site.position, position) < SAME_SPOT then
			return true
		end
	end
	return false
end

-- The eight places beside a building, the four sides before the corners.
local NEIGHBOURS: { Vector2 } = {
	Vector2.new(1, 0),
	Vector2.new(-1, 0),
	Vector2.new(0, 1),
	Vector2.new(0, -1),
	Vector2.new(1, 1),
	Vector2.new(-1, 1),
	Vector2.new(1, -1),
	Vector2.new(-1, -1),
}

-- Whether a building of `def_name` could go up at `center`, turned to `facing`: it is on the map, somewhere quiet, off
-- the metal spots unless it is an extractor, clear of every lab's doorway and of what its builders have been sent to
-- put up, and, for a lab, with its own doorway clear; and the ground and what stands on it let it.
local function site_clear(brain: Brain, census: Census, def_name: string, center: Vector3, facing: number): boolean
	if heightmap.in_bounds(center.X, center.Z) == false then
		return false
	end
	if danger_field.at(brain.field, center) >= brain.profile.safe_danger or given_up(brain, center) then
		return false
	end
	local def = unit_defs.get(def_name)
	local half = geometry.rotated_half_extents(unit_defs.footprint_half_extents(def), facing)
	for _, plan in census.plans do
		if geometry.aabb_overlap(center, half, plan.position, plan.half, 0) then
			return false
		end
	end
	for _, lane in census.lanes do
		if geometry.aabb_overlap(center, half, lane.center, lane.half, 0) then
			return false
		end
	end
	if def.spot == nil then
		local reach = math.max(half.X, half.Y) + SPOT_CLEARANCE
		if spots.nearest("metal", center.X, center.Z, reach, nil) ~= nil then
			return false
		end
	end
	if catalog.role_of(def_name).factory then
		local lane = censuses.lane_of(def_name, center, facing)
		if heightmap.in_bounds(lane.center.X, lane.center.Z) == false then
			return false
		end
		for _, building in census.structures do
			if
				geometry.aabb_overlap(
					lane.center,
					lane.half,
					building.position,
					placement.half_extents_for(building),
					0
				)
			then
				return false
			end
		end
		for _, plan in census.plans do
			if geometry.aabb_overlap(lane.center, lane.half, plan.position, plan.half, 0) then
				return false
			end
		end
	end
	return placement.can_place(def_name, center, facing, nil, brain.team)
end

-- The first place for `def_name` on rings round `around`, from `inner` out to `outer`.
local function ring_site(
	brain: Brain,
	census: Census,
	def_name: string,
	around: Vector3,
	inner: number,
	outer: number,
	facing: number
): Task?
	return placement.ring_search(
		around,
		inner,
		outer,
		RING_STEP,
		rng.stream(brain.stream),
		function(x: number, z: number): Task?
			local center = placement.resolve_center(def_name, x, z, facing)
			if center ~= nil and site_clear(brain, census, def_name, center, facing) then
				return { def_name = def_name, position = center, facing = facing }
			end
			return nil
		end,
		heightmap.in_bounds,
		MAX_SITE_TRIES
	)
end

-- Where a new block of `def_name` starts (catalog.block_of): construction turrets beside the first lab, and the rest
-- of the economy behind home, away from the enemy, stores and converters off to one side of it.
local function seed_of(brain: Brain, census: Census, def_name: string): Vector3
	local block = catalog.block_of(def_name)
	if block == "turret" then
		local lab = census.factories[1]
		if lab ~= nil then
			local out = Vector3.new(math.sin(lab.facing), 0, math.cos(lab.facing))
			local right = Vector3.new(-out.Z, 0, out.X)
			local half = placement.half_extents_for(lab)
			return lab.position + right * (math.max(half.X, half.Y) + 4)
		end
	end
	local behind = brain.home - brain.forward * ECONOMY_OFFSET
	if block == "store" then
		-- off to one side of the energy, so the two blocks grow apart
		behind += Vector3.new(-brain.forward.Z, 0, brain.forward.X) * ECONOMY_OFFSET
	end
	return behind
end

-- A place for `def_name` beside another of its kind, nearest home first, or where a new block of it starts if there is
-- no room beside any.
local function cluster_site(brain: Brain, census: Census, def_name: string): Task?
	local half = unit_defs.footprint_half_extents(unit_defs.get(def_name))
	local anchors: { { position: Vector3, half: Vector2, id: EntityId? } } = {}
	for _, building in censuses.buildings_of(census, def_name) do
		if brain.full[building.id] ~= true then
			table.insert(
				anchors,
				{ position = building.position, half = placement.half_extents_for(building), id = building.id }
			)
		end
	end
	for _, plan in census.plans do
		if plan.def_name == def_name then
			table.insert(anchors, { position = plan.position, half = plan.half, id = nil })
		end
	end
	table.sort(anchors, function(a, b): boolean
		return geometry.distance_2d(a.position, brain.home) < geometry.distance_2d(b.position, brain.home)
	end)
	for index, anchor in anchors do
		if index > CLUSTER_ANCHORS then
			break
		end
		local room = false
		for _, side in NEIGHBOURS do
			local x = anchor.position.X + side.X * (anchor.half.X + half.X)
			local z = anchor.position.Z + side.Y * (anchor.half.Y + half.Y)
			local center = placement.resolve_center(def_name, x, z, 0)
			if center == nil then
				continue
			end
			if site_clear(brain, census, def_name, center, 0) then
				return { def_name = def_name, position = center, facing = 0 }
			end
			-- somewhere a plan may yet free up, or the enemy may yet leave, is not given up on
			if danger_field.at(brain.field, center) >= brain.profile.safe_danger then
				room = true
			end
		end
		local id = anchor.id
		if room == false and id ~= nil then
			brain.full[id] = true
		end
	end
	return ring_site(brain, census, def_name, seed_of(brain, census, def_name), 0, CLUSTER_SEARCH_RADIUS, 0)
end

-- The metal spots an extractor of anyone's stands on, or one its own builders have been sent to put up: a spot within
-- SAME_SPOT of one of them is taken.
local function taken_spots(census: Census): { Vector3 }
	local taken = table.clone(census.taken_spots)
	for _, plan in census.plans do
		if catalog.role_of(plan.def_name).extractor then
			table.insert(taken, plan.position)
		end
	end
	return taken
end

return table.freeze({
	SAME_SPOT = SAME_SPOT,
	given_up = given_up,
	site_clear = site_clear,
	ring_site = ring_site,
	cluster_site = cluster_site,
	taken_spots = taken_spots,
})
