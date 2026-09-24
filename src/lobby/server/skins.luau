-- Skins in the lobby: where a player picks the skin they wear in their games (the lobby's Skins tab). What they pick is
-- kept in skin_store, which the game place reads as they arrive (server/skins.luau), and published on them as the
-- `skin` attribute, which the tab reads.
--
-- A player's stored skin is read as they join; until then, and if it cannot be read, they are shown
-- config.DEFAULT_SKIN, and nothing is saved over what may be stored.

local Players = game:GetService "Players"
local ReplicatedStorage = game:GetService "ReplicatedStorage"

local config = require(ReplicatedStorage.Shared.config)
local developers = require(ReplicatedStorage.Shared.developers)
local skin_store = require(ReplicatedStorage.Shared.skin_store)
local skins = require(ReplicatedStorage.Shared.skins)

-- What a player has equipped is published on them as this attribute.
local ATTRIBUTE = "skin"

-- Whose stored skin has been read, so may be saved over.
local may_save: { [Player]: boolean } = {}

local function publish(player: Player, skin_name: string)
	player:SetAttribute(ATTRIBUTE, skin_name)
end

-- Equips the skin called `skin_name` for `player`, for their games from now on: `(ok, why not)`. Yields while it saves.
local function equip(player: Player, skin_name: string): (boolean, string?)
	if skins.exists(skin_name) == false then
		return false, "There is no such skin"
	end
	if skins.may_wear(skin_name, developers.is_developer(player)) == false then
		return false, "Only a developer can wear that skin"
	end
	if may_save[player] ~= true then
		return false, "Your skins haven't loaded yet"
	end
	local ok, reason = skin_store.save(player.UserId, skin_name)
	if ok == false then
		warn(`could not save {player.Name}'s skin: {reason}`)
		return false, "Couldn't save your skin; try again"
	end
	publish(player, skin_name)
	return true, nil
end

-- Reads what `player` has equipped and publishes it. Yields. A developer's skin is shown only to a developer, so call
-- it once whether they are one has been read (developers.load).
local function load(player: Player)
	local stored, reason = skin_store.load(player.UserId)
	if player.Parent == nil then
		return
	end
	if reason ~= nil then
		warn(`could not read {player.Name}'s skin: {reason}`)
		return
	end
	may_save[player] = true
	if stored ~= nil and skins.may_wear(stored, developers.is_developer(player)) then
		publish(player, stored)
	end
end

-- Shows `player` the default until what they have equipped is read.
local function player_added(player: Player)
	publish(player, config.DEFAULT_SKIN)
end

local function init()
	Players.PlayerRemoving:Connect(function(player: Player)
		may_save[player] = nil
	end)
end

return table.freeze({
	init = init,
	player_added = player_added,
	load = load,
	equip = equip,
})
