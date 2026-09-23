-- The lobby's buttons. Each is a TextButton with no text of its own and its label in a TextLabel inside it, as the
-- HUD's cells are: the cell's face is a gradient, which outlass makes a UIGradient on the button, and a UIGradient
-- tints its object's own text as well as its background - white text over the cell's dark gradient comes out nearly
-- black - where in CSS a background image never touches the text. A child label is left alone.

local ReplicatedStorage = game:GetService "ReplicatedStorage"

local React = require(ReplicatedStorage.Packages.react)

-- `kind` is the button's class, "button" or "chip"; `tag` any more classes; a `locked` button cannot be pressed.
local function Button(props: {
	kind: string,
	label: string,
	tag: string?,
	locked: boolean?,
	on_press: () -> (),
	LayoutOrder: number?,
})
	local tag = props.kind
	if props.tag ~= nil then
		tag ..= ` {props.tag}`
	end
	if props.locked == true then
		tag ..= " locked"
	end
	return React.createElement("TextButton", {
		[React.Tag] = tag,
		LayoutOrder = props.LayoutOrder,
		Text = "",
		AutoButtonColor = false,
		Interactable = props.locked ~= true,
		[React.Event.Activated] = props.on_press,
	}, {
		Label = React.createElement("TextLabel", {
			[React.Tag] = `{props.kind}-label`,
			Text = props.label,
		}),
	})
end

return table.freeze({
	Button = Button,
})
