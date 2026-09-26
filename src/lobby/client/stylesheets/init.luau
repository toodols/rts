--!strict
-- The lobby's stylesheet: lobby.scss, compiled by outlass into lobby_stylesheet.lua (see build_stylesheets.bat). It
-- is the game's theme, mixins and base rules with the lobby's own screens on top, so the two look like one game.
--
-- A StyleLink only applies a sheet that is in the DataModel, so the first time it is asked for it is put in
-- ReplicatedStorage; only the client asks, and what it puts there is its own.

local ReplicatedStorage = game:GetService "ReplicatedStorage"

local sheet: StyleSheet? = nil

local function lobby(): StyleSheet
	if sheet ~= nil then
		return sheet
	end
	local made = require(script.lobby_stylesheet) :: StyleSheet
	made.Name = "LobbyStylesheet"
	made.Parent = ReplicatedStorage
	sheet = made
	return made
end

return table.freeze({
	lobby = lobby,
})
