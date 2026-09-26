--!strict
-- What the cursor is doing on the map, as one state, and every way it changes (command_input.luau drives it from the
-- mouse and keys, the build menu and command panel from their buttons). Only one thing is ever going on: nothing, a
-- box being dragged out from a left press, an order being aimed from a right press, a mode waiting for its click (and
-- maybe a line or a circle being dragged out in it), or a building being placed (and maybe a line or grid of them
-- being dragged out). Starting any of them ends whatever was going on, whichever way it was started.
--
-- What the HUD shows of it is told as it changes: the mode (`subscribe_mode`), the building being placed
-- (`subscribe_placing`), the box (`subscribe_rect`), and the whole state for whatever draws it (`subscribe`).

local ReplicatedStorage = game:GetService "ReplicatedStorage"

local signal = require(ReplicatedStorage.Shared.signal)
local unit_defs = require(ReplicatedStorage.Shared.unit_defs)

local campaign_standing = require(ReplicatedStorage.ClientShared.campaign_standing)

local order_modes = require(ReplicatedStorage.Client.order_modes)
local selected = require(ReplicatedStorage.Client.selected)
local selection = require(ReplicatedStorage.Client.selection)

type Mode = order_modes.Mode

-- A rectangle on the screen, in viewport pixels.
export type Rect = { min: Vector2, max: Vector2 }

-- A line or a circle being dragged out in a mode, with the button that is held, from where it went down.
export type ModeDrag = { shape: "line" | "area", button: "left" | "right", from: Vector3 }

export type State =
	{ kind: "idle" }
	-- the left button held from nothing: a click, or once it has moved far enough, a box (`rect`)
	| { kind: "selecting", from: Vector2, rect: Rect? }
	-- the right button held from nothing: a click, or a line of moves once it has been dragged far enough
	| { kind: "ordering", from: Vector3 }
	| { kind: "mode", mode: Mode, drag: ModeDrag? }
	-- `from` while shift held a line or grid of them is being dragged out from there
	| { kind: "placing", def_name: string, from: Vector3? }

local IDLE: State = { kind = "idle" }

local state: State = IDLE
local changed = signal.new() :: signal.Signal<State, State>
local mode_changed = signal.new() :: signal.Signal<Mode?>
local placing_changed = signal.new() :: signal.Signal<string?>
local rect_changed = signal.new() :: signal.Signal<Rect?>

local function mode_of(of: State): Mode?
	return if of.kind == "mode" then of.mode else nil
end

local function placing_of(of: State): string?
	return if of.kind == "placing" then of.def_name else nil
end

local function rect_of(of: State): Rect?
	return if of.kind == "selecting" then of.rect else nil
end

local function set(next_state: State)
	local before = state
	state = next_state
	changed.fire(next_state, before)
	if mode_of(before) ~= mode_of(next_state) then
		mode_changed.fire(mode_of(next_state))
	end
	if placing_of(before) ~= placing_of(next_state) then
		placing_changed.fire(placing_of(next_state))
	end
	if rect_of(before) ~= rect_of(next_state) then
		rect_changed.fire(rect_of(next_state))
	end
end

local function get(): State
	return state
end

local function mode(): Mode?
	return mode_of(state)
end

local function placing(): string?
	return placing_of(state)
end

local function to_idle()
	if state.kind ~= "idle" then
		set(IDLE)
	end
end

-- Puts the cursor in `new_mode`, if anything selected can take part in it, and says whether it did.
local function enter_mode(new_mode: Mode): boolean
	if #selected.for_mode(order_modes.get(new_mode)) == 0 then
		return false
	end
	set({ kind = "mode", mode = new_mode })
	return true
end

-- A command panel button: the same as its key, or out of the mode again if it is the one that is on.
local function toggle_mode(new_mode: Mode)
	if mode() == new_mode then
		to_idle()
	else
		enter_mode(new_mode)
	end
end

-- Picks up `def_name` to place, from the build menu or a key. Nothing the player has not unlocked can be picked up.
local function place(def_name: string)
	local def = unit_defs.defs[def_name]
	if def == nil or def.kind ~= "building" or campaign_standing.is_unlocked(def_name) == false then
		return
	end
	set({ kind = "placing", def_name = def_name })
end

-- The left button went down on the map with nothing going on, at `at` on the screen.
local function press_select(at: Vector2)
	set({ kind = "selecting", from = at })
end

-- The box a left drag has stretched to.
local function stretch_box(rect: Rect?)
	if state.kind == "selecting" and state.rect ~= rect then
		set({ kind = "selecting", from = state.from, rect = rect })
	end
end

-- The right button went down on the map with nothing going on, over `from` on the ground.
local function press_order(from: Vector3)
	set({ kind = "ordering", from = from })
end

-- A button went down in the mode that is on, to drag out a line or a circle.
local function drag_in_mode(drag: ModeDrag)
	if state.kind == "mode" then
		set({ kind = "mode", mode = state.mode, drag = drag })
	end
end

-- Shift and the left button went down while placing: a line or grid of the building is dragged out from `from`.
local function drag_placing(from: Vector3)
	if state.kind == "placing" then
		set({ kind = "placing", def_name = state.def_name, from = from })
	end
end

-- What was being clicked or dragged has been let go of, and whatever it did is done. A mode or a placement goes on
-- if `keep` (shift held, to give another), and ends otherwise; anything else ends.
local function release(keep: boolean)
	if keep and state.kind == "mode" then
		set({ kind = "mode", mode = state.mode })
	elseif keep and state.kind == "placing" then
		set({ kind = "placing", def_name = state.def_name })
	else
		to_idle()
	end
end

-- A building being placed is put down as soon as nothing selected can build it any more, so that the ghost does not
-- outlive its builder.
local function init()
	selection.subscribe(function()
		local def_name = placing()
		if def_name ~= nil and table.find(selected.buildable(), def_name) == nil then
			to_idle()
		end
	end)
end

return table.freeze({
	init = init,
	get = get,
	mode = mode,
	placing = placing,
	to_idle = to_idle,
	enter_mode = enter_mode,
	toggle_mode = toggle_mode,
	place = place,
	press_select = press_select,
	stretch_box = stretch_box,
	press_order = press_order,
	drag_in_mode = drag_in_mode,
	drag_placing = drag_placing,
	release = release,
	subscribe = changed.subscribe,
	subscribe_mode = mode_changed.subscribe,
	subscribe_placing = placing_changed.subscribe,
	subscribe_rect = rect_changed.subscribe,
})
