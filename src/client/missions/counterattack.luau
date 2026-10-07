--!strict
-- The counterattack's guide: select a resurrector (the graverobbers the player starts with), then raise the old base's
-- guns below the cliff with an area resurrect. Once every step is done, or the first wave arrives, what is left is the
-- objective.

local ReplicatedStorage = game:GetService "ReplicatedStorage"

local mission_state = require(ReplicatedStorage.Shared.mission_state)
local mission_map = require(ReplicatedStorage.Shared.mission_map)
local unit_defs = require(ReplicatedStorage.Shared.unit_defs)
local types = require(ReplicatedStorage.Shared.types)
local entity_attrs = require(ReplicatedStorage.Shared.entity_attrs)

local command_state = require(ReplicatedStorage.Client.command_state)
local selection = require(ReplicatedStorage.Client.selection)
local tutorial_marker = require(ReplicatedStorage.Client.tutorial_marker)
local world = require(ReplicatedStorage.Client.world)

local kit = require(script.Parent.kit)

type EntityDef = types.EntityDef
type Guide = kit.Guide

-- How wide the ring on each of the old guns' wrecks is, and on each resurrector, and how far a resurrector moves before
-- its marker follows it.
local WRECK_RING = 4
local RESURRECTOR_RING = 3
local RESURRECTOR_FOLLOW = 1.5

-- What raises wrecks: a unit whose buildpower resurrects.
local function resurrects(def: EntityDef): boolean
	return unit_defs.does(def, "resurrect")
end

-- The old base's guns: its buildings that fight.
local function is_gun(def: EntityDef): boolean
	return def.kind == "building" and def.weapons ~= nil and #def.weapons > 0
end

local function below_cliff(model: Model): boolean
	local at = world.position_of(model)
	return mission_map.above_brink(at.X, at.Z) == false
end

-- The old guns' wrecks lying below the cliff, by model.
local function gun_wrecks(): { Model }
	local wrecks: { Model } = {}
	for _, model in world.all() do
		local def = world.def_of(model)
		if entity_attrs.kind(model) == "wreck" and def ~= nil and is_gun(def) and below_cliff(model) then
			table.insert(wrecks, model)
		end
	end
	return wrecks
end

-- How many finished guns of yours stand below the cliff, where the old base's wrecks lie: those raised.
local function guns_raised(): number
	local raised = 0
	for _, model in kit.mine(is_gun, false) do
		if below_cliff(model) then
			raised += 1
		end
	end
	return raised
end

local GUIDE: Guide = {
	steps = {
		{
			id = "select_graverobber",
			title = "Select a Graverobber",
			cards = {
				{
					id = "click_graverobber",
					caption = "Left click a marked Graverobber",
					mark = "check",
					picture = { kind = "click", def_name = "graverobber" },
				},
			},
			-- Done once one of yours is selected, or once there were some and none are left. Each is marked, following it
			-- if it moves. The mission starts before the player's base (and its resurrectors) goes down, so the camera
			-- looks over at them when they first appear.
			watch = function(complete: (card: string) -> ()): () -> ()
				local markers: { [Model]: { hide: () -> (), at: Vector2 } } = {}
				local seen = false
				local stop = kit.every_check(function()
					local present: { [Model]: boolean } = {}
					local robbers = kit.mine(resurrects, true)
					if seen == false and #robbers > 0 then
						seen = true
						kit.glide_below_guide(world.position_of(robbers[1]))
					end
					for _, model in robbers do
						present[model] = true
						local position = world.position_of(model)
						local at = Vector2.new(position.X, position.Z)
						local marker: { hide: () -> (), at: Vector2 }? = markers[model]
						if marker ~= nil and (marker.at - at).Magnitude > RESURRECTOR_FOLLOW then
							marker.hide()
							marker = nil
						end
						if marker == nil then
							markers[model] = { hide = tutorial_marker.show(at, RESURRECTOR_RING), at = at }
						end
						local id = world.id_of(model)
						if id ~= nil and selection.contains(id) then
							complete "click_graverobber"
						end
					end
					for model, marker in markers do
						if present[model] ~= true then
							marker.hide()
							markers[model] = nil
						end
					end
					if seen and #robbers == 0 then
						complete "click_graverobber"
					end
				end)
				return function()
					stop()
					for _, marker in markers do
						marker.hide()
					end
				end
			end,
		},
		{
			id = "raise",
			title = "Resurrect the destroyed base's wrecks",
			cards = {
				{
					id = "resurrect_mode",
					caption = "Press {key:mode_resurrect} or click Resurrect",
					mark = "check",
					picture = { kind = "resurrect_mode" },
				},
				{
					id = "resurrect_area",
					caption = "Drag a circle over the marked wrecks",
					mark = "check",
					picture = { kind = "area_resurrect", def_name = "guard" },
				},
			},
			every_card = true,
			select = { def_name = "graverobber", until_card = "resurrect_mode" },
			click = { kind = "command", mode = "resurrect", next = "Now drag a circle over the wrecks" },
			-- Done once resurrect mode has been on and every gun that can be raised is yours and alive: no gun's wreck
			-- is left below the cliff. One reclaimed away can no longer be raised, and one of yours that dies lies there
			-- to be raised again. Each gun's wreck is marked while it lies there.
			watch = function(complete: (card: string) -> (), report: (card: string, text: string) -> ()): () -> ()
				local hide_markers: { [Model]: () -> () } = {}
				local wrecks = gun_wrecks()
				if #wrecks > 0 then
					local middle = Vector3.zero
					for _, wreck in wrecks do
						middle += world.position_of(wreck) / #wrecks
					end
					kit.glide_below_guide(middle)
				end
				local stop_mode = command_state.subscribe_mode(function(mode: string?)
					if mode == "resurrect" then
						complete "resurrect_mode"
					end
				end)
				local stop = kit.every_check(function()
					local lying: { [Model]: boolean } = {}
					local lying_count = 0
					for _, wreck in gun_wrecks() do
						lying[wreck] = true
						lying_count += 1
						if hide_markers[wreck] == nil then
							local at = world.position_of(wreck)
							hide_markers[wreck] = tutorial_marker.show(Vector2.new(at.X, at.Z), WRECK_RING)
						end
					end
					for wreck, hide in hide_markers do
						if lying[wreck] ~= true then
							hide()
							hide_markers[wreck] = nil
						end
					end
					local raised = guns_raised()
					local raisable = raised + lying_count
					-- nothing to count until the old base has come in
					if raisable == 0 then
						return
					end
					report("resurrect_area", `{raised}/{raisable}`)
					if lying_count == 0 then
						-- raised some other way: resurrect mode is nothing more to learn
						complete "resurrect_mode"
						complete "resurrect_area"
					end
				end)
				return function()
					stop()
					stop_mode()
					for _, hide in hide_markers do
						hide()
					end
				end
			end,
		},
	},
	objective = { title = "Survive", lines = { "Don't let your commander die" } },
	finish = nil,
	-- the guide stops when the first wave arrives
	is_over = function(): boolean
		local waves = mission_state.waves()
		return waves ~= nil and waves.wave > 0
	end,
	preload = nil,
}

return table.freeze(GUIDE)
