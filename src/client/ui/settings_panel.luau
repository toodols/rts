--!strict
-- The game's settings: a button at the top left that opens them over the middle of the screen, the keybinds
-- (ClientShared.keybind_settings), as the lobby's Settings tab has them. While they are open every key and button is
-- theirs, an exclusive layer of the input router, so that nothing pressed to rebind a key is also a command; Escape
-- closes them, unless a key is being waited for, when it stops waiting instead.

local ReplicatedStorage = game:GetService "ReplicatedStorage"

local React = require(ReplicatedStorage.Packages.react)

local input_router = require(ReplicatedStorage.Client.input_router)
local use_viewport = require(ReplicatedStorage.Client.ui.use_viewport)

local keybind_settings = require(ReplicatedStorage.ClientShared.keybind_settings)

-- An element's properties: strict mode cannot type a table of them that mixes tags, properties and handlers.
type Props = { [any]: any }

local function SettingsPanel()
	local open, set_open = React.useState(false)
	local ui_scale = use_viewport.use_ui_scale()
	-- what the keybinds are waiting on a key with, while they are
	local capture = React.useRef(nil :: ((input: InputObject) -> ())?)

	React.useEffect(function(): (() -> ())?
		if open == false then
			return nil
		end
		return input_router.push({
			began = function(input: InputObject, processed: boolean): boolean
				local handler = capture.current
				-- a key typed into a text box, like the chat, is not one pressed to bind
				if processed and input.UserInputType == Enum.UserInputType.Keyboard then
					return true
				elseif handler ~= nil then
					handler(input)
				elseif input.KeyCode == Enum.KeyCode.Escape then
					set_open(false)
				end
				return true
			end,
			ended = function() end,
			wheel = function(): boolean
				return true
			end,
			exclusive = true,
		})
	end, { open })

	local listen = React.useCallback(function(handler: (input: InputObject) -> ()): () -> ()
		capture.current = handler
		return function()
			if capture.current == handler then
				capture.current = nil
			end
		end
	end, {})

	return React.createElement(React.Fragment, {}, {
		Button = React.createElement(
			"TextButton",
			{
				[React.Tag] = if open then "settings-button active" else "settings-button",
				Text = "",
				AutoButtonColor = false,
				[React.Event.Activated] = function()
					set_open(not open)
				end,
			} :: Props,
			{
				Scale = React.createElement("UIScale", { Scale = ui_scale }),
				Label = React.createElement("TextLabel", {
					[React.Tag] = "settings-button-label",
					Text = "SETTINGS",
				}),
			}
		),
		Panel = if open
			then React.createElement("Frame", {
				[React.Tag] = "settings-panel",
			}, {
				Scale = React.createElement("UIScale", { Scale = ui_scale }),
				Keybinds = React.createElement(keybind_settings.KeybindSettings, {
					listen = listen,
					on_close = function()
						set_open(false)
					end,
				}),
			})
			else nil,
	})
end

return table.freeze({
	SettingsPanel = SettingsPanel,
})
