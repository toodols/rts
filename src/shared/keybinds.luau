--!strict
-- Every key the game hears, as data: the actions a key can be bound to, the profiles that bind them, and each player's
-- keybinds, a profile and what they have rebound in it. The same everywhere: the lobby's Settings tab and the game's
-- settings panel rebind them (ClientShared.keybind_settings), a server keeps them in a DataStore and publishes them on
-- the player (server_shared/keybind_session.luau), and everything that hears a key or shows one reads them
-- (ClientShared.keybind_state).
--
-- A binding is a key's KeyCode name ("G"), that with ctrl held ("Ctrl+B"), or "" for none. An action that is held
-- (camera panning, steering a piloted unit) is polled rather than pressed, and takes no ctrl. Escape, shift, ctrl and
-- alt are never bound: Escape cancels, and the modifiers change what a click or a key does.
--
-- Two actions conflict when they share a scope and a binding. Within a scope a key does one thing, so binding a key
-- unbinds whatever else has it there (`bind`). The build menu's key slots (Shared.build_hotkeys) have a scope of their
-- own, as their keys only mean them while something is being placed, and piloting has its own, as its keys mean nothing
-- else while a unit is piloted.
--
-- Text that names a key, like a tip, writes it `{key:<action>}`, which `fill` turns into its key.

local ReplicatedStorage = game:GetService "ReplicatedStorage"

local build_hotkeys = require(ReplicatedStorage.Shared.build_hotkeys)
local replicated = require(ReplicatedStorage.Shared.replicated)

export type Action = {
	id: string,
	label: string,
	-- the heading it is listed under in the settings
	section: string,
	scopes: { string },
	held: boolean,
	-- whether only a developer has it: piloting (Shared.piloting), and so everything in its scope
	developer: boolean,
	-- for a key slot of the build menu, where it is in the grid of them, which is how the settings show it
	grid: { row: number, column: number }?,
}

export type Profile = {
	id: string,
	name: string,
	binds: { [string]: string },
}

-- A player's keybinds as stored: the profile they use, and by profile what they have rebound in it.
export type Record = {
	profile: string,
	custom: { [string]: { [string]: string } },
}

-- Every action's binding, by action.
export type Bindings = { [string]: string }

local CTRL = "Ctrl+"

-- Every key that can be bound, by its KeyCode name, and how it is shown.
local KEY_LABELS: { [string]: string } = {
	Space = "Space",
	Tab = "Tab",
	Return = "Enter",
	Backspace = "Backspace",
	Delete = "Del",
	Insert = "Ins",
	Home = "Home",
	End = "End",
	PageUp = "PgUp",
	PageDown = "PgDn",
	Up = "↑",
	Down = "↓",
	Left = "←",
	Right = "→",
	LeftBracket = "[",
	RightBracket = "]",
	Semicolon = ";",
	Quote = "'",
	Comma = ",",
	Period = ".",
	Slash = "/",
	BackSlash = "\\",
	Minus = "-",
	Equals = "=",
	Backquote = "`",
	KeypadPeriod = "Num.",
	KeypadDivide = "Num/",
	KeypadMultiply = "Num*",
	KeypadMinus = "Num-",
	KeypadPlus = "Num+",
	KeypadEnter = "NumEnter",
}
for code = string.byte "A", string.byte "Z" do
	local letter = string.char(code)
	KEY_LABELS[letter] = letter
end
for index, name in { "Zero", "One", "Two", "Three", "Four", "Five", "Six", "Seven", "Eight", "Nine" } do
	KEY_LABELS[name] = tostring(index - 1)
	KEY_LABELS[`Keypad{name}`] = `Num{index - 1}`
end
for index = 1, 12 do
	KEY_LABELS[`F{index}`] = `F{index}`
end
table.freeze(KEY_LABELS)

-- The scope of everything heard on the map, of the build menu's picks while something is being placed, and of piloting.
local COMMAND = "command"
local BUILD = "build"
local PILOT = "pilot"

local ACTIONS: { Action } = {}
local BY_ID: { [string]: Action } = {}

local function action(
	id: string,
	label: string,
	section: string,
	scopes: { string },
	held: boolean?,
	grid: { row: number, column: number }?
)
	assert(BY_ID[id] == nil, `the keybind action "{id}" is declared twice`)
	local made: Action = table.freeze({
		id = id,
		label = label,
		section = section,
		scopes = table.freeze(scopes),
		held = held == true,
		developer = table.find(scopes, PILOT) ~= nil,
		grid = if grid ~= nil then table.freeze(grid) else nil,
	})
	table.insert(ACTIONS, made)
	BY_ID[id] = made
