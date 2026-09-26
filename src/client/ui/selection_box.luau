--!strict
-- The drag rectangle drawn while box-selecting. Client.command_state owns it; this only draws it.

local GuiService = game:GetService "GuiService"
local ReplicatedStorage = game:GetService "ReplicatedStorage"

local React = require(ReplicatedStorage.Packages.react)

local command_state = require(ReplicatedStorage.Client.command_state)

local use_store = require(ReplicatedStorage.ClientShared.use_store)

local function rect(): command_state.Rect?
	local state = command_state.get()
	return if state.kind == "selecting" then state.rect else nil
end

local function SelectionBox()
	local shown = use_store.use_store(rect, command_state.subscribe_rect)
	if shown == nil then
		return nil
	end

	-- These are two different spaces and they are one topbar apart.
	--
	-- The rectangle is in viewport space: that is what UserInputService:GetMouseLocation returns,
	-- and it is the space Camera:ViewportPointToRay and Camera:WorldToViewportPoint work in, which
	-- is why picking and box-selecting land on the right units. The HUD's ScreenGui leaves
	-- IgnoreGuiInset false so its panels dodge the Roblox topbar, which puts its origin a GUI inset
	-- below the top of the viewport. Drawing viewport coordinates there without taking the inset
	-- back off is what leaves the box sitting below the cursor.
	local inset = GuiService:GetGuiInset()
	local size = shown.max - shown.min
	return React.createElement("Frame", {
		[React.Tag] = "selection-box",
		Position = UDim2.fromOffset(shown.min.X - inset.X, shown.min.Y - inset.Y),
		Size = UDim2.fromOffset(size.X, size.Y),
	})
end

return table.freeze({
	SelectionBox = SelectionBox,
})
