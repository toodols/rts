--!strict
-- This player's keybinds (Shared.keybinds), in the lobby and in a game alike: what the server published on them, or
-- what they have just rebound, which is sent to the server to keep (server_shared/keybind_session.luau) and used at
-- once, without waiting to hear it back. Everything that hears a key asks here what it is bound to (`actions_for`,
-- `is_down`), and everything that shows one shows it from here (`label`, `use_bindings`, `fill`), so both follow a
-- rebinding the moment it is made.

local Players = game:GetService "Players"
local ReplicatedStorage = game:GetService "ReplicatedStorage"
local UserInputService = game:GetService "UserInputService"

local keybinds = require(ReplicatedStorage.Shared.keybinds)
local signal = require(ReplicatedStorage.Shared.signal)

local use_store = require(script.Parent.use_store)

type Record = keybinds.Record
type Bindings = keybinds.Bindings

-- How long a change sent is waited on before what the server publishes is believed again, if it never comes back.
local PENDING_SECONDS = 5

local save_keybinds: RemoteEvent = ReplicatedStorage.Shared.SaveKeybinds
local player = Players.LocalPlayer

local record: Record = keybinds.fresh()
local bindings: Bindings = keybinds.resolve(record)
-- the actions bound to each binding
local by_binding: { [string]: { [string]: boolean } } = {}
-- the last change sent, until the server publishes it back
local pending: Record? = nil
local pending_at = 0
local changed = signal.new()
local started = false

local NONE: { [string]: boolean } = table.freeze({})

local function adopt(now: Record)
	record = now
	bindings = keybinds.resolve(now)
	by_binding = {}
	for id, binding in bindings do
		if binding ~= "" then
			local actions = by_binding[binding]
			if actions == nil then
				actions = {}
				by_binding[binding] = actions
			end
			actions[id] = true
		end
	end
	changed.fire()
end

local function on_published()
	local published = keybinds.record_of(player)
	if pending ~= nil then
		if keybinds.same(published, pending) then
			pending = nil
		elseif os.clock() - pending_at < PENDING_SECONDS then
			-- an older change coming back, or what was read before this one was sent
			return
		end
		pending = nil
	end
	adopt(published)
end

-- Starts following what the server publishes. Anything here starts it as it is first used.
local function init()
	if started then
		return
	end
	started = true
	keybinds.record_changed(player, on_published)
	adopt(keybinds.record_of(player))
end

local function get(): Bindings
	init()
	return bindings
end

local function current(): Record
	init()
	return record
end

local function send(now: Record)
	pending = now
	pending_at = os.clock()
	adopt(now)
	save_keybinds:FireServer(keybinds.encode(now))
end

-- Binds the action `id` to `binding`, and returns the actions that lost it to this one.
local function bind(id: string, binding: string): { string }
	init()
	local now, unbound = keybinds.bind(record, id, binding)
	send(now)
	return unbound
end

-- Puts back every key of the profile in use.
local function reset()
	init()
	send(keybinds.reset(record))
end

local function choose(profile_id: string)
	init()
	send(keybinds.choose(record, profile_id))
end

-- The binding of the action `id`.
local function binding_of(id: string): string
	return get()[id] or ""
end

-- How the key of the action `id` is shown, "" when it has none.
local function label(id: string): string
	return keybinds.label(binding_of(id))
end

-- The actions `key` is bound to, with ctrl held (`ctrl`) or not: a set, by action.
local function actions_for(key: Enum.KeyCode, ctrl: boolean): { [string]: boolean }
	init()
	return by_binding[keybinds.join(key.Name, ctrl)] or NONE
end

-- The KeyCode of the action `id`'s key, if it has one.
local function key_of(id: string): Enum.KeyCode?
	local key = keybinds.split(binding_of(id))
	if key == "" then
		return nil
	end
	return (Enum.KeyCode :: any)[key]
end

-- Whether the key of the action `id`, one that is held, is down, and no text box is being typed in.
local function is_down(id: string): boolean
	local key = key_of(id)
	return key ~= nil and UserInputService:GetFocusedTextBox() == nil and UserInputService:IsKeyDown(key)
end

-- `text` with each `{key:<action>}` in it this player's key for that action.
local function fill(text: string): string
	return keybinds.fill(text, get())
end

local function subscribe(listener: () -> ()): () -> ()
	init()
	return changed.subscribe(listener)
end

-- Every action's binding, rendering again as any changes.
local function use_bindings(): Bindings
	return use_store.use_store(get, subscribe)
end

return table.freeze({
	init = init,
	get = get,
	current = current,
	bind = bind,
	reset = reset,
	choose = choose,
	binding_of = binding_of,
	label = label,
	actions_for = actions_for,
	key_of = key_of,
	is_down = is_down,
	fill = fill,
	subscribe = subscribe,
	use_bindings = use_bindings,
})
