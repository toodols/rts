-- The ways a game can be set up, and what a lobby hands the game server when it starts one.
--
-- A mode is scavengers (everyone on one side against them, at a difficulty), a team game of N against N, or a free for
-- all. The lobby lets its host pick one and seats its players by it; the game server reads the result back as a
-- `Match` (see `server/match.luau`) and builds the map, the teams and the alliances from it.
--
-- The match travels from the lobby server to the reserved game server through a MemoryStore hash map, keyed by the
-- reserved server's PrivateServerId, rather than in the teleport data, which a client can tamper with.

export type ModeKind = "scavengers" | "teams" | "ffa"

export type Mode = {
	-- what is sent and stored, like "scav_hard", "2v2" or "ffa"
	id: string,
	kind: ModeKind,
	-- what the lobby shows
	label: string,
	-- how many sides the players are seated on: 1 against the scavengers, 2 in a team game, one each in a free for all
	sides: number,
	-- how many players each side seats; a free for all has one to a side and as many sides as it seats players
	per_side: number,
	-- the most players it seats in all
	capacity: number,
	-- the fewest players it can start with
	minimum: number,
	-- the scavengers' difficulty, for a scavengers mode
	difficulty: string?,
}

export type Difficulty = {
	id: string,
	label: string,
	-- How long the scavengers take to reach full strength, as a multiple of config.SCAVENGER_GAME_LENGTH. Their
	-- strength follows the game's progress, so a shorter game is a harder one.
	pace: number,
}

-- One player at the table, on a side.
export type Seat = {
	user_id: number,
	name: string,
	-- 1-based
	side: number,
}

export type Match = {
	mode: string,
	preset: string,
	seed: number,
	seats: { Seat },
}

local DIFFICULTIES: { Difficulty } = {
	{ id = "easy", label = "Easy", pace = 1.6 },
	{ id = "normal", label = "Normal", pace = 1 },
	{ id = "hard", label = "Hard", pace = 0.7 },
	{ id = "brutal", label = "Brutal", pace = 0.45 },
}

-- A game against the scavengers seats this many at most.
local SCAVENGER_CAPACITY = 8
local LARGEST_TEAM = 5
local FFA_CAPACITY = 8

-- The seed the procedural maps are built from. The BAR maps ignore it.
local DEFAULT_SEED = 1337

-- Where a started match waits for its server, and how long it waits.
local MATCH_STORE = "matches"
local MATCH_TTL = 60 * 60

local difficulty_by_id: { [string]: Difficulty } = {}
for _, difficulty in DIFFICULTIES do
	difficulty_by_id[difficulty.id] = difficulty
end

local MODES: { Mode } = {}
for _, difficulty in DIFFICULTIES do
	table.insert(MODES, {
		id = `scav_{difficulty.id}`,
		kind = "scavengers" :: ModeKind,
		label = `Scav {difficulty.label}`,
		sides = 1,
		per_side = SCAVENGER_CAPACITY,
		capacity = SCAVENGER_CAPACITY,
		minimum = 1,
		difficulty = difficulty.id,
	})
end
for size = 1, LARGEST_TEAM do
	table.insert(MODES, {
		id = `{size}v{size}`,
		kind = "teams" :: ModeKind,
		label = `{size}v{size}`,
		sides = 2,
		per_side = size,
		capacity = size * 2,
		-- one a side at least, so there is someone to play against
		minimum = 2,
		difficulty = nil,
	})
end
table.insert(MODES, {
	id = "ffa",
	kind = "ffa" :: ModeKind,
	label = "FFA",
	sides = FFA_CAPACITY,
	per_side = 1,
	capacity = FFA_CAPACITY,
	minimum = 2,
	difficulty = nil,
})

local mode_by_id: { [string]: Mode } = {}
for _, mode in MODES do
	mode_by_id[mode.id] = mode
end

local DEFAULT_MODE = "scav_normal"

local function get(id: string): Mode?
	return mode_by_id[id]
end

local function difficulty(id: string): Difficulty?
	return difficulty_by_id[id]
end

-- The mode of `kind`, for team games of `per_side` a side and for scavengers at `difficulty_id`.
local function find(kind: ModeKind, per_side: number?, difficulty_id: string?): Mode?
	for _, mode in MODES do
		if mode.kind ~= kind then
			continue
		end
		if kind == "teams" and mode.per_side ~= per_side then
			continue
		end
		if kind == "scavengers" and mode.difficulty ~= difficulty_id then
			continue
		end
		return mode
	end
	return nil
end

-- Whether a match seated as `seats` can start in `mode`: enough players, and every side of a team game manned.
-- Returns why not when it cannot.
local function can_start(mode: Mode, seats: { Seat }): (boolean, string?)
	if #seats < mode.minimum then
		return false, if mode.minimum == 1 then "Nobody is seated" else `Needs {mode.minimum} players`
	end
	if mode.kind == "teams" then
		local manned: { [number]: boolean } = {}
		for _, seat in seats do
			manned[seat.side] = true
		end
		for side = 1, mode.sides do
			if manned[side] ~= true then
				return false, `Team {side} is empty`
			end
		end
	end
	return true, nil
end

-- A match as a plain table of strings and numbers, for the MemoryStore.
local function encode(match: Match): { [string]: any }
	local seats = {}
	for _, seat in match.seats do
		table.insert(seats, { user_id = seat.user_id, name = seat.name, side = seat.side })
	end
	return { mode = match.mode, preset = match.preset, seed = match.seed, seats = seats }
end

-- The match a table read from the MemoryStore holds, or nil if it is not one.
local function decode(value: any): Match?
	if typeof(value) ~= "table" then
		return nil
	end
	if typeof(value.mode) ~= "string" or typeof(value.preset) ~= "string" or typeof(value.seed) ~= "number" then
		return nil
	end
	if mode_by_id[value.mode] == nil or typeof(value.seats) ~= "table" then
		return nil
	end
	local seats: { Seat } = {}
	for _, seat in value.seats do
		if typeof(seat) ~= "table" or typeof(seat.user_id) ~= "number" or typeof(seat.side) ~= "number" then
			return nil
		end
		table.insert(seats, {
			user_id = seat.user_id,
			name = if typeof(seat.name) == "string" then seat.name else tostring(seat.user_id),
			side = seat.side,
		})
	end
	return table.freeze({ mode = value.mode, preset = value.preset, seed = value.seed, seats = seats })
end

return table.freeze({
	MODES = MODES,
	DIFFICULTIES = DIFFICULTIES,
	DEFAULT_MODE = DEFAULT_MODE,
	DEFAULT_SEED = DEFAULT_SEED,
	MATCH_STORE = MATCH_STORE,
	MATCH_TTL = MATCH_TTL,
	get = get,
	difficulty = difficulty,
	find = find,
	can_start = can_start,
	encode = encode,
	decode = decode,
})
