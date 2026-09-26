--!strict
-- Where each simulation step's time actually goes, and how many entities are alive, so a leak - one
-- kind or def quietly never being cleaned up - shows up as a count that only ever grows rather than
-- having to be guessed at from lag alone.
--
-- `mark(label)` closes out whatever section was open (attributing the time since the last mark to it)
-- and opens the next one under `label`. The step marks each of its phases by name (server/simulation.luau), and
-- nothing inside a phase marks anything, so the report reads as the step's own list. `mark(nil)` closes the last
-- section without opening a new one, for the end of a step.
--
-- Time accumulates into a running total per label, alongside how many steps have gone by since the
-- last reset, so `report()` can give both a share of the step and an average time per step. It always
-- runs - `os.clock()` twice a section is cheap next to what a step actually does - so it is there
-- the moment something needs looking into, with no separate switch to remember to flip first.

local state = require(script.Parent.state)

local totals: { [string]: number } = {}
local steps = 0
local reset_at = os.clock()

-- Live entity counts, by kind ("unit", "building", "wreck") and by def name, alongside what each
-- count was at the last reset, so a growing one stands out as a positive delta rather than needing
-- two /profile runs compared by eye.
local by_kind: { [string]: number } = {}
local by_kind_at_reset: { [string]: number } = {}
local by_def: { [string]: number } = {}
local by_def_at_reset: { [string]: number } = {}
local entity_total = 0
local entity_total_at_reset = 0

-- Recounts every live entity, when a count is asked for (`reset`, `entity_report`) and never as part of a step.
local function sample_entities()
	table.clear(by_kind)
	table.clear(by_def)
	entity_total = 0
	for _, entity in state.all() do
		entity_total += 1
		by_kind[entity.kind] = (by_kind[entity.kind] or 0) + 1
		by_def[entity.def_name] = (by_def[entity.def_name] or 0) + 1
	end
end

local last_label: string? = nil
local last_time = 0

local function mark(label: string?)
	local now = os.clock()
	if last_label ~= nil then
		totals[last_label] = (totals[last_label] or 0) + (now - last_time)
	end
	last_label = label
	last_time = now
end

-- Call once per step, after the last `mark`, so `steps` only counts whole steps.
local function step_done()
	steps += 1
end

local function reset()
	table.clear(totals)
	steps = 0
	reset_at = os.clock()
	last_label = nil

	sample_entities()
	by_kind_at_reset = table.clone(by_kind)
	by_def_at_reset = table.clone(by_def)
	entity_total_at_reset = entity_total
end

export type Row = {
	label: string,
	seconds: number,
	fraction: number,
	ms_per_step: number,
}

-- Every label seen since the last reset, heaviest first: its total time, its share of all the time
-- spent across every label (not wall-clock time, which also includes whatever this never got a mark
-- for), and its average milliseconds per step.
local function report(): { Row }
	local grand_total = 0
	for _, seconds in totals do
		grand_total += seconds
	end

	local rows: { Row } = {}
	for label, seconds in totals do
		table.insert(rows, {
			label = label,
			seconds = seconds,
			fraction = if grand_total > 0 then seconds / grand_total else 0,
			ms_per_step = if steps > 0 then seconds / steps * 1000 else 0,
		})
	end
	table.sort(rows, function(a, b)
		return a.seconds > b.seconds
	end)
	return rows
end

local function elapsed_since_reset(): number
	return os.clock() - reset_at
end

local function step_count(): number
	return steps
end

export type CountRow = {
	label: string,
	count: number,
	delta: number,
}

export type EntitySummary = {
	total: number,
	total_delta: number,
	by_kind: { CountRow },
	by_def: { CountRow },
}

local function count_rows(counts: { [string]: number }, at_reset: { [string]: number }): { CountRow }
	local rows: { CountRow } = {}
	for label, count in counts do
		table.insert(rows, { label = label, count = count, delta = count - (at_reset[label] or 0) })
	end
	table.sort(rows, function(a, b)
		return a.count > b.count
	end)
	return rows
end

-- The live entity count, its change since the last reset, and both broken down by kind and by def
-- name, heaviest first, counted now.
local function entity_report(): EntitySummary
	sample_entities()
	return {
		total = entity_total,
		total_delta = entity_total - entity_total_at_reset,
		by_kind = count_rows(by_kind, by_kind_at_reset),
		by_def = count_rows(by_def, by_def_at_reset),
	}
end

return table.freeze({
	mark = mark,
	step_done = step_done,
	reset = reset,
	report = report,
	elapsed_since_reset = elapsed_since_reset,
	step_count = step_count,
	entity_report = entity_report,
})
