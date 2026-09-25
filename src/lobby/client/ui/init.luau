-- The lobby's whole screen: a header with the tabs, then the tab open: Play, the browser while this player is in no
-- lobby (or the campaign screen, which the browser opens) and the lobby itself while they are in one; Skins, where they
-- pick what their units wear (skins_tab.luau); the Encyclopedia, an entry for every unit and building (encyclopedia.luau),
-- which the campaign's missions link into; and Microtransactions (microtransactions_tab.luau). And a line along
-- the bottom for anything that went wrong. All of it over the scene (see LobbyClient.scene), which the backdrop only darkens toward the edges, so the
-- menus sit in a world rather than on a blank page.

local Players = game:GetService "Players"
local ReplicatedStorage = game:GetService "ReplicatedStorage"
local Workspace = game:GetService "Workspace"

local React = require(ReplicatedStorage.Packages.react)
local ReactRoblox = require(ReplicatedStorage.Packages["react-roblox"])

local game_modes = require(ReplicatedStorage.Shared.game_modes)

local use_lobby = require(ReplicatedStorage.LobbyClient.use_lobby)
local stylesheets = require(ReplicatedStorage.LobbyClient.stylesheets)
local scene = require(ReplicatedStorage.LobbyClient.scene)
local browser = require(script.browser)
local room = require(script.room)
local campaign = require(script.campaign)
local controls = require(script.controls)
local skins_tab = require(script.skins_tab)
local encyclopedia = require(script.encyclopedia)
local microtransactions_tab = require(script.microtransactions_tab)

local player = Players.LocalPlayer

-- how long a notice stays up
local NOTICE_SECONDS = 4

-- The shell's size as the stylesheet has it (`.shell`), and how much of the screen it is scaled up to fill. The lobby is
-- the whole screen, unlike the HUD's panels, so it fills it: scaled only by height against 1080, as the HUD is, it
-- left a third of the screen empty at 1080p and its text too small to read.
local SHELL_SIZE = Vector2.new(1240, 720)
local SCREEN_FILL = 0.94
local MIN_SCALE = 0.6

local function fit_scale(viewport: Vector2): number
	if viewport.X <= 0 or viewport.Y <= 0 then
		return 1
	end
	local fill = viewport * SCREEN_FILL
	return math.max(MIN_SCALE, math.min(fill.X / SHELL_SIZE.X, fill.Y / SHELL_SIZE.Y))
end

-- The scale that fits the shell to the screen, following the screen as it changes size.
local function use_fit_scale(): number
	local scale, set_scale = React.useState(1)
	React.useEffect(function()
		local camera = Workspace.CurrentCamera
		if camera == nil then
			return
		end
		local connection = camera:GetPropertyChangedSignal("ViewportSize"):Connect(function()
			set_scale(fit_scale(camera.ViewportSize))
		end)
		set_scale(fit_scale(camera.ViewportSize))
		return function()
			connection:Disconnect()
		end
	end, {})
	return scale
end

type Tab = "play" | "skins" | "encyclopedia" | "microtransactions"

-- The tabs along the header, in order, and what each is labelled.
local TABS: { { id: Tab, label: string } } = {
	{ id = "play", label = "PLAY" },
	{ id = "skins", label = "SKINS" },
	{ id = "encyclopedia", label = "ENCYCLOPEDIA" },
	{ id = "microtransactions", label = "MICROTRANSACTIONS" },
}

