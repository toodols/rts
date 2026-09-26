--!strict
-- What a brain's units have been given to do (brains.luau's `Assignment`): one assignment to a unit at most, given with
-- `assign`, taken off with `release`, and asked after with `job_of`, `get` and `each`. A unit given a job, or let go
-- of one, is sent afresh next time rather than kept going where it was last sent (the brain's `goals`).
--
-- Each job's units are kept in a list of their own besides, in the order they were given it, so that going over one
-- job's units (`each`) goes over them in the same order every time the same game is played.

local ReplicatedStorage = game:GetService "ReplicatedStorage"
local ServerScriptService = game:GetService "ServerScriptService"

local types = require(ReplicatedStorage.Shared.types)

local state = require(ServerScriptService.Server.state)

local brains = require(script.Parent.brains)

type Entity = types.Entity
type EntityId = types.EntityId
type Brain = brains.Brain
type Job = brains.Job
type Assignment = brains.Assignment

local function get(brain: Brain, unit_id: EntityId): Assignment?
	return brain.assignments.of[unit_id]
end

local function job_of(brain: Brain, unit_id: EntityId): Job?
	local found = brain.assignments.of[unit_id]
	return if found ~= nil then found.job else nil
end

-- Takes `unit_id` off `job`'s list.
local function unlist(brain: Brain, unit_id: EntityId, job: Job)
	local listed = brain.assignments.by_job[job]
	table.remove(listed, table.find(listed, unit_id) :: number)
end

-- Takes `unit_id`'s assignment off it, if it has one.
local function release(brain: Brain, unit_id: EntityId)
	local assignments = brain.assignments
	local found = assignments.of[unit_id]
	if found == nil then
		return
	end
	assignments.of[unit_id] = nil
	unlist(brain, unit_id, found.job)
	brain.goals[unit_id] = nil
end

-- Gives `unit_id` `assignment`, in place of whatever it had. The same job again only changes what it says.
local function assign(brain: Brain, unit_id: EntityId, assignment: Assignment)
	local assignments = brain.assignments
	local found = assignments.of[unit_id]
	if found ~= nil and found.job == assignment.job then
		assignments.of[unit_id] = assignment
		return
	end
	release(brain, unit_id)
	assignments.of[unit_id] = assignment
	table.insert(assignments.by_job[assignment.job], unit_id)
	brain.goals[unit_id] = nil
end

-- Takes `unit_id` off `job`, if that is its job.
local function release_from(brain: Brain, unit_id: EntityId, job: Job)
	if job_of(brain, unit_id) == job then
		release(brain, unit_id)
	end
end

-- The units with `job`, in the order they were given it. Any of them may be released while they are gone over.
local function each(brain: Brain, job: Job): { EntityId }
	return table.clone(brain.assignments.by_job[job])
end

-- Whether any unit has `job`.
local function any(brain: Brain, job: Job): boolean
	return #brain.assignments.by_job[job] > 0
end

local function count(brain: Brain, job: Job): number
	return #brain.assignments.by_job[job]
end

-- Takes `job` off every unit that has it, and, with `resend`, has each sent afresh next time; without, each keeps going
-- where it was last sent.
local function release_all(brain: Brain, job: Job, resend: boolean)
	local assignments = brain.assignments
	for _, unit_id in assignments.by_job[job] do
		assignments.of[unit_id] = nil
		if resend then
			brain.goals[unit_id] = nil
		end
	end
	table.clear(assignments.by_job[job])
end

-- Whether `unit` is free for the army: waiting with it, out with the wave, or sent to see off an intruder, and not
-- escorting, raiding or gone home to be mended.
local function with_army(brain: Brain, unit: Entity): boolean
	local job = job_of(brain, unit.id)
	return job == nil or job == "wave" or job == "defend"
end

-- Whether `unit` has nothing to do but wait with the army: free to be sent as an escort, on a raid or on a wave.
local function is_free(brain: Brain, unit: Entity): boolean
	return brain.assignments.of[unit.id] == nil
end

-- Forgets the assignments of anything that is gone.
local function prune(brain: Brain)
	for _, job: Job in brains.JOBS do
		for _, unit_id in each(brain, job) do
			if state.get(unit_id) == nil then
				release(brain, unit_id)
			end
		end
	end
end

return table.freeze({
	get = get,
	job_of = job_of,
	assign = assign,
	release = release,
	release_from = release_from,
	release_all = release_all,
	each = each,
	any = any,
	count = count,
	with_army = with_army,
	is_free = is_free,
	prune = prune,
})
