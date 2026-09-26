--!strict
-- Keeping a game and putting it back (server/snapshot).
--
-- - `snapshot_roundtrip`: an AI match played `before` seconds, kept, and put back twice, each time played on `after`
--   seconds: once straight away, once after the game had already played on past the snapshot. Both have to end the
--   same, to the byte, which they only do if everything that decides how the game goes was kept and nothing left over
--   from before it was put back counts. What was put back has to be kept again as it was (`idempotent`), and it says
--   whether the game played on from where it was kept, never put back, ends the same too (`continues`), and where the
--   first difference is if it does not. Args: `before`, `after`, `teams`, `line`, and `scavengers` (true) with their
--   `progress`.
-- - `pcg32`: server/pcg32.luau rolls what Random rolls, for a spread of seeds and every way the game rolls.

local ServerScriptService = game:GetService "ServerScriptService"

local ReplicatedStorage = game:GetService "ReplicatedStorage"

local switches = require(ReplicatedStorage.Shared.switches)
local unit_defs = require(ReplicatedStorage.Shared.unit_defs)
local surface = require(ReplicatedStorage.Shared.surface)
local heightmap = require(ReplicatedStorage.Shared.heightmap)

local ai = require(ServerScriptService.Server.ai)
local scavengers = require(ServerScriptService.Server.scavengers)
local state = require(ServerScriptService.Server.state)
local orders = require(ServerScriptService.Server.orders)
local shields = require(ServerScriptService.Server.shields)
local self_destruct = require(ServerScriptService.Server.self_destruct)
local snapshot = require(ServerScriptService.Server.snapshot)
local pcg32 = require(ServerScriptService.Server.pcg32)

local harness = require(script.Parent.harness)

local advance = harness.advance
local round = harness.round
local spawn = harness.spawn
local spawn_resting = harness.spawn_resting
local unkillable = harness.unkillable
local OWN = harness.OWN
local ENEMY = harness.ENEMY

type Entity = typeof(state.create_entity("grunt", 1, Vector3.zero, 0, "active"))

type Args = harness.Args
type Findings = harness.Findings
type Test = harness.Test

local function arg(args: Args, key: string, kind: string, fallback: any): any
	return if typeof(args[key]) == kind then args[key] else fallback
end

