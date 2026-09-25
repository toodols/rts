local Players = game:GetService "Players"
local ReplicatedStorage = game:GetService "ReplicatedStorage"

local React = require(ReplicatedStorage.Packages.react)
local ReactRoblox = require(ReplicatedStorage.Packages["react-roblox"])

local tutorial_steps = require(ReplicatedStorage.Client.tutorial)
local stylesheets = require(ReplicatedStorage.Client.ui.stylesheets)
local resource_bar = require(ReplicatedStorage.Client.ui.resource_bar)
local selection_panel = require(ReplicatedStorage.Client.ui.selection_panel)
local build_menu = require(ReplicatedStorage.Client.ui.build_menu)
local command_panel = require(ReplicatedStorage.Client.ui.command_panel)
local selection_box = require(ReplicatedStorage.Client.ui.selection_box)
local world_bars = require(ReplicatedStorage.Client.ui.world_bars)
local ping_markers = require(ReplicatedStorage.Client.ui.ping_markers)
local pilot_hud = require(ReplicatedStorage.Client.ui.pilot_hud)
local lobby_panel = require(ReplicatedStorage.Client.ui.lobby_panel)
local victory_screen = require(ReplicatedStorage.Client.ui.victory_screen)
local pause_overlay = require(ReplicatedStorage.Client.ui.pause_overlay)
local player_list = require(ReplicatedStorage.Client.ui.player_list)
local notifications = require(ReplicatedStorage.Client.ui.notifications)
local tooltip = require(ReplicatedStorage.Client.ui.tooltip)
local tutorial = require(ReplicatedStorage.Client.ui.tutorial)
local use_mission = require(ReplicatedStorage.Client.ui.use_mission)
local use_tutorial = require(ReplicatedStorage.Client.ui.use_tutorial)

local ResourceBar = resource_bar.ResourceBar
local SelectionPanel = selection_panel.SelectionPanel
local BuildMenu = build_menu.BuildMenu
local CommandPanel = command_panel.CommandPanel
local SelectionBox = selection_box.SelectionBox
local PlacementHint = selection_box.PlacementHint
local PlacementProblem = selection_box.PlacementProblem
local ModeHint = selection_box.ModeHint

local player = Players.LocalPlayer

local function Main()
	-- The tutorial pares the HUD down to what it teaches: no economy readout (nor the wind or scavengers beside it)
	-- until it has had the player build extractors and solar collectors, and its own cards across the top.
	local in_tutorial = use_mission.use_mission() == "tutorial"
	local tutorial_state = use_tutorial.use_tutorial()
	local economy_shown = in_tutorial == false or (tutorial_state.active and tutorial_steps.shown "economy")
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
		ResourceBar = if economy_shown then React.createElement(ResourceBar) else nil,
		-- the tutorial's cards, or the suggestions of another mission that makes them
		Tutorial = if tutorial_state.active then React.createElement(tutorial.Tutorial) else nil,
		SelectionBox = React.createElement(SelectionBox),
		PlacementHint = React.createElement(PlacementHint),
		PlacementProblem = React.createElement(PlacementProblem),
		ModeHint = React.createElement(ModeHint),
		PlayerList = React.createElement(player_list.PlayerList),
		Notifications = React.createElement(notifications.Notifications),
		LobbyPanel = React.createElement(lobby_panel.LobbyPanel),
		PauseOverlay = React.createElement(pause_overlay.PauseOverlay),
		VictoryScreen = React.createElement(victory_screen.VictoryScreen),
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
		-- the crosshair has to be in the very middle of the view, which only a GUI that ignores the inset has
		PilotHud = React.createElement(pilot_hud.PilotHud),
		-- what piloted units say, over them, which everyone sees
		PilotCallouts = React.createElement(pilot_hud.PilotCallouts),
	})
end

-- The pings' names and the arrows to those off screen, in a GUI of their own over the HUD, so that an arrow along
-- the bottom edge is not lost behind the panels there; it ignores the inset for the same reason the bars' does.
local function Pings()
	return React.createElement(React.Fragment, {}, {
		StyleLink = React.createElement("StyleLink", {
			StyleSheet = stylesheets.default_stylesheet,
		}),
		PingMarkers = React.createElement(ping_markers.PingMarkers),
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

	-- tooltips are portalled into this GUI, above everything in it
	ReactRoblox.createRoot(gui):render(React.createElement(tooltip.Layer.Provider, { value = gui }, {
		Main = React.createElement(Main),
	}))

	local overlay = Instance.new "ScreenGui"
	overlay.Name = "World"
	overlay.ResetOnSpawn = false
	overlay.IgnoreGuiInset = true
	overlay.DisplayOrder = -1
	overlay.ZIndexBehavior = Enum.ZIndexBehavior.Sibling
	overlay.Parent = player:WaitForChild "PlayerGui"

	ReactRoblox.createRoot(overlay):render(React.createElement(Overlay))

	local pings = Instance.new "ScreenGui"
	pings.Name = "Pings"
	pings.ResetOnSpawn = false
	pings.IgnoreGuiInset = true
	pings.DisplayOrder = 1
	pings.ZIndexBehavior = Enum.ZIndexBehavior.Sibling
	pings.Parent = player:WaitForChild "PlayerGui"

	ReactRoblox.createRoot(pings):render(React.createElement(Pings))
end

return table.freeze({
	init_ui = init_ui,
})
