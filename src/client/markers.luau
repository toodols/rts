-- Order feedback drawn in the world:
--
--   preview dots   where a move order will put each unit, while the right button is held
--   paths          for every selected unit, a line through each order still in its queue with a
--                  dot on every waypoint, for as long as the unit stays selected
--   work beams     a beam from any unit or factory to the blueprint it is building or the thing it
--                  is reclaiming, visible to everyone
--
-- All of it is rewritten every frame - the preview follows the cursor, paths start at a moving
-- unit and beams follow their builders - so parts come from pools rather than being created and
-- destroyed at that rate. A part that falls out of use is parked by unparenting it.

local ReplicatedStorage = game:GetService "ReplicatedStorage"
local RunService = game:GetService "RunService"
local Workspace = game:GetService "Workspace"

local types = require(ReplicatedStorage.Shared.types)
local config = require(ReplicatedStorage.Shared.config)
local unit_defs = require(ReplicatedStorage.Shared.unit_defs)
local model_fit = require(ReplicatedStorage.Shared.model_fit)
local heightmap = require(ReplicatedStorage.Shared.heightmap)
local projectile = require(ReplicatedStorage.Shared.projectile)

local world = require(ReplicatedStorage.Client.world)
local selection = require(ReplicatedStorage.Client.selection)
local art = require(ReplicatedStorage.Client.art)

type Pool = {
	parts: { Part },
	used: number,
}

type Waypoint = {
	kind: string,
	point: Vector3,
	target_id: number?,
	-- what a build order will build, and how it will be turned
	def_name: string?,
	facing: number?,
}

local PREVIEW_COLOR = Color3.fromRGB(126, 240, 154)

-- What each kind of order looks like on a path, matching the HUD palette.
local KIND_COLORS: { [string]: Color3 } = {
	move = Color3.fromRGB(126, 240, 154),
	attack = Color3.fromRGB(238, 88, 74),
	attack_ground = Color3.fromRGB(238, 88, 74),
	fight = Color3.fromRGB(255, 138, 64),
	dgun = Color3.fromRGB(255, 60, 60),
	reclaim = Color3.fromRGB(236, 184, 68),
	assist = Color3.fromRGB(96, 210, 242),
	guard = Color3.fromRGB(190, 150, 255),
	build = Color3.fromRGB(96, 210, 242),
	repair = Color3.fromRGB(255, 230, 64),
	resurrect = Color3.fromRGB(176, 96, 240),
	load = Color3.fromRGB(96, 210, 242),
	unload = Color3.fromRGB(236, 184, 68),
}
local BUILD_BEAM_COLOR = Color3.fromRGB(96, 210, 242)
local RECLAIM_BEAM_COLOR = Color3.fromRGB(236, 184, 68)

local DOT_SIZE = Vector3.new(0.2, 2, 2)
local DOT_LIFT = 0.3
local DOT_TRANSPARENCY = 0.4

-- Paths are laid along the ground in short dashes, one per PATH_STEP studs of a leg, so they climb
-- hills rather than cutting through them.
local PATH_STEP = config.CELL_STUDS
local PATH_LIFT = 0.45
local PATH_THICKNESS = 0.35
local PATH_TRANSPARENCY = 0.3
-- A ceiling on dashes, so a huge selection with long queues cannot bog the frame down.
local MAX_PATH_SEGMENTS = 900

local BEAM_THICKNESS = 0.35
local BEAM_BASE_TRANSPARENCY = 0.3
local BEAM_PULSE = 0.2
local BEAM_PULSE_RATE = 14

-- The glow under something a selected unit is guarding.
local HALO_HEIGHT = 0.15
local HALO_MARGIN = 1.5
local HALO_TRANSPARENCY = 0.65

