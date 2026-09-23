-- The lobby's whole screen: a header, then the browser while this player is in no lobby and the lobby itself while
-- they are in one, and a line along the bottom for anything that went wrong.

local Players = game:GetService "Players"
local ReplicatedStorage = game:GetService "ReplicatedStorage"

local React = require(ReplicatedStorage.Packages.react)
local ReactRoblox = require(ReplicatedStorage.Packages["react-roblox"])

local game_modes = require(ReplicatedStorage.Shared.game_modes)

local use_viewport = require(ReplicatedStorage.Client.ui.use_viewport)

local use_lobby = require(ReplicatedStorage.LobbyClient.use_lobby)
local stylesheets = require(ReplicatedStorage.LobbyClient.stylesheets)
local browser = require(script.browser)
local room = require(script.room)

local player = Players.LocalPlayer

-- how long a notice stays up
local NOTICE_SECONDS = 4

local function App()
	local state, received = use_lobby.use_state()
	local notice, set_notice = React.useState(nil :: string?)
	local ui_scale = use_viewport.use_ui_scale()

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

	local function act(action: string, argument: any?)
		task.spawn(function()
			local ok, message = use_lobby.request(action, argument)
			if ok == false then
				show(message or "That didn't work")
			end
		end)
	end

	local current = state.current
	local subtitle = "Find a game, or make one"
	if current ~= nil then
		local mode = game_modes.get(current.mode)
		subtitle = `Lobby {current.id} · {if mode ~= nil then mode.label else current.mode}`
	end

	return React.createElement(React.Fragment, {}, {
		StyleLink = React.createElement("StyleLink", {
			StyleSheet = stylesheets.lobby_stylesheet,
		}),
		Backdrop = React.createElement("Frame", {
			[React.Tag] = "backdrop",
		}, {
			Rail = React.createElement("Frame", {
				[React.Tag] = "backdrop-rail",
			}),
		}),
		Shell = React.createElement("Frame", {
			[React.Tag] = "shell",
		}, {
			Scale = React.createElement("UIScale", { Scale = ui_scale }),
			Header = React.createElement("Frame", {
				[React.Tag] = "header panel",
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
						Text = "LOBBY",
					}),
					Subtitle = React.createElement("TextLabel", {
						[React.Tag] = "header-subtitle",
						LayoutOrder = 2,
						Text = subtitle,
					}),
				}),
				Player = React.createElement("TextLabel", {
					[React.Tag] = "header-player readout",
					LayoutOrder = 3,
					Text = player.DisplayName,
				}),
			}),
			Body = React.createElement("Frame", {
				[React.Tag] = "body",
				LayoutOrder = 2,
			}, {
				Screen = if current ~= nil
					then React.createElement(room.Room, { lobby = current, act = act })
					else React.createElement(browser.Browser, {
						lobbies = state.lobbies,
						received = received,
						act = act,
					}),
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
