-- Skins on the server: which skin each player has equipped, and which skin each team wears (shared/skins).
--
-- A player picks their skin in the lobby (its Skins tab, lobby/server/skins.luau), which keeps it in skin_store; nothing
-- in a game changes it but a developer's pow `equip` or `skin`. As a player joins, what they have equipped is read and
-- goes on their team: on everything the team makes from then on (`state.create_entity`) and on everything it already
-- has. A developer's skin (golden) is only worn by a developer (shared/developers), so a stored one is dropped for
-- anyone else. What a player has equipped is published on them as the `skin` attribute; until it has been read they
-- wear config.DEFAULT_SKIN.
--
-- A skin is worn by the entity (`Entity.skin`, the model's `skin` attribute), so every player sees every unit in
-- the skin its owner equipped.

local Players = game:GetService "Players"
local ReplicatedStorage = game:GetService "ReplicatedStorage"
local ServerScriptService = game:GetService "ServerScriptService"

local config = require(ReplicatedStorage.Shared.config)
local developers = require(ReplicatedStorage.Shared.developers)
local skin_store = require(ReplicatedStorage.Shared.skin_store)
local skins = require(ReplicatedStorage.Shared.skins)
local types = require(ReplicatedStorage.Shared.types)
local unit_defs = require(ReplicatedStorage.Shared.unit_defs)

local players = require(ServerScriptService.Server.players)
local state = require(ServerScriptService.Server.state)

type Entity = types.Entity
type TeamId = types.TeamId

-- What a player has equipped is published on them as this attribute.
local ATTRIBUTE = "skin"

-- What each player in this server has equipped, and whether it may be saved: only once what was stored for them has
-- been read, so that a read that failed is never saved over.
local equipped: { [Player]: string } = {}
local may_save: { [Player]: boolean } = {}

-- Puts `entity` in the skin called `skin_name`. A finished thing keeps the same share of its health, so one at full
-- health stays at full health whatever the new skin makes of it; a blueprint's health follows its build progress
-- through the new def on the next step (`construction`).
local function wear(entity: Entity, skin_name: string)
	if entity.skin == skin_name then
		return
	end
	local before = unit_defs.of(entity)
	entity.skin = skin_name
	local after = unit_defs.of(entity)
	if entity.state == "active" and before.health ~= after.health then
		local share = entity.health / entity.max_health
		entity.max_health = after.health
		entity.health = after.health * share
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

-- The skin `player` has equipped.
local function equipped_by(player: Player): string
	return equipped[player] or config.DEFAULT_SKIN
end

-- Whether `player` may equip the skin called `skin_name`.
local function may_equip(player: Player, skin_name: string): boolean
	return skins.may_wear(skin_name, developers.is_developer(player))
end

-- Puts what `player` has equipped on their team, if they have one.
local function apply(player: Player)
	local team_id = players.team_of(player)
	if team_id ~= nil then
		set_team(team_id, equipped_by(player))
	end
end

local function publish(player: Player)
	player:SetAttribute(ATTRIBUTE, equipped_by(player))
end

-- Equips the skin called `skin_name` for `player`: on their team at once, and kept for next time. Only pow's `equip`
-- does this in a game, `anyway`, as a developer's command; otherwise, only what they may wear. Returns whether it was equipped, and
-- why not.
local function equip(player: Player, skin_name: string, anyway: boolean?): (boolean, string?)
	if skins.exists(skin_name) == false then
		return false, `there is no skin "{skin_name}"`
	end
	if anyway ~= true and may_equip(player, skin_name) == false then
		return false, `only a developer may wear {skin_name}`
	end
	equipped[player] = skin_name
	publish(player)
	apply(player)
	if may_save[player] == true then
		local user_id = player.UserId
		task.spawn(function()
			local ok, reason = skin_store.save(user_id, skin_name)
			if ok == false then
				warn(`could not save {player.Name}'s skin: {reason}`)
			end
		end)
	end
	return true, nil
end

-- A player joining: the default until what they have equipped is read, then that, if they may still wear it (a
-- developer taken off the list goes back to the default). Call once they have a team, if they are to have one.
local function player_added(player: Player)
	publish(player)
	apply(player)
	task.spawn(function()
		-- whether they are a developer is needed to know what they may wear
		developers.load(player)
		local stored, reason = skin_store.load(player.UserId)
		if player.Parent == nil then
			return
		end
		if reason ~= nil then
			warn(`could not read {player.Name}'s skin, so they wear {config.DEFAULT_SKIN}: {reason}`)
			return
		end
		may_save[player] = true
		-- anything they equipped while it was being read is kept
		if equipped[player] == nil and stored ~= nil and may_equip(player, stored) then
			equipped[player] = stored
			publish(player)
			apply(player)
		end
	end)
end

local function player_removing(player: Player)
	equipped[player] = nil
	may_save[player] = nil
end

local function init()
	Players.PlayerRemoving:Connect(player_removing)
end

return table.freeze({
	init = init,
	player_added = player_added,
	equip = equip,
	equipped_by = equipped_by,
	may_equip = may_equip,
	set_team = set_team,
	of_team = of_team,
	wear = wear,
})