local halo_pool: Pool = { parts = {}, used = 0 }
local preview_pool: Pool = { parts = {}, used = 0 }
local waypoint_pool: Pool = { parts = {}, used = 0 }
local segment_pool: Pool = { parts = {}, used = 0 }
-- The line from the cursor to the metal spot an extractor is locking onto.
local lock_pool: Pool = { parts = {}, used = 0 }
local LOCK_COLOR = Color3.fromRGB(196, 206, 220)
local beam_pool: Pool = { parts = {}, used = 0 }

-- Bumped by every change to the preview, so a delayed clear can tell whether it is still the one
-- that owns the dots.
local preview_generation = 0
local parsed_paths: { [string]: { Waypoint } } = {}
local parsed_count = 0

local function effects_folder(): Instance
	local folder = Workspace:FindFirstChild "Effects"
	if folder ~= nil then
		return folder
	end
	return Workspace
end

local function make_dot(): Part
	local dot = Instance.new "Part"
	dot.Name = "OrderDot"
	dot.Anchored = true
	dot.CanCollide = false
	dot.CanQuery = false
	dot.CanTouch = false
	dot.CastShadow = false
	dot.Shape = Enum.PartType.Cylinder
	dot.Size = DOT_SIZE
	dot.Material = Enum.Material.Neon
	dot.Transparency = DOT_TRANSPARENCY
	return dot
end

local function make_bar(name: string): Part
	local bar = Instance.new "Part"
	bar.Name = name
	bar.Anchored = true
	bar.CanCollide = false
	bar.CanQuery = false
	bar.CanTouch = false
	bar.CastShadow = false
	bar.Material = Enum.Material.Neon
	return bar
end

local function make_halo(): Part
	local halo = make_bar "GuardHalo"
	halo.Shape = Enum.PartType.Cylinder
	halo.Transparency = HALO_TRANSPARENCY
	return halo
end

local ghost_pool: Pool = { parts = {}, used = 0 }
local GHOST_TRANSPARENCY = 0.6

local function make_ghost(): Part
	local ghost = make_bar "BuildGhost"
	ghost.Material = Enum.Material.ForceField
	ghost.Transparency = GHOST_TRANSPARENCY
	return ghost
end

local function make_segment(): Part
	local segment = make_bar "PathSegment"
	segment.Transparency = PATH_TRANSPARENCY
	return segment
end

local function make_beam(): Part
	return make_bar "WorkBeam"
end

local function acquire(pool: Pool, make: () -> Part): Part
	pool.used += 1
	local part = pool.parts[pool.used]
	if part == nil then
		part = make()
		pool.parts[pool.used] = part
	end
	if part.Parent == nil then
		part.Parent = effects_folder()
	end
	return part
end

-- Parks everything that was not acquired since the last call and starts the next frame over.
local function release_rest(pool: Pool)
	for index = pool.used + 1, #pool.parts do
		local part = pool.parts[index]
		if part.Parent ~= nil then
			part.Parent = nil
		end
	end
	pool.used = 0
end

-- A Cylinder part's flat faces point along X, so it is rolled to lie flat on the ground.
local function place_dot(dot: Part, point: Vector3, color: Color3)
	dot.CFrame = CFrame.new(point + Vector3.new(0, DOT_LIFT, 0)) * CFrame.Angles(0, 0, math.pi / 2)
	dot.Color = color
end

-- The colour an order of `kind` is drawn in, on paths and while it is being laid out.
local function color_of(kind: string?): Color3
	local color = if kind ~= nil then KIND_COLORS[kind] else nil
	return if color ~= nil then color else PREVIEW_COLOR
end

-- Draws one preview dot per point, on the ground, in the colour of the order of `kind` they are for, replacing
-- whatever was shown before.
local function show_points(points: { Vector3 }, kind: string?)
	preview_generation += 1
	preview_pool.used = 0
	local color = color_of(kind)
	for _, point in points do
		place_dot(acquire(preview_pool, make_dot), point, color)
	end
	release_rest(preview_pool)
end

local function clear_points()
	preview_generation += 1
	release_rest(preview_pool)
