--!strict
-- Retreat and repair, taken from BARb (behaviour.json "retreat", CircuitAI's RetreatTask): with the profile's
-- retreat_health, a fighter under it leaves its wave, raid, escort or defence and goes home to be mended
-- (`repair_spot`); once there a construction turret is told to mend it, and with none a builder with nothing better to
-- do comes to (errands.luau's `assist`). It goes back into the army once it has the profile's repaired_share of its
-- health again (BARb's RetreatTask lets go at 98%), or as it is once it has been its repair_patience seconds home with
-- its health not going up, or its retreat_walk_seconds on its way there.

local ReplicatedStorage = game:GetService "ReplicatedStorage"
local ServerScriptService = game:GetService "ServerScriptService"

local types = require(ReplicatedStorage.Shared.types)
local unit_defs = require(ReplicatedStorage.Shared.unit_defs)
local heightmap = require(ReplicatedStorage.Shared.heightmap)
local geometry = require(ReplicatedStorage.Shared.geometry)

local orders = require(ServerScriptService.Server.orders)

local brains = require(script.Parent.brains)
local assignments = require(script.Parent.assignments)
local catalog = require(script.Parent.catalog)
local censuses = require(script.Parent.census)
local squads = require(script.Parent.squads)

type Entity = types.Entity
type EntityId = types.EntityId
type Brain = brains.Brain
type Retreat = brains.Retreat
type Job = brains.Job
type Census = censuses.Census

-- A hurt fighter waits this share of a construction turret's reach from it, and counts as home within RETREAT_SLACK of
-- where it was sent.
local TURRET_REACH_SHARE = 0.5
local RETREAT_SLACK = 8
-- What of the army a hurt fighter may be doing when it goes home.
local ARMY_JOBS: { Job } = { "wave", "group", "escort", "defend" }

-- Where `unit`, hurt, goes to be mended: in the reach of its own finished construction turret nearest it, and which
-- turret that is, or with none, the rally point, where a builder with nothing better to do comes to it.
local function repair_spot(brain: Brain, census: Census, unit: Entity): (Vector3, Entity?)
	local best: Entity? = nil
	local best_distance = math.huge
	for _, def_name in catalog.TURRET_DEFS do
		for _, turret in censuses.buildings_of(census, def_name) do
			local distance = geometry.distance_2d(turret.position, unit.position)
			if turret.state == "active" and distance < best_distance then
				best = turret
				best_distance = distance
			end
		end
	end
	if best == nil then
		return squads.rally_point(brain), nil
	end
	local reach = (unit_defs.build_range(best.def) or 0) * TURRET_REACH_SHARE
	local away = geometry.flatten(unit.position - best.position)
	local point = if away.Magnitude > 1 then best.position + away.Unit * reach else best.position
	return heightmap.ground_position(point.X, point.Z), best
end

-- Lets `unit_id`, gone home to be mended, back into the army, and, if `waive`, does not send it home again until it
-- is over the profile's retreat_health once more.
local function release(brain: Brain, unit_id: EntityId, waive: boolean)
	assignments.release(brain, unit_id)
	if waive then
		brain.waived[unit_id] = true
	end
end

local function run_retreats(brain: Brain, census: Census)
	local profile = brain.profile
	local threshold = profile.retreat_health
	if threshold == nil then
		for _, unit_id in assignments.each(brain, "retreat") do
			release(brain, unit_id, false)
		end
		return
	end
	local now = brains.now()
	for _, unit in census.army do
		local share = unit.health / math.max(1, unit.max_health)
		local assignment = assignments.get(brain, unit.id)
		local retreat: Retreat
		if assignment ~= nil and assignment.job == "retreat" then
			retreat = assignment.retreat
		else
			if brain.waived[unit.id] == true then
				if share >= threshold then
					brain.waived[unit.id] = nil
				end
				continue
			end
			if share >= threshold or unit_defs.is_air(unit.def) then
				continue
			end
			-- it leaves whatever it was doing
			for _, job: Job in ARMY_JOBS do
				assignments.release_from(brain, unit.id, job)
			end
			brain.goals[unit.id] = nil
			retreat = { since = now, health = unit.health, arrived = false, turret = nil }
			assignments.assign(brain, unit.id, { job = "retreat", retreat = retreat })
		end
		if share >= profile.repaired_share then
			release(brain, unit.id, false)
			continue
		end
		if unit.health > retreat.health then
			retreat.health = unit.health
			retreat.since = now
		end
		if
			now - retreat.since > (if retreat.arrived then profile.repair_patience else profile.retreat_walk_seconds)
		then
			release(brain, unit.id, true)
			continue
		end
		local spot, turret = repair_spot(brain, census, unit)
		retreat.turret = if turret ~= nil then turret.id else nil
		if geometry.distance_2d(unit.position, spot) > RETREAT_SLACK then
			squads.send_all(brain, { unit }, spot, "move", RETREAT_SLACK)
			continue
		end
		if retreat.arrived == false then
			retreat.arrived = true
			retreat.since = now
		end
		-- a turret with nothing else to do is told to mend it; a busy one gets to it once it is done
		if turret ~= nil and #turret.orders == 0 then
			orders.issue(turret, { { kind = "repair", position = nil, target_id = unit.id } }, false, false)
		end
	end
end

return table.freeze({
	run_retreats = run_retreats,
})
