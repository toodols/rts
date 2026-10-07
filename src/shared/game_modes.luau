--!strict
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

-- The groups a lobby's host picks a mode from.
export type ModeGroup = "scavengers" | "teams" | "ffa"

-- A mode is data: what the lobby shows and seats by, and the rules the game server plays it by, which the systems that
-- keep them read (`difficulty`, `eliminates`, `rated`, `mission`), so that nothing asks what kind of mode it is.
export type Mode = {
	-- what is sent and stored, like "scav_hard", "2v2" or "ffa"
	id: string,
	-- the group a lobby offers it in; nil for a campaign mode, which no lobby's host can pick (see `mission`)
	group: ModeGroup?,
	-- its name, and what its chip in its group says, where the group's caption already says the rest
	label: string,
	chip_label: string,
	-- what the lobby's browser and title call it
	lobby_label: string,
	-- whether each player picks the side they sit on, as in a team game, rather than taking whichever seat is free
	picks_sides: boolean,
	-- what the lobby calls a side: numbered after it for a mode whose players pick one, or else the one group of seats
	side_label: string,
	-- how many sides the players are seated on: 1 against the scavengers, 2 in a team game, one each in a free for all
	sides: number,
	-- how many players each side seats; a free for all has one to a side and as many sides as it seats players
	per_side: number,
	-- the most players it seats in all
	capacity: number,
	-- the fewest players it can start with
	minimum: number,
	-- whether every side must be manned for it to start, as a team game's must
	every_side_manned: boolean,
	-- the scavengers' difficulty, for a mode they play in (see server/match.luau); they are off in any other
	difficulty: string?,
	-- whether a side is put out by what it loses, by the match's end mode, until one is left (server/conquest.luau)
	eliminates: boolean,
	-- whether a game of it is rated (server/ratings.luau)
	rated: boolean,
	-- the mission played, for a campaign mode: an id from campaign.MISSIONS. A campaign mode is never offered in the
	-- lobby's list of modes; the campaign screen starts it, on the mission's own map, for one player or for a co-op
	-- lobby, whose players are all on one side, up to the mission's `coop`: allied, or on one team (`shares_team`).
	mission: string?,
	-- whether a campaign mode plays its mission's hard mode (campaign.Mission's `hard_mode`)
	hard: boolean,
	-- whether the players on a side all share one team, rather than each having a team of their own: those of a mission
	-- played together whose `coop_kind` is "shared" (server/match.luau)
	shares_team: boolean,
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
	-- How long the scavengers take to reach full strength, as a multiple of their game length (server/scavengers/
	-- settings.luau's GAME_LENGTH, 80 minutes). Their strength follows the game's progress, so a shorter game is a harder
	-- one.
	pace: number,
	-- What everything the scavengers field has in health, as a multiple of its def's: their units, their defences and
	-- their boss. Their beacons grow tougher with the progress instead (server/scavengers/settings.luau's
	-- BEACON_HEALTH_GROWTH).
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

local END_MODES: { EndModeOption } = table.freeze({
	table.freeze({ id = "commanders" :: EndMode, label = "Coms dead" }),
	table.freeze({ id = "builders" :: EndMode, label = "Builders dead" }),
	table.freeze({ id = "units" :: EndMode, label = "All dead" }),
	table.freeze({ id = "never" :: EndMode, label = "Never" }),
})

local DEFAULT_END_MODE: EndMode = "commanders"

local DIFFICULTIES: { Difficulty } = table.freeze({
	-- 80, 64, 52 and 40 minutes
	table.freeze({ id = "easy", label = "Easy", pace = 1, health = 1 }),
	table.freeze({ id = "normal", label = "Normal", pace = 0.8, health = 2 }),
	table.freeze({ id = "hard", label = "Hard", pace = 0.65, health = 3 }),
	table.freeze({ id = "brutal", label = "Brutal", pace = 0.5, health = 5 }),
})

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
-- by 1 + bonus / 100, so +100 doubles it and -100 leaves nothing. Dragging it moves in steps of BONUS_STEP.
local BONUS_MIN = -100
local BONUS_MAX = 100
local BONUS_STEP = 5

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
		group = "scavengers" :: ModeGroup,
		label = `Scav {difficulty.label}`,
		chip_label = difficulty.label,
		lobby_label = `Scav {difficulty.label}`,
		picks_sides = false,
		side_label = "AGAINST THE SCAVENGERS",
		sides = 1,
		per_side = SCAVENGER_CAPACITY,
		capacity = SCAVENGER_CAPACITY,
		minimum = 1,
		every_side_manned = false,
		difficulty = difficulty.id,
		eliminates = false,
		rated = false,
		mission = nil,
		hard = false,
		shares_team = false,
	})