end

-- The outline on whatever the cursor is over. One highlight is kept and moved from thing to thing.
local hover_highlight: Highlight? = nil

local function show_hover(model: Model?, color: Color3)
	local highlight = hover_highlight
	if highlight == nil then
		if model == nil then
			return
		end
		highlight = Instance.new "Highlight"
		highlight.Name = "HoverHighlight"
		highlight.FillTransparency = 0.85
		highlight.OutlineTransparency = 0
		highlight.DepthMode = Enum.HighlightDepthMode.AlwaysOnTop
		highlight.Parent = effects_folder()
		hover_highlight = highlight
	end
	highlight.FillColor = color
	highlight.OutlineColor = color
	if highlight.Adornee ~= model then
		highlight.Adornee = model
	end
end

-- Where a manual shot would sweep, as a red rectangle from `from` to `to` that wide.
local blast_preview: Part? = nil

local function show_blast(from: Vector3, to: Vector3, half_width: number)
	local part = blast_preview
	if part == nil then
		part = make_bar "BlastPreview"
		part.Color = Color3.fromRGB(238, 60, 48)
		part.Transparency = 0.55
		blast_preview = part
	end
	local length = (to - from).Magnitude
	if length < 1e-3 then
		return
	end
	local lift = Vector3.new(0, DOT_LIFT, 0)
	part.Size = Vector3.new(half_width * 2, HALO_HEIGHT, length)
	part.CFrame = CFrame.lookAt((from + to) / 2 + lift, to + lift)
	if part.Parent == nil then
		part.Parent = effects_folder()
	end
end

local function hide_blast()
	if blast_preview ~= nil and blast_preview.Parent ~= nil then
		blast_preview.Parent = nil
	end
end

-- Shows the points and takes them away again, unless a newer drag or order has claimed the dots in
-- the meantime.
local function flash_points(points: { Vector3 }, seconds: number, kind: string?)
	show_points(points, kind)
	local generation = preview_generation
	task.delay(seconds, function()
		if preview_generation == generation then
			clear_points()
		end
	end)
end

-- "kind,x,z,target;..." as published by the server, with each point dropped onto the ground.
local function parse_path(text: string): { Waypoint }
	local cached = parsed_paths[text]
	if cached ~= nil then
		return cached
	end

	local waypoints: { Waypoint } = {}
	for _, step in string.split(text, ";") do
		local fields = string.split(step, ",")
		local x = tonumber(fields[2])
		local z = tonumber(fields[3])
		if fields[1] ~= nil and x ~= nil and z ~= nil then
			local is_build = fields[1] == "build"
			table.insert(waypoints, {
				kind = fields[1],
				point = heightmap.ground_position(x, z),
				target_id = if is_build then nil else tonumber(fields[4]),
				def_name = if is_build then fields[4] else nil,
				facing = tonumber(fields[5]),
			})
		end
	end

	-- paths are few and repeat every frame, but a long session should not collect them forever
	if parsed_count >= 256 then
		table.clear(parsed_paths)
		parsed_count = 0
	end
	parsed_paths[text] = waypoints
	parsed_count += 1
	return waypoints
end

local function draw_dash(pool: Pool, from: Vector3, to: Vector3, color: Color3)
	local lift = Vector3.new(0, PATH_LIFT, 0)
	local start = from + lift
	local finish = to + lift
	local length = (finish - start).Magnitude
	if length < 1e-3 then
		return
	end
	local dash = acquire(pool, make_segment)
	dash.Size = Vector3.new(PATH_THICKNESS, PATH_THICKNESS, length)
	dash.CFrame = CFrame.lookAt((start + finish) / 2, finish)
	dash.Color = color
end

