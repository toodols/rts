-- Whether a game kept on one server plays on the same once it is put back on another (server/snapshot), headless:
-- the second is a process of its own, which has only ever loaded the map.
--
--     lune run tools/headless_tests/snapshot_check.luau save <file> '<json args>'
--     lune run tools/headless_tests/snapshot_check.luau load <file>
--     lune run tools/headless_tests/snapshot_check.luau describe <file> <text file>
--
-- `save` plays an AI match `before` seconds (args as the snapshot_roundtrip test takes them: `teams`, `line`,
-- `scavengers`, `progress`), takes it (`snapshot.take`) into <file>, plays on `after` seconds and keeps where that
-- got to in <file>.after, with `after` beside it in <file>.json. `load` starts a fresh session on the same map, puts
-- <file> back, plays on as long, and says whether it got to exactly the same place, and where it first did not; it
-- exits with 1 if it did not. `describe` writes a snapshot out as text, a line for each value (snapshot.describe).

local fs = require "@lune/fs"
local process = require "@lune/process"
local serde = require "@lune/serde"

local session = require "../lib/session"

local root = process.cwd
local mode, file = process.args[1], process.args[2]
assert(
	(mode == "save" or mode == "load" or mode == "describe") and file ~= nil,
	"usage: snapshot_check.luau save|load|describe <file> ['<json args>' | <text file>]"
)

local TICKS_PER_SECOND = 20

-- Everything but the snapshot is left as a session a test starts has it, so both processes build the same map.
local function start()
	return session.start({ root = root, random_seed = 7 })
end

if mode == "describe" then
	local game = start()
	local lines = game.server("snapshot").describe(buffer.fromstring(fs.readFile(file)))
	fs.writeFile(process.args[3], table.concat(lines, "\n"))
elseif mode == "save" then
	local args = if process.args[3] ~= nil then serde.decode("json", process.args[3]) else {}
	local before = args.before or 240
	local after = args.after or 60
	local game = start()
	local ai = game.server "ai"
	local snapshot = game.server "snapshot"
	for index = 1, args.teams or 2 do
		local team = ai.spawn_opponent(`AI {index}`, nil, nil, nil)
		assert(team ~= nil, `there was no room for AI {index}`)
		if args.line == "bot" or args.line == "vehicle" then
			ai.set_line(team, args.line)
		end
	end
	if args.scavengers == true then
		game.shared("switches").set("scavengers", true)
		game.server("scavengers").set_progress(args.progress or 0.3)
	end
	game.advance(before * TICKS_PER_SECOND)
	local kept = snapshot.take()
	fs.writeFile(file, buffer.tostring(kept))
	game.advance(after * TICKS_PER_SECOND)
	fs.writeFile(`{file}.after`, buffer.tostring(snapshot.capture()))
	fs.writeFile(`{file}.json`, serde.encode("json", { after = after }))
	print(`kept {buffer.len(kept)} bytes at {before} s, and where it got to {after} s on`)
else
	local settings = serde.decode("json", fs.readFile(`{file}.json`))
	local game = start()
	local snapshot = game.server "snapshot"
	snapshot.restore(buffer.fromstring(fs.readFile(file)))
	game.advance(settings.after * TICKS_PER_SECOND)
	local got = snapshot.capture()
	local expected = buffer.fromstring(fs.readFile(`{file}.after`))
	if buffer.tostring(got) == buffer.tostring(expected) then
		print(`SAME: put back in a fresh session, it played on {settings.after} s to exactly the same place`)
	else
		local lines_expected, lines_got = snapshot.describe(expected), snapshot.describe(got)
		local shown = 0
		local by_part: { [string]: number } = {}
		for index = 1, math.max(#lines_expected, #lines_got) do
			if lines_expected[index] ~= lines_got[index] then
				local line = lines_expected[index] or lines_got[index]
				local part = string.match(line, "^[^.= ]+") or "?"
				by_part[part] = (by_part[part] or 0) + 1
				if shown < 15 then
					shown += 1
					print(`  {lines_expected[index] or "(none)"}  |  {lines_got[index] or "(none)"}`)
				end
			end
		end
		print(`DIFFERENT after {settings.after} s: {serde.encode("json", by_part)}`)
		process.exit(1)
	end
end
