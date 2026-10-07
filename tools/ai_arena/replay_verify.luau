-- Whether a replay (a duel the arena recorded, see arena.luau's `record`) plays back as it was played: in a fresh game,
-- each jump point is put back and played on to the next, and at every check the arena recorded on the way (`checks`)
-- and at the next jump point, the game's checksum has to be the one recorded there. Run from the repository's root:
--
--     lune run tools/ai_arena/replay_verify.luau <replay folder>
--
-- Prints a line for each checksum, and on the last line, as JSON, how many played back the same. Exits with 1 if any did
-- not. With --diff, the first that does not is shown line by line (snapshot.describe) against what was recorded, for a
-- jump point.

local fs = require "@lune/fs"
local process = require "@lune/process"
local serde = require "@lune/serde"

local session = require "../lib/session"

local folder = process.args[1]
assert(folder ~= nil, "which replay? lune run tools/ai_arena/replay_verify.luau <replay folder>")
local manifest = serde.decode("json", fs.readFile(`{folder}/manifest.json`))

local game = session.start({ root = process.cwd, preset = manifest.map.preset, seed = manifest.map.seed })
local snapshot = game.server "snapshot"
local ticks_per_second = math.round(1 / game.tick_delta)
local HALF_STEP = game.tick_delta / 2

-- a game the Rust AI played: what it told its sides each second, given again after the step that ends that second
local orders_player = if manifest.orders ~= nil
	then game.server("external_orders").player(serde.decode("json", fs.readFile(`{folder}/{manifest.orders}`)))
	else nil

-- Puts the game back to `keyframe`.
local function put_back(keyframe: { [string]: any })
	snapshot.restore(buffer.fromstring(fs.readFile(`{folder}/{keyframe.file}.bin`)))
	if orders_player ~= nil then
		orders_player.rewind(keyframe.t, HALF_STEP)
	end
end

-- Plays on from `from` seconds of game to `to`.
local function play(from: number, to: number)
	if orders_player == nil then
		game.advance((to - from) * ticks_per_second)
		return
	end
	for second = from + 1, to do
		game.advance(ticks_per_second)
		orders_player.at(second, HALF_STEP)
	end
end

-- with --dump <seconds>: the game as it stands at that moment, played from the jump point before it, as
-- snapshot.describe lays it out, into dump_<seconds>.txt in the replay's folder
local dump_at = if process.args[2] == "--dump" then tonumber(process.args[3]) else nil
if dump_at ~= nil then
	local from = manifest.keyframes[1]
	for _, keyframe in manifest.keyframes do
		if keyframe.t <= dump_at then
			from = keyframe
		end
	end
	put_back(from)
	play(from.t, dump_at)
	fs.writeFile(`{folder}/dump_{dump_at}.txt`, table.concat(snapshot.describe(snapshot.capture()), "\n"))
	local order = {}
	for id in game.server("state").all() do
		table.insert(order, tostring(id))
	end
	fs.writeFile(`{folder}/dump_{dump_at}_order.txt`, table.concat(order, " "))
	print(`dumped {dump_at} s to {folder}/dump_{dump_at}.txt`)
	process.exit(0)
end

-- with --steps <keyframe> <ticks> [filter]: jump point <keyframe> (1 for the first) played on <ticks> steps, the game's
-- checksum then and the lines of it that have [filter] in them, as the Studio test `replay_steps` gives them, to hold up
-- against Studio's; the Rust AI's orders are given after each step, as Studio's replay gives them
if process.args[2] == "--steps" then
	local keyframe = manifest.keyframes[tonumber(process.args[3]) or 1]
	put_back(keyframe)
	local now = game.server("state").now
	for _ = 1, tonumber(process.args[4]) or 0 do
		game.advance(1)
		if orders_player ~= nil then
			orders_player.at(now(), HALF_STEP)
		end
	end
	local captured = snapshot.capture()
	local lines = {}
	local filter = process.args[5]
	if filter ~= nil then
		for _, line in snapshot.describe(captured) do
			if string.find(line, filter, 1, true) ~= nil and #lines < 200 then
				table.insert(lines, line)
			end
		end
	end
	local parts = {}
	for _, line in snapshot.describe(captured) do
		local part = string.match(line, "^[^.= ]+") or "?"
		local sum = parts[part] or 0
		for at = 1, #line do
			sum = (sum * 31 + string.byte(line, at)) % 2147483647
		end
		parts[part] = sum
	end
	print(serde.encode("json", { checksum = snapshot.checksum(captured), lines = lines, parts = parts }))
	process.exit(0)
end

local same, different = 0, 0
local checks = manifest.checks or {}
for index = 1, #manifest.keyframes - 1 do
	local from, to = manifest.keyframes[index], manifest.keyframes[index + 1]
	put_back(from)
	local at = from.t
	-- the checks in this gap, played to one by one
	for _, check in checks do
		if check.t > from.t and check.t < to.t then
			play(at, check.t)
			at = check.t
			local checked = snapshot.checksum(snapshot.capture())
			if checked == check.checksum then
				same += 1
			else
				different += 1
			end
			print(
				string.format("  check %5d s: %s", check.t, if checked == check.checksum then "same" else "DIFFERENT")
			)
		end
	end
	play(at, to.t)
	local captured = snapshot.capture()
	local checksum = snapshot.checksum(captured)
	local ok = checksum == to.checksum
	-- with --diff, where the first gap that plays back differently differs, line by line
	if not ok and different == 0 and process.args[2] == "--diff" then
		local recorded = snapshot.describe(buffer.fromstring(fs.readFile(`{folder}/{to.file}.bin`)))
		local played = snapshot.describe(captured)
		local shown = 0
		for line = 1, math.max(#recorded, #played) do
			if recorded[line] ~= played[line] then
				print(`  recorded: {recorded[line]}`)
				print(`  played:   {played[line]}`)
				shown += 1
				if shown >= 12 then
					break
				end
			end
		end
	end
	if ok then
		same += 1
	else
		different += 1
	end
	print(
		string.format(
			"%5d s -> %5d s: %s",
			from.t,
			to.t,
			if ok then "same" else `DIFFERENT ({checksum}, recorded {to.checksum})`
		)
	)
end
-- the checks after the last jump point, to where the game ended
local last = manifest.keyframes[#manifest.keyframes]
put_back(last)
local at = last.t
for _, check in checks do
	if check.t > last.t then
		play(at, check.t)
		at = check.t
		local checked = snapshot.checksum(snapshot.capture())
		if checked == check.checksum then
			same += 1
		else
			different += 1
		end
		print(string.format("  check %5d s: %s", check.t, if checked == check.checksum then "same" else "DIFFERENT"))
	end
end
print(serde.encode("json", { same = same, different = different, keyframes = #manifest.keyframes }))
process.exit(if different == 0 then 0 else 1)
