-- Lobby client entry point: the menus for finding a game and setting one up, over a scene of the game's own units
-- that is only there to be looked at.

local ReplicatedStorage = game:GetService "ReplicatedStorage"
local StarterGui = game:GetService "StarterGui"

local scene = require(ReplicatedStorage.LobbyClient.scene)
local sounds = require(ReplicatedStorage.Client.sounds)
local ui = require(ReplicatedStorage.LobbyClient.ui)

-- the Roblox player list and chat stay; the backpack and health have nothing to show
StarterGui:SetCoreGuiEnabled(Enum.CoreGuiType.Backpack, false)
StarterGui:SetCoreGuiEnabled(Enum.CoreGuiType.Health, false)

scene.init()
ui.init_ui()
sounds.init_clicks()
