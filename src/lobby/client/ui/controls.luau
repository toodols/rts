--!strict
-- The lobby's buttons. Each is a TextButton with no text of its own and its label in a TextLabel inside it, as the
-- HUD's cells are: the cell's face is a gradient, which outlass makes a UIGradient on the button, and a UIGradient
-- tints its object's own text as well as its background - white text over the cell's dark gradient comes out nearly
-- black - where in CSS a background image never touches the text. A child label is left alone.
--
-- A command button (kind "button") also carries a rail and a sheen over its label. The stylesheet lights the face, the
-- edge and the words and runs the rail out; this sweeps the sheen across each time the button lights, and lights it
-- while a gamepad has it selected, which Roblox's styles have no state for.

local ReplicatedStorage = game:GetService "ReplicatedStorage"
local TweenService = game:GetService "TweenService"

local React = require(ReplicatedStorage.Packages.react)

-- An element's properties: strict mode cannot type a table of them that mixes tags, properties and handlers.
type Props = { [any]: any }

-- The sheen's gradient carries a band of light across its middle, and is slid from a width left of the button to a
-- width right of it, where it stays parked, out of sight.
local SHEEN = TweenInfo.new(0.6, Enum.EasingStyle.Quint, Enum.EasingDirection.Out)
local SHEEN_START = Vector2.new(-1, 0)
local SHEEN_PARKED = Vector2.new(1, 0)
local SHEEN_BAND = NumberSequence.new({
	NumberSequenceKeypoint.new(0, 1),
	NumberSequenceKeypoint.new(0.4, 1),
	NumberSequenceKeypoint.new(0.5, 0.8),
	NumberSequenceKeypoint.new(0.6, 1),
	NumberSequenceKeypoint.new(1, 1),
})
local SHEEN_ROTATION = 15

-- `kind` is the button's class, "button" or "chip"; `tag` any more classes; a `locked` button cannot be pressed.
local function Button(props: {
	kind: string,
	label: string,
	tag: string?,
	locked: boolean?,
	on_press: () -> (),
	LayoutOrder: number?,
})
	local command = props.kind == "button"
	local locked = props.locked == true
	local selected, set_selected = React.useState(false)
	local sheen_ref = React.useRef(nil :: UIGradient?)
	local sweep_ref = React.useRef(nil :: Tween?)

	React.useEffect(function()
		return function()
			if sweep_ref.current ~= nil then
				sweep_ref.current:Cancel()
			end
		end
	end, {})

	local function sweep()
		local sheen = sheen_ref.current
		if sheen == nil or locked then
			return
		end
		if sweep_ref.current ~= nil then
			sweep_ref.current:Cancel()
		end
		sheen.Offset = SHEEN_START
		local tween = TweenService:Create(sheen, SHEEN, { Offset = SHEEN_PARKED })
		sweep_ref.current = tween
		tween:Play()
	end

	local tag = props.kind
	if props.tag ~= nil then
		tag ..= ` {props.tag}`
	end
	if locked then
		tag ..= " locked"
	elseif selected then
		tag ..= " selected"
	end
	return React.createElement(
		"TextButton",
		{
			[React.Tag] = tag,
			LayoutOrder = props.LayoutOrder,
			Text = "",
			AutoButtonColor = false,
			Interactable = not locked,
			[React.Event.Activated] = props.on_press,
			[React.Event.MouseEnter] = if command then sweep else nil,
			[React.Event.SelectionGained] = if command
				then function()
					set_selected(true)
					sweep()
				end
				else nil,
			[React.Event.SelectionLost] = if command
				then function()
					set_selected(false)
				end
				else nil,
		} :: Props,
		{
			Label = React.createElement("TextLabel", {
				[React.Tag] = `{props.kind}-label`,
				Text = props.label,
			}),
			Rail = if command then React.createElement("Frame", { [React.Tag] = "button-rail" }) else nil,
			Sheen = if command
				then React.createElement("Frame", { [React.Tag] = "button-sheen" }, {
					Band = React.createElement("UIGradient", {
						Transparency = SHEEN_BAND,
						Rotation = SHEEN_ROTATION,
						Offset = SHEEN_PARKED,
						ref = sheen_ref,
					}),
				})
				else nil,
		}
	)
end

return table.freeze({
	Button = Button,
})
