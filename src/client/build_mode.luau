-- Placement mode: after picking a building from a constructor's menu the cursor carries a ghost
-- of that building until it is placed or cancelled.
--
-- The validity check here is a client-side preview only. The server re-runs the real check in
-- `placement` before it creates anything, so a disagreement costs a rejected order, not an exploit.

local ReplicatedStorage = game:GetService "ReplicatedStorage"
local Workspace = game:GetService "Workspace"

local types = require(ReplicatedStorage.Shared.types)
local config = require(ReplicatedStorage.Shared.config)
local unit_defs = require(ReplicatedStorage.Shared.unit_defs)
local heightmap = require(ReplicatedStorage.Shared.heightmap)
local metal_spots = require(ReplicatedStorage.Shared.metal_spots)
local geometry = require(ReplicatedStorage.Shared.geometry)

local world = require(ReplicatedStorage.Client.world)
local markers = require(ReplicatedStorage.Client.markers)

type EntityId = types.EntityId

local VALID_COLOR = Color3.fromRGB(120, 220, 140)
local INVALID_COLOR = Color3.fromRGB(226, 96, 84)

local current_def: string? = nil
local facing = 0
local ghost: Part? = nil
-- The building's own model, see-through, drawn in the box: what it will look like, where the box is
-- what it will occupy. There is none for a building that has no model yet.
local ghost_model: Model? = nil
local ghost_model_valid: boolean? = nil
local listeners: { (def_name: string?) -> () } = {}
-- Boxes drawn at the other places a dragged line or grid would put a building.
local preview_parts: { Part } = {}
-- Most buildings a single drag may lay out.
local MAX_LAYOUT = 100

local function notify()
	for _, listener in listeners do
		listener(current_def)
	end
end

local function subscribe(listener: (def_name: string?) -> ()): () -> ()
	table.insert(listeners, listener)
	return function()
		local index = table.find(listeners, listener)
		if index ~= nil then
			table.remove(listeners, index)
		end
	end
end

-- Where spot-bound buildings stand or are queued to be built, from what the client can see: the
-- buildings themselves, and the build orders every unit publishes in its `path`.
local TAKEN_RADIUS = 1.5

-- Whether `model` is the finished T1 mex that `placing_def_name` (a T2 mex) is upgrading in place:
-- it does not count as taking its spot, mirroring the server's placement.is_upgrade_target.
local function is_upgrade_target(placing_def_name: string, model: Model): boolean
	return placing_def_name == "advanced_metal_extractor" and model:GetAttribute "def_name" == "metal_extractor"
end

local function taken_positions(placing_def_name: string): { Vector2 }
	local taken = {}
	for _, model in world.all() do
		if model:GetAttribute "kind" == "building" and is_upgrade_target(placing_def_name, model) == false then
			local def_name = model:GetAttribute "def_name"
			local def = if typeof(def_name) == "string" then unit_defs.defs[def_name] else nil
			if def ~= nil and def.requires_metal_spot == true then
				local position = world.position_of(model)
				table.insert(taken, Vector2.new(position.X, position.Z))
			end
		end

		local path = model:GetAttribute "path"
		if typeof(path) == "string" and path ~= "" then
			for _, step in string.split(path, ";") do
				local fields = string.split(step, ",")
				local queued = if fields[1] == "build" and fields[4] ~= nil then unit_defs.defs[fields[4]] else nil
				local x = tonumber(fields[2])
				local z = tonumber(fields[3])
				if queued ~= nil and queued.requires_metal_spot == true and x ~= nil and z ~= nil then
					table.insert(taken, Vector2.new(x, z))
				end
			end
		end
	end
	return taken
end