end

action("stop", "Stop", "Commands", { COMMAND })
action("select_same", "Select same type on screen", "Commands", { COMMAND })
action("select_same_map", "Select same type on map", "Commands", { COMMAND })
action("select_commander", "Select commander", "Commands", { COMMAND })
action("player_list", "Player list", "Commands", { COMMAND })
-- the same key lets go of the unit again
action("pilot", "Pilot unit", "Commands", { COMMAND, PILOT })
action("shield", "Shield", "Commands", { COMMAND })
action("self_destruct", "Self-destruct", "Commands", { COMMAND })
action("rotate_left", "Rotate building left", "Commands", { COMMAND })
action("rotate_right", "Rotate building right", "Commands", { COMMAND })
action("queue_front", "Queue first", "Commands", { COMMAND }, true)

-- the order modes (Client.order_modes); the disintegrator and launch share one
action("mode_attack", "Attack", "Orders", { COMMAND })
action("mode_fight", "Fight", "Orders", { COMMAND })
action("mode_reclaim", "Reclaim", "Orders", { COMMAND })
action("mode_repair", "Repair", "Orders", { COMMAND })
action("mode_resurrect", "Resurrect", "Orders", { COMMAND })
action("mode_load", "Load", "Orders", { COMMAND })
action("mode_unload", "Unload", "Orders", { COMMAND })
action("mode_guard", "Guard", "Orders", { COMMAND })
action("mode_manual", "Disintegrator / Launch", "Orders", { COMMAND })

action("camera_up", "Pan up", "Camera", { COMMAND }, true)
action("camera_down", "Pan down", "Camera", { COMMAND }, true)
action("camera_left", "Pan left", "Camera", { COMMAND }, true)
action("camera_right", "Pan right", "Camera", { COMMAND }, true)

for _, category in build_hotkeys.categories do
	action(category.action, category.name, "Build menu", { COMMAND })
end
-- The key slots of the build menu's picks (Shared.build_hotkeys), each a position in its grid, which is all the settings
-- show of it: what a slot places depends on the category, and the build menu shows that against its key.
for row_index, row in build_hotkeys.slot_rows do
	for column, slot in row do
		action(
			build_hotkeys.slot_action(slot),
			`Row {row_index}, key {column}`,
			"Build keys",
			{ BUILD },
			false,
			{ row = row_index, column = column }
		)
	end
end

action("pilot_forward", "Forward", "Piloting", { PILOT }, true)
action("pilot_back", "Back", "Piloting", { PILOT }, true)
action("pilot_left", "Left", "Piloting", { PILOT }, true)
action("pilot_right", "Right", "Piloting", { PILOT }, true)
action("pilot_up", "Climb", "Piloting", { PILOT }, true)
for index = 1, 9 do
	action(`pilot_weapon_{index}`, `Weapon {index}`, "Piloting", { PILOT })
end
action("pilot_dgun", "DGun", "Piloting", { PILOT })
action("pilot_hold", "Army: hold", "Piloting", { PILOT })
action("pilot_follow", "Army: follow", "Piloting", { PILOT })
action("pilot_attack", "Army: attack", "Piloting", { PILOT })
action("pilot_load", "Load", "Piloting", { PILOT })
action("pilot_unload", "Unload", "Piloting", { PILOT })
action("pilot_call", "Call transport", "Piloting", { PILOT })
action("pilot_shield", "Shield", "Piloting", { PILOT })

table.freeze(ACTIONS)
table.freeze(BY_ID)

