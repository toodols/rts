--!strict
-- Whether a modifier key is held, either of its pair: what shift-queues an order, shift-adds to a selection or builds a
-- batch, and what alt and ctrl change.

local UserInputService = game:GetService "UserInputService"

local function shift_held(): boolean
	return UserInputService:IsKeyDown(Enum.KeyCode.LeftShift) or UserInputService:IsKeyDown(Enum.KeyCode.RightShift)
end

local function alt_held(): boolean
	return UserInputService:IsKeyDown(Enum.KeyCode.LeftAlt) or UserInputService:IsKeyDown(Enum.KeyCode.RightAlt)
end

local function ctrl_held(): boolean
	return UserInputService:IsKeyDown(Enum.KeyCode.LeftControl) or UserInputService:IsKeyDown(Enum.KeyCode.RightControl)
end

return table.freeze({
	shift_held = shift_held,
	alt_held = alt_held,
	ctrl_held = ctrl_held,
})
