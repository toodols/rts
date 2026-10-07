--!strict
-- The tutorial's guide: the player is walked through the basics one step at a time, on a HUD pared down to what they
-- have been shown so far, and it ends in a card of its own.

local ReplicatedStorage = game:GetService "ReplicatedStorage"
local RunService = game:GetService "RunService"

local mission_map = require(ReplicatedStorage.Shared.mission_map)
local types = require(ReplicatedStorage.Shared.types)
local teams = require(ReplicatedStorage.Shared.teams)
local entity_attrs = require(ReplicatedStorage.Shared.entity_attrs)

local camera = require(ReplicatedStorage.Client.camera)
local events = require(ReplicatedStorage.Client.events)
local input_router = require(ReplicatedStorage.Client.input_router)
local selection = require(ReplicatedStorage.Client.selection)
local tutorial_marker = require(ReplicatedStorage.Client.tutorial_marker)
local world = require(ReplicatedStorage.Client.world)

local kit = require(script.Parent.kit)

type EntityId = types.EntityId
type Guide = kit.Guide

-- How close to where the move step asks the commander to be sent (the map's `first_move`) a right click, or the
-- commander, has to be to count.
local MOVE_TOLERANCE = 12
-- W, A, S and D, which the keybinds may or may not pan with (in BAR's they do not).
local WASD: { [Enum.KeyCode]: boolean } = table.freeze({
	[Enum.KeyCode.W] = true,
	[Enum.KeyCode.A] = true,
	[Enum.KeyCode.S] = true,
	[Enum.KeyCode.D] = true,
})
-- How many solar collectors, and how many grunts, their steps ask for.
local SOLARS = 3
local GRUNTS = 5
-- How wide the ring round the pass's boulder is, and the one round your commander on the way to it.
local BOULDER_RING = 26
local COMMANDER_RING = 5

-- Whether none of W, A, S and D pans.
local function wasd_still(): boolean
	for key in WASD do
		if camera.pans(key) then
			return false
		end
	end
	return true
end

local function within_reach(position: Vector3): boolean
	local target = mission_map.here "first_move"
	return Vector2.new(position.X - target.X, position.Z - target.Y).Magnitude <= MOVE_TOLERANCE
end

-- Whether the pass's boulder still stands: the one building on the map that is nobody's.
local function boulder_standing(): boolean
	for _, model in world.all() do
		if entity_attrs.team(model) == teams.NEUTRAL and entity_attrs.kind(model) == "building" then
			return true
		end
	end
	return false
end

-- Whether a metal spot is on your side of the pass.
local function west_of_pass(spot: Vector3): boolean
	return spot.X < mission_map.here("pass").X
end

local GUIDE: Guide = {
	steps = {
		{
			id = "camera",
			title = "Move the camera",
			cards = {
				{
					id = "wasd",
					caption = "WASD does not move the camera",
					mark = "cross",
					picture = { kind = "wasd" },
					shown = wasd_still,
				},
				{
					id = "arrows",
					caption = "Use {key:camera_up} {key:camera_left} {key:camera_down} {key:camera_right}",
					mark = "check",
					picture = { kind = "arrows" },
				},
				{
					id = "middle_drag",
					caption = "Or hold the middle mouse button and drag",
					mark = "check",
					picture = { kind = "middle_mouse" },
				},
			},
			watch = function(complete: (card: string) -> ()): () -> ()
				-- W, A, S and D, those of them that do not pan, only show that they do not here (the card watches them),
				-- rather than starting the commands they are bound to: a layer over the rest takes them
				local unblock = input_router.push({
					began = function(input: InputObject): boolean
						return WASD[input.KeyCode] == true and camera.pans(input.KeyCode) == false
					end,
					ended = function() end,
					exclusive = false,
				})
				local stop = events.panned.subscribe(function(method: events.PanMethod)
					complete(if method == "keys" then "arrows" else "middle_drag")
				end)
				return function()
					stop()
					unblock()
				end
			end,
		},
		{
			id = "select",
			title = "Select your commander",
			cards = {
				{
					id = "box_select",
					caption = "Drag a box over it with the left mouse button",
					mark = "check",
					picture = { kind = "box_select", def_name = "commander" },
				},
				{
					id = "click_select",
					caption = "Or left click it",
					mark = "check",
					picture = { kind = "click", def_name = "commander" },
				},
			},
			watch = function(complete: (card: string) -> ()): () -> ()
				-- it may have been panned out of sight in the step before; brought back into view, not looked over at, so
				-- the view stays there
				local commander = kit.my_commander()
				if commander ~= nil then
					camera.glide_to(world.position_of(commander))
				end
				return events.selected.subscribe(function(method: events.SelectMethod, ids: { EntityId })
					local id = kit.commander_id()
					if id ~= nil and table.find(ids, id) ~= nil and selection.contains(id) then
						complete(if method == "box" then "box_select" else "click_select")
					end
				end)
			end,
		},
		{
			id = "move",
			title = "Move your commander",
			cards = {
				{
					id = "right_click",
					caption = "Right click the marker to send your commander there",
					mark = "check",
					picture = { kind = "move", def_name = "commander" },
				},
			},
			reveals = "economy",
			done_note = "Your metal and energy are now shown at the top of the screen",
			-- Done once the commander stands at the marker, however it got there. Sending it there says it is on its way.
			watch = function(complete: (card: string) -> (), report: (card: string, text: string) -> ()): () -> ()
				local target = mission_map.here "first_move"
				local hide_marker = tutorial_marker.show(target, MOVE_TOLERANCE)
				-- look between the commander and the marker, so both are in view
				local commander = kit.my_commander()
				local target_point = Vector3.new(target.X, 0, target.Y)
				if commander ~= nil then
					kit.look_at((world.position_of(commander) + target_point) / 2)
				else
					kit.look_at(target_point)
				end
				local stop_watching_moves = events.moved.subscribe(function(ids: { EntityId }, positions: { Vector3 })
					local id = kit.commander_id()
					local index = if id ~= nil then table.find(ids, id) else nil
					if index ~= nil and within_reach(positions[index]) then
						report("right_click", "On its way...")
					end
				end)
				local arrival = RunService.Heartbeat:Connect(function()
					local model = kit.my_commander()
					if model ~= nil and within_reach(world.position_of(model)) then
						complete "right_click"
					end
				end)
				return function()
					hide_marker()
					stop_watching_moves()
					arrival:Disconnect()
				end
			end,
		},
		{
			id = "extractors",
			title = "Build metal extractors",
			cards = {
				{
					id = "extractors",
					caption = `Metal Extractors mine metal. With your commander selected, {kit.build_path "metal_extractor"}, then click each marked metal spot`,
					mark = "check",
					picture = { kind = "unit", def_name = "metal_extractor" },
				},
			},
			select = { def_name = "commander" },
			click = { kind = "build", def_name = "metal_extractor", next = "Now click a marked metal spot" },
			watch = kit.watch_extractors(west_of_pass),
		},
		{
			id = "solars",
			title = "Build solar collectors",
			cards = {
				{
					id = "solars",
					caption = `Solar Collectors make energy. With your commander selected, {kit.build_path "solar_collector"}, then place {SOLARS} of them`,
					mark = "check",
					picture = { kind = "unit", def_name = "solar_collector" },
				},
			},
			select = { def_name = "commander" },
			click = { kind = "build", def_name = "solar_collector", next = "Now click on open ground to place it" },
			watch = kit.watch_count("solars", SOLARS, function(): number
				return kit.count_mine "solar_collector"
			end),
		},
		{
			id = "bot_lab",
			title = "Build a Bot Lab",
			cards = {
				{
					id = "bot_lab",
					caption = `A Bot Lab makes your army. With your commander selected, {kit.build_path "bot_lab"}, then place it`,
					mark = "check",
					picture = { kind = "unit", def_name = "bot_lab" },
				},
			},
			select = { def_name = "commander" },
			click = { kind = "build", def_name = "bot_lab", next = "Now click on open ground to place it" },
			watch = kit.watch_count("bot_lab", 1, function(): number
				return kit.count_mine "bot_lab"
			end),
		},
		{
			id = "grunts",
			title = "Make Grunts",
			cards = {
				{
					id = "grunts",
					caption = `Select your Bot Lab and click Grunt in its build menu {GRUNTS} times`,
					mark = "check",
					picture = { kind = "unit", def_name = "grunt" },
				},
			},
			select = { def_name = "bot_lab" },
			click = { kind = "build", def_name = "grunt" },
			reveals = "weapons",
			done_note = "Select a unit to see its weapons in the panel at the bottom left",
			watch = kit.watch_count("grunts", GRUNTS, function(): number
				return kit.count_mine "grunt"
			end),
		},
		{
			id = "dgun",
			title = "Clear the pass",
			select = { def_name = "commander" },
			click = { kind = "command", mode = "disintegrator", next = "Now click the boulder" },
			cards = {
				{
					id = "dgun",
					caption = "Move your commander towards the boulder, then press {key:mode_manual} to use your Disintegrator Gun on the boulder.",
					mark = "check",
					picture = { kind = "unit", def_name = "commander" },
				},
			},
			-- Done once the boulder is gone, however that came about. Your commander is marked too, so it can be found.
			watch = kit.watch_all({
				function(): () -> ()
					local commander = kit.my_commander()
					if commander == nil then
						return function() end
					end
					return tutorial_marker.follow(commander, COMMANDER_RING)
				end,
				kit.with_marker(
					function(): Vector2
						return mission_map.here "pass"
					end,
					BOULDER_RING,
					function(complete: (card: string) -> ()): () -> ()
						return kit.every_check(function()
							if boulder_standing() == false then
								complete "dgun"
							end
						end)
					end
				),
			}),
		},
		{
			id = "destroy",
			title = "Destroy the enemy",
			cards = {
				{
					id = "destroy",
					caption = "Take your Grunts and commander through the pass and destroy everything the enemy has",
					mark = "check",
					picture = { kind = "unit", def_name = "grunt" },
				},
			},
			watch = kit.watch_destroy(),
		},
	},
	objective = nil,
	finish = { title = "Nice work!", status = "That's all for now. More coming soon." },
	is_over = nil,
	-- the pictures it teaches with, which are few and small
	preload = {
		"tutorial_wasd",
		"tutorial_arrows",
		"tutorial_mouse",
		"tutorial_cursor",
		"tutorial_check",
		"tutorial_cross",
	},
}

return table.freeze(GUIDE)
