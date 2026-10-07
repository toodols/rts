--!strict
-- The queues of the selected units (yours, or anyone's for a spectator), drawn every frame: for each, a line from where
-- it stands through each order still in its queue, as the server published it (shared/order_path), a dot on each
-- waypoint (or a glow under what it guards), the see-through building each build order will put up, and the circle of
-- each area order. Where each order is drawn is its kind's (`order_kinds` `drawn_at`). Also where a unit is expected to
-- end up once its queue is done (`expected_end`), which what is aimed from the end of a queue starts from.

local ReplicatedStorage = game:GetService "ReplicatedStorage"
local RunService = game:GetService "RunService"

local types = require(ReplicatedStorage.Shared.types)
local unit_defs = require(ReplicatedStorage.Shared.unit_defs)
local surface = require(ReplicatedStorage.Shared.surface)
local heightmap = require(ReplicatedStorage.Shared.heightmap)
local order_kinds = require(ReplicatedStorage.Shared.order_kinds)
local entity_attrs = require(ReplicatedStorage.Shared.entity_attrs)
local order_path = require(ReplicatedStorage.Shared.order_path)

local art_models = require(ReplicatedStorage.ClientShared.art_models)

local world = require(ReplicatedStorage.Client.world)
local selection = require(ReplicatedStorage.Client.selection)
local world_fx = require(ReplicatedStorage.Client.world_fx)
local order_colors = require(ReplicatedStorage.Client.order_colors)
local markers = require(ReplicatedStorage.Client.markers)
local frame_profile = require(ReplicatedStorage.Client.frame_profile)

type EntityDef = types.EntityDef
type Step = order_path.Step

-- Ghost models by def, reused from frame to frame like every pooled part, and how many are out this frame.
type GhostSet = {
	models: { Model },
	used: number,
}

-- A ceiling on dashes, so a huge selection with long queues cannot bog the frame down.
local MAX_PATH_SEGMENTS = 900
-- The glow under something a selected unit is guarding, its own team's or an ally's.
local HALO_HEIGHT = 0.15
local HALO_MARGIN = 1.5
local HALO_TRANSPARENCY = 0.65
local HALO_LIFT = 0.3
local GHOST_TRANSPARENCY = 0.6

local function make_halo(): Part
	local halo = world_fx.part "GuardHalo"
	halo.Shape = Enum.PartType.Cylinder
	halo.Transparency = HALO_TRANSPARENCY
	return halo
end

local function make_ghost(): Part
	local ghost = world_fx.part "BuildGhost"
	ghost.Material = Enum.Material.ForceField
	ghost.Transparency = GHOST_TRANSPARENCY
	return ghost
end

local halo_pool = world_fx.pool(make_halo)
local waypoint_pool = world_fx.pool(markers.make_dot)
local segment_pool = world_fx.pool(markers.make_dash)
local ghost_pool = world_fx.pool(make_ghost)
local area_pool = world_fx.pool(markers.make_dash)
local ghost_sets: { [string]: GhostSet } = {}
-- the defs there is no art for, which are drawn as a box instead
local without_art: { [string]: boolean } = {}

-- Where `point` is drawn for something of `def` that travels through it: on the water's surface if it rides it,
-- and where the ground is otherwise.
local function travelled(def: EntityDef?, point: Vector3): Vector3
	return world_fx.at(world_fx.footing_of(def), point.X, point.Z)
end

-- What `step` is aimed at, if it is aimed at something that is there.
local function target_of(step: Step): Model?
	return if step.target_id ~= nil then world.get(step.target_id) else nil
end

-- Where `step` of the queue of something of `def` is drawn, as its kind says (`order_kinds.DrawnAt`), and what it is
-- following, for one that follows what it is aimed at.
local function drawn_at(def: EntityDef?, step: Step): (Vector3, Model?)
	local point = heightmap.ground_position(step.x, step.z)
	local how = order_kinds.get(step.kind).drawn_at
	if how == "travelled" then
		return travelled(def, point), nil
	elseif how == "built" then
		local built = if step.def_name ~= nil then unit_defs.defs[step.def_name] else nil
		return if built ~= nil then surface.position(built, point.X, point.Z) else point, nil
	end
	local target = target_of(step)
	if target == nil then
		return point, nil
	elseif how == "target" then
		-- a wreck's height is whatever it actually is: a sea wreck floats, and the seabed is nowhere near it
		return world.position_of(target), nil
	elseif how == "follows_target" then
		-- what is followed moves, so it is drawn where it is rather than where the server last published
		local at = world.position_of(target)
		return travelled(def, heightmap.ground_position(at.X, at.Z)), target
	end
	return point, nil
end

-- A glow on the ground under an entity, sized to its collider.
local function draw_halo(model: Model, point: Vector3, color: Color3)
	local def = world.def_of(model)
	local radius = if def ~= nil then unit_defs.collider_radius(def) else 2
	local diameter = (radius + HALO_MARGIN) * 2
	local halo = world_fx.acquire(halo_pool)
	halo.Size = Vector3.new(HALO_HEIGHT, diameter, diameter)
	halo.CFrame = world_fx.lying_flat(point + Vector3.new(0, HALO_LIFT, 0))
	halo.Color = color
end

-- What a queued build order will put down: the building's own model, see-through, standing where it will and turned
-- the way it will be. A def with no model yet is a see-through box the size of its collider.
local function draw_ghost(def_name: string, point: Vector3, facing: number?, color: Color3)
	local def = unit_defs.defs[def_name]
	if def == nil then
		return
	end
	local height = unit_defs.collider_height(def)
	local frame = CFrame.new(point + Vector3.new(0, height / 2, 0))
		* CFrame.Angles(0, if facing ~= nil then facing else 0, 0)

	if without_art[def_name] ~= true then
		local set = ghost_sets[def_name]
		if set == nil then
			set = { models = {}, used = 0 }
			ghost_sets[def_name] = set
		end
		set.used += 1
		local model: Model? = set.models[set.used]
		if model == nil then
			model = world_fx.ghost_model(def_name, color, height)
			if model == nil then
				set.used -= 1
				-- art still being built is asked for again next frame, and drawn as a box until then
				if art_models.status(def_name) ~= "building" then
					without_art[def_name] = true
				end
			else
				table.insert(set.models, model)
			end
		end
		if model ~= nil then
			if model.Parent == nil then
				model.Parent = world_fx.folder()
			end
			model:PivotTo(frame)
			return
		end
	end

	local collider = def.collider
	if collider.shape ~= "box" then
		return
	end
	local ghost = world_fx.acquire(ghost_pool)
	ghost.Size = Vector3.new(collider.width, collider.height, collider.length)
	ghost.CFrame = frame
	ghost.Color = color
end

-- Parks the ghost models that were not drawn this frame.
local function release_ghost_models()
	for _, set in ghost_sets do
		for index = set.used + 1, #set.models do
			local model = set.models[index]
			if model.Parent ~= nil then
				model.Parent = nil
			end
		end
		set.used = 0
	end
end

-- Where `model` is expected to be once it has carried out every order in its queue: it walks each leg from where the
-- one before left it, stopping as far short of each waypoint as that order lets it, following anything it follows to
-- where that is now. Where it stands now if it has nothing queued.
local function expected_end(model: Model): Vector3
	local position = world.position_of(model)
	local cursor = heightmap.ground_position(position.X, position.Z)
	local def = world.def_of(model)
	local text = entity_attrs.text(model, "path")
	if def == nil or def.max_speed == nil or text == nil or text == "" then
		return cursor
	end
	for _, step in order_path.decode(text) do
		local point = heightmap.ground_position(step.x, step.z)
		local followed = if order_kinds.get(step.kind).drawn_at == "follows_target" then target_of(step) else nil
		if followed ~= nil then
			local at = world.position_of(followed)
			point = heightmap.ground_position(at.X, at.Z)
		end
		local offset = Vector3.new(point.X - cursor.X, 0, point.Z - cursor.Z)
		local short = order_kinds.reach(def, step.kind, step.launch)
		if offset.Magnitude > short then
			local stop = cursor + offset.Unit * (offset.Magnitude - short)
			cursor = heightmap.ground_position(stop.X, stop.Z)
		end
	end
	return cursor
end

local function update()
	for _, id in selection.get() do
		local model = world.get(id)
		if model == nil or world.is_selectable(model) == false then
			continue
		end
		local text = entity_attrs.text(model, "path")
		if text == nil or text == "" then
			continue
		end

		local def = world.def_of(model)
		local position = world.position_of(model)
		local cursor = travelled(def, heightmap.ground_position(position.X, position.Z))
		for _, step in order_path.decode(text) do
			local color = order_colors.of(step.kind)
			local point, followed = drawn_at(def, step)
			if followed ~= nil then
				draw_halo(followed, point, color)
			else
				markers.place_dot(waypoint_pool, point, color)
			end
			if order_kinds.get(step.kind).drawn_at == "built" and step.def_name ~= nil then
				draw_ghost(step.def_name, point, step.facing, color)
			end
			local radius = step.radius
			if radius ~= nil and radius > 0 then
				markers.draw_circle(area_pool, point, radius, color)
			end
			markers.draw_leg(segment_pool, cursor, point, color, def, MAX_PATH_SEGMENTS)
			cursor = point
		end
	end
	world_fx.release_rest(segment_pool)
	world_fx.release_rest(waypoint_pool)
	world_fx.release_rest(halo_pool)
	world_fx.release_rest(ghost_pool)
	world_fx.release_rest(area_pool)
	release_ghost_models()
end

local function init()
	RunService.RenderStepped:Connect(frame_profile.wrap("queue_paths", update))
end

return table.freeze({
	init = init,
	expected_end = expected_end,
})
