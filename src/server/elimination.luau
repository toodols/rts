--!strict
-- Who is out: the one evaluator a game between players (conquest.luau) and a campaign mission (missions) both end by.
-- A side is some teams played together, and what keeps it in is its end mode (game_modes.EndMode), BAR's own:
--
-- - "commanders": a commander of its teams, alive;
-- - "builders": anything finished of its teams that can build, which is its commanders, its constructors, its labs and
--   its construction turrets alike (anything whose def has a builder);
-- - "units": anything of its teams at all, a unit or a building, finished or not;
-- - "never": it is never out, whatever it loses.
--
-- Things being carried count as well. A side is out once none of its teams has any of what its mode looks at, and one
-- of them has had some on the field (`fielded`), so that nobody is out before their commander has been put down. What
-- each caller does with that, who wins and when, is its own.

local ReplicatedStorage = game:GetService "ReplicatedStorage"

local types = require(ReplicatedStorage.Shared.types)
local game_modes = require(ReplicatedStorage.Shared.game_modes)
local teams = require(ReplicatedStorage.Shared.teams)
local unit_defs = require(ReplicatedStorage.Shared.unit_defs)

local state = require(script.Parent.state)

type TeamId = types.TeamId
type Entity = types.Entity
type EndMode = game_modes.EndMode

export type Side = {
	teams: { TeamId },
	end_mode: EndMode,
}

-- How much of what each end mode looks at each team has on the field, by end mode ("units" and the rest) and team, for
-- each end mode a look counted; a team with none is left out.
export type Standing = { [string]: { [TeamId]: number } }

-- What an evaluator remembers between looks: every team that has had what each end mode looks at on the field.
export type Evaluator = {
	-- Which of `sides` are out now, by index, and what was counted to say so.
	look: (sides: { Side }) -> ({ boolean }, Standing),
	-- Forgets what was on the field, for a game that starts over.
	reset: () -> (),
}

-- Whether `entity` is something that keeps a side in by `end_mode`.
local function counts(entity: Entity, end_mode: EndMode): boolean
	local def = entity.def
	if entity.alive == false or entity.team == teams.NEUTRAL or unit_defs.is_remains(def) then
		return false
	end
	if end_mode == "units" then
		return true
	end
	if end_mode == "commanders" then
		return unit_defs.is_commander(def)
	end
	return entity.state == "active" and def.builder ~= nil
end

-- How many of what `end_mode` looks at each team has on the field, what is being carried included.
local function count(end_mode: EndMode): { [TeamId]: number }
	local found: { [TeamId]: number } = {}
	local function add(entity: Entity)
		if counts(entity, end_mode) then
			found[entity.team] = (found[entity.team] or 0) + 1
		end
	end
	for _, entity in state.all() do
		add(entity)
	end
	for _, entity in state.carried() do
		add(entity)
	end
	return found
end

local function new(): Evaluator
	local fielded: { [EndMode]: { [TeamId]: boolean } } = {}

	local function look(sides: { Side }): ({ boolean }, Standing)
		local standing: Standing = {}
		local out: { boolean } = table.create(#sides, false)
		for index, side in sides do
			local end_mode: EndMode = side.end_mode
			if end_mode == "never" then
				continue
			end
			local counted = standing[end_mode]
			local seen = fielded[end_mode]
			if counted == nil then
				counted = count(end_mode)
				standing[end_mode] = counted
				seen = seen or {}
				fielded[end_mode] = seen
				for team_id in counted do
					seen[team_id] = true
				end
			end
			local was_fielded = false
			local standing_now = false
			for _, team_id in side.teams do
				if counted[team_id] ~= nil then
					standing_now = true
					break
				end
				if (seen :: { [TeamId]: boolean })[team_id] == true then
					was_fielded = true
				end
			end
			out[index] = standing_now == false and was_fielded
		end
		return out, standing
	end

	local function reset()
		table.clear(fielded)
	end

	return table.freeze({
		look = look,
		reset = reset,
	})
end

return table.freeze({
	count = count,
	new = new,
})