-- A line from `from` to `to` that follows the ground between them, laid as short joined pieces so
-- it is one unbroken stroke however long the leg is. For something that floats it runs along the water's
-- surface instead, and only comes down to `to` at the very end.
local function draw_leg(pool: Pool, from: Vector3, to: Vector3, color: Color3, traveller: types.EntityDef?)
	local on_water = traveller ~= nil and unit_defs.floats(traveller)
	local run = Vector2.new(to.X - from.X, to.Z - from.Z).Magnitude
	local steps = math.max(1, math.floor(run / PATH_STEP))
	local previous = from
	for step = 1, steps do
		if pool.used >= MAX_PATH_SEGMENTS then
			return
		end
		local t = step / steps
		local x = from.X + (to.X - from.X) * t
		local z = from.Z + (to.Z - from.Z) * t
		local point = if step == steps
			then to
			elseif on_water and traveller ~= nil then unit_defs.surface_position(traveller, x, z)
			else heightmap.ground_position(x, z)
		draw_dash(pool, previous, point, color)
		previous = point
	end
end

-- The shape a drag has traced so far, laid on the ground in the colour of the order of `kind` it will give.
local trace_pool: Pool = { parts = {}, used = 0 }

local function show_trace(path: { Vector3 }, kind: string?)
	trace_pool.used = 0
	local color = color_of(kind)
	for index = 2, #path do
		draw_leg(trace_pool, path[index - 1], path[index], color)
	end
	release_rest(trace_pool)
end

local function hide_trace()
	trace_pool.used = 0
	release_rest(trace_pool)
end

-- A glow on the ground under an entity, sized to its collider.
local function draw_halo(model: Model, point: Vector3, color: Color3)
	local radius = 2
	local def_name = model:GetAttribute "def_name"
	if typeof(def_name) == "string" and unit_defs.defs[def_name] ~= nil then
		radius = unit_defs.collider_radius(unit_defs.defs[def_name])
	end
	local diameter = (radius + HALO_MARGIN) * 2
	local halo = acquire(halo_pool, make_halo)
	halo.Size = Vector3.new(HALO_HEIGHT, diameter, diameter)
	halo.CFrame = CFrame.new(point + Vector3.new(0, DOT_LIFT, 0)) * CFrame.Angles(0, 0, math.pi / 2)
	halo.Color = color
end

-- Range rings around whatever the cursor is over: how far it can build, and how far it can shoot.
local RING_SEGMENTS = 48
local BUILD_RING_COLOR = Color3.fromRGB(96, 210, 242)
local ATTACK_RING_COLOR = Color3.fromRGB(238, 88, 74)
local ring_pool: Pool = { parts = {}, used = 0 }

-- How many times the reach of an arcing weapon is worked out again in each direction, for the ground where the
-- last guess put it. The ground changes slowly enough that it settles in a few.
local REACH_ITERATIONS = 4

-- A ring round `center`, laid on the ground so that it climbs hills, `radius(direction)` out in each direction,
-- into `pool`.
local function draw_ring(pool: Pool, center: Vector3, radius: (Vector3) -> number, color: Color3)
	local previous: Vector3? = nil
	for step = 0, RING_SEGMENTS do
		local angle = step / RING_SEGMENTS * math.pi * 2
		local direction = Vector3.new(math.cos(angle), 0, math.sin(angle))
		local out = radius(direction)
		local point = heightmap.ground_position(center.X + direction.X * out, center.Z + direction.Z * out)
		if previous ~= nil then
			draw_dash(pool, previous, point, color)
		end
		previous = point
	end
end

-- The circle an area command (reclaim, repair, resurrect or attack) is being dragged out to: concentric
-- rings, in the colour of the mode it is for, filling the circle in and, like the range rings, laid on
-- the ground so they climb hills instead of a flat disc that would sink into them or float over dips.
local AREA_RING_COUNT = 8
local area_pool: Pool = { parts = {}, used = 0 }

