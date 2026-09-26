--!strict
-- Commanding with the mouse and keys: the input router's layer for the map (input_router.luau), which turns each
-- press into a change of what the cursor is doing (command_state.luau) and, as it is let go, into what the selection
-- is told (commands.luau), what is selected (picking.luau) or what is built (placing.luau).
--
-- Left button:
--   click on an entity             selects exactly that entity, shift adds it to or takes it from the selection
--   click on empty ground          clears the selection
--   drag                           box-selects your own units, shift keeps the existing selection
--
-- Right button:
--   click on ground                move there
--   click on an entity             attack, reclaim, assist, guard or load, depending on what it is
--   drag a line                    spread the selection evenly along the shape the drag traces
--
-- Shift queues an order after what each unit is doing, and space puts it at the front instead.
--
-- A mode's key (order_modes.luau) puts the cursor in it: the next left click gives its order, a right click cancels
-- it, and shift keeps it on for another. In a mode that gives an order at a spot, the left button (and the right) can
-- instead be dragged out into a line, and the units spread along it; in one that gives an area order, the left button
-- drags out a circle, and every unit that can do the job is sent to do it to whatever turns up inside.
--
-- A building picked from the build menu, or by its key (shared/build_hotkeys.luau), is placed by a left click, or with
-- shift dragged out into a line, and with alt as well a grid; [ and ] turn it, and a right click puts it down.
--
-- G stops everything selected, ctrl+B sets it to destroy itself, K switches its shields, Q selects everything on screen of
-- the same kind, Tab selects your commanders in turn, T opens and closes the player list, P pilots a unit (pilot.luau),
-- and Escape closes the player list and ends whatever the cursor was doing.
--
-- A spectator commands nothing: the left button selects, to look at what it selects, and Q, T and Escape do what they
-- do, and nothing else is heard.
--
-- A factory's build orders always queue, shift or not, so they never go through here.

local ReplicatedStorage = game:GetService "ReplicatedStorage"
local RunService = game:GetService "RunService"
local UserInputService = game:GetService "UserInputService"

local heightmap = require(ReplicatedStorage.Shared.heightmap)
local geometry = require(ReplicatedStorage.Shared.geometry)
local build_hotkeys = require(ReplicatedStorage.Shared.build_hotkeys)

local campaign_standing = require(ReplicatedStorage.ClientShared.campaign_standing)

local cursor = require(ReplicatedStorage.Client.cursor)
local modifiers = require(ReplicatedStorage.Client.modifiers)
local markers = require(ReplicatedStorage.Client.markers)
local queue_paths = require(ReplicatedStorage.Client.queue_paths)
local world = require(ReplicatedStorage.Client.world)
local pilot = require(ReplicatedStorage.Client.pilot)
local hud_state = require(ReplicatedStorage.Client.hud_state)
local build_mode = require(ReplicatedStorage.Client.build_mode)
local input_router = require(ReplicatedStorage.Client.input_router)
local command_state = require(ReplicatedStorage.Client.command_state)
local order_modes = require(ReplicatedStorage.Client.order_modes)
local orders = require(ReplicatedStorage.Client.orders)
local selected = require(ReplicatedStorage.Client.selected)
local commands = require(ReplicatedStorage.Client.commands)
local picking = require(ReplicatedStorage.Client.picking)
local placing = require(ReplicatedStorage.Client.placing)
local drag_trace = require(ReplicatedStorage.Client.drag_trace)
local hover = require(ReplicatedStorage.Client.hover)
local mode_aim = require(ReplicatedStorage.Client.mode_aim)

type State = command_state.State
type ModeInfo = order_modes.ModeInfo

-- A left-drag shorter than this, in pixels, is a click rather than a selection box.
local SELECTION_DRAG_THRESHOLD = 6

-- Set while an exclusive layer (piloting) is over this one: nothing is commanded, hovered or drawn.
local covered = false

-- Mouse ---------------------------------------------------------------------------------------------------------------

-- A click in the mode `info`: its order is given, and the mode goes on only if it was and shift is held.
local function click_mode(info: ModeInfo)
	local queueing = orders.from_keys()
	command_state.release(commands.mode_click(info, queueing) and queueing.queue)
end

