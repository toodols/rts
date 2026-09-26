--!strict
-- Buildpower at work. A builder puts its buildpower into one job a tick (`Kind`): building a blueprint up
-- (server/construction.luau), repairing something back to health (the same), taking remains or something standing
-- apart (server/reclaim.luau), or raising a wreck (server/resurrection.luau). Each of those says what its job costs
-- and does, as a piece of work for the economy (`economy.Drain`), and hands it in here (`take`); every piece of the
-- tick's work is then paid for and done together once it is all gathered (`economy.settle`), so that a team that
-- cannot afford everything at once holds every builder back by the same share instead of by who asked first.
--
-- What each builder is on is kept here, for this tick and the one before: a builder guarding another reads what that
-- one was on while the tick is still being gathered, when the other may not have asked yet, so the tick before is what
-- keeps the answer from depending on which of them goes first.

local ReplicatedStorage = game:GetService "ReplicatedStorage"

local types = require(ReplicatedStorage.Shared.types)
local entity_attrs = require(ReplicatedStorage.Shared.entity_attrs)

local state = require(script.Parent.state)
local economy = require(script.Parent.economy)
local alliances = require(script.Parent.alliances)
local snapshot = require(script.Parent.snapshot)

type Entity = types.Entity
type EntityId = types.EntityId

export type Kind = "build" | "repair" | "reclaim" | "resurrect"

-- One builder's job for a tick.
type Job = {
	builder: Entity,
	kind: Kind,
	target: Entity,
}

-- This tick's jobs by builder, and the same by what they are on; and last tick's.
local jobs: { [EntityId]: Job } = {}
local jobs_on: { [EntityId]: { Job } } = {}
local previous_jobs: { [EntityId]: Job } = {}
local previous_jobs_on: { [EntityId]: { Job } } = {}

-- A new tick: this tick's jobs become the last tick's, and every builder is free for a new one.
local function begin_tick()
	previous_jobs, jobs = jobs, previous_jobs
	previous_jobs_on, jobs_on = jobs_on, previous_jobs_on
	table.clear(jobs)
	table.clear(jobs_on)
end

-- The buildpower `builder` works with a second, if it builds at all.
local function buildpower_of(builder: Entity): number?
	local builder_def = builder.def.builder
	return if builder_def ~= nil then builder_def.buildpower else nil
end

-- `builder` is on `kind` of work on `target` this tick, `drain` being what it costs and does. A builder does one job a
-- tick: one that has already taken one takes no other, and says so.
local function take(builder: Entity, kind: Kind, target: Entity, drain: economy.Drain): boolean
	if jobs[builder.id] ~= nil then
		return false
	end
	local job: Job = { builder = builder, kind = kind, target = target }
	jobs[builder.id] = job
	local on = jobs_on[target.id]
	if on == nil then
		on = {}
		jobs_on[target.id] = on
	end
	table.insert(on, job)
	economy.drain(drain)
	return true
end

-- Whether `job` is still going: what it is on is still there, and a blueprint being built is still a blueprint.
local function ongoing(job: Job): boolean
	local target = job.target
	if state.get(target.id, true) == nil then
		return false
	end
	return job.kind ~= "build" or target.state == "blueprint"
end

-- What `builder_id` is on this tick, and how, if it still is.
local function current(builder_id: EntityId): (Kind?, Entity?)
	local job = jobs[builder_id]
	if job == nil or ongoing(job) == false then
		return nil, nil
	end
	return job.kind, job.target
end

-- What `builder_id` was on as `kind` of work this tick or, failing that, last tick, if it still is.
local function recent(builder_id: EntityId, kind: Kind): Entity?
	for _, record in { jobs, previous_jobs } do
		local job = record[builder_id]
		if job ~= nil and job.kind == kind then
			return if ongoing(job) then job.target else nil
		end
	end
	return nil
end

-- Everyone on `target_id` as `kind` of work this tick.
local function workers_on(target_id: EntityId, kind: Kind): { Entity }
	local found = {}
	local on: { Job } = jobs_on[target_id] or {}
	for _, job in on do
		if job.kind == kind then
			table.insert(found, job.builder)
		end
	end
	return found
end

-- Whether something of `target`'s own side or an ally's, still there, was on it as `kind` of work this tick or last.
local function worked_by_ally(target: Entity, kind: Kind): boolean
	for _, record in { jobs_on, previous_jobs_on } do
		local on: { Job } = record[target.id] or {}
		for _, job in on do
			if
				job.kind == kind
				and state.get(job.builder.id) ~= nil
				and alliances.are_allied(job.builder.team, target.team)
			then
				return true
			end
		end
	end
	return false
end

-- Publishes what `entity` is putting its buildpower into right now (`work_target`), and how (`work_kind`), so the client
-- can show it working.
local function publish(entity: Entity, _def: types.EntityDef, write: entity_attrs.Publish)
	local kind, target = current(entity.id)
	write("work_target", if target ~= nil then target.id else nil)
	write("work_kind", kind)
end

local function forget(id: EntityId)
	jobs[id] = nil
	previous_jobs[id] = nil
end

snapshot.keep("work", function()
	return {
		jobs = jobs,
		jobs_on = jobs_on,
		previous_jobs = previous_jobs,
		previous_jobs_on = previous_jobs_on,
	}
end, function(saved)
	jobs = saved.jobs
	jobs_on = saved.jobs_on
	previous_jobs = saved.previous_jobs
	previous_jobs_on = saved.previous_jobs_on
end)

return table.freeze({
	begin_tick = begin_tick,
	buildpower_of = buildpower_of,
	take = take,
	current = current,
	recent = recent,
	workers_on = workers_on,
	worked_by_ally = worked_by_ally,
	publish = publish,
	forget = forget,
})
