--!strict
-- Replays: a game the AI arena played (tools/ai_arena, a duel with `record`), played back in Studio to watch.
--
-- A replay is the game itself at a number of moments, its jump points: the whole game as it stood then, as
-- server/snapshot captures it, from just after its sides were put down and every so many seconds after (the
-- `keyframe_every` its manifest says). The arena `take`s each (snapshot.take), so that the game it played went on from
-- exactly what was kept; a copy put back from the same bytes therefore plays on bit for bit as the arena did, and one
-- played on through a jump point is taken there too (see `check`). Played back, the game is put back to the jump point
-- at or before where it is wanted, and the simulation runs on from there,
-- warped (server/warp.luau) to the moment asked for: skipping to the end is never more than one gap between jump points
-- of simulation. A moment a little ahead is warped to from where the game already is.
--
-- As it plays past each jump point, and each of the checks the arena recorded between them (`checks`, every
-- `check_every` seconds), it takes the game's checksum (snapshot.checksum of a capture) and holds it up against the one
-- the arena recorded there: the same means the replay is still the game that was played; anything else
-- (another version of the game's code, most likely) means it has gone its own way since the last one. Where it stands
-- is published on Workspace for anyone watching: REPLAY_ATTRIBUTES.
--
-- The replay is loaded into Studio by tools/ai_arena/replay.py (`studio`), as ServerStorage.Replay: a StringValue
-- `manifest` holding the manifest's JSON, and a Folder `keyframes` holding a Folder for each jump point, named by its
-- file, of StringValues named 1, 2, ... whose values, in that order, are the snapshot's bytes in base64. With
-- Workspace's `Replay` set, a Studio session plays it (session_config.luau). The pow command `replay` seeks, and so
-- does setting Workspace's `replay_seek` (REPLAY_ATTRIBUTES.seek) to a number of seconds.
--
-- A game the Rust AI played (tools/rust_ai) comes with what it told its sides to do each second (orders.json, loaded as
-- ServerStorage.Replay.orders, StringValues named 1, 2, ... of its JSON in order), as that player cannot run here: they
-- are given again after the step that ends each second, before anything is checked there, as the arena gave them
-- (server/external_orders.luau).
--
-- It is watched like a video (client/ui/replay_seeker.luau): played and paused, run faster (pace.luau), and sought by
-- the time along a bar. One of those watching has the controls, the first to join, and the next once they leave
-- (REPLAY_ATTRIBUTES.controller); what anyone else asks for is ignored. It stops at the end of the recorded game, past
-- which the game would only go on unrecorded.

local HttpService = game:GetService "HttpService"
local Players = game:GetService "Players"
local ReplicatedStorage = game:GetService "ReplicatedStorage"
local ServerScriptService = game:GetService "ServerScriptService"
local ServerStorage = game:GetService "ServerStorage"
local Workspace = game:GetService "Workspace"

local tick_rate = require(ReplicatedStorage.Shared.tick_rate)
local switches = require(ReplicatedStorage.Shared.switches)
local decode = require(ReplicatedStorage.Shared.decode)

local remotes = require(ServerScriptService.ServerShared.remotes)

local snapshot = require(script.Parent.snapshot)
local state = require(script.Parent.state)
local warp = require(script.Parent.warp)
local simulation = require(script.Parent.simulation)
local pace = require(script.Parent.pace)
local external_orders = require(script.Parent.external_orders)

export type Keyframe = {
	-- seconds of game when it was taken
	t: number,
	file: string,
	checksum: number,
	bytes: number,
}

export type Manifest = {
	version: number,
	map: { preset: string, seed: number },
	-- seconds of game the recorded game lasted
	length: number,
	keyframe_every: number,
	keyframes: { Keyframe },
	-- the game's checksum between jump points
	check_every: number?,
	checks: { { t: number, checksum: number } }?,
	-- the file of what the Rust AI told its sides each second, for a game it played
	orders: string?,
	-- what played it, how it ended and with what code, as the arena wrote them
	sides: any,
	result: any,
	code: any,
}

-- What is published on Workspace for anyone watching, by what it is.
local REPLAY_ATTRIBUTES = table.freeze({
	-- seconds of game the replay has got to
	time = "replay_time",
	-- seconds of game it lasts
	length = "replay_length",
	-- how it stands against the recorded game: "in sync" up to the last check it passed, or where it went its own way
	status = "replay_status",
	-- set to a number of seconds of game, to go there (as `seek`); it is cleared once it has
	seek = "replay_seek",
	-- the UserId of the one watching who has the controls
	controller = "replay_controller",
	-- how many times as fast as real time it plays (pace.luau)
	speed = "replay_speed",
	-- whether it is being warped to a moment it was sought to
	seeking = "replay_seeking",
	-- the seconds between its jump points, where a seek lands at once
	jump_every = "replay_jump_every",
})
-- What the one with the controls may ask for (the ReplayControl remote): to go to a moment (seconds of game), to pause
-- or to play, or to play at a speed (times as fast as real time), and how often.
local ACTIONS = { "seek", "pause", "play", "speed" }
local CONTROL_RATE: remotes.Rate = { per_second = 10, burst = 20 }
local FOLDER = "Replay"
-- A game's clock is a sum of step lengths, so a jump point's moment is matched to within half a step.
local HALF_STEP = tick_rate.TICK_DELTA / 2

local manifest: Manifest? = nil
-- each jump point's snapshot, once it has been read out of its StringValues
local decoded: { [number]: buffer } = {}
-- every moment there is a checksum for, jump points (`jump`) and checks alike, in order of time
local marks: { { t: number, checksum: number, jump: boolean? } } = {}
-- the last of `marks` put back to or checked, by index
local reached = 0
local diverged_at: number? = nil
local started = false
-- the UserId of the one with the controls, if anyone is watching
local controller: number? = nil
-- whether it is to be paused again once the warp to where it was sought ends: a paused replay sought stays paused
local pause_after_seek = false
-- whether it has been stopped at the end of the recorded game
local ended = false
-- for a game the Rust AI played, its orders, given again as the game gets to them
local orders_player: external_orders.Player? = nil

-- base64, as Python's base64.b64encode writes it
local ALPHABET = "ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789+/"
local VALUE: { [number]: number } = {}
for index = 1, #ALPHABET do
	VALUE[string.byte(ALPHABET, index)] = index - 1
end

local function decode_base64(text: string): buffer
	local length = #text
	local padding = if string.sub(text, -2) == "==" then 2 elseif string.sub(text, -1) == "=" then 1 else 0
	local size = length // 4 * 3 - padding
	local out = buffer.create(size)
	local at = 0
	for index = 1, length, 4 do
		local a, b, c, d = string.byte(text, index, index + 3)
		local bits = bit32.bor(
			bit32.lshift(VALUE[a] or 0, 18),
			bit32.lshift(VALUE[b] or 0, 12),
			bit32.lshift(VALUE[c] or 0, 6),
			VALUE[d] or 0
		)
		buffer.writeu8(out, at, bit32.extract(bits, 16, 8))
		if at + 1 < size then
			buffer.writeu8(out, at + 1, bit32.extract(bits, 8, 8))
		end
		if at + 2 < size then
			buffer.writeu8(out, at + 2, bit32.extract(bits, 0, 8))
		end
		at += 3
	end
	return out
end

-- Whether a replay has been loaded into ServerStorage.
local function available(): boolean
	local folder = ServerStorage:FindFirstChild(FOLDER)
	return folder ~= nil and folder:FindFirstChild "manifest" ~= nil
end

-- The loaded replay's manifest, read once.
local function read_manifest(): Manifest
	if manifest == nil then
		local value = (ServerStorage:FindFirstChild(FOLDER) :: Folder):FindFirstChild "manifest" :: StringValue
		manifest = HttpService:JSONDecode(value.Value)
	end
	return manifest :: Manifest
end

-- Jump point `index`'s snapshot.
local function keyframe_data(index: number): buffer
	local cached = decoded[index]
	if cached ~= nil then
		return cached
	end
	local keyframe = read_manifest().keyframes[index]
	local folder = (ServerStorage:FindFirstChild(FOLDER) :: Folder):FindFirstChild "keyframes" :: Folder
	local found = folder:FindFirstChild(keyframe.file)
	assert(found ~= nil, `the replay has no jump point {keyframe.file}`)
	local parts = found :: Folder
	local pieces: { string } = {}
	for part = 1, #parts:GetChildren() do
		table.insert(pieces, (parts:FindFirstChild(tostring(part)) :: StringValue).Value)
	end
	local data = decode_base64(table.concat(pieces))
	assert(
		buffer.len(data) == keyframe.bytes,
		`jump point {keyframe.file} is {buffer.len(data)} bytes, not {keyframe.bytes}`
	)
	decoded[index] = data
	return data
end

-- Seconds as m:ss.
local function clock(seconds: number): string
	return `{math.floor(seconds // 60)}:{string.format("%02d", math.floor(seconds % 60))}`
end

local function publish()
	Workspace:SetAttribute(REPLAY_ATTRIBUTES.time, state.now())
	local checked = marks[reached]
	Workspace:SetAttribute(
		REPLAY_ATTRIBUTES.status,
		if diverged_at ~= nil
			then `went its own way before {clock(diverged_at)}`
			elseif checked ~= nil then `in sync, checked to {clock(checked.t)}`
			else "in sync"
	)
end

-- Puts the game back to jump point `index`, keeping the pause as whoever is watching left it.
local function restore(index: number)
	local paused = switches.is_on "paused"
	snapshot.restore(keyframe_data(index))
	switches.set("paused", paused)
	local at = read_manifest().keyframes[index].t
	if orders_player ~= nil then
		orders_player.rewind(at, HALF_STEP)
	end
	reached = 0
	for mark_index, mark in marks do
		if mark.t <= at + HALF_STEP then
			reached = mark_index
		end
	end
	publish()
end

-- At a mark, whether it is still the recorded game. At a jump point the game is `take`n, as the arena took it there
-- (snapshot.take): the recorded game went on from a copy put back, whose tables go through their entries in another
-- order than those of a game played on to it, so one only played on to it goes its own way after.
local function check()
	local next_index = reached + 1
	local mark = marks[next_index]
	if mark == nil or math.abs(state.now() - mark.t) >= HALF_STEP then
		return
	end
	reached = next_index
	local captured = if mark.jump == true then snapshot.take() else snapshot.capture()
	local checksum = snapshot.checksum(captured)
	if checksum ~= mark.checksum and diverged_at == nil then
		-- for finding out what differs: the game as it stands, as snapshot.describe lays it out, on Workspace
		if Workspace:GetAttribute "replay_dump" == true then
			local lines = snapshot.describe(captured)
			local dump = Instance.new "Folder"
			dump.Name = `replay_dump_{mark.t}`
			for part = 1, math.ceil(#lines / 2000) do
				local value = Instance.new "StringValue"
				value.Name = tostring(part)
				value.Value = table.concat(lines, "\n", (part - 1) * 2000 + 1, math.min(#lines, part * 2000))
				value.Parent = dump
			end
			-- and the order the world's entities are gone through in, which a sum over them depends on
			local order: { string } = {}
			for id in state.all() do
				table.insert(order, tostring(id))
			end
			local order_value = Instance.new "StringValue"
			order_value.Name = "order"
			order_value.Value = table.concat(order, " ")
			order_value.Parent = dump
			dump.Parent = ServerStorage
		end
		diverged_at = mark.t
		warn(
			`replay: at {mark.t} s the game is not the recorded one (checksum {checksum}, recorded {mark.checksum}); `
				.. "it was recorded with other code, most likely"
		)
	end
	publish()
end

-- After every step: the time it has got to, and at a mark, whether it is still the recorded game; then paused, where a
-- seek or the recorded game ends. Checked first: the pause is kept with the game (bootstrap's switches keeper), and the
-- recorded game was never paused.
local function stepped()
	local loaded = manifest
	if loaded == nil then
		return
	end
	-- the Rust AI's orders of the second it has got to come first, as they did in the arena, before its checksum
	if orders_player ~= nil then
		orders_player.at(state.now(), HALF_STEP)
	end
	Workspace:SetAttribute(REPLAY_ATTRIBUTES.time, state.now())
	check()
	if Workspace:GetAttribute(REPLAY_ATTRIBUTES.seeking) == true and warp.is_warping() == false then
		Workspace:SetAttribute(REPLAY_ATTRIBUTES.seeking, false)
		if pause_after_seek then
			pause_after_seek = false
			switches.set("paused", true)
		end
	end
	if ended == false and state.now() >= loaded.length - HALF_STEP then
		ended = true
		warp.stop()
		switches.set("paused", true)
	end
end

-- Plays from `seconds` of game on: put back to the jump point at or before it, and warped the rest of the way, paused
-- again once there if it was. A moment ahead of where it is, with no jump point between, is warped to from where it
-- is instead, which is the same game and less of it to run - unless it has gone its own way, which only a jump point
-- puts right. Returns where it will be.
local function seek(seconds: number): number
	local loaded = read_manifest()
	local target = math.clamp(seconds, 0, loaded.length)
	local index = 1
	for at, keyframe in loaded.keyframes do
		if keyframe.t <= target + HALF_STEP then
			index = at
		end
	end
	-- paused as whoever is watching left it, which a seek still under way has only lifted for its warp
	local was_paused = switches.is_on "paused"
		or (Workspace:GetAttribute(REPLAY_ATTRIBUTES.seeking) == true and pause_after_seek)
	local from = state.now()
	if diverged_at ~= nil or target < from - HALF_STEP or loaded.keyframes[index].t > from + HALF_STEP then
		-- whatever was found out about going its own way was about what came after the last jump point put back
		diverged_at = nil
		-- it stops at the end again, getting there
		ended = false
		restore(index)
		from = loaded.keyframes[index].t
	end
	warp.stop()
	pause_after_seek = false
	Workspace:SetAttribute(REPLAY_ATTRIBUTES.seeking, false)
	switches.set("paused", was_paused)
	local ticks = math.round((target - from) / tick_rate.TICK_DELTA)
	if ticks > 0 then
		-- the warp only runs while the game is not paused, and it is paused again once it gets there if it was
		pause_after_seek = was_paused
		switches.set("paused", false)
		Workspace:SetAttribute(REPLAY_ATTRIBUTES.seeking, true)
		warp.start(ticks)
	end
	return target
end

-- Hands the controls to `player`, or to nobody.
local function give_controls(player: Player?)
	controller = if player ~= nil then player.UserId else nil
	Workspace:SetAttribute(REPLAY_ATTRIBUTES.controller, controller)
end

-- What the one with the controls asked for.
local function on_control(player: Player, action: string, value: number)
	if player.UserId ~= controller then
		return
	end
	if action == "seek" then
		seek(value)
	elseif action == "pause" then
		switches.set("paused", true)
	elseif action == "play" then
		-- at the end it plays from the start again, as a video does
		if ended then
			seek(0)
		end
		switches.set("paused", false)
	elseif action == "speed" then
		pace.set(value)
		Workspace:SetAttribute(REPLAY_ATTRIBUTES.speed, pace.get())
	end
end

-- Starts playing the loaded replay from its first jump point.
-- For a game the Rust AI played, a player of its orders from the start, as loaded with the replay; nil for any other.
local function load_orders(): external_orders.Player?
	if read_manifest().orders == nil then
		return nil
	end
	local folder = (ServerStorage:FindFirstChild(FOLDER) :: Folder):FindFirstChild "orders"
	assert(folder ~= nil, "the replay is of a game the Rust AI played, but its orders were not loaded")
	local pieces: { string } = {}
	for part = 1, #folder:GetChildren() do
		table.insert(pieces, ((folder :: Folder):FindFirstChild(tostring(part)) :: StringValue).Value)
	end
	return external_orders.player(HttpService:JSONDecode(table.concat(pieces)))
end

local function start()
	assert(available(), "no replay is loaded (tools/ai_arena/replay.py studio <replay>)")
	local loaded = read_manifest()
	Workspace:SetAttribute(REPLAY_ATTRIBUTES.length, loaded.length)
	Workspace:SetAttribute(REPLAY_ATTRIBUTES.jump_every, loaded.keyframe_every)
	table.clear(marks)
	for _, keyframe in loaded.keyframes do
		table.insert(marks, { t = keyframe.t, checksum = keyframe.checksum, jump = true })
	end
	local checks: { { t: number, checksum: number } } = loaded.checks or {}
	for _, check in checks do
		table.insert(marks, { t = check.t, checksum = check.checksum })
	end
	table.sort(marks, function(a, b): boolean
		return a.t < b.t
	end)
	orders_player = load_orders()
	if started == false then
		started = true
		simulation.on_stepped(stepped)
		Workspace:SetAttribute(REPLAY_ATTRIBUTES.speed, pace.get())
		Workspace:SetAttribute(REPLAY_ATTRIBUTES.seeking, false)
		remotes.listen(
			ReplicatedStorage.Shared.ReplayControl,
			{ args = { decode.one_of(ACTIONS), decode.number }, rate = CONTROL_RATE },
			on_control
		)
		-- the first to watch has the controls, and the next once they leave
		local watching = Players:GetPlayers()
		give_controls(watching[1])
		Players.PlayerAdded:Connect(function(player: Player)
			if controller == nil then
				give_controls(player)
			end
		end)
		Players.PlayerRemoving:Connect(function(player: Player)
			if player.UserId == controller then
				local next_player: Player? = nil
				for _, other in Players:GetPlayers() do
					if other ~= player then
						next_player = other
						break
					end
				end
				give_controls(next_player)
			end
		end)
		Workspace:SetAttribute(REPLAY_ATTRIBUTES.seek, nil)
		Workspace:GetAttributeChangedSignal(REPLAY_ATTRIBUTES.seek):Connect(function()
			local asked = Workspace:GetAttribute(REPLAY_ATTRIBUTES.seek)
			if typeof(asked) == "number" then
				Workspace:SetAttribute(REPLAY_ATTRIBUTES.seek, nil)
				seek(asked)
			end
		end)
	end
	restore(1)
	print(
		`replay: {loaded.map.preset}, {#loaded.keyframes} jump points {loaded.keyframe_every} s apart, `
			.. `{math.floor(loaded.length)} s long`
	)
end

-- Whether a replay is being played.
local function playing(): boolean
	return started
end

return table.freeze({
	REPLAY_ATTRIBUTES = REPLAY_ATTRIBUTES,
	available = available,
	read_manifest = read_manifest,
	start = start,
	seek = seek,
	playing = playing,
	keyframe_data = keyframe_data,
	load_orders = load_orders,
	decode_base64 = decode_base64,
})
