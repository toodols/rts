-- How a game between players ends, a team game (NvN) or a free for all (see shared/game_modes.luau): with the last side
-- standing. A side is the teams seated on it, allied, and which of them are out is the match's end mode
-- (game_modes.EndMode, "commanders" by default), as elimination.luau says of every side. Once out that way a side stays
-- out, and everything it has left blows up, as a team that has lost does in BAR. Whatever the mode, a side is out while
-- none of its players is here, all of them having left or none having come; its things are left as they are, and it is
-- back in if one of them comes back while the game lasts. When one side is left the game ends in victory for its teams;
-- when the last sides go out together, with no winners.
--
-- Nothing is looked at before the game is playing or once it has ended. Only a match a lobby started (or a test handed
-- in) in a mode that `eliminates` (game_modes: the team games and free for alls) is ended this way; the others end their
-- own ways, and a game played straight from Studio never.

local ReplicatedStorage = game:GetService "ReplicatedStorage"

local types = require(ReplicatedStorage.Shared.types)
local game_modes = require(ReplicatedStorage.Shared.game_modes)
local game_phase = require(ReplicatedStorage.Shared.game_phase)

local state = require(script.Parent.state)
local deaths = require(script.Parent.deaths)
local match = require(script.Parent.match)
local elimination = require(script.Parent.elimination)
local snapshot = require(script.Parent.snapshot)

type TeamId = types.TeamId
type Entity = types.Entity

-- The teams a side is seated on, how it is put out, and the players seated there.
type Side = {
	teams: { TeamId },
	end_mode: game_modes.EndMode,
	users: { number },
}

-- How often, in sim seconds, the sides are looked at.
local CHECK_SECONDS = 1
local LAST_STANDING = "One side is left standing"
local NONE_STANDING = "No side is left standing"

local check_timer = 0
local evaluator = elimination.new()
-- the match's sides, once they have been read
local sides: { Side }? = nil
-- the sides put out by what they lost, by index; they stay out
local eliminated: { [number]: boolean } = {}
-- the sides just put out, whose things are blown up at the next tick
local to_destroy: { Side } = {}

-- The sides of the match being played, if it is one ended this way, in side order; none if it is not.
local function sides_of_match(): { Side }
	local cached = sides
	if cached ~= nil then
		return cached
	end
	local by_number: { [number]: Side } = {}
	local current = match.get()
	local mode = if current ~= nil then game_modes.get(current.mode) else nil
	if current ~= nil and mode ~= nil and mode.eliminates then
		for _, seat in current.seats do
			local team_id = match.team_of(seat.user_id)
			if game_modes.is_spectator(seat) or team_id == nil then
				continue
			end
			local side = by_number[seat.side]
			if side == nil then
				side = { teams = {}, end_mode = current.end_mode, users = {} }
				by_number[seat.side] = side
			end
			table.insert(side.teams, team_id)
			table.insert(side.users, seat.user_id)
		end
	end
	local numbers: { number } = {}
	for number, side in by_number do
		table.sort(side.teams)
		table.insert(numbers, number)
	end
	table.sort(numbers)
	local result: { Side } = {}
	for _, number in numbers do
		table.insert(result, by_number[number])
	end
	sides = result
	return result
end

-- Whether none of `side`'s players is here.
local function is_deserted(side: Side): boolean
	for _, user_id in side.users do
		if match.is_here(user_id) then
			return false
		end
	end
	return true
end

-- Blows up everything the sides put out since the last tick have left, carried things and all, each as if it had
-- destroyed itself: a commander leaves its wreck and nothing else does.
local function destroy_eliminated()
	if #to_destroy == 0 then
		return
	end
	local out: { [TeamId]: boolean } = {}
	for _, side in to_destroy do
		for _, team_id in side.teams do
			out[team_id] = true
		end
	end
	table.clear(to_destroy)
	local doomed: { Entity } = {}
	for _, entity in state.all() do
		if entity.alive and out[entity.team] == true and (entity.kind == "unit" or entity.kind == "building") then
			table.insert(doomed, entity)
		end
	end
	for _, entity in state.carried() do
		if entity.alive and out[entity.team] == true then
			table.insert(doomed, entity)
		end
	end
	for _, entity in doomed do
		-- a transport lost takes what it carries with it, which is then already gone
		deaths.destroy(entity, "self_destructed")
	end
end

-- Ends the game if at most one side is left.
local function check()
	if game_phase.is_playing() == false then
		return
	end
	local all_sides = sides_of_match()
	if #all_sides == 0 then
		return
	end
	local out = evaluator.look(all_sides :: { any })
	local remaining: { Side } = {}
	for index, side in all_sides do
		if eliminated[index] ~= true and out[index] then
			eliminated[index] = true
			table.insert(to_destroy, side)
		end
		if eliminated[index] ~= true and is_deserted(side) == false then
			table.insert(remaining, side)
		end
	end
	if #remaining > 1 then
		return
	end
	if #remaining == 1 then
		game_phase.set_ended(remaining[1].teams, LAST_STANDING)
	else
		game_phase.set_ended({}, NONE_STANDING)
	end
end

-- Called at the end of every step, once its dead are gone.
local function tick(delta: number)
	-- the losers' things go up even once the game is over, while its last moments play out behind the end screen
	destroy_eliminated()
	check_timer += delta
	if check_timer < CHECK_SECONDS then
		return
	end
	check_timer = 0
	check()
end

-- Called as each player leaves, after the match has been told: their side may be out now, and if they were the last
-- here, there may be no step after this to notice.
local function player_removing(_player: Player)
	check()
end

-- A new map is a new game: nothing is out, and nothing has been on the field.
local function start_over()
	evaluator.reset()
	table.clear(eliminated)
	table.clear(to_destroy)
	check_timer = 0
end

snapshot.keep("conquest", function()
	return {
		evaluator = evaluator.kept(),
		check_timer = check_timer,
		sides = sides,
		eliminated = eliminated,
		to_destroy = to_destroy,
	}
end, function(saved)
	evaluator.put_back(saved.evaluator)
	check_timer = saved.check_timer
	sides = saved.sides
	eliminated = saved.eliminated
	to_destroy = saved.to_destroy
end)

return table.freeze({
	tick = tick,
	player_removing = player_removing,
	start_over = start_over,
})