local function App()
	local state, received = use_lobby.use_state()
	local notice, set_notice = React.useState(nil :: string?)
	-- out of a lobby, whether the campaign screen is open rather than the browser
	local in_campaign, set_in_campaign = React.useState(false)
	local tab: Tab, set_tab = React.useState("play" :: Tab)
	-- the encyclopedia entry another screen last asked to open
	local focus: encyclopedia.Focus?, set_focus = React.useState(nil :: encyclopedia.Focus?)
	local ui_scale = use_fit_scale()

	local function show(message: string)
		set_notice(message)
		task.delay(NOTICE_SECONDS, function()
			set_notice(function(current: string?): string?
				return if current == message then nil else current
			end)
		end)
	end

	React.useEffect(function()
		if state.notice ~= nil then
			show(state.notice)
		end
	end, { state })

	local function open_entry(name: string)
		set_focus({ name = name, nonce = os.clock() })
		set_tab "encyclopedia"
	end

	local function act(action: string, argument: any?)
		task.spawn(function()
			local ok, message = use_lobby.request(action, argument)
			if ok == false then
				show(message or "That didn't work")
			end
		end)
	end

	local current = state.current
	local playing = tab == "play"
	local campaign_open = playing and current == nil and in_campaign
	-- the campaign screen and the other tabs are as wide as a lobby, so the scene is shaded the same way behind them
	local wide = current ~= nil or campaign_open or playing == false
	React.useEffect(function()
		scene.set_view(if wide then "room" else "browser")
	end, { wide })

	local title = "LOBBY"
	local subtitle = ""
	if current ~= nil then
		local mode = game_modes.get(current.mode)
		local label = if mode == nil
			then current.mode
			elseif mode.kind == "campaign" then `Co-op: {mode.label}`
			else mode.label
		subtitle = `Lobby {current.id} · {label}`
	elseif campaign_open then
		title = "CAMPAIGN"
	end
	if tab == "skins" then
		title = "SKINS"
	elseif tab == "encyclopedia" then
		title = "ENCYCLOPEDIA"
	elseif tab == "microtransactions" then
		title = "MICROTRANSACTIONS"
	end

	local screen
	if tab == "skins" then
		screen = React.createElement(skins_tab.SkinsTab, { act = act })
	elseif tab == "encyclopedia" then
		screen = React.createElement(encyclopedia.Encyclopedia, { focus = focus })
	elseif tab == "microtransactions" then
		screen = React.createElement(microtransactions_tab.MicrotransactionsTab)
	elseif current ~= nil then
		screen = React.createElement(room.Room, { lobby = current, act = act })
	elseif campaign_open then
		screen = React.createElement(campaign.Campaign, {
			mission = state.mission,
			on_back = function()
				set_in_campaign(false)
			end,
			open_entry = open_entry,
		})
	else
		screen = React.createElement(browser.Browser, {
			lobbies = state.lobbies,
			received = received,
			act = act,
			open_campaign = function()
				set_in_campaign(true)
			end,
		})
	end

	local tab_buttons: { [string]: any } = {}
	for index, entry in TABS do
		tab_buttons[entry.id] = React.createElement(controls.Button, {
			kind = "chip",
			tag = if entry.id == tab then "tab active" else "tab",
			label = entry.label,
			on_press = function()
				set_tab(entry.id)
			end,
			LayoutOrder = index,
		})
	end

	return React.createElement(React.Fragment, {}, {
		StyleLink = React.createElement("StyleLink", {
			StyleSheet = stylesheets.lobby_stylesheet,
		}),
		Backdrop = React.createElement("Frame", {
			[React.Tag] = if wide then "backdrop room-view" else "backdrop",
		}, {
			Vignette = React.createElement("Frame", {
				[React.Tag] = "vignette",
			}),
			Rail = React.createElement("Frame", {
				[React.Tag] = "backdrop-rail",
			}),
		}),
		Shell = React.createElement("Frame", {
			[React.Tag] = if current ~= nil or playing == false then "shell" else "shell browsing",
		}, {
			Scale = React.createElement("UIScale", { Scale = ui_scale }),
			Header = React.createElement("Frame", {
				[React.Tag] = "header",
				LayoutOrder = 1,
			}, {
				Accent = React.createElement("Frame", {
					[React.Tag] = "accent-bar tall",
					LayoutOrder = 1,
				}),
				Titles = React.createElement("Frame", {
					[React.Tag] = "header-titles grow",
					LayoutOrder = 2,
				}, {
					Title = React.createElement("TextLabel", {
						[React.Tag] = "header-title",
						LayoutOrder = 1,
						Text = title,
					}),
					Subtitle = React.createElement("TextLabel", {
						[React.Tag] = "header-subtitle",
						LayoutOrder = 2,
						Text = subtitle,
						Visible = subtitle ~= "",
					}),
				}),
				Tabs = React.createElement("Frame", {
					[React.Tag] = "tabs",
					LayoutOrder = 3,
				}, tab_buttons),
			}),
			Body = React.createElement("Frame", {
				[React.Tag] = "body",
				LayoutOrder = 2,
			}, {
				Screen = screen,
			}),
		}),
		Notice = if notice ~= nil
			then React.createElement("TextLabel", {
				[React.Tag] = "notice",
				Text = notice,
			})
			else nil,
	})
end

local function init_ui()
	local gui = Instance.new "ScreenGui"
	gui.Name = "Lobby"
	gui.ResetOnSpawn = false
	gui.IgnoreGuiInset = true
	gui.ZIndexBehavior = Enum.ZIndexBehavior.Sibling
	gui.Parent = player:WaitForChild "PlayerGui"

	ReactRoblox.createRoot(gui):render(React.createElement(App))
end

return table.freeze({
	init_ui = init_ui,
})