local function show_area(center: Vector3, radius: number, kind: string?)
	area_pool.used = 0
	local color = color_of(kind)
	for step = 1, AREA_RING_COUNT do
		local out = radius * step / AREA_RING_COUNT
		draw_ring(area_pool, center, function(_: Vector3): number
			return out
		end, color)
	end
	release_rest(area_pool)
end

local function hide_area()
	area_pool.used = 0
	release_rest(area_pool)
end

-- The weapon something of `def` reaches furthest with, which is the one its range ring is drawn for.
local function longest_weapon(def: types.EntityDef): types.Weapon?
	local longest: types.Weapon? = nil
	if def.weapons ~= nil then
		for _, weapon in def.weapons do
			if longest == nil or weapon.range > longest.range then
				longest = weapon
			end
		end
	end
	return longest
end

-- Shows a build range ring and an attack range ring, whichever of them apply, around `center`. The attack ring of
-- something whose longest weapon arcs under gravity is drawn as far as it really reaches, which is further over
-- ground lower than `muzzle`, where its shells come from, and less far over ground higher up, the way the server
-- judges it (`projectile.range_to`). Any other is a circle.
local function show_ranges(
	center: Vector3,
	build_range: number?,
	attack_range: number?,
	def: types.EntityDef?,
	muzzle: Vector3?
)
	ring_pool.used = 0
	if build_range ~= nil then
		draw_ring(ring_pool, center, function(_: Vector3): number
			return build_range
		end, BUILD_RING_COLOR)
	end
	if attack_range ~= nil then
		local weapon = if def ~= nil then longest_weapon(def) else nil
		local params = if weapon ~= nil then weapon.projectile else nil
		if weapon ~= nil and params ~= nil and muzzle ~= nil and weapon.range == attack_range then
			draw_ring(ring_pool, center, function(direction: Vector3): number
				local out = weapon.range
				for _ = 1, REACH_ITERATIONS do
					local ground = heightmap.ground_position(center.X + direction.X * out, center.Z + direction.Z * out)
					out = projectile.range_to(weapon.range, muzzle, ground, params)
				end
				return out
			end, ATTACK_RING_COLOR)
		else
			draw_ring(ring_pool, center, function(_: Vector3): number
				return attack_range
			end, ATTACK_RING_COLOR)
		end
	end
	release_rest(ring_pool)
end

local function hide_ranges()
	ring_pool.used = 0
	release_rest(ring_pool)
end

-- A dashed line from the cursor to the metal spot a placement is locking onto.
local function show_lock(from: Vector3, to: Vector3)
	lock_pool.used = 0
	draw_leg(lock_pool, from, to, LOCK_COLOR)
	release_rest(lock_pool)
end

local function hide_lock()
	lock_pool.used = 0
	release_rest(lock_pool)
end

local GHOST_MODEL_TRANSPARENCY = 0.55

type GhostSet = {
	models: { Model },
	used: number,
}

-- Ghost models by def, reused from frame to frame like every other pooled part here, and the defs there
-- is no art for, which are drawn as a box instead.
local ghost_sets: { [string]: GhostSet } = {}
local without_art: { [string]: boolean } = {}

-- A see-through copy of a def's model, sat on its collider the way the real one will be, or nil if the
-- def has no model.
local function make_ghost_model(def_name: string, color: Color3, collider_height: number): Model?
	local folder = ReplicatedStorage:FindFirstChild "Models"
	local template = if folder ~= nil then folder:FindFirstChild(def_name) else nil
	local model: Model
	if template ~= nil and template:IsA "Model" then
		model = (template :: Model):Clone()
	else
		-- procedural art, if the def has some and it has been built
		local ghost = art.ghost(def_name)
		if ghost == nil then
			return nil
		end
		model = ghost
	end
	for _, descendant in model:GetDescendants() do
		if descendant:IsA "BasePart" then
			descendant.Anchored = true
			descendant.CanCollide = false
			descendant.CanQuery = false
			descendant.CanTouch = false
			descendant.CastShadow = false
			descendant.Material = Enum.Material.ForceField
			descendant.Color = color
			-- parts that were meant to be invisible stay that way
			descendant.Transparency = math.max(descendant.Transparency, GHOST_MODEL_TRANSPARENCY)
		end
	end
	model_fit.align_to_collider_bottom(model, collider_height)
	return model