-- A button went down in the mode `info`. What it does waits for the button to come up, to tell a click from a line or
-- a circle; with no ground under the cursor to start one from it is a click at once.
local function press_in_mode(info: ModeInfo, button: "left" | "right")
	local shape: "line" | "area" = if button == "left" and info.area ~= nil then "area" else "line"
	local from = cursor.ground_point()
	if from == nil then
		if button == "left" then
			click_mode(info)
		else
			command_state.to_idle()
		end
		return
	end
	if shape == "line" then
		drag_trace.begin(from)
	end
	command_state.drag_in_mode({ shape = shape, button = button, from = from })
end

local function on_left_down()
	local state = command_state.get()
	if state.kind == "idle" then
		command_state.press_select(UserInputService:GetMouseLocation())
	elseif state.kind == "mode" and state.drag == nil then
		local info = order_modes.get(state.mode)
		if info.area ~= nil or info.line ~= nil then
			press_in_mode(info, "left")
		else
			click_mode(info)
		end
	elseif state.kind == "placing" and state.from == nil then
		if modifiers.shift_held() then
			-- shift starts a line, or with alt a grid, that the drag stretches and letting go places
			local center = placing.under_cursor(state.def_name)
			if center ~= nil then
				command_state.drag_placing(center)
			end
		elseif placing.place_one(state.def_name) then
			command_state.to_idle()
		end
	end
end

-- A line or circle dragged in the mode `info` with the left button, let go: a line or circle if it was dragged far
-- enough, and a click otherwise.
local function release_mode_drag(info: ModeInfo, drag: command_state.ModeDrag)
	local queueing = orders.from_keys()
	local sent = false
	if drag.shape == "line" then
		local path = drag_trace.finish()
		sent = if drag_trace.is_line(path)
			then commands.mode_line(info, path, queueing)
			else commands.mode_click(info, queueing)
	else
		markers.hide_area()
		local point = cursor.ground_point()
		local radius = if point ~= nil then geometry.distance_2d(drag.from, point) else 0
		sent = if radius >= drag_trace.FORMATION_DRAG_THRESHOLD and info.area ~= nil
			then commands.mode_area(info, drag.from, radius, queueing)
			else commands.mode_click(info, queueing)
	end
	command_state.release(sent and queueing.queue)
end

local function on_left_up()
	local state = command_state.get()
	if state.kind == "mode" and state.drag ~= nil and state.drag.button == "left" then
		release_mode_drag(order_modes.get(state.mode), state.drag)
	elseif state.kind == "placing" and state.from ~= nil then
		placing.place_layout(state.def_name, state.from)
		command_state.release(modifiers.shift_held())
	elseif state.kind == "selecting" then
		local rect = state.rect
		command_state.to_idle()
		if rect ~= nil then
			picking.select_box(rect, modifiers.shift_held())
		else
			picking.select_click(modifiers.shift_held())
		end
	end
end

local function on_right_down()
	local state = command_state.get()
	if state.kind == "idle" then
		local from = cursor.ground_point()
		if from ~= nil then
			drag_trace.begin(from)
			command_state.press_order(from)
		end
	elseif state.kind == "mode" and state.drag == nil and order_modes.get(state.mode).line ~= nil then
		-- a plain right click still cancels the mode, while a right drag lays down a line of its orders instead
		press_in_mode(order_modes.get(state.mode), "right")
	elseif state.kind == "mode" or state.kind == "placing" then
		command_state.to_idle()
	end
end

local function on_right_up()
	local state = command_state.get()
	if state.kind == "mode" and state.drag ~= nil and state.drag.button == "right" then
		local path = drag_trace.finish()
		local queueing = orders.from_keys()
		if drag_trace.is_line(path) then
			command_state.release(commands.mode_line(order_modes.get(state.mode), path, queueing) and queueing.queue)
		else
			command_state.to_idle()
		end
	elseif state.kind == "ordering" then
		local path = drag_trace.finish()
		command_state.to_idle()
		-- a long enough right drag is a formation along the shape it traced; anything shorter is a plain right click
		if drag_trace.is_line(path) then
			commands.move_along(path, orders.from_keys())
		else
			commands.right_click(orders.from_keys())
		end
	end
end

-- Keys ----------------------------------------------------------------------------------------------------------------

-- Whether the selection can build `def_name`, out of what it can build (`builds`), and the player has unlocked it.
local function can_build(def_name: string, builds: { string }): boolean
	return campaign_standing.is_unlocked(def_name) and table.find(builds, def_name) ~= nil