-- The game's keys as Beyond All Reason has them.
local BAR: { [string]: string } = {
	stop = "G",
	select_same = "Q",
	select_same_map = "Ctrl+W",
	select_commander = "Tab",
	player_list = "T",
	pilot = "P",
	shield = "K",
	self_destruct = "Ctrl+B",
	rotate_left = "LeftBracket",
	rotate_right = "RightBracket",
	queue_front = "Space",

	mode_attack = "A",
	mode_fight = "F",
	mode_reclaim = "E",
	mode_repair = "R",
	mode_resurrect = "W",
	mode_load = "J",
	mode_unload = "U",
	mode_guard = "O",
	mode_manual = "D",

	camera_up = "Up",
	camera_down = "Down",
	camera_left = "Left",
	camera_right = "Right",

	build_economy = "Z",
	build_combat = "X",
	build_utility = "C",
	build_production = "V",

	build_key_q = "Q",
	build_key_w = "W",
	build_key_e = "E",
	build_key_r = "R",
	build_key_t = "T",
	build_key_a = "A",
	build_key_s = "S",
	build_key_d = "D",
	build_key_f = "F",
	build_key_z = "Z",
	build_key_x = "X",
	build_key_c = "C",
	build_key_v = "V",

	pilot_forward = "W",
	pilot_back = "S",
	pilot_left = "A",
	pilot_right = "D",
	pilot_up = "Space",
	pilot_weapon_1 = "One",
	pilot_weapon_2 = "Two",
	pilot_weapon_3 = "Three",
	pilot_weapon_4 = "Four",
	pilot_weapon_5 = "Five",
	pilot_weapon_6 = "Six",
	pilot_weapon_7 = "Seven",
	pilot_weapon_8 = "Eight",
	pilot_weapon_9 = "Nine",
	pilot_dgun = "Q",
	pilot_hold = "X",
	pilot_follow = "C",
	pilot_attack = "V",
	pilot_load = "J",
	pilot_unload = "U",
	pilot_call = "G",
	pilot_shield = "K",
}

-- BAR's keys with the camera on W, A, S and D, and what BAR has there in the command scope moved to keys it leaves free:
-- Attack, Resurrect and Disintegrator / Launch. The build keys stay BAR's: while a building is being placed, or a lab is
-- selected, they come first, the camera's keys among what they override.
local DEFAULT: { [string]: string } = table.clone(BAR)
for id, binding in
	{
		camera_up = "W",
		camera_left = "A",
		camera_down = "S",
		camera_right = "D",

		select_same_map = "Ctrl+A",

		mode_attack = "H",
		mode_resurrect = "Ctrl+R",
		mode_manual = "Ctrl+D",
	} :: { [string]: string }
do
	DEFAULT[id] = binding
end

-- The profiles a player picks from, in the order they are offered.
local PROFILES: { Profile } = table.freeze({
	table.freeze({ id = "default", name = "Default", binds = table.freeze(DEFAULT) }),
	table.freeze({ id = "bar", name = "BAR", binds = table.freeze(BAR) }),
})
local DEFAULT_PROFILE = "default"

local PROFILE_BY_ID: { [string]: Profile } = {}
for _, profile in PROFILES do
	PROFILE_BY_ID[profile.id] = profile
end
table.freeze(PROFILE_BY_ID)

