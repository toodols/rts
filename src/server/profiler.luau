-- Where each simulation step's time actually goes. `mark(label)` closes out whatever section was
-- open (attributing the time since the last mark to it) and opens the next one under `label`, so a
-- step just calls it once between each piece of work it does - no per-call closures, no wrapping.
-- `mark(nil)` closes the last section without opening a new one, for the end of a step.
--
-- Time accumulates into a running total per label, alongside how many steps have gone by since the
-- last reset, so `report()` can give both a share of the step and an average time per step. It always
-- runs - `os.clock()` twice a section is cheap next to what a step actually does - so it is there
-- the moment something needs looking into, with no separate switch to remember to flip first.

local totals: { [string]: number } = {}
local steps = 0
local reset_at = os.clock()

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

return table.freeze({
	mark = mark,
	step_done = step_done,
	reset = reset,
	report = report,
	elapsed_since_reset = elapsed_since_reset,
	step_count = step_count,
})