end

-- Handles `key` if it is a build key right now, and says whether it was. Within the category of what is being placed
-- its keys pick the buildings the menu shows them against, ahead of anything they mean otherwise (Q selecting
-- everything of a type, say). Outside one, a category's key places what the build menu's first page offers for it.
local function press_build_key(key: string): boolean
	local placing_now = command_state.placing()
	local category = if placing_now ~= nil then build_hotkeys.category_of(placing_now) else nil
	local candidates = if category ~= nil then build_hotkeys.pick(category, key) else nil
	if candidates ~= nil then
		local builds = selected.buildable()
		for _, def_name in candidates do
			if can_build(def_name, builds) then
				command_state.place(def_name)
				break
			end
		end
		return true
	end
	local started = build_hotkeys.started_by(key)
	local entry = if started ~= nil
		then build_hotkeys.entry(started, selected.buildable(), campaign_standing.is_unlocked)
		else nil
	if entry == nil then
		return false
	end
	command_state.place(entry)
	return true
end

-- Puts the cursor in the first mode `key` starts that the selection can use, and says whether `key` starts any.
local function press_mode_key(key: string): boolean
	local modes = order_modes.for_key(key)
	for _, info in modes do
		if command_state.enter_mode(info.mode) then
			break
		end
	end
	return #modes > 0
end

local KEYS: { [Enum.KeyCode]: () -> () } = table.freeze({
	-- a mode waiting for its click ends with the orders it would have given; a building being placed stays in hand
	[Enum.KeyCode.G] = function()
		if command_state.mode() ~= nil then
			command_state.to_idle()
		end
		commands.stop()
	end,
	[Enum.KeyCode.Q] = picking.select_same_type,
	[Enum.KeyCode.LeftBracket] = function()
		build_mode.rotate(1)
	end,
	[Enum.KeyCode.RightBracket] = function()
		build_mode.rotate(-1)
	end,
	[Enum.KeyCode.T] = hud_state.toggle_player_list,
	[Enum.KeyCode.Escape] = function()
		hud_state.close_player_list()
		command_state.to_idle()
	end,
	[Enum.KeyCode.Tab] = picking.cycle_commander,
	[Enum.KeyCode.P] = pilot.take_selected,
	[Enum.KeyCode.K] = commands.toggle_shield,
})

-- The keys a spectator has: those that select, or open and close the player list.
local SPECTATOR_KEYS: { [Enum.KeyCode]: boolean } = table.freeze({
	[Enum.KeyCode.Q] = true,
	[Enum.KeyCode.T] = true,
	[Enum.KeyCode.Escape] = true,
})

-- Handles `key`, and says whether it means anything here. Build keys come first, then the keys of their own, then the
-- modes'.
local function on_key(key: Enum.KeyCode): boolean
	if key == Enum.KeyCode.B and modifiers.ctrl_held() then
		commands.self_destruct()
		return true
	end
	if press_build_key(key.Name) then
		return true
	end
	local action = KEYS[key]
	if action ~= nil then
		action()
		return true
	end
	return press_mode_key(key.Name)
end

-- Frames --------------------------------------------------------------------------------------------------------------

-- Shows the rectangle the first shooter's shot would sweep, from it toward the cursor out to its range. With shift
-- held the shot is queued behind everything it has to do first, so the rectangle starts where it is expected to be
-- once that is done, and not where it stands now.
local function preview_manual(info: ModeInfo)
	local point = cursor.ground_point()
	local first = selected.for_mode(info)[1]
	local weapon = if first ~= nil then first.def.manual_weapon else nil
	if point == nil or first == nil or weapon == nil then
		markers.hide_blast()
		return
	end
	local at = if modifiers.shift_held() then queue_paths.expected_end(first.model) else world.position_of(first.model)
	local direction = geometry.flatten(point - at)
	if direction.Magnitude < 1e-3 then
		markers.hide_blast()
		return
	end
	local far = at + direction.Unit * weapon.range
	markers.show_blast(heightmap.ground_position(at.X, at.Z), heightmap.ground_position(far.X, far.Z), weapon.radius)
end

