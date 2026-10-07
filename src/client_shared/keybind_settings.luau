--!strict
-- The keybind settings, the same in the lobby's Settings tab and the game's settings panel: the profiles to choose
-- from (Shared.keybinds), a reset of everything rebound in the one in use, and every action under its section against
-- its key. A click on a key waits for the next one pressed, which it is bound to (with ctrl, if held, for an action that
-- is not held down), and whatever else had that key where it would clash loses it, as the line under the header says;
-- Escape or a click anywhere stops waiting. A right click on a key unbinds it. Only a developer, who can pilot a unit,
-- sees the piloting keys. The build menu's key slots are a grid of keys laid out as BAR's build grid is, with nothing
-- beside them: what a slot places depends on the category, and the build menu shows that against its key.
--
-- Where the keys come from while one is waited for is `listen`'s, if given: the game's panel hands them over from its
-- own input layer, which takes every key while it is open. Otherwise they come straight from UserInputService.

local Players = game:GetService "Players"
local ReplicatedStorage = game:GetService "ReplicatedStorage"
local UserInputService = game:GetService "UserInputService"

local React = require(ReplicatedStorage.Packages.react)

local developers = require(ReplicatedStorage.Shared.developers)
local keybinds = require(ReplicatedStorage.Shared.keybinds)

local keybind_state = require(script.Parent.keybind_state)
local use_store = require(script.Parent.use_store)

local local_player = Players.LocalPlayer

-- Hands `handler` every input that begins until the returned function is called.
export type Listen = (handler: (input: InputObject) -> ()) -> () -> ()

-- An element's properties: strict mode cannot type a table of them that mixes tags, properties and handlers.
type Props = { [any]: any }

-- Keys that are never bound: Escape stops waiting, and the modifiers are held along with a key rather than bound.
local NEVER_BOUND: { [Enum.KeyCode]: boolean } = {
	[Enum.KeyCode.Escape] = true,
	[Enum.KeyCode.LeftShift] = true,
	[Enum.KeyCode.RightShift] = true,
	[Enum.KeyCode.LeftControl] = true,
	[Enum.KeyCode.RightControl] = true,
	[Enum.KeyCode.LeftAlt] = true,
	[Enum.KeyCode.RightAlt] = true,
}

local function from_user_input(handler: (input: InputObject) -> ()): () -> ()
	local connection = UserInputService.InputBegan:Connect(function(input: InputObject)
		if UserInputService:GetFocusedTextBox() == nil then
			handler(input)
		end
	end)
	return function()
		connection:Disconnect()
	end
end

local function ctrl_held(): boolean
	return UserInputService:IsKeyDown(Enum.KeyCode.LeftControl) or UserInputService:IsKeyDown(Enum.KeyCode.RightControl)
end

local function Chip(props: { label: string, active: boolean?, on_press: () -> (), LayoutOrder: number })
	return React.createElement(
		"TextButton",
		{
			[React.Tag] = if props.active == true then "keybinds-chip active" else "keybinds-chip",
			LayoutOrder = props.LayoutOrder,
			Text = "",
			AutoButtonColor = false,
			[React.Event.Activated] = props.on_press,
		} :: Props,
		{
			Label = React.createElement("TextLabel", {
				[React.Tag] = "keybinds-chip-label",
				Text = props.label,
			}),
		}
	)
end

-- What a key's cell does: its binding, whether it waits for a key, and what a click and a right click do.
type Cell = {
	binding: string,
	capturing: boolean,
	on_capture: () -> (),
	on_clear: () -> (),
}

-- An action's key, to click and press a new one on. `tag` is more classes for it.
local function KeyCell(props: Cell & { tag: string?, LayoutOrder: number })
	local shown = keybinds.label(props.binding)
	local tag = "keybinds-key"
	if props.tag ~= nil then
		tag ..= ` {props.tag}`
	end
	if props.capturing then
		tag ..= " capturing"
	elseif shown == "" then
		tag ..= " unbound"
	end
	return React.createElement(
		"TextButton",
		{
			[React.Tag] = tag,
			LayoutOrder = props.LayoutOrder,
			Text = "",
			AutoButtonColor = false,
			[React.Event.Activated] = props.on_capture,
			[React.Event.MouseButton2Click] = props.on_clear,
		} :: Props,
		{
			Label = React.createElement("TextLabel", {
				[React.Tag] = "keybinds-key-label",
				Text = if props.capturing then "…" elseif shown == "" then "—" else shown,
			}),
		}
	)
end

-- An action on a line of its own: what it is, and its key.
local function Row(props: Cell & { label: string, LayoutOrder: number })
	return React.createElement("Frame", {
		[React.Tag] = "keybinds-row",
		LayoutOrder = props.LayoutOrder,
	}, {
		Label = React.createElement("TextLabel", {
			[React.Tag] = "keybinds-label",
			LayoutOrder = 1,
			Text = props.label,
		}),
		Key = React.createElement(KeyCell, {
			binding = props.binding,
			capturing = props.capturing,
			on_capture = props.on_capture,
			on_clear = props.on_clear,
			LayoutOrder = 2,
		}),
	})
end

