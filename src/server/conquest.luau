-- How a game between players ends, a team game (NvN) or a free for all (see shared/game_modes.luau): with the last side
-- standing. A side is the teams seated on it, allied, and which of them are out is the match's end mode
-- (game_modes.EndMode), BAR's own:
--
-- - "commanders", the default: a side is out once every commander of its teams is dead;
-- - "builders": once it has nothing left that can build, which is its commanders, its constructors, its labs and its
--   construction turrets alike (anything whose def has build options or buildpower), finished;
-- - "units": once it has nothing left at all, no unit and no building, finished or not, as a campaign mission is lost;
-- - "never": never, whatever it loses.
--
-- A side goes out that way only once it has had what the mode looks at on the field, so nobody is out before their
-- commander has been put down; and once out that way it stays out, and everything it has left blows up, as a team that
-- has lost does in BAR. Whatever the mode, a side is out while none of its players is here, all of them having left or
-- none having come; its things are left as they are, and it is back in if one of them comes back while the game lasts.
-- When one side is left the game ends in victory for its teams; when the last sides go out together, with no winners.
--
-- Nothing is looked at before the game is playing or once it has ended. Only a match a lobby started (or a test handed
-- in) is ended this way; scavenger and campaign games end their own ways, and a game played straight from Studio never.

local ReplicatedStorage = game:GetService "ReplicatedStorage"

local types = require(ReplicatedStorage.Shared.types)
local game_modes = require(ReplicatedStorage.Shared.game_modes)
local game_phase = require(ReplicatedStorage.Shared.game_phase)
local unit_defs = require(ReplicatedStorage.Shared.unit_defs)

local state = require(script.Parent.state)
local combat = require(script.Parent.combat)
local match = require(script.Parent.match)
local missions = require(script.Parent.missions)

type TeamId = types.TeamId
type Entity = types.Entity
type EntityDef = types.EntityDef
type EndMode = game_modes.EndMode

-- The teams a side is seated on and the players seated there.
type Side = {
	teams: { TeamId },
	users: { number },
}

-- How often, in sim seconds, the sides are looked at.
local CHECK_SECONDS = 1
local LAST_STANDING = "One side is left standing"
local NONE_STANDING = "No side is left standing"

local check_timer = 0
-- the teams that have had what the end mode looks at on the field this game
local fielded: { [TeamId]: boolean } = {}
-- the match's sides, by side, once they have been read
local sides: { [number]: Side }? = nil
-- the sides put out by what they lost, by side; they stay out
local eliminated: { [number]: boolean } = {}
-- the sides just put out, whose things are blown up at the next tick
local to_destroy: { Side } = {}

-- Whether `def` is a commander: only a commander shows its team's name over it.
local function is_commander(def: EntityDef): boolean
	return def.nametag == true
end

-- Whether `def` can build anything, units or buildings, or put buildpower into anything: a commander, a constructor, a
-- lab, a construction turret. A drone is only a part of its carrier.
local function is_builder(def: EntityDef): boolean
	if def.drone == true then
		return false
	end
	return (def.build_options ~= nil and #def.build_options > 0) or def.buildpower ~= nil
end

-- Whether `entity` is something `end_mode` keeps its side in with, but for "units", which counts as a mission does.
local function counts(entity: Entity, end_mode: EndMode): boolean
	if entity.alive == false or entity.team == 0 or (entity.kind ~= "unit" and entity.kind ~= "building") then
		return false
	end
	local def = unit_defs.of(entity)
	if end_mode == "commanders" then
		return is_commander(def)
	end
	return entity.state == "active" and is_builder(def)
end

-- How many of what `end_mode` looks at each team has on the field, its carried things included; a team with none is
-- left out.
local function count_standing(end_mode: EndMode): { [TeamId]: number }
	if end_mode == "units" then
		return missions.count_standing()
	end
	local result: { [TeamId]: number } = {}
	local function count(entity: Entity)
		if counts(entity, end_mode) then
			result[entity.team] = (result[entity.team] or 0) + 1
		end
	end
	for _, entity in state.all() do
		count(entity)
	end
	for _, entity in state.carried() do
		count(entity)
	end
	return result
end

-- The sides of the match being played, if it is one ended this way; empty if it is not.
local function sides_of_match(): { [number]: Side }
	local cached = sides
	if cached ~= nil then
		return cached
	end
	local result: { [number]: Side } = {}
	local current = match.get()
	local mode = if current ~= nil then game_modes.get(current.mode) else nil
	if current ~= nil and mode ~= nil and (mode.kind == "teams" or mode.kind == "ffa") then
		for _, seat in current.seats do
			local team_id = match.team_of_user(seat.user_id)
			if game_modes.is_spectator(seat) or team_id == nil then
				continue
			end
			local side = result[seat.side]
			if side == nil then
				side = { teams = {}, users = {} }
				result[seat.side] = side
			end
			table.insert(side.teams, team_id)
			table.insert(side.users, seat.user_id)
		end
	end
	for _, side in result do
		table.sort(side.teams)
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

-- Whether `side` has lost what `end_mode` looks at, `standing` being how much of it each team has on the field.
local function has_lost(side: Side, standing: { [TeamId]: number }, end_mode: EndMode): boolean
	if end_mode == "never" then
		return false
	end
	local was_fielded = false
	for _, team_id in side.teams do
		if standing[team_id] ~= nil then
			return false
		end
		if fielded[team_id] == true then
			was_fielded = true
		end
	end
	return was_fielded
end

-- Blows up everything the sides put out since the last tick have left, carried things and all, each as if it had
-- destroyed itself: a commander leaves its wreck and nothing else does.
local function destroy_eliminated()
	if #to_destroy == 0 then
		return
	end
	local teams: { [TeamId]: boolean } = {}
	for _, side in to_destroy do
		for _, team_id in side.teams do
			teams[team_id] = true
		end
	end
	table.clear(to_destroy)
	local doomed: { Entity } = {}
	for _, entity in state.all() do
		if entity.alive and teams[entity.team] == true and (entity.kind == "unit" or entity.kind == "building") then
			table.insert(doomed, entity)
		end
	end
	for _, entity in state.carried() do
		if entity.alive and teams[entity.team] == true then
			table.insert(doomed, entity)
		end
	end
	for _, entity in doomed do
		-- a transport lost takes what it carries with it, which is then already gone
		combat.self_destruct(entity)
	end
end

-- Ends the game if at most one side is left.
local function check()
	if game_phase.is_playing() == false then
		return
	end
	local all_sides = sides_of_match()
	if next(all_sides) == nil then
		return
	end
	local end_mode = (match.get() :: game_modes.Match).end_mode
	local standing = count_standing(end_mode)
	for team_id in standing do
		fielded[team_id] = true
	end
	local remaining: { Side } = {}
	for number, side in all_sides do
		if eliminated[number] ~= true and has_lost(side, standing, end_mode) then
			eliminated[number] = true
			table.insert(to_destroy, side)
		end
		if eliminated[number] ~= true and is_deserted(side) == false then
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

return table.freeze({
	tick = tick,
	player_removing = player_removing,
})