-- The circle an area drag has stretched to, once it is far enough to be one.
local function preview_area(info: ModeInfo, from: Vector3)
	local point = cursor.ground_point()
	local radius = if point ~= nil then geometry.distance_2d(from, point) else 0
	if radius >= drag_trace.FORMATION_DRAG_THRESHOLD then
		markers.show_area(from, radius, info.area)
	else
		markers.hide_area()
	end
end

local function preview_mode(info: ModeInfo, drag: command_state.ModeDrag?)
	if info.click == "manual" then
		preview_manual(info)
	end
	if drag == nil then
		return
	elseif drag.shape == "line" and info.line ~= nil then
		drag_trace.preview(#selected.for_mode(info), info.line, false)
	elseif drag.shape == "area" then
		preview_area(info, drag.from)
	end
end

-- The box a left drag has stretched to, once the cursor is far enough from where it went down to be one.
local function stretch_box(from: Vector2)
	local now = UserInputService:GetMouseLocation()
	if (now - from).Magnitude < SELECTION_DRAG_THRESHOLD then
		return
	end
	command_state.stretch_box({
		min = Vector2.new(math.min(from.X, now.X), math.min(from.Y, now.Y)),
		max = Vector2.new(math.max(from.X, now.X), math.max(from.Y, now.Y)),
	})
end

local function on_render()
	if covered then
		return
	end
	local state = command_state.get()
	local placing_at = if state.kind == "placing" then placing.preview(state.def_name, state.from) else nil
	hover.render(state, placing_at)
	if state.kind == "mode" then
		local info = order_modes.get(state.mode)
		mode_aim.render(info, state.drag)
		preview_mode(info, state.drag)
	elseif state.kind == "ordering" then
		drag_trace.preview(#selected.movers(), "move", true)
	elseif state.kind == "selecting" then
		stretch_box(state.from)
	end
end

-- Whatever drew what the cursor was doing is taken down as it stops doing it, however it came to stop.
local function on_state_changed(now: State, before: State)
	local drag_before = if before.kind == "mode" then before.drag else nil
	local drag_now = if now.kind == "mode" then now.drag else nil
	if (drag_before ~= nil and drag_now == nil) or (before.kind == "ordering" and now.kind ~= "ordering") then
		drag_trace.cancel()
		markers.hide_area()
	end
	local still_same_mode = now.kind == "mode" and before.kind == "mode" and now.mode == before.mode
	if before.kind == "mode" and order_modes.get(before.mode).click == "manual" and still_same_mode == false then
		markers.hide_blast()
	end
	if before.kind == "mode" and now.kind ~= "mode" then
		mode_aim.clear()
	end
	if before.kind == "placing" and before.from ~= nil and (now.kind ~= "placing" or now.from == nil) then
		build_mode.clear_preview()
	end
end

-- Layer -----------------------------------------------------------------------------------------------------------

local function began(input: InputObject, processed: boolean): boolean
	if processed then
		return false
	end
	if world.spectating() then
		if input.UserInputType == Enum.UserInputType.MouseButton1 then
			on_left_down()
			return true
		elseif input.UserInputType == Enum.UserInputType.Keyboard and SPECTATOR_KEYS[input.KeyCode] == true then
			KEYS[input.KeyCode]()
			return true
		end
		return false
	end
	if input.UserInputType == Enum.UserInputType.MouseButton1 then
		on_left_down()
		return true
	elseif input.UserInputType == Enum.UserInputType.MouseButton2 then
		on_right_down()
		return true
	elseif input.UserInputType == Enum.UserInputType.Keyboard then
		return on_key(input.KeyCode)
	end
	return false
end

local function ended(input: InputObject)
	if covered then
		return
	elseif input.UserInputType == Enum.UserInputType.MouseButton1 then
		on_left_up()
	elseif input.UserInputType == Enum.UserInputType.MouseButton2 then
		on_right_up()
	end
end

-- Under a unit being piloted nothing is commanded: whatever the cursor was doing is dropped.
local function on_covered(now: boolean)
	covered = now
	if now then
		command_state.to_idle()
		hover.clear()
		mode_aim.clear()
	end
end

local function init()
	command_state.subscribe(on_state_changed)
	input_router.push({
		began = began,
		ended = ended,
		exclusive = false,
		covered = on_covered,
	})
	-- after the camera, which it casts rays through
	RunService:BindToRenderStep("rts_input", Enum.RenderPriority.Camera.Value + 1, on_render)
end

return table.freeze({
	init = init,
})
