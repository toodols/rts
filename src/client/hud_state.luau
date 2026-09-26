--!strict
-- What of the HUD the player has opened with a key: the player list (ui/player_list.luau), which T opens and closes and
-- Escape closes (command_input.luau).

local ReplicatedStorage = game:GetService "ReplicatedStorage"

local signal = require(ReplicatedStorage.Shared.signal)

local player_list_open = false
local player_list_changed = signal.new() :: signal.Signal<boolean>

local function is_player_list_open(): boolean
	return player_list_open
end

local function set_player_list_open(open: boolean)
	if player_list_open == open then
		return
	end
	player_list_open = open
	player_list_changed.fire(open)
end

local function toggle_player_list()
	set_player_list_open(player_list_open == false)
end

local function close_player_list()
	set_player_list_open(false)
end

return table.freeze({
	is_player_list_open = is_player_list_open,
	toggle_player_list = toggle_player_list,
	close_player_list = close_player_list,
	subscribe_player_list = player_list_changed.subscribe,
})
