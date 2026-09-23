local Players = game:GetService "Players"
local ReplicatedStorage = game:GetService "ReplicatedStorage"

local React = require(ReplicatedStorage.Packages.react)
local ReactRoblox = require(ReplicatedStorage.Packages["react-roblox"])

local stylesheets = require(ReplicatedStorage.Client.ui.stylesheets)
local resource_bar = require(ReplicatedStorage.Client.ui.resource_bar)
local selection_panel = require(ReplicatedStorage.Client.ui.selection_panel)
local build_menu = require(ReplicatedStorage.Client.ui.build_menu)
local command_panel = require(ReplicatedStorage.Client.ui.command_panel)
local selection_box = require(ReplicatedStorage.Client.ui.selection_box)
local world_bars = require(ReplicatedStorage.Client.ui.world_bars)
local lobby_panel = require(ReplicatedStorage.Client.ui.lobby_panel)

local ResourceBar = resource_bar.ResourceBar
local SelectionPanel = selection_panel.SelectionPanel
local BuildMenu = build_menu.BuildMenu
local CommandPanel = command_panel.CommandPanel
local SelectionBox = selection_box.SelectionBox
local PlacementHint = selection_box.PlacementHint
local ModeHint = selection_box.ModeHint

local player = Players.LocalPlayer

local function Main()
	return React.createElement(React.Fragment, {}, {
		StyleLink = React.createElement("StyleLink", {
			StyleSheet = stylesheets.default_stylesheet,
		}),
		-- Both bottom panels sit directly under the ScreenGui so that their percentage positions
		-- resolve against the screen. Nesting them in a zero-height bar put the build menu 20px below
		-- the bottom edge and the selection panel a full panel-height above it.
		-- The selection panel and the command menu are one row along the bottom left, the menu after the panel, so
		-- it follows the panel however wide or narrow that is and needs no position of its own.
		BottomLeft = React.createElement("Frame", {
			[React.Tag] = "bottom-left",
		}, {
			SelectionPanel = React.createElement(SelectionPanel),
			CommandPanel = React.createElement(CommandPanel),
		}),
		BuildMenu = React.createElement(BuildMenu),
		ResourceBar = React.createElement(ResourceBar),
		SelectionBox = React.createElement(SelectionBox),
		PlacementHint = React.createElement(PlacementHint),
		ModeHint = React.createElement(ModeHint),
		LobbyPanel = React.createElement(lobby_panel.LobbyPanel),
	})
end

-- The bars over entities. They live in a GUI of their own that ignores the GUI inset, so that the
-- viewport point of an entity is also the position of its bar with no inset arithmetic, and that
-- sits behind the HUD panels.
local function Overlay()
	return React.createElement(React.Fragment, {}, {
		StyleLink = React.createElement("StyleLink", {
			StyleSheet = stylesheets.default_stylesheet,
		}),
		WorldBars = React.createElement(world_bars.WorldBars),
	})
end

local function init_ui()
	local gui = Instance.new "ScreenGui"
	gui.Name = "Hud"
	gui.ResetOnSpawn = false
	-- Left false on purpose, so the panels sit clear of the Roblox topbar rather than under it.
	-- The cost is that this GUI's origin is one GUI inset below the top of the viewport, so
	-- anything positioned from viewport coordinates - the drag box, anything else drawn over a
	-- world point - has to subtract GuiService:GetGuiInset() first. See selection_box.luau.
	gui.IgnoreGuiInset = false
	gui.ZIndexBehavior = Enum.ZIndexBehavior.Sibling
	gui.Parent = player:WaitForChild "PlayerGui"

	ReactRoblox.createRoot(gui):render(React.createElement(Main))

	local overlay = Instance.new "ScreenGui"
	overlay.Name = "World"
	overlay.ResetOnSpawn = false
	overlay.IgnoreGuiInset = true
	overlay.DisplayOrder = -1
	overlay.ZIndexBehavior = Enum.ZIndexBehavior.Sibling
	overlay.Parent = player:WaitForChild "PlayerGui"

	ReactRoblox.createRoot(overlay):render(React.createElement(Overlay))
end

return table.freeze({
	init_ui = init_ui,
})