-- The key a binding is of, and whether it is with ctrl.
local function split(binding: string): (string, boolean)
	if string.sub(binding, 1, #CTRL) == CTRL then
		return string.sub(binding, #CTRL + 1), true
	end
	return binding, false
end

local function join(key: string, ctrl: boolean): string
	return if ctrl then CTRL .. key else key
end

-- Whether `binding` is one `of` can have.
local function valid(of: Action, binding: string): boolean
	if binding == "" then
		return true
	end
	local key, ctrl = split(binding)
	return KEY_LABELS[key] ~= nil and not (ctrl and of.held)
end

do
	-- every profile binds every action, to something it can have
	for _, profile in PROFILES do
		for _, each in ACTIONS do
			local binding = profile.binds[each.id]
			assert(binding ~= nil and valid(each, binding), `profile "{profile.id}" binds "{each.id}" to nothing valid`)
		end
		for id in profile.binds do
			assert(BY_ID[id] ~= nil, `profile "{profile.id}" binds "{id}", which is no action`)
		end
	end
end

-- How `binding` is shown: "G", "Ctrl+B", "[", "↑"; "" for none.
local function label(binding: string): string
	if binding == "" then
		return ""
	end
	local key, ctrl = split(binding)
	return join(KEY_LABELS[key] or key, ctrl)
end

local function fresh(): Record
	return { profile = DEFAULT_PROFILE, custom = {} }
end

-- The profile `record` uses.
local function profile_of(record: Record): Profile
	return PROFILE_BY_ID[record.profile] or PROFILE_BY_ID[DEFAULT_PROFILE]
end

-- Every action's binding in `record`: its profile's, with what was rebound over it.
local function resolve(record: Record): Bindings
	local profile = profile_of(record)
	local custom = record.custom[profile.id] or {}
	local bindings: Bindings = {}
	for _, each in ACTIONS do
		bindings[each.id] = custom[each.id] or profile.binds[each.id]
	end
	return bindings
end

local function share_scope(a: Action, b: Action): boolean
	for _, scope in a.scopes do
		if table.find(b.scopes, scope) ~= nil then
			return true
		end
	end
	return false
end

-- `record` with the action `id` bound to `binding`, and every action that had it in a scope they share unbound; and
-- those actions, in order.
local function bind(record: Record, id: string, binding: string): (Record, { string })
	local bound = BY_ID[id]
	assert(bound ~= nil and valid(bound, binding), `cannot bind "{id}" to "{binding}"`)
	local profile = profile_of(record)
	local bindings = resolve(record)
	local unbound: { string } = {}
	if binding ~= "" then
		for _, other in ACTIONS do
			if other ~= bound and bindings[other.id] == binding and share_scope(bound, other) then
				table.insert(unbound, other.id)
			end
		end
	end
	local custom: { [string]: { [string]: string } } = table.clone(record.custom)
	local mine: { [string]: string } = table.clone(custom[profile.id] or {})
	local function set(action_id: string, to: string)
		if to == profile.binds[action_id] then
			mine[action_id] = nil
		else
			mine[action_id] = to
		end
	end
	set(id, binding)
	for _, other in unbound do
		set(other, "")
	end
	custom[profile.id] = mine
	return { profile = profile.id, custom = custom }, unbound
end

-- `record` with nothing rebound in the profile it uses.
local function reset(record: Record): Record
	local custom: { [string]: { [string]: string } } = table.clone(record.custom)
	custom[profile_of(record).id] = nil
	return { profile = record.profile, custom = custom }
end

-- `record` using the profile `id`, with whatever was rebound in it before.
local function choose(record: Record, id: string): Record
	assert(PROFILE_BY_ID[id] ~= nil, `there is no keybind profile "{id}"`)
	return { profile = id, custom = record.custom }
end

-- A record out of whatever was stored or sent: only profiles and actions there are, bound to what they can be.
local function decode(value: unknown): Record
	local record = fresh()
	if typeof(value) ~= "table" then
		return record
	end
	local stored = value :: any
	if typeof(stored.profile) == "string" and PROFILE_BY_ID[stored.profile] ~= nil then
		record.profile = stored.profile
	end
	if typeof(stored.custom) ~= "table" then
		return record
	end
	for _, profile in PROFILES do
		local binds = stored.custom[profile.id]
		if typeof(binds) ~= "table" then
			continue
		end
		local kept: { [string]: string } = {}
		for _, each in ACTIONS do
			local binding = binds[each.id]
			if typeof(binding) == "string" and valid(each, binding) and binding ~= profile.binds[each.id] then
				kept[each.id] = binding
			end
		end
		record.custom[profile.id] = kept
	end
	return record
end

local function encode(record: Record): any
	return { profile = record.profile, custom = record.custom }
end

-- Whether two records bind everything the same.
local function same(a: Record, b: Record): boolean
	if a.profile ~= b.profile then
		return false
	end
	for _, profile in PROFILES do
		local mine = a.custom[profile.id] or {}
		local theirs = b.custom[profile.id] or {}
		for _, each in ACTIONS do
			if mine[each.id] ~= theirs[each.id] then
				return false
			end
		end
	end
	return true
end

-- `text` with each `{key:<action>}` in it the key `bindings` binds that action to, or "—" for none.
local function fill(text: string, bindings: Bindings): string
	return (
		string.gsub(text, "{key:([%w_]+)}", function(id: string): string
			local shown = label(bindings[id] or "")
			return if shown == "" then "—" else shown
		end)
	)
end

-- Each player's keybinds, as a server publishes them on them.
local RECORD = replicated.player(
	"keybinds",
	"record",
	replicated.json(function(decoded: any): Record?
		return decode(decoded)
	end)
)

-- `player`'s keybinds as a server published them; fresh ones until it has.
local function record_of(player: Player): Record
	return RECORD.get(player) or fresh()
end

-- The server's side.
local function publish(player: Player, record: Record)
	RECORD.set(player, record)
end

return table.freeze({
	actions = ACTIONS,
	get = function(id: string): Action?
		return BY_ID[id]
	end,
	profiles = PROFILES,
	DEFAULT_PROFILE = DEFAULT_PROFILE,
	key_labels = KEY_LABELS,
	split = split,
	join = join,
	valid = valid,
	label = label,
	fresh = fresh,
	profile_of = profile_of,
	resolve = resolve,
	bind = bind,
	reset = reset,
	choose = choose,
	decode = decode,
	encode = encode,
	same = same,
	fill = fill,
	record_of = record_of,
	record_changed = RECORD.changed,
	publish = publish,
})