-- Mirrors placement.can_place using only what the client can see.
local function can_place(def_name: string, position: Vector3, yaw: number): boolean
	local def = unit_defs.get(def_name)
	local half = geometry.rotated_half_extents(unit_defs.footprint_half_extents(def), yaw)

	if heightmap.in_bounds(position.X - half.X, position.Z - half.Y) == false then
		return false
	end
	if heightmap.in_bounds(position.X + half.X, position.Z + half.Y) == false then
		return false
	end

	if def.kind == "building" then
		local grid_x, grid_z = geometry.snap_center(position.X, position.Z, half, config.CELL_STUDS)
		if math.abs(grid_x - position.X) > 0.01 or math.abs(grid_z - position.Z) > 0.01 then
			return false
		end
	end

	if def.requires_metal_spot == true and metal_spots.nearest(position.X, position.Z, 0.5) == nil then
		return false
	end

	local lowest, highest = heightmap.height_range(position.X, position.Z, half.X, half.Y)
	if highest - lowest > config.MAX_BUILD_SLOPE_STUDS then
		return false
	end
	if
		unit_defs.tolerates_water(
			def,
			math.max(0, config.WATER_LEVEL - highest),
			math.max(0, config.WATER_LEVEL - lowest)
		) == false
	then
		return false
	end

	for _, model in world.all() do
		local other_def_name = model:GetAttribute "def_name"
		if typeof(other_def_name) ~= "string" then
			continue
		end
		local other_def = unit_defs.defs[other_def_name]
		if other_def == nil then
			continue
		end
		-- wrecks, and your own units that can move, are cleared off by the builder when it gets there
		local other_kind = model:GetAttribute "kind"
		if
			other_kind == "wreck"
			or (other_kind == "unit" and model:GetAttribute "state" == "active" and other_def.max_speed ~= nil and world.is_mine(
				model
			))
			or is_upgrade_target(def_name, model)
		then
			continue
		end
		local other_yaw = select(2, model:GetPivot():ToOrientation())
		local other_half = geometry.rotated_half_extents(unit_defs.footprint_half_extents(other_def), other_yaw)
		if geometry.aabb_overlap(position, half, world.position_of(model), other_half, 0) then
			return false
		end
	end

	return true
end

local function clear_preview()
	for _, part in preview_parts do
		part:Destroy()
	end
	table.clear(preview_parts)
end

local function destroy_ghost()
	clear_preview()
	if ghost_model ~= nil then
		ghost_model:Destroy()
		ghost_model = nil
		ghost_model_valid = nil
	end
	if ghost ~= nil then
		ghost:Destroy()
		ghost = nil
	end
end

local function enter(def_name: string)
	local def = unit_defs.defs[def_name]
	if def == nil or def.kind ~= "building" then
		return
	end
	destroy_ghost()
	current_def = def_name
	facing = 0

	local collider = def.collider
	local part = Instance.new "Part"
	part.Name = "PlacementGhost"
	part.Anchored = true
	part.CanCollide = false
	part.CanQuery = false
	part.CanTouch = false
	part.Transparency = 0.5
	part.Material = Enum.Material.ForceField
	if collider.shape == "box" then
		part.Size = Vector3.new(collider.width, collider.height, collider.length)
	else
		part.Size = Vector3.new(collider.radius * 2, collider.height, collider.radius * 2)
	end
	part.Parent = Workspace:FindFirstChild "Effects" or Workspace
	ghost = part

	-- with the model showing what it looks like, the box is only there to show the space it takes
	local model = markers.make_ghost_model(def_name, VALID_COLOR, unit_defs.collider_height(def))
	if model ~= nil then
		model.Parent = Workspace:FindFirstChild "Effects" or Workspace
		ghost_model = model
		part.Transparency = 0.8
	end

	notify()
end

local function exit()
	if current_def == nil then
		return
	end
	current_def = nil
	destroy_ghost()
	markers.hide_lock()
	notify()
end

local function active(): string?
	return current_def
end

-- Turns the ghost a quarter turn: +1 is counterclockwise seen from above, -1 clockwise.
local function rotate(direction: number)
	facing = geometry.snap_facing(facing + direction * math.pi / 2)
end

local function get_facing(): number
	return facing
end

-- Where a drag from `from` to `to` puts buildings, edge to edge on the building grid: a line along
-- whichever axis the drag runs further, or with `as_grid` a rectangle with the two as opposite
-- corners. Both are axis aligned, and the first place is always `from`. Something bound to a metal spot
-- is never laid out: it only takes the one place.
local function layout(def_name: string, from: Vector3, to: Vector3, as_grid: boolean): { Vector3 }
	local def = unit_defs.get(def_name)
	if def.requires_metal_spot == true then
		return { from }
	end

	local half = geometry.rotated_half_extents(unit_defs.footprint_half_extents(def), facing)
	local step_x = half.X * 2
	local step_z = half.Y * 2
	local dx = to.X - from.X
	local dz = to.Z - from.Z
	local sign_x = if dx < 0 then -1 else 1
	local sign_z = if dz < 0 then -1 else 1
	local more_x = math.floor(math.abs(dx) / step_x + 0.5)
	local more_z = math.floor(math.abs(dz) / step_z + 0.5)
	if as_grid == false then
		if math.abs(dx) >= math.abs(dz) then
			more_z = 0
		else
			more_x = 0
		end
	end

	local centers: { Vector3 } = {}
	local half_height = unit_defs.collider_height(def) / 2
	for row = 0, more_z do
		for column = 0, more_x do
			if #centers >= MAX_LAYOUT then
				return centers
			end
			local x = from.X + column * step_x * sign_x
			local z = from.Z + row * step_z * sign_z
			table.insert(centers, Vector3.new(x, unit_defs.surface_height(def, x, z) + half_height, z))
		end
	end
	return centers