local function KeybindSettings(
	props: {
		listen: Listen?,
		-- a close button, for a panel that can be closed
		on_close: (() -> ())?,
		-- more classes for the whole, like the lobby's glass panel
		tag: string?,
	}
)
	local bindings = keybind_state.use_bindings()
	local record = keybind_state.current()
	local developer = use_store.use_store(function(): boolean
		return developers.is_developer(local_player)
	end, function(listener: () -> ()): () -> ()
		return developers.changed(local_player, listener)
	end)
	-- the action waiting for a key, if any
	local capturing: string?, set_capturing = React.useState(nil :: string?)
	-- what lost its key to the last one bound
	local notice: string?, set_notice = React.useState(nil :: string?)

	local function bind(id: string, binding: string)
		local unbound = keybind_state.bind(id, binding)
		local names = table.create(#unbound)
		for _, other in unbound do
			local action = keybinds.get(other)
			if action ~= nil and (developer or action.developer == false) then
				table.insert(names, `{action.section}: {action.label}`)
			end
		end
		set_notice(if #names > 0 then `Unbound {table.concat(names, ", ")}` else nil)
	end

	React.useEffect(function(): (() -> ())?
		if capturing == nil then
			return nil
		end
		local action = keybinds.get(capturing)
		local listen: Listen = props.listen or from_user_input
		return listen(function(input: InputObject)
			if input.UserInputType ~= Enum.UserInputType.Keyboard then
				-- a click anywhere stops waiting; one on a key starts waiting for that one
				if string.find(input.UserInputType.Name, "MouseButton") ~= nil then
					set_capturing(nil)
				end
				return
			end
			if input.KeyCode == Enum.KeyCode.Escape then
				set_capturing(nil)
				return
			end
			local name = input.KeyCode.Name
			if NEVER_BOUND[input.KeyCode] or keybinds.key_labels[name] == nil or action == nil then
				return
			end
			bind(action.id, keybinds.join(name, action.held == false and ctrl_held()))
			set_capturing(nil)
		end)
	end, { capturing, props.listen } :: { any })

	local header: { [string]: any } = {
		Title = React.createElement("TextLabel", {
			[React.Tag] = "keybinds-title",
			LayoutOrder = 1,
			Text = "KEYBINDS",
		}),
	}
	for index, profile in keybinds.profiles do
		header[`Profile_{profile.id}`] = React.createElement(Chip, {
			label = string.upper(profile.name),
			active = profile.id == keybinds.profile_of(record).id,
			on_press = function()
				set_notice(nil)
				keybind_state.choose(profile.id)
			end,
			LayoutOrder = 1 + index,
		})
	end
	header.Reset = React.createElement(Chip, {
		label = "RESET",
		on_press = function()
			set_capturing(nil)
			set_notice(nil)
			keybind_state.reset()
		end,
		LayoutOrder = 100,
	})
	if props.on_close ~= nil then
		header.Close = React.createElement(Chip, {
			label = "CLOSE",
			on_press = props.on_close,
			LayoutOrder = 101,
		})
	end

	local function cell(action: keybinds.Action): Cell
		return {
			binding = bindings[action.id] or "",
			capturing = capturing == action.id,
			on_capture = function()
				set_capturing(action.id)
			end,
			on_clear = function()
				set_capturing(nil)
				bind(action.id, "")
			end,
		}
	end

	local rows: { [string]: any } = {}
	-- the grid of the build menu's key slots, by row, each row's keys by column
	local grid_rows: { [number]: { [string]: any } } = {}
	local grid_order: number? = nil
	local section: string? = nil
	for index, action in keybinds.actions do
		if action.developer and developer == false then
			continue
		end
		if action.section ~= section then
			section = action.section
			rows[`Section_{action.section}`] = React.createElement("TextLabel", {
				[React.Tag] = "keybinds-section",
				LayoutOrder = index * 2 - 1,
				Text = string.upper(action.section),
			})
		end
		local grid = action.grid
		if grid ~= nil then
			grid_order = grid_order or index * 2
			local keys = grid_rows[grid.row] or {}
			grid_rows[grid.row] = keys
			local props: any = cell(action)
			props.tag = "slot"
			props.LayoutOrder = grid.column
			keys[action.id] = React.createElement(KeyCell, props)
			continue
		end
		local props: any = cell(action)
		props.label = action.label
		props.LayoutOrder = index * 2
		rows[action.id] = React.createElement(Row, props)
	end
	if grid_order ~= nil then
		local lines: { [string]: any } = {}
		for row, keys in grid_rows do
			lines[`Row{row}`] = React.createElement("Frame", {
				[React.Tag] = `keybinds-grid-row stagger-{row - 1}`,
				LayoutOrder = row,
			}, keys)
		end
		rows.Grid = React.createElement("Frame", {
			[React.Tag] = "keybinds-grid",
			LayoutOrder = grid_order,
		}, lines)
	end

	return React.createElement("Frame", {
		[React.Tag] = if props.tag ~= nil then `keybinds {props.tag}` else "keybinds",
	}, {
		Header = React.createElement("Frame", {
			[React.Tag] = "keybinds-header",
			LayoutOrder = 1,
		}, header),
		Notice = React.createElement("TextLabel", {
			[React.Tag] = "keybinds-notice",
			LayoutOrder = 2,
			Text = notice or "",
		}),
		List = React.createElement("ScrollingFrame", {
			[React.Tag] = "keybinds-list",
			LayoutOrder = 3,
			CanvasSize = UDim2.new(),
			AutomaticCanvasSize = Enum.AutomaticSize.Y,
			ScrollingDirection = Enum.ScrollingDirection.Y,
		}, rows),
	})
end

return table.freeze({
	KeybindSettings = KeybindSettings,
})
