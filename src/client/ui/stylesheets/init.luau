--!strict
-- The HUD's stylesheet: default.scss, compiled by outlass into default_stylesheet.lua (see build_stylesheets.bat).
--
-- A StyleLink only applies a sheet that is in the DataModel, so the first time it is asked for it is put in
-- ReplicatedStorage; only the client asks, and what it puts there is its own.

local ReplicatedStorage = game:GetService "ReplicatedStorage"

local sheet: StyleSheet? = nil

local function default(): StyleSheet
	if sheet ~= nil then
		return sheet
	end
	local made = require(script.default_stylesheet) :: StyleSheet
	made.Name = "DefaultStylesheet"
	made.Parent = ReplicatedStorage
	sheet = made
	return made
end

return table.freeze({
	default = default,
})
