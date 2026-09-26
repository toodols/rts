--!strict
-- Putting down the building being placed (command_state's "placing"): where it goes under the cursor, the line or grid
-- a shift-drag lays out, and the builders sent to put it up at each place of it that fits.

local ReplicatedStorage = game:GetService "ReplicatedStorage"

local types = require(ReplicatedStorage.Shared.types)

local campaign_standing = require(ReplicatedStorage.ClientShared.campaign_standing)

local cursor = require(ReplicatedStorage.Client.cursor)
local modifiers = require(ReplicatedStorage.Client.modifiers)
local build_mode = require(ReplicatedStorage.Client.build_mode)
local orders = require(ReplicatedStorage.Client.orders)
local selected = require(ReplicatedStorage.Client.selected)

type EntityId = types.EntityId

-- Where `def_name` would go under the cursor, as its ghost shows it, and whether it fits there. The ghost is moved
-- there too. Its spot-snapping treats as taken only what the builder the server would use has queued already. It goes
-- nowhere while the cursor is over one of the HUD's panels, so that a spot in the world behind it neither moves the
-- ghost nor puts up a problem over the panel.
local function under_cursor(def_name: string): (Vector3?, boolean)
	local point = if cursor.over_panel() then nil else cursor.ground_point()
	return build_mode.update(point, selected.builders_of(def_name)[1])
end

-- The places a shift-drag from `from` has laid out so far, a line or with alt a grid, to where the cursor is.
local function layout(def_name: string, from: Vector3): { Vector3 }
	local center = under_cursor(def_name)
	if center == nil then
		return { from }
	end
	return build_mode.layout(def_name, from, center, modifiers.alt_held())
end

-- Sends every selected builder of `def_name` to put it up at each of `centers` that fits.
local function send(def_name: string, centers: { Vector3 })
	-- the server refuses what is locked anyway; this keeps a stale placement from even asking
	if campaign_standing.is_unlocked(def_name) == false then
		return
	end
	local facing = build_mode.get_facing()
	local fitting: { Vector3 } = {}
	for _, center in centers do
		if build_mode.can_place(def_name, center, facing) then
			table.insert(fitting, center)
		end
	end
	orders.place(def_name, selected.builders_of(def_name), fitting, facing, orders.from_keys())
end

-- A click while placing: the building goes where the cursor is, if it fits. Says whether it did.
local function place_one(def_name: string): boolean
	local center, valid = under_cursor(def_name)
	if center == nil or valid == false then
		return false
	end
	send(def_name, { center })
	return true
end

-- A shift-drag let go: everything that fits along the line, or across the grid, is ordered at once.
local function place_layout(def_name: string, from: Vector3)
	send(def_name, layout(def_name, from))
	build_mode.clear_preview()
end

-- Every frame while placing: the ghost follows the cursor, or the drag's line or grid is shown. Returns where the
-- building would go, the last place of a line or grid, for its range rings.
local function preview(def_name: string, from: Vector3?): Vector3?
	local at = under_cursor(def_name)
	if from == nil or at == nil then
		return at
	end
	local centers = layout(def_name, from)
	build_mode.show_layout(centers)
	-- only the last place of a line or grid shows its ranges, or the rings would bury the ground
	return centers[#centers]
end

return table.freeze({
	under_cursor = under_cursor,
	place_one = place_one,
	place_layout = place_layout,
	preview = preview,
})