end
for size = 1, LARGEST_TEAM do
	table.insert(MODES, {
		id = `{size}v{size}`,
		group = "teams" :: ModeGroup,
		label = `{size}v{size}`,
		chip_label = `{size}v{size}`,
		lobby_label = `{size}v{size}`,
		picks_sides = true,
		side_label = "TEAM",
		sides = 2,
		per_side = size,
		capacity = size * 2,
		-- one a side at least, so there is someone to play against
		minimum = 2,
		every_side_manned = true,
		difficulty = nil,
		eliminates = true,
		rated = true,
		mission = nil,
		hard = false,
		shares_team = false,
	})
end
table.insert(MODES, {
	id = "ffa",
	group = "ffa" :: ModeGroup,
	label = "FFA",
	chip_label = "FFA",
	lobby_label = "FFA",
	picks_sides = false,
	side_label = "EVERY PLAYER FOR THEMSELVES",
	sides = FFA_CAPACITY,
	per_side = 1,
	capacity = FFA_CAPACITY,
	minimum = 2,
	every_side_manned = false,
	difficulty = nil,
	eliminates = true,
	rated = false,
	mission = nil,
	hard = false,
	shares_team = false,
})
-- each mission's, and its hard mode's for one that has one ("campaign_overlook_hard")
for _, mission in campaign.MISSIONS do
	local shares_team = mission.coop_kind == "shared"
	for _, hard in { false, true } do
		if hard and mission.hard_mode == false then
			continue
		end
		local label = if hard then `{mission.label} (Hard)` else mission.label
		table.insert(MODES, {
			id = `campaign_{campaign.key(mission.id, hard)}`,
			group = nil,
			label = label,
			chip_label = label,
			-- a lobby only ever plays one together
			lobby_label = `Co-op: {label}`,
			picks_sides = false,
			side_label = if shares_team then "CO-OP: SHARED TEAM" else "CO-OP: ALLIED",
			sides = 1,
			per_side = mission.coop or 1,
			capacity = mission.coop or 1,
			minimum = 1,
			every_side_manned = false,
			difficulty = nil,
			eliminates = false,
			rated = false,
			mission = mission.id,
			hard = hard :: boolean,
			shares_team = shares_team,
		})
	end
end

local mode_by_id: { [string]: Mode } = {}
-- The most players any mode seats, and so the most teams a match has for its players.
local LARGEST_CAPACITY = 0
for _, mode in MODES do
	table.freeze(mode)
	mode_by_id[mode.id] = mode
	LARGEST_CAPACITY = math.max(LARGEST_CAPACITY, mode.capacity)
end
table.freeze(MODES)

local DEFAULT_MODE = "scav_normal"

local end_mode_by_id: { [string]: EndMode } = {}
for _, option in END_MODES do
	end_mode_by_id[option.id] = option.id
end

-- `value` as an end mode, or nil if it is not one.
local function end_mode(value: any): EndMode?
	return if typeof(value) == "string" then end_mode_by_id[value] else nil
end

local function get(id: string): Mode?
	return mode_by_id[id]
end

-- What the lobby calls the mode `mode_id`; an id that is no mode is shown as it is.
local function label_of(mode_id: string): string
	local mode = mode_by_id[mode_id]
	return if mode ~= nil then mode.lobby_label else mode_id
end

-- The campaign mode that plays `mission_id`, in its hard mode for `hard`; nil for a hard mode it has not got.
local function campaign_mode(mission_id: string, hard: boolean): Mode?
	return mode_by_id[`campaign_{campaign.key(mission_id, hard)}`]
end

local function difficulty(id: string): Difficulty?
	return difficulty_by_id[id]
end

local function is_spectator(seat: Seat): boolean
	return seat.side == SPECTATOR_SIDE
