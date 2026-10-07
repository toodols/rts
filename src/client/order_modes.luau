--!strict
-- The modes the cursor can be put in to give an order with the next click, as data: one entry per mode, each saying
-- which keybind action (Shared.keybinds) starts it, who among the selection can take part, and what a click, a dragged
-- line or a dragged circle sends (as order kinds, shared/order_kinds.luau). Everything that handles a mode reads it
-- from here: the keys and clicks (command_input.luau), what the cursor lights, the command panel's rows and the badge
-- on the cursor.

local ReplicatedStorage = game:GetService "ReplicatedStorage"

local types = require(ReplicatedStorage.Shared.types)
local unit_defs = require(ReplicatedStorage.Shared.unit_defs)
local order_kinds = require(ReplicatedStorage.Shared.order_kinds)

local order_colors = require(ReplicatedStorage.Client.order_colors)

type EntityDef = types.EntityDef
type Command = order_kinds.Command

export type Mode =
	"attack"
	| "fight"
	| "reclaim"
	| "repair"
	| "resurrect"
	| "load"
	| "unload"
	| "guard"
	| "disintegrator"
	| "launch"

-- What a click in the mode does:
-- - "attack": attacks the enemy under the cursor, or failing one the ground there;
-- - "spot": sends the order to the ground under the cursor, whatever is on it;
-- - "entity": sends the order at what is under the cursor, and is only another click with nothing there;
-- - "manual": fires the manual weapon at the ground under the cursor.
export type Click = "attack" | "spot" | "entity" | "manual"

export type ModeInfo = {
	mode: Mode,
	label: string,
	-- the keybind action that starts it (Shared.keybinds)
	action: string,
	-- the order a click gives, at an entity; an "attack" click gives `attack_ground` at the ground instead
	order: Command,
	click: Click,
	-- the order each unit is given along a line dragged out in the mode, a spot of its own on it
	line: Command?,
	-- the area order a circle dragged out in the mode gives
	area: Command?,
	-- whether its attacks are launches, firing the manual-fire weapons (`Order.launch`)
	launch: boolean,
	-- whether only finished things take part, for what only a finished one can do, like firing a weapon
	active_only: boolean,
	-- whether something of `def` can take part
	can: (def: EntityDef) -> boolean,
	-- its colour: what the cursor lights things in while it is on, its badge by the cursor and the outlines of those
	-- selected who take part
	color: Color3,
	-- its icon in the command panel (Shared.ui_art), if it has one
	icon: string?,
}

-- Whether something can be sent somewhere: what can move, and the labs, whose units go there once they are made.
local function can_go(def: EntityDef): boolean
	return def.max_speed ~= nil or unit_defs.is_factory(def)
end

-- Whether something of `def` does `job` with its buildpower.
local function works(job: unit_defs.Job): (def: EntityDef) -> boolean
	return function(def: EntityDef): boolean
		return unit_defs.does(def, job)
	end
end

local function carries(def: EntityDef): boolean
	return def.transport ~= nil
end

-- Every mode, in the order the command panel lists them. The disintegrator and launch share an action, which starts
-- the disintegrator, or failing anything selected having one, launch, the first of the two the selection can use.
local MODES: { ModeInfo } = table.freeze({
	table.freeze({
		mode = "attack",
		label = "Attack",
		action = "mode_attack",
		order = "attack",
		click = "attack",
		line = "attack_ground",
		area = "area_attack",
		launch = false,
		active_only = false,
		can = function(def: EntityDef): boolean
			return unit_defs.order_range(def, false) ~= nil or unit_defs.is_factory(def)
		end,
		color = order_colors.of "attack",
		icon = "icon_attack",
	} :: ModeInfo),
	table.freeze({
		mode = "fight",
		label = "Fight",
		action = "mode_fight",
		order = "fight",
		click = "spot",
		line = "fight",
		launch = false,
		active_only = false,
		can = can_go,
		color = order_colors.of "fight",
		icon = "icon_fight",
	} :: ModeInfo),
	table.freeze({
		mode = "reclaim",
		label = "Reclaim",
		action = "mode_reclaim",
		order = "reclaim",
		click = "entity",
		area = "area_reclaim",
		launch = false,
		active_only = false,
		can = works "reclaim",
		color = order_colors.of "reclaim",
		icon = "icon_reclaim",
	} :: ModeInfo),
	table.freeze({
		mode = "repair",
		label = "Repair",
		action = "mode_repair",
		order = "repair",
		click = "entity",
		area = "area_repair",
		launch = false,
		active_only = false,
		can = works "repair",
		color = order_colors.of "repair",
		icon = "icon_repair",
	} :: ModeInfo),
	table.freeze({
		mode = "resurrect",
		label = "Resurrect",
		action = "mode_resurrect",
		order = "resurrect",
		click = "entity",
		area = "area_resurrect",
		launch = false,
		active_only = false,
		can = works "resurrect",
		color = order_colors.of "resurrect",
		icon = "icon_resurrect",
	} :: ModeInfo),
	table.freeze({
		mode = "load",
		label = "Load",
		action = "mode_load",
		order = "load",
		click = "entity",
		launch = false,
		active_only = false,
		can = carries,
		color = order_colors.of "load",
	} :: ModeInfo),
	table.freeze({
		mode = "unload",
		label = "Unload",
		action = "mode_unload",
		order = "unload",
		click = "spot",
		line = "unload",
		launch = false,
		active_only = false,
		can = carries,
		color = order_colors.of "unload",
	} :: ModeInfo),
	table.freeze({
		mode = "guard",
		label = "Guard",
		action = "mode_guard",
		order = "guard",
		click = "entity",
		launch = false,
		active_only = false,
		can = function(_: EntityDef): boolean
			return true
		end,
		color = order_colors.of "guard",
		icon = "icon_guard",
	} :: ModeInfo),
	table.freeze({
		mode = "disintegrator",
		label = "Disintegrator",
		action = "mode_manual",
		order = "dgun",
		click = "manual",
		launch = false,
		active_only = true,
		can = function(def: EntityDef): boolean
			return def.manual_weapon ~= nil
		end,
		color = order_colors.of "dgun",
		icon = "icon_disintegrator",
	} :: ModeInfo),
	table.freeze({
		mode = "launch",
		label = "Launch",
		action = "mode_manual",
		order = "attack",
		click = "attack",
		line = "attack_ground",
		launch = true,
		active_only = false,
		can = function(def: EntityDef): boolean
			return unit_defs.order_range(def, true) ~= nil
		end,
		color = order_colors.of "attack",
		icon = "icon_missile",
	} :: ModeInfo),
})

local BY_MODE: { [Mode]: ModeInfo } = {}
for _, info in MODES do
	BY_MODE[info.mode] = info
end
table.freeze(BY_MODE)

local function get(mode: Mode): ModeInfo
	return BY_MODE[mode]
end

-- The modes any of `actions` (a set of keybind actions) starts, in the order they are tried.
local function for_actions(actions: { [string]: boolean }): { ModeInfo }
	local found = {}
	for _, info in MODES do
		if actions[info.action] == true then
			table.insert(found, info)
		end
	end
	return found
end

return table.freeze({
	all = MODES,
	get = get,
	for_actions = for_actions,
	can_go = can_go,
})
