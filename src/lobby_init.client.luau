-- Lobby client entry point: there is no world here, only the menus for finding a game and setting one up.

local ReplicatedStorage = game:GetService "ReplicatedStorage"
local StarterGui = game:GetService "StarterGui"

local ui = require(ReplicatedStorage.LobbyClient.ui)

-- the Roblox player list and chat stay; the backpack and health have nothing to show
StarterGui:SetCoreGuiEnabled(Enum.CoreGuiType.Backpack, false)
StarterGui:SetCoreGuiEnabled(Enum.CoreGuiType.Health, false)

ui.init_ui()
