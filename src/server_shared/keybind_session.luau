--!strict
-- Each player's keybinds (Shared.keybinds), the same in every place of the experience: they rebind them in the lobby's
-- Settings tab or a game's settings panel, and their client sends the whole record here on `SaveKeybinds` as it
-- changes. It is kept in a DataStore, one record a player, and published on them (keybinds.publish).
--
-- A change is published at once, but only saved once the player has stopped rebinding for SAVE_SECONDS, so that
-- going through a dozen keys is one write; one still waiting as they leave is saved then.

local ReplicatedStorage = game:GetService "ReplicatedStorage"

local keybinds = require(ReplicatedStorage.Shared.keybinds)

local record_store = require(script.Parent.record_store)
local player_session = require(script.Parent.player_session)
local remotes = require(script.Parent.remotes)

type Record = keybinds.Record

local SAVE_SECONDS = 3
-- A player rebinds a key at a time, each a click and a press.
local SAVE_RATE: remotes.Rate = { per_second = 4, burst = 20 }

local store = record_store.new({
	store = "keybinds",
	decode = keybinds.decode,
	encode = keybinds.encode,
})

local session = player_session.new({
	label = "keybinds",
	store = store,
	key = record_store.player_key,
	fresh = keybinds.fresh,
	publish = keybinds.publish,
})

-- The record each player has changed to and not yet saved.
local unsaved: { [Player]: Record } = {}

-- Whatever a client sent, as long as it is a table: `keybinds.decode` keeps only what a record can hold.
local function a_record(value: unknown): (boolean, Record)
	if typeof(value) ~= "table" then
		return false, keybinds.fresh()
	end
	return true, keybinds.decode(value)
end

local function save(player: Player, record: Record)
	if unsaved[player] ~= record then
		-- a newer one is waiting its turn
		return
	end
	unsaved[player] = nil
	session.change(player, function(): Record
		return record
	end, true)
end

local function on_save(player: Player, record: Record)
	-- nothing is changed before what is stored has been read, or it would be read over it
	session.wait_loaded(player)
	if player.Parent == nil then
		return
	end
	session.change(player, function(): Record
		return record
	end, false)
	unsaved[player] = record
	task.delay(SAVE_SECONDS, save, player, record)
end

local function left(player: Player)
	local record = unsaved[player]
	unsaved[player] = nil
	if record ~= nil and session.status(player) == "loaded" then
		task.spawn(store.update, record_store.player_key(player.UserId), function(): Record
			return record
		end)
	end
	session.left(player)
end

local function init()
	remotes.listen(ReplicatedStorage.Shared.SaveKeybinds, { args = { a_record }, rate = SAVE_RATE }, on_save)
end

return table.freeze({
	init = init,
	joined = session.joined,
	left = left,
	status = session.status,
})
