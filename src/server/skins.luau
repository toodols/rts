-- Skins in a game: the skin each team wears (shared/skins), which is what its player has equipped
-- (server_shared/skin_session.luau, where they pick it in the lobby). A team puts on its player's skin as the player
-- joins, again once what they have equipped has been read, and whenever they equip another: on everything the team
-- makes from then on (`state.create_entity`) and on everything it already has.
--
-- A skin is worn by the entity (`Entity.skin`, the model's `skin` attribute), so every player sees every unit in
-- the skin its owner equipped.

local ReplicatedStorage = game:GetService "ReplicatedStorage"
local ServerScriptService = game:GetService "ServerScriptService"

local skins = require(ReplicatedStorage.Shared.skins)
local types = require(ReplicatedStorage.Shared.types)
local unit_defs = require(ReplicatedStorage.Shared.unit_defs)

local skin_session = require(ServerScriptService.ServerShared.skin_session)

local players = require(script.Parent.players)
local state = require(script.Parent.state)

type Entity = types.Entity
type TeamId = types.TeamId

-- Puts `entity` in the skin called `skin_name`. A finished thing keeps the same share of its health, so one at full
-- health stays at full health whatever the new skin makes of it; a blueprint's health follows its build progress
-- through the new def on the next step (`construction`).
local function wear(entity: Entity, skin_name: string)
	if entity.skin == skin_name then
		return
	end
	local before = entity.def
	local after = unit_defs.skinned(entity.def_name, skin_name)
	entity.skin = skin_name
	entity.def = after
	local full = unit_defs.max_health(after)
	if entity.state == "active" and unit_defs.max_health(before) ~= full then
		local share = entity.health / entity.max_health
		entity.max_health = full
		entity.health = full * share
	end
end

-- Puts team `team_id` in the skin called `skin_name`, and everything it has with it, carried cargo included. False
-- for a team or a skin that is not there.
local function set_team(team_id: TeamId, skin_name: string): boolean
	local team = state.get_team(team_id)
	if team == nil or skins.exists(skin_name) == false then
		return false
	end
	team.skin = skin_name
	for _, entity in state.all() do
		if entity.team == team_id and entity.skin ~= nil then
			wear(entity, skin_name)
		end
	end
	for _, entity in state.carried() do
		if entity.team == team_id and entity.skin ~= nil then
			wear(entity, skin_name)
		end
	end
	return true
end

-- The skin team `team_id` wears, or nil for a team that is not there.
local function of_team(team_id: TeamId): string?
	local team = state.get_team(team_id)
	return if team ~= nil then team.skin else nil
end

-- Puts what `player` has equipped on their team, if they have one.
local function dress_team_of(player: Player)
	local team_id = players.team_of(player)
	if team_id ~= nil then
		set_team(team_id, skin_session.equipped_by(player))
	end
end

local function init()
	skin_session.on_worn(dress_team_of)
end

return table.freeze({
	init = init,
	set_team = set_team,
	of_team = of_team,
	dress_team_of = dress_team_of,
	wear = wear,
})
