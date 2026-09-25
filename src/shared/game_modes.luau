-- The ways a game can be set up, and what a lobby hands the game server when it starts one.
--
-- A mode is scavengers (everyone on one side against them, at a difficulty), a team game of N against N, a free for
-- all, or a campaign mission played alone (see campaign.luau). The lobby lets its host pick one of the first three and
-- seats its players by it; the game server reads the result back as a `Match` (see `server/match.luau`) and builds the
-- map, the teams and the alliances from it.
--
-- The match travels from the lobby server to the reserved game server through a MemoryStore hash map, keyed by the
-- reserved server's PrivateServerId, and in every player's teleport data as well. The game trusts the store, which only
-- a server can write; the teleport data comes by way of the client, so it is the fallback (see server/match.luau).

local ReplicatedStorage = game:GetService "ReplicatedStorage"

local campaign = require(ReplicatedStorage.Shared.campaign)

export type ModeKind = "scavengers" | "teams" | "ffa" | "campaign"

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
	-- the mission played, for a campaign mode: an id from campaign.MISSIONS. A campaign mode is never offered in the
	-- lobby's list of modes; the campaign screen starts it, on the mission's own map, for one player or for a co-op
	-- lobby, whose players are all on one side, allied, up to the mission's `coop`.
	mission: string?,
}

-- How a team game or a free for all is won: which sides are out (see server/conquest.luau). A side is an alliance, the
-- teams seated on it, and it is out once what the mode looks at is gone from every one of them, as BAR's end modes have
-- it: its commanders ("commanders", BAR's default and this game's), anything that can build, units and labs alike
-- ("builders"), or everything it has ("units"). The last side left wins. "never" puts no side out, whatever it loses.
-- Scavenger and campaign games end their own ways, whatever a match says.
export type EndMode = "commanders" | "builders" | "units" | "never"

export type EndModeOption = {
	id: EndMode,
	-- what the lobby shows
	label: string,
}

export type Difficulty = {
	id: string,
	label: string,
	-- How long the scavengers take to reach full strength, as a multiple of config.SCAVENGER_GAME_LENGTH (80
	-- minutes). Their strength follows the game's progress, so a shorter game is a harder one.
	pace: number,
	-- What everything the scavengers field has in health, as a multiple of its def's: their units, their defences and
	-- their boss. Their beacons grow tougher with the progress instead (config.SCAVENGER_BEACON_HEALTH_GROWTH).
	health: number,
}

-- One player at the table, on a side, or watching.
export type Seat = {
	user_id: number,
	name: string,
	-- 1-based, or SPECTATOR_SIDE for someone who only watches: they come to the game with everyone else, but are on no
	-- team and have nothing to command
	side: number,
}

export type Match = {
	mode: string,
	preset: string,
	seed: number,
	seats: { Seat },
	-- each player's resource bonus, by user id as a string (a table keyed by numbers this sparse does not survive a
	-- remote or the store), as a whole percent from BONUS_MIN to BONUS_MAX; a player with none is left out (`bonus_of`)
	bonuses: { [string]: number },
	-- whether a team's weapons hurt its allies' things, as BAR's always do; off, they only hurt its own and its enemies'
	ally_griefing: boolean,
	-- how a team game or a free for all is won
	end_mode: EndMode,
}

local END_MODES: { EndModeOption } = {
	{ id = "commanders", label = "Coms dead" },
	{ id = "builders", label = "Builders dead" },
	{ id = "units", label = "All dead" },
	{ id = "never", label = "Never" },
}

local DEFAULT_END_MODE: EndMode = "commanders"

local DIFFICULTIES: { Difficulty } = {
	-- 80, 64, 52 and 40 minutes
	{ id = "easy", label = "Easy", pace = 1, health = 1 },
	{ id = "normal", label = "Normal", pace = 0.8, health = 2 },
	{ id = "hard", label = "Hard", pace = 0.65, health = 3 },
	{ id = "brutal", label = "Brutal", pace = 0.5, health = 5 },
}

-- The side a spectator sits on, and how many a lobby has room for besides its players.
local SPECTATOR_SIDE = 0
local SPECTATOR_CAPACITY = 8

-- A game against the scavengers seats this many at most.
local SCAVENGER_CAPACITY = 8
local LARGEST_TEAM = 5
local FFA_CAPACITY = 8

-- The seed the procedural maps are built from. The BAR maps ignore it.
local DEFAULT_SEED = 1337

-- The resource bonus a developer may give each player, in percent: what their extractors and generators make is scaled
-- by 1 + bonus / 100, so +100 doubles it and -100 leaves nothing. It is picked in steps of BONUS_STEP.
local BONUS_MIN = -100
local BONUS_MAX = 100
local BONUS_STEP = 10

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
		mission = nil,
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
		mission = nil,
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
	mission = nil,
})
for _, mission in campaign.MISSIONS do
	table.insert(MODES, {
		id = `campaign_{mission.id}`,
		kind = "campaign" :: ModeKind,
		label = mission.label,
		sides = 1,
		per_side = mission.coop or 1,
		capacity = mission.coop or 1,
		minimum = 1,
		difficulty = nil,
		mission = mission.id,
	})
