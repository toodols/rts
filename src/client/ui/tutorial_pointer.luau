-- The tutorial's finger on the button it wants clicked (Client.tutorial's `build_target` and `command_target`): the
-- button lit (`lit`), and a CLICK tag standing off one side of it, toward the middle of the screen, bobbing toward it.
-- Its parent is the button; it is styled by `.tutorial-pointer` (and the button by `.tutorial-highlight`), and placed
-- here rather than in the stylesheet, since it moves.

local ReplicatedStorage = game:GetService "ReplicatedStorage"
local RunService = game:GetService "RunService"

local React = require(ReplicatedStorage.Packages.react)

-- Which side of the button it stands off: "left" for a button at the right of the screen, "right" for one at the left.
export type Side = "left" | "right"

-- How far it stands off the button, how far it bobs toward it, and how many times a second.
local GAP = 8
local BOB = 6
local RATE = 1.5

-- The tags of a button, `tag`, lit when it is the one pointed at.
local function lit(tag: string, pointed: boolean): string
	return if pointed then `{tag} tutorial-highlight` else tag
end

local function TutorialPointer(props: { side: Side })
	local offset, set_offset = React.useBinding(0)
	React.useEffect(function()
		local began = os.clock()
		local connection = RunService.RenderStepped:Connect(function()
			set_offset(math.abs(math.sin((os.clock() - began) * RATE * math.pi)) * BOB)
		end)
		return function()
			connection:Disconnect()
		end
	end, {})
	local right = props.side == "right"
	return React.createElement("TextLabel", {
		[React.Tag] = "tutorial-pointer",
		AnchorPoint = if right then Vector2.new(0, 0.5) else Vector2.new(1, 0.5),
		Position = offset:map(function(x: number): UDim2
			return if right then UDim2.new(1, GAP + BOB - x, 0.5, 0) else UDim2.new(0, -GAP - BOB + x, 0.5, 0)
		end),
		Text = "CLICK",
	})
end

return table.freeze({
	lit = lit,
	TutorialPointer = TutorialPointer,
})