end

-- What a queued build order will put down: the building's own model, see-through, standing where it
-- will and turned the way it will be. A def with no model yet is a see-through box the size of its
-- collider.
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
		local model = set.models[set.used]
		if model == nil then
			model = make_ghost_model(def_name, color, height)
			if model == nil then
				set.used -= 1
				-- art still being built is asked for again next frame, and drawn as a box until then
				if art.pending(def_name) == false then
					without_art[def_name] = true
				end
			else
				table.insert(set.models, model)
			end
		end
		if model ~= nil then
			if model.Parent == nil then
				model.Parent = effects_folder()
			end
			model:PivotTo(frame)
			return
		end
	end

	if def.collider.shape ~= "box" then
		return
	end
	local collider = def.collider
	local ghost = acquire(ghost_pool, make_ghost)
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

-- Everything still ahead of every selected unit: a line from where it stands through each order in
-- its queue, and a dot on each waypoint.
-- Where `point` is drawn for something of `def` that travels through it: on the water's surface if it floats,
-- and where the ground is otherwise.
local function travelled(def: types.EntityDef?, point: Vector3): Vector3
	if def ~= nil and unit_defs.floats(def) then
		return unit_defs.surface_position(def, point.X, point.Z)
	end
	return point
end

-- Where `model` is expected to be once it has carried out every order in its queue: it walks each leg from
-- where the one before left it, stopping as far short of each waypoint as that order lets it. Where it stands
-- now if it has nothing queued.
local function expected_end(model: Model): Vector3
	local position = world.position_of(model)
	local cursor = heightmap.ground_position(position.X, position.Z)
	local def_name = model:GetAttribute "def_name"
	local def = if typeof(def_name) == "string" then unit_defs.defs[def_name] else nil
	local text = model:GetAttribute "path"
	if def == nil or def.max_speed == nil or typeof(text) ~= "string" or text == "" then
		return cursor
	end
	for _, waypoint in parse_path(text) do
		local point = waypoint.point
		if waypoint.kind == "guard" and waypoint.target_id ~= nil then
			local guarded = world.get(waypoint.target_id)
			if guarded ~= nil then
				local at = world.position_of(guarded)
				point = heightmap.ground_position(at.X, at.Z)
			end
		end
		local offset = Vector3.new(point.X - cursor.X, 0, point.Z - cursor.Z)
		local short = unit_defs.order_reach(def, waypoint.kind)
		if offset.Magnitude > short then
			local stop = cursor + offset.Unit * (offset.Magnitude - short)
			cursor = heightmap.ground_position(stop.X, stop.Z)
		end
	end
	return cursor
end