end

-- Shows boxes at every place of a layout but the last, which the ghost itself covers, each coloured
-- by whether a building fits there.
local function show_layout(centers: { Vector3 })
	local part = ghost
	local def_name = current_def
	if part == nil or def_name == nil then
		return
	end
	local extra = math.max(0, #centers - 1)
	while #preview_parts > extra do
		(table.remove(preview_parts) :: Part):Destroy()
	end
	while #preview_parts < extra do
		local box = Instance.new "Part"
		box.Name = "PlacementLayout"
		box.Anchored = true
		box.CanCollide = false
		box.CanQuery = false
		box.CanTouch = false
		box.Transparency = 0.5
		box.Material = Enum.Material.ForceField
		box.Size = part.Size
		box.Parent = Workspace:FindFirstChild "Effects" or Workspace
		table.insert(preview_parts, box)
	end
	for index = 1, extra do
		local center = centers[index]
		local box = preview_parts[index]
		box.CFrame = CFrame.new(center) * CFrame.Angles(0, facing, 0)
		box.Color = if can_place(def_name, center, facing) then VALID_COLOR else INVALID_COLOR
	end
end

-- Moves the ghost onto the ground under `point` and recolours it by validity. Returns the placement
-- the client would send, or nil when there is nothing to place.
local function update(point: Vector3?): (Vector3?, boolean)
	local def_name = current_def
	local part = ghost
	if def_name == nil or part == nil or point == nil then
		markers.hide_lock()
		return nil, false
	end

	local def = unit_defs.get(def_name)
	-- a spot-bound building snaps onto the nearest metal spot, as it will on the server
	local x = point.X
	local z = point.Z
	local locked: Vector3? = nil
	if def.requires_metal_spot == true then
		local taken = taken_positions(def_name)
		locked = metal_spots.nearest(x, z, config.METAL_SPOT_SNAP, function(spot: Vector3): boolean
			for _, at in taken do
				if (at - Vector2.new(spot.X, spot.Z)).Magnitude < TAKEN_RADIUS then
					return true
				end
			end
			return false
		end)
	end
	if locked ~= nil then
		-- show which spot the cursor has locked onto, since it may be some way off
		markers.show_lock(heightmap.ground_position(x, z), locked)
		x = locked.X
		z = locked.Z
	else
		markers.hide_lock()
		-- everything else snaps onto the building grid, as it will on the server
		local half = geometry.rotated_half_extents(unit_defs.footprint_half_extents(def), facing)
		x, z = geometry.snap_center(x, z, half, config.CELL_STUDS)
	end
	local center = Vector3.new(x, unit_defs.surface_height(def, x, z) + unit_defs.collider_height(def) / 2, z)
	local valid = can_place(def_name, center, facing)

	part.CFrame = CFrame.new(center) * CFrame.Angles(0, facing, 0)
	part.Color = if valid then VALID_COLOR else INVALID_COLOR

	local model = ghost_model
	if model ~= nil then
		model:PivotTo(part.CFrame)
		-- recoloured only when validity changes, since it is every part of the model
		if ghost_model_valid ~= valid then
			ghost_model_valid = valid
			for _, descendant in model:GetDescendants() do
				if descendant:IsA "BasePart" then
					descendant.Color = if valid then VALID_COLOR else INVALID_COLOR
				end
			end
		end
	end

	return center, valid
end

return table.freeze({
	enter = enter,
	exit = exit,
	active = active,
	rotate = rotate,
	get_facing = get_facing,
	update = update,
	layout = layout,
	show_layout = show_layout,
	clear_preview = clear_preview,
	can_place = can_place,
	subscribe = subscribe,
})
