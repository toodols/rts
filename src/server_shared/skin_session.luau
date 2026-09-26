--!strict
-- The skin each player has equipped (shared/skins), the same in every place of the experience: they pick it in the
-- lobby (its Skins tab), and in a game their team wears it (the game's server/skins.luau). It is kept in a DataStore,
-- one record a player, `{ equipped = <skin name> }`, and published on them (skins.publish_equipped).
--
-- Until what they have equipped is read they have skins.DEFAULT_SKIN, and so if it cannot be read. A developer's skin
-- is only worn by a developer, so one stored for someone who is no longer one is dropped as it is read; which is why
-- what is stored waits for whether they are a developer to be published (developer_list.luau).

local ReplicatedStorage = game:GetService "ReplicatedStorage"

local developers = require(ReplicatedStorage.Shared.developers)
local skins = require(ReplicatedStorage.Shared.skins)
local signal = require(ReplicatedStorage.Shared.signal)

local record_store = require(script.Parent.record_store)
local player_session = require(script.Parent.player_session)
local developer_list = require(script.Parent.developer_list)

type Outcome = player_session.Outcome

type Record = {
	-- nil for someone who has never equipped one
	equipped: string?,
}

-- told of each player whose equipped skin was published, as it was
local worn = signal.new() :: signal.Signal<Player>

local function equipped_in(record: Record): string
	return record.equipped or skins.DEFAULT_SKIN
end

local session = player_session.new({
	label = "skin",
	store = record_store.new({
		store = "skins",
		decode = function(value: any): Record
			local equipped = if typeof(value) == "table" then value.equipped else nil
			return { equipped = if typeof(equipped) == "string" then equipped else nil }
		end,
		encode = function(record: Record): any
			return { equipped = record.equipped }
		end,
	}),
	key = record_store.player_key,
	fresh = function(): Record
		return { equipped = nil }
	end,
	publish = function(player: Player, record: Record)
		skins.publish_equipped(player, equipped_in(record))
		worn.fire(player)
	end,
	prepare = developer_list.wait_published,
	admit = function(player: Player, record: Record): Record
		local equipped = record.equipped
		if equipped ~= nil and skins.may_wear(equipped, developers.is_developer(player)) == false then
			return { equipped = nil }
		end
		return record
	end,
})

-- The skin `player` has equipped.
local function equipped_by(player: Player): string
	return equipped_in(session.get(player))
end

-- Whether `player` may equip the skin called `skin_name`.
local function may_equip(player: Player, skin_name: string): boolean
	return skins.may_wear(skin_name, developers.is_developer(player))
end

-- Equips the skin called `skin_name` for `player`, for every game they play from now on; `anyway` equips even a
-- developer's skin on someone who is not one, for pow's `equip`. Yields while it saves. Returns what became of it, and
-- why it was not saved or not equipped.
local function equip(player: Player, skin_name: string, anyway: boolean?): (Outcome, string?)
	if skins.exists(skin_name) == false then
		return "refused", "There is no such skin"
	end
	if anyway ~= true and may_equip(player, skin_name) == false then
		return "refused", "Only a developer can wear that skin"
	end
	return session.change(player, function(): Record
		return { equipped = skin_name }
	end, true)
end

-- Tells `listener` of each player whose equipped skin is published, as they join, once it has been read, and as they
-- equip another, until the returned function is called.
local function on_worn(listener: (Player) -> ()): () -> ()
	return worn.subscribe(listener)
end

return table.freeze({
	joined = session.joined,
	left = session.left,
	status = session.status,
	wait_loaded = session.wait_loaded,
	equipped_by = equipped_by,
	may_equip = may_equip,
	equip = equip,
	on_worn = on_worn,
})
