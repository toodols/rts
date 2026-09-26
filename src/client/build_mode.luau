-- The ghost of the building being placed (command_state's "placing"): the cursor carries it, a box of the space it
-- will take with its model inside, coloured by whether it fits where it is, until it is placed or put down.
--
-- Where it goes and whether it fits there are judged by the same rules the server's `placement` judges by
-- (shared/placement_rules), from the models the client can see (client/occupants.luau).

local ReplicatedStorage = game:GetService "ReplicatedStorage"

local signal = require(ReplicatedStorage.Shared.signal)
local types = require(ReplicatedStorage.Shared.types)
local unit_defs = require(ReplicatedStorage.Shared.unit_defs)
local heightmap = require(ReplicatedStorage.Shared.heightmap)
local geometry = require(ReplicatedStorage.Shared.geometry)
local placement_rules = require(ReplicatedStorage.Shared.placement_rules)

local occupants = require(ReplicatedStorage.Client.occupants)
local markers = require(ReplicatedStorage.Client.markers)
local command_state = require(ReplicatedStorage.Client.command_state)
local world_fx = require(ReplicatedStorage.Client.world_fx)

local palette = require(ReplicatedStorage.ClientShared.palette)

type EntityId = types.EntityId

local VALID_COLOR = palette.gain
local INVALID_COLOR = palette.danger

-- the building the ghost is of, while there is one
local ghost_def: string? = nil
-- Kept between placements: the next building picked up faces the way the last one was turned.
local facing = 0
local ghost: Part? = nil
-- The building's own model, see-through, drawn in the box: what it will look like, where the box is
-- what it will occupy. There is none for a building that has no model yet.
local ghost_model: Model? = nil
local ghost_model_valid: boolean? = nil
-- Why the ghost cannot be built where it is, or nil while it can, for the note under the cursor.
local problem: string? = nil
local problem_changed = signal.new() :: signal.Signal<string?>
-- Boxes drawn at the other places a dragged line or grid would put a building.
local preview_parts: { Part } = {}
-- Most buildings a single drag may lay out.
local MAX_LAYOUT = 100

local function set_problem(next_problem: string?)
	if next_problem == problem then
		return
	end
	problem = next_problem
	problem_changed.fire(problem)
end

local function get_problem(): string?
	return problem
end

-- What the note under the cursor says of each thing wrong with a place.
local PROBLEM_TEXT: { [placement_rules.Problem]: string } = table.freeze({
	outside_map = "Outside the map",
	off_grid = "Off the building grid",
	needs_metal_spot = "Requires a metal spot",
	needs_geo_vent = "Requires a geothermal vent",
	too_steep = "Requires flat terrain",
	needs_water = "Can only be built on water",
	needs_deeper_water = "Requires deeper water",
	no_water = "Cannot be built on water",
	too_deep = "Water is too deep",
	blocked = "Something is in the way",
})

-- What is wrong with the place, as the note under the cursor puts it, or nil when the building fits there.
local function placement_problem(def_name: string, position: Vector3, yaw: number): string?
	local problem_here = placement_rules.problem(occupants.ALL, def_name, position, yaw, nil)
	return if problem_here ~= nil then PROBLEM_TEXT[problem_here] else nil
end

local function can_place(def_name: string, position: Vector3, yaw: number): boolean
	return placement_rules.problem(occupants.ALL, def_name, position, yaw, nil) == nil
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

local function show_ghost(def_name: string)
	local def = unit_defs.get(def_name)
	destroy_ghost()
	ghost_def = def_name

	local collider = def.collider
	local part = world_fx.part "PlacementGhost"
	part.Transparency = 0.5
	part.Material = Enum.Material.ForceField
	if collider.shape == "box" then
		part.Size = Vector3.new(collider.width, collider.height, collider.length)
	else
		part.Size = Vector3.new(collider.radius * 2, collider.height, collider.radius * 2)
	end
	part.Parent = world_fx.folder()
	ghost = part

	-- with the model showing what it looks like, the box is only there to show the space it takes
	local model = world_fx.ghost_model(def_name, VALID_COLOR, unit_defs.collider_height(def))
	if model ~= nil then
		model.Parent = world_fx.folder()
		ghost_model = model
		part.Transparency = 0.8
	end
end

local function hide_ghost()
	if ghost_def == nil then
		return
	end
	ghost_def = nil
	destroy_ghost()
	markers.hide_lock()
	set_problem(nil)
end

-- The ghost follows what is being placed.
local function on_placing(def_name: string?)
	if def_name == nil then
		hide_ghost()
	else
		show_ghost(def_name)
	end
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
-- corners. Both are axis aligned, and the first place is always `from`. Something bound to a metal spot or a
-- geothermal vent is never laid out: it only takes the one place.
local function layout(def_name: string, from: Vector3, to: Vector3, as_grid: boolean): { Vector3 }
	local def = unit_defs.get(def_name)
	if def.spot ~= nil then
		return { from }
	end

	local half = placement_rules.footprint(def, facing)
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
	for row = 0, more_z do
		for column = 0, more_x do
			if #centers >= MAX_LAYOUT then
				return centers
			end
			local x = from.X + column * step_x * sign_x
			local z = from.Z + row * step_z * sign_z
			table.insert(centers, placement_rules.ground_center(def, x, z))
		end
	end
	return centers
end

-- Shows boxes at every place of a layout but the last, which the ghost itself covers, each coloured
-- by whether a building fits there.
local function show_layout(centers: { Vector3 })
	local part = ghost
	local def_name = ghost_def
	if part == nil or def_name == nil then
		return
	end
	local extra = math.max(0, #centers - 1)
	while #preview_parts > extra do
		(table.remove(preview_parts) :: Part):Destroy()
	end
	while #preview_parts < extra do
		local box = world_fx.part "PlacementLayout"
		box.Transparency = 0.5
		box.Material = Enum.Material.ForceField
		box.Size = part.Size
		box.Parent = world_fx.folder()
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
-- the client would send, or nil when there is nothing to place. `builder_id` is the unit that would be
-- sent to build it: only its own queued mexes are treated as taking their spot, not other builders'.
local function update(point: Vector3?, builder_id: EntityId?): (Vector3?, boolean)
	local def_name = ghost_def
	local part = ghost
	if def_name == nil or part == nil or point == nil then
		markers.hide_lock()
		set_problem(nil)
		return nil, false
	end

	local def = unit_defs.get(def_name)
	-- it goes where it will on the server: a spot-bound building onto the nearest free spot of its kind, and anything
	-- else onto the building grid
	local resolved =
		placement_rules.resolve_center(occupants.ALL, def, point.X, point.Z, facing, occupants.queued_spots(builder_id))
	if resolved ~= nil and def.spot ~= nil then
		-- show which spot the cursor has locked onto, since it may be some way off
		markers.show_lock(
			heightmap.ground_position(point.X, point.Z),
			heightmap.ground_position(resolved.X, resolved.Z)
		)
	else
		markers.hide_lock()
	end
	-- with no spot free near enough it is shown on the grid under the cursor, as somewhere it cannot go
	local center = if resolved ~= nil then resolved else placement_rules.grid_center(def, point.X, point.Z, facing)
	local reason = placement_problem(def_name, center, facing)
	local valid = reason == nil
	set_problem(reason)

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

local function init()
	command_state.subscribe_placing(on_placing)
end

return table.freeze({
	init = init,
	rotate = rotate,
	get_facing = get_facing,
	update = update,
	layout = layout,
	show_layout = show_layout,
	clear_preview = clear_preview,
	can_place = can_place,
	subscribe_problem = problem_changed.subscribe,
	get_problem = get_problem,
})