local function update_paths()
	for _, id in selection.get() do
		local model = world.get(id)
		if model == nil or world.is_mine(model) == false then
			continue
		end
		local text = model:GetAttribute "path"
		if typeof(text) ~= "string" or text == "" then
			continue
		end

		local def_name = model:GetAttribute "def_name"
		local def = if typeof(def_name) == "string" then unit_defs.defs[def_name] else nil
		local position = world.position_of(model)
		local cursor = travelled(def, heightmap.ground_position(position.X, position.Z))
		for _, waypoint in parse_path(text) do
			local color = KIND_COLORS[waypoint.kind]
			if color == nil then
				color = PREVIEW_COLOR
			end
			local point = waypoint.point
			-- a building's spot is where it stands, on the sea floor if it is underwater, and only the places a
			-- ship sails to are on the surface
			if waypoint.kind == "move" or waypoint.kind == "fight" then
				point = travelled(def, point)
			end
			-- what is built rests where its own kind does: on the water if it floats, like a shipyard
			local built = if waypoint.kind == "build" and waypoint.def_name ~= nil
				then unit_defs.defs[waypoint.def_name]
				else nil
			if built ~= nil then
				point = unit_defs.surface_position(built, point.X, point.Z)
			end
			-- a reclaim or resurrect waypoint's height is whatever the wreck's actually is, not the
			-- ground under it: a sea wreck floats, and dropping the dot to the seabed puts it nowhere
			-- near what is being reclaimed
			if (waypoint.kind == "reclaim" or waypoint.kind == "resurrect") and waypoint.target_id ~= nil then
				local target = world.get(waypoint.target_id)
				if target ~= nil then
					point = world.position_of(target)
				end
			end
			local guarded = if waypoint.kind == "guard" and waypoint.target_id ~= nil
				then world.get(waypoint.target_id)
				else nil
			if guarded ~= nil then
				-- what is guarded moves, so the line and the halo follow it rather than the point
				-- the server last published
				local at = world.position_of(guarded)
				point = travelled(def, heightmap.ground_position(at.X, at.Z))
				draw_halo(guarded, point, color)
			else
				place_dot(acquire(waypoint_pool, make_dot), point, color)
			end
			if waypoint.kind == "build" and waypoint.def_name ~= nil then
				draw_ghost(waypoint.def_name, point, waypoint.facing, color)
			end
			draw_leg(segment_pool, cursor, point, color, def)
			cursor = point
		end
	end
	release_rest(segment_pool)
	release_rest(waypoint_pool)
	release_rest(halo_pool)
	release_rest(ghost_pool)
	release_ghost_models()
end

-- A pulsing beam from every builder or reclaimer to what it is working on.
local function update_beams()
	local pulse = BEAM_BASE_TRANSPARENCY + BEAM_PULSE * math.sin(os.clock() * BEAM_PULSE_RATE)
	for _, model in world.all() do
		local target_id = model:GetAttribute "work_target"
		if typeof(target_id) ~= "number" then
			continue
		end
		local target = world.get(target_id)
		if target == nil then
			continue
		end

		-- from the top of the worker, so the beam clears its own body
		local from = world.position_of(model)
		local def_name = model:GetAttribute "def_name"
		if typeof(def_name) == "string" and unit_defs.defs[def_name] ~= nil then
			from += Vector3.new(0, unit_defs.collider_height(unit_defs.defs[def_name]) / 2, 0)
		end
		local to = world.position_of(target)
		local length = (to - from).Magnitude
		if length < 1e-3 then
			continue
		end

		local beam = acquire(beam_pool, make_beam)
		beam.Size = Vector3.new(BEAM_THICKNESS, BEAM_THICKNESS, length)
		beam.CFrame = CFrame.lookAt((from + to) / 2, to)
		local work_kind = model:GetAttribute "work_kind"
		beam.Color = if work_kind == "reclaim"
			then RECLAIM_BEAM_COLOR
			elseif work_kind == "repair" then KIND_COLORS.repair
			elseif work_kind == "resurrect" then KIND_COLORS.resurrect
			else BUILD_BEAM_COLOR
		beam.Transparency = pulse
	end
	release_rest(beam_pool)
end

local function update()
	update_paths()
	update_beams()
end

local function init()
	RunService.RenderStepped:Connect(update)
end

return table.freeze({
	init = init,
	show_points = show_points,
	clear_points = clear_points,
	flash_points = flash_points,
	show_lock = show_lock,
	hide_lock = hide_lock,
	make_ghost_model = make_ghost_model,
	show_hover = show_hover,
	show_ranges = show_ranges,
	hide_ranges = hide_ranges,
	show_blast = show_blast,
	hide_blast = hide_blast,
	show_area = show_area,
	hide_area = hide_area,
	expected_end = expected_end,
	show_trace = show_trace,
	hide_trace = hide_trace,
})