end

local mode_by_id: { [string]: Mode } = {}
for _, mode in MODES do
	mode_by_id[mode.id] = mode
end

local DEFAULT_MODE = "scav_normal"

-- `value` as an end mode, or nil if it is not one.
local function end_mode(value: any): EndMode?
	for _, option in END_MODES do
		if option.id == value then
			return option.id
		end
	end
	return nil
end

local function get(id: string): Mode?
	return mode_by_id[id]
end

-- The campaign mode that plays `mission_id`.
local function campaign_mode(mission_id: string): Mode?
	return mode_by_id[`campaign_{mission_id}`]
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

local function is_spectator(seat: Seat): boolean
	return seat.side == SPECTATOR_SIDE
end

-- How many of `seats` are players, and not spectators.
local function player_count(seats: { Seat }): number
	local count = 0
	for _, seat in seats do
		if is_spectator(seat) == false then
			count += 1
		end
	end
	return count
end

-- How many of `seats` are spectators.
local function spectator_count(seats: { Seat }): number
	return #seats - player_count(seats)
end

-- Whether a match seated as `seats` can start in `mode`: enough players, and every side of a team game manned.
-- Spectators do not count. Returns why not when it cannot.
local function can_start(mode: Mode, seats: { Seat }): (boolean, string?)
	if player_count(seats) < mode.minimum then
		return false, if mode.minimum == 1 then "Nobody is seated" else `Needs {mode.minimum} players`
	end
	if mode.kind == "teams" then
		local manned: { [number]: boolean } = {}
		for _, seat in seats do
			if is_spectator(seat) == false then
				manned[seat.side] = true
			end
		end
		for side = 1, mode.sides do
			if manned[side] ~= true then
				return false, `Team {side} is empty`
			end
		end
	end
	return true, nil
end

-- `percent` as a bonus can be: a whole number from BONUS_MIN to BONUS_MAX. Anything that is not a number is none.
local function clamp_bonus(percent: any): number
	if typeof(percent) ~= "number" or percent ~= percent then
		return 0
	end
	return math.clamp(math.round(percent), BONUS_MIN, BONUS_MAX)
end

-- The resource bonus of the player `user_id` in `match`, in percent; 0 for one it gives none.
local function bonus_of(match: Match, user_id: number): number
	return match.bonuses[tostring(user_id)] or 0
end

-- A match as a plain table of strings and numbers, for the MemoryStore.
local function encode(match: Match): { [string]: any }
	local seats = {}
	for _, seat in match.seats do
		table.insert(seats, { user_id = seat.user_id, name = seat.name, side = seat.side })
	end
	return {
		mode = match.mode,
		preset = match.preset,
		seed = match.seed,
		seats = seats,
		bonuses = table.clone(match.bonuses),
		ally_griefing = match.ally_griefing,
		end_mode = match.end_mode,
	}
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
	-- a match stored before there were bonuses has none, and one from when they were by side has none of these
	local bonuses: { [string]: number } = {}
	if typeof(value.bonuses) == "table" then
		for _, seat in seats do
			local percent = clamp_bonus(value.bonuses[tostring(seat.user_id)])
			if percent ~= 0 then
				bonuses[tostring(seat.user_id)] = percent
			end
		end
	end
	return table.freeze({
		mode = value.mode,
		preset = value.preset,
		seed = value.seed,
		seats = seats,
		bonuses = table.freeze(bonuses),
		-- a match stored before it could be chosen has it off
		ally_griefing = value.ally_griefing == true,
		-- and one stored before it could be chosen ends as BAR's games do by default
		end_mode = end_mode(value.end_mode) or DEFAULT_END_MODE,
	})
end

return table.freeze({
	MODES = MODES,
	DIFFICULTIES = DIFFICULTIES,
	END_MODES = END_MODES,
	DEFAULT_MODE = DEFAULT_MODE,
	DEFAULT_END_MODE = DEFAULT_END_MODE,
	DEFAULT_SEED = DEFAULT_SEED,
	SPECTATOR_SIDE = SPECTATOR_SIDE,
	SPECTATOR_CAPACITY = SPECTATOR_CAPACITY,
	MATCH_STORE = MATCH_STORE,
	MATCH_TTL = MATCH_TTL,
	BONUS_MIN = BONUS_MIN,
	BONUS_MAX = BONUS_MAX,
	BONUS_STEP = BONUS_STEP,
	get = get,
	end_mode = end_mode,
	clamp_bonus = clamp_bonus,
	bonus_of = bonus_of,
	difficulty = difficulty,
	campaign_mode = campaign_mode,
	find = find,
	can_start = can_start,
	is_spectator = is_spectator,
	player_count = player_count,
	spectator_count = spectator_count,
	encode = encode,
	decode = decode,
})