-- The first `count` lines where the snapshots `a` and `b` differ, as "a | b".
local function differences(a: buffer, b: buffer, count: number): { string }
	local lines_a, lines_b = snapshot.describe(a), snapshot.describe(b)
	local found: { string } = {}
	for index = 1, math.max(#lines_a, #lines_b) do
		if lines_a[index] ~= lines_b[index] then
			table.insert(found, `{lines_a[index] or "(none)"} | {lines_b[index] or "(none)"}`)
			if #found >= count then
				break
			end
		end
	end
	return found
end

-- How many lines differ between the snapshots `a` and `b`, by the part of the game that kept them.
local function differing_parts(a: buffer, b: buffer): { [string]: number }
	local lines_a, lines_b = snapshot.describe(a), snapshot.describe(b)
	local by_part: { [string]: number } = {}
	for index = 1, math.max(#lines_a, #lines_b) do
		if lines_a[index] ~= lines_b[index] then
			local part = string.match(lines_a[index] or lines_b[index], "^[^.= ]+") or "?"
			by_part[part] = (by_part[part] or 0) + 1
		end
	end
	return by_part
end

local function same(a: buffer, b: buffer): boolean
	return buffer.len(a) == buffer.len(b) and buffer.tostring(a) == buffer.tostring(b)
end

local function snapshot_roundtrip(args: Args): Findings
	local before = arg(args, "before", "number", 240)
	local after = arg(args, "after", "number", 60)
	local count = arg(args, "teams", "number", 2)
	for index = 1, count do
		local team = ai.spawn_opponent(`AI {index}`, nil, nil, nil)
		assert(team ~= nil, `there was no room for AI {index}`)
		if args.line == "bot" or args.line == "vehicle" then
			ai.set_line(team, args.line)
		end
	end
	-- the scavengers too, from `progress` on, if asked for
	if args.scavengers == true then
		switches.set("scavengers", true)
		scavengers.set_progress(arg(args, "progress", "number", 0.3))
	end
	advance(before)

	local started = os.clock()
	local kept = snapshot.capture()
	local capture_seconds = os.clock() - started

	-- played on as it was, never put back
	advance(after)
	local continued = snapshot.capture()

	-- put back once the game has played on past it, and played on again
	started = os.clock()
	snapshot.restore(kept)
	local restore_seconds = os.clock() - started
	local kept_again = snapshot.capture()
	advance(after)
	local first = snapshot.capture()

	-- and again, from the end of that
	snapshot.restore(kept)
	advance(after)
	local second = snapshot.capture()

	if args.scavengers == true then
		switches.set("scavengers", false)
	end

	local idempotent = same(kept, kept_again)
	local repeatable = same(first, second)
	local continues = same(continued, first)
	return {
		bytes = buffer.len(kept),
		capture_ms = round(capture_seconds * 1000, 1),
		restore_ms = round(restore_seconds * 1000, 1),
		idempotent = idempotent,
		idempotent_differences = if idempotent then nil else differences(kept, kept_again, 12),
		repeatable = repeatable,
		repeatable_differences = if repeatable then nil else differences(first, second, 12),
		continues = continues,
		continues_differences = if continues then nil else differences(continued, first, 12),
		continues_differing_parts = if continues then nil else differing_parts(continued, first),
		pass = idempotent and repeatable,
	}
end

-- Everything a match may not get round to in a few minutes, going on at once: a transport flying with a unit in its
-- hold, a carrier's drones out, a nuke in the air with an anti-nuke to meet it, beams burning, a bomber's EMP, a
-- shield under fire, a gunship circling its target and a unit counting down to destroy itself. Every `every` seconds
-- for `seconds` it is taken (`snapshot.take`), played on `after` seconds, put back and played on as long again, which
-- has to end the same to the byte each time. It says which of those were under way at some snapshot (`under_way`),
-- and passes only if they all were.
local function snapshot_zoo(args: Args): Findings
	local every = arg(args, "every", "number", 0.35)
	local seconds = arg(args, "seconds", "number", 24)
	local after = arg(args, "after", "number", 2)
	harness.ensure_team(ENEMY)
	local findings: Findings = {}
	harness.with_switch(harness.NOCOST, true, function()
		local function standing(def_name: string, team: number, x: number, z: number): Entity
			local def = unit_defs.get(def_name)
			local y = surface.height(def, x, z) + unit_defs.collider_height(def) / 2
			return state.create_entity(def_name, team, Vector3.new(x, y, z), 0, "active")
		end

		-- the enemy: a shielded commander, thugs (one for a gunship to circle, which it does only round a unit) and an
		-- anti-nuke
		local commander = unkillable(spawn_resting("commander", ENEMY, 150, 0))
		local thug = unkillable(spawn("thug", ENEMY, 120, 20))
		local circled = unkillable(spawn("thug", ENEMY, 120, -20))
		local anti = unkillable(standing("prevailer", ENEMY, -120, 60))
		anti.weapon_stockpiles[1].held = 1

		-- ours
		for index, def_name in { "sumo", "sharpshooter", "pulsar" } do
			unkillable(spawn_resting(def_name, OWN, 100, (index - 2) * 12))
		end
		local bomber = unkillable(spawn("stiletto", OWN, -150, 0))
		unkillable(spawn("mantis", OWN, 60, 40))
		local silo = unkillable(standing("apocalypse", OWN, -200, 0))
		silo.weapon_stockpiles[1].held = 1
		local cargo = spawn("grunt", OWN, -60, -40)
		local carrier = unkillable(spawn("hephaestus", OWN, -60, -60))
		local gunship = unkillable(spawn("tyrannus", OWN, 90, -90))
		local doomed = spawn_resting("juggernaut", OWN, -30, 90)
		advance(0.05)

		shields.toggle(commander)
		orders.issue(bomber, { { kind = "attack", target_id = thug.id } }, false, false)
		orders.issue(carrier, { { kind = "load", target_id = cargo.id } }, false, false)
		orders.issue(gunship, { { kind = "attack", target_id = circled.id } }, false, false)
		-- the nuke goes for the anti-nuke itself, which it covers
		orders.issue(silo, { { kind = "attack", target_id = anti.id, launch = true } }, false, false)
		self_destruct.toggle(doomed)

		local exercised: { [string]: boolean } = {
			hold = false,
			drones = false,
			nuke = false,
			beam = false,
			emp = false,
			shield = false,
			orbit = false,
			self_destruct = false,
		}
		local prefixes: { [string]: string } = {
			hold = "state.holds.",
			drones = "drones.carriers.",
			nuke = "projectiles.nuke_list.",
			beam = "beams.burning.",
			emp = "emp.charged.",
			shield = "shields.power.",
			orbit = "orbits.stations.",
			self_destruct = "self_destruct.counting.",
		}
		local snapshots = 0
		local differing: { string }? = nil
		local sent_off = false
		local elapsed = 0
		while elapsed < seconds do
			advance(every)
			elapsed += every
			-- once the transport has its load, it flies off with it
			local transport = state.get(carrier.id)
			if sent_off == false and transport ~= nil and #state.cargo_of(transport.id) > 0 then
				sent_off = true
				orders.issue(
					transport,
					{ { kind = "move", position = heightmap.ground_position(40, -120) } },
					false,
					false
				)
			end

			local kept = snapshot.take()
			snapshots += 1
			for _, line in snapshot.describe(kept) do
				for name, prefix in prefixes do
					if string.sub(line, 1, #prefix) == prefix then
						exercised[name] = true
					end
				end
			end
			advance(after)
			local first = snapshot.capture()
			snapshot.restore(kept)
			advance(after)
			local second = snapshot.capture()
			if differing == nil and not same(first, second) then
				differing = differences(first, second, 12)
				table.insert(differing :: { string }, 1, `at {round(elapsed, 2)} s`)
			end
		end
		local all_under_way = true
		for _, going in exercised do
			all_under_way = all_under_way and going
		end
		findings = {
			snapshots = snapshots,
			under_way = exercised,
			repeatable = differing == nil,
			differences = differing,
			pass = differing == nil and all_under_way,
		}
	end)
	return findings
end

local function pcg32_test(_args: Args): Findings
	local mismatches: { string } = {}
	local rolls = 0
	for _, seed in { 0, 1, 7, 12345, 2 ^ 31, 2 ^ 40 + 17, 2 ^ 52 - 1, 987654321 * 4096 + 5 } do
		local random = Random.new(seed)
		local generator = pcg32.new(seed)
		for index = 1, 200 do
			local expected, got
			local way = index % 4
			if way == 0 then
				expected, got = random:NextNumber(), pcg32.next_number(generator)
			elseif way == 1 then
				expected, got = random:NextNumber(-3.5, 1e6), pcg32.next_number(generator, -3.5, 1e6)
			elseif way == 2 then
				expected, got = random:NextInteger(1, 7), pcg32.next_integer(generator, 1, 7)
			else
				expected, got = random:NextInteger(-50, 2 ^ 20), pcg32.next_integer(generator, -50, 2 ^ 20)
			end
			rolls += 1
			if expected ~= got and #mismatches < 10 then
				table.insert(mismatches, `seed {seed} roll {index}: Random {expected}, pcg32 {got}`)
			end
		end
	end
	return { rolls = rolls, mismatches = mismatches, pass = #mismatches == 0 }
end

local TESTS: { [string]: Test } = {
	snapshot_roundtrip = { run = snapshot_roundtrip },
	snapshot_zoo = { run = snapshot_zoo },
	pcg32 = { run = pcg32_test },
}

return table.freeze(TESTS)
