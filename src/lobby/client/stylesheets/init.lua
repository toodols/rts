-- The lobby's stylesheet: lobby.scss, compiled by outlass into lobby_stylesheet.lua (see build_stylesheets.bat). It
-- is the game's theme, mixins and base rules with the lobby's own screens on top, so the two look like one game.
--
-- A StyleLink only applies a sheet that is in the DataModel, so it is kept in ReplicatedStorage; only the client
-- requires this, and what it puts there is its own.

local ReplicatedStorage = game:GetService "ReplicatedStorage"

local lobby_stylesheet = require(script.lobby_stylesheet)

lobby_stylesheet.Name = "LobbyStylesheet"
lobby_stylesheet.Parent = ReplicatedStorage

return table.freeze({ lobby_stylesheet = lobby_stylesheet })