end

-- Whether a seat in `mode` can be on `side`: watching, or one of its sides. Anything else, a fraction, NaN or a side
-- past its last, is not, whoever asks for it.
local function has_side(mode: Mode, side: number): boolean
	return side == SPECTATOR_SIDE or (side >= 1 and side <= mode.sides and side == math.floor(side))
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
	if mode.every_side_manned then
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

-- A new match of `mode_id` on the map `preset`, seated as `seats`, with everything else as a new lobby has it: the
-- default seed, no bonuses, no ally griefing and BAR's default end mode.
local function new_match(mode_id: string, preset: string, seats: { Seat }): Match
	return {
		mode = mode_id,
		preset = preset,
		seed = DEFAULT_SEED,
		seats = seats,
		bonuses = {},
		ally_griefing = false,
		end_mode = DEFAULT_END_MODE,
	}
end

-- The match that plays the campaign mission the key `mission_key` names (campaign.key: its id, or its hard mode's) for
-- `seats`, everyone on the one side: on the mission's map, as the campaign screen, a co-op lobby, a vote to go on and a
-- Studio playtest all start it. Nil for no such mission.
local function mission_match(mission_key: string, seats: { Seat }): Match?
	local mission, hard = campaign.parse_key(mission_key)
	local mode = if mission ~= nil then campaign_mode(mission.id, hard) else nil
	if mode == nil or mission == nil then
		return nil
	end
	return new_match(mode.id, mission.preset, seats)
end

-- A copy of `match`, sharing nothing with it, so that changing one leaves the other as it was.
local function copy(match: Match): Match
	local seats: { Seat } = {}
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

-- A match as a plain table of strings and numbers, for the MemoryStore.
local function encode(match: Match): { [string]: any }
	return copy(match) :: any
end

-- The match a table read from the MemoryStore holds, or nil if it is not one.
local function decode(value: any): Match?
	if typeof(value) ~= "table" then
		return nil
	end
	if typeof(value.mode) ~= "string" or typeof(value.preset) ~= "string" or typeof(value.seed) ~= "number" then
		return nil
	end
	local mode = mode_by_id[value.mode]
	if mode == nil or typeof(value.seats) ~= "table" then
		return nil
	end
	local seats: { Seat } = {}
	for _, seat in value.seats do
		if
			typeof(seat) ~= "table"
			or typeof(seat.user_id) ~= "number"
			or typeof(seat.side) ~= "number"
			or has_side(mode, seat.side) == false
		then
			return nil
		end
		table.insert(seats, {
			user_id = seat.user_id,
			name = if typeof(seat.name) == "string" then seat.name else tostring(seat.user_id),
			side = seat.side,
		})
	end
	local chosen_end = end_mode(value.end_mode)
	if typeof(value.bonuses) ~= "table" or typeof(value.ally_griefing) ~= "boolean" or chosen_end == nil then
		return nil
	end
	local bonuses: { [string]: number } = {}
	for _, seat in seats do
		local percent = clamp_bonus(value.bonuses[tostring(seat.user_id)])
		if percent ~= 0 then
			bonuses[tostring(seat.user_id)] = percent
		end
	end
	return table.freeze({
		mode = value.mode,
		preset = value.preset,
		seed = value.seed,
		seats = seats,
		bonuses = table.freeze(bonuses),
		ally_griefing = value.ally_griefing,
		end_mode = chosen_end :: EndMode,
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
	LARGEST_CAPACITY = LARGEST_CAPACITY,
	MATCH_STORE = MATCH_STORE,
	MATCH_TTL = MATCH_TTL,
	BONUS_MIN = BONUS_MIN,
	BONUS_MAX = BONUS_MAX,
	BONUS_STEP = BONUS_STEP,
	get = get,
	label_of = label_of,
	end_mode = end_mode,
	clamp_bonus = clamp_bonus,
	bonus_of = bonus_of,
	difficulty = difficulty,
	campaign_mode = campaign_mode,
	mission_match = mission_match,
	can_start = can_start,
	is_spectator = is_spectator,
	has_side = has_side,
	player_count = player_count,
	spectator_count = spectator_count,
	new_match = new_match,
	copy = copy,
	encode = encode,
	decode = decode,
})
