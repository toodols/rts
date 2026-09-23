-- Dresses entity models in their procedural art, and moves it.
--
-- Where a def has art (ReplicatedStorage.Shared.art), the server's model is only an invisible hitbox: meshes
-- built with EditableMesh do not replicate, so each client builds them for itself. A def's meshes are built once,
-- the first time something of it appears, and every entity of that def gets its own copy of them, parented into
-- its model. The copy is client-only, so it moves with the model wherever interpolation.luau pivots it, and the
-- server never touches it.
--
-- Everything the art shows comes from what the server already replicates, the same attributes the rest of the
-- client reads: `kind`, `state` and `team_color` for how it is painted (the same way the server paints its own
-- models, see Shared.appearance), `aim_<n>` for where each turret points, and `work_target` for what a builder is
-- working on. The sim decides all of it, and a shot waits on its turret in the sim (server/turrets.luau); this
-- only turns the meshes to match, smoothly, between the server's updates.

local AssetService = game:GetService "AssetService"
local ReplicatedStorage = game:GetService "ReplicatedStorage"
local RunService = game:GetService "RunService"

local art = require(ReplicatedStorage.Shared.art)
local appearance = require(ReplicatedStorage.Shared.appearance)
local unit_defs = require(ReplicatedStorage.Shared.unit_defs)
local world = require(ReplicatedStorage.Client.world)

local TAU = 2 * math.pi
-- How much faster than its turret really turns the drawn one may, to catch up with an update it has fallen behind.
local TURRET_CATCH_UP = 1.5
-- How fast a builder's head turns toward its work, in radians a second. It is only drawn, so it is not in a def.
local WORK_TURN_RATE = math.rad(150)
-- The material every mesh that does not glow is drawn in.
local MATERIAL = Enum.Material.SmoothPlastic
-- Roblox's importer turns every mesh uploaded from the pipeline's .glb half a turn about its own vertical axis (it
-- faces glTF's +Z the other way), so each uploaded mesh is turned back by as much where it is placed. A mesh built
-- here from its vertices is already the right way round.
local UPLOADED_TURN = CFrame.Angles(0, math.pi, 0)
-- Walking legs: how far a leg swings either way, and how many studs of ground one step cycle covers, for a leg whose
-- art does not say; how fast a leg straightens once the unit stops, in radians a second; and the least speed, in
-- studs a second, that counts as walking, and the most ground one frame's walk can cover before it is a jump instead.
local DEFAULT_SWING = math.rad(25)
local DEFAULT_STRIDE = 3
local LEG_SETTLE_RATE = math.rad(180)
local WALK_MIN_SPEED = 0.3
local WALK_MAX_STEP = 5
-- A wheel whose art does not give its radius; how long a hatch stays open after its weapon fires, in seconds, and how
-- fast it swings, in radians a second.
local DEFAULT_WHEEL_RADIUS = 0.5
local HATCH_HOLD = 1.5
local HATCH_RATE = math.rad(240)

-- One mesh of a def's art, built once: a MeshPart to copy for each entity, and where it sits in its piece.
type TemplatePart = {
	mesh: MeshPart,
	-- a built mesh, kept alive for as long as any MeshPart shows it; nil for an uploaded one
	editable: EditableMesh?,
	group: string,
	offset: CFrame,
	color: Color3,
	neon: boolean,
	team: boolean,
}

type Template = {
	art: art.Art,
	parts: { TemplatePart },
}

-- One entity's copy of a mesh.
type Piece = {
	part: MeshPart,
	source: TemplatePart,
}

-- One of the rigid pieces of an entity's art, and where it is turned to now.
type Group = {
	def: art.Group,
	pivot: CFrame,
	pieces: { Piece },
	-- radians: a turret's or builder's yaw, or a spinning piece's angle
	angle: number,
	-- the angle its parts were last placed at, so a piece holding still is not rewritten every frame
	placed: number?,
	-- for a turret, the attribute its weapon's aim is replicated in
	aim_attribute: string?,
	-- for a leg, how many strides it has walked
	cycle: number,
	-- for a hatch: the attribute its weapon's shots are counted in, the count it last saw, and until when it stays open
	fired_attribute: string?,
	fired: number?,
	open_until: number,
}

type Dressing = {
	model: Model,
	def_name: string,
	folder: Folder,
	groups: { Group },
	-- half the collider's height: the art's origin is on the ground, the model's pivot is the collider's middle
	half_height: number,
	-- what it was last painted as, and where its origin last was
	paint_key: string?,
	origin: CFrame?,
}

local templates: { [string]: Template } = {}
local building: { [string]: boolean } = {}
local failed: { [string]: boolean } = {}
local dressings: { [Model]: Dressing } = {}

local function vector(values: { number }): Vector3
	return Vector3.new(values[1], values[2], values[3])
end

local function finish_mesh(mesh: MeshPart, part: art.Part): MeshPart
	mesh.Anchored = true
	mesh.CanCollide = false
	mesh.CanTouch = false
	-- picking goes by the hitbox the server put in the model, the size of the collider
	mesh.CanQuery = false
	mesh.Material = if part.neon == true then Enum.Material.Neon else MATERIAL
	mesh.Color = Color3.new(part.color[1], part.color[2], part.color[3])
	mesh.Size = vector(part.size)
	return mesh
end

-- One mesh: its uploaded asset if it has one, and otherwise built from its packed vertices and triangles with
-- EditableMesh (which the experience has to allow). Every vertex of a built one gets a normal of its own, computed
-- from the faces around it: the pipeline has already split its sharp edges, so what shares a vertex is smooth.
-- Either way it is sized to the mesh's own bounds, whatever units it was imported in.
local function build_mesh(part: art.Part): (MeshPart, EditableMesh?)
	if part.mesh ~= nil then
		local mesh = AssetService:CreateMeshPartAsync(
			Content.fromUri(part.mesh),
			{ CollisionFidelity = Enum.CollisionFidelity.Box }
		)
		return finish_mesh(mesh, part), nil
	end
	-- nil, not an error, once this client has used up its EditableMesh memory budget
	local editable = AssetService:CreateEditableMesh()
	if editable == nil then
		error "out of EditableMesh memory; this def's meshes need uploading (tools/model_pipeline/roblox/upload_art.py)"
	end
	local vertices = {}
	local normals = {}
	for x, y, z in string.gmatch(part.vertices :: string, "([^,|]+),([^,|]+),([^,|]+)") do
		table.insert(
			vertices,
			editable:AddVertex(Vector3.new(tonumber(x) :: number, tonumber(y) :: number, tonumber(z) :: number))
		)
		table.insert(normals, editable:AddNormal())
	end
	for a, b, c in string.gmatch(part.triangles :: string, "(%d+),(%d+),(%d+)") do
		local ia, ib, ic = (tonumber(a) :: number) + 1, (tonumber(b) :: number) + 1, (tonumber(c) :: number) + 1
		local face = editable:AddTriangle(vertices[ia], vertices[ib], vertices[ic])
		editable:SetFaceNormals(face, { normals[ia], normals[ib], normals[ic] })
	end
	local mesh = AssetService:CreateMeshPartAsync(
		Content.fromObject(editable),
		{ CollisionFidelity = Enum.CollisionFidelity.Box }
	)
	return finish_mesh(mesh, part), editable
end

-- Builds `def_name`'s meshes, once. It yields, so it runs in a thread of its own, and anything of that def
-- is dressed once it is done. Its meshes are fetched all at once rather than one after another.
local function build_template(def_name: string)
	if building[def_name] == true or templates[def_name] ~= nil or failed[def_name] == true then
		return
	end
	building[def_name] = true
	task.spawn(function()
		local data = art.get(def_name)
		local ok, result = pcall(function(): Template
			local sources = (data :: art.Art).parts
			local parts: { TemplatePart } = table.create(#sources)
			local problem: string? = nil
			local remaining = #sources
			local waiting = coroutine.running()
			for index, part in sources do
				task.spawn(function()
					local built, mesh, editable = pcall(build_mesh, part)
					if built then
						mesh.Name = part.group
						parts[index] = {
							mesh = mesh,
							editable = editable,
							group = part.group,
							offset = if part.mesh ~= nil
								then CFrame.new(vector(part.offset)) * UPLOADED_TURN
								else CFrame.new(vector(part.offset)),
							color = mesh.Color,
							neon = part.neon == true,
							team = part.team == true,
						}
					elseif problem == nil then
						problem = tostring(mesh)
					end
					remaining -= 1
					if remaining == 0 and coroutine.status(waiting) == "suspended" then
						task.spawn(waiting)
					end
				end)
			end
			if remaining > 0 then
				coroutine.yield()
			end
			if problem ~= nil then
				error(problem)
			end
			return { art = data :: art.Art, parts = parts }
		end)
		building[def_name] = nil
		if ok then
			templates[def_name] = result
		else
			-- most likely the experience does not allow EditableMesh (Game Settings > Security), and nothing of
			-- this def will be dressed: it stays an invisible hitbox, so say why once
			failed[def_name] = true
			warn(`could not build the art for {def_name}: {result}`)
		end
	end)
end

-- A copy of a template mesh for one entity. A MeshPart made from an EditableMesh copies like any other.
local function copy_mesh(source: TemplatePart): MeshPart
	return source.mesh:Clone()
end

local function dress(model: Model, def_name: string, template: Template)
	local def = unit_defs.get(def_name)
	local folder = Instance.new "Folder"
	folder.Name = "Art"

	local by_name: { [string]: Group } = {}
	local groups: { Group } = {}
	for name, group_def in template.art.groups do
		local group: Group = {
			def = group_def,
			pivot = CFrame.new(vector(group_def.pivot)),
			pieces = {},
			angle = 0,
			placed = nil,
			aim_attribute = if group_def.weapon ~= nil then `aim_{group_def.weapon}` else nil,
			cycle = 0,
			fired_attribute = if group_def.kind == "hatch" and group_def.weapon ~= nil
				then `fired_{group_def.weapon}`
				else nil,
			fired = nil,
			open_until = 0,
		}
		by_name[name] = group
		table.insert(groups, group)
	end
	for _, source in template.parts do
		local part = copy_mesh(source)
		part.Parent = folder
		table.insert(by_name[source.group].pieces, { part = part, source = source })
	end

	folder.Parent = model
	dressings[model] = {
		model = model,
		def_name = def_name,
		folder = folder,
		groups = groups,
		half_height = unit_defs.collider_height(def) / 2,
		paint_key = nil,
		origin = nil,
	}
end

local function paint(dressing: Dressing)
	local model = dressing.model
	local kind = model:GetAttribute "kind"
	local entity_state = model:GetAttribute "state"
	local team = model:GetAttribute "team_color"
	local team_color = if typeof(team) == "Color3" then team else appearance.team_color(0)
	local key = `{kind}|{entity_state}|{team_color}`
	if dressing.paint_key == key then
		return
	end
	dressing.paint_key = key

	local def_color = unit_defs.get(dressing.def_name).color
	for _, group in dressing.groups do
		for _, piece in group.pieces do
			local part, source = piece.part, piece.source
			if kind == "wreck" then
				part.Color = appearance.WRECK_COLOR
				part.Transparency = appearance.WRECK_TRANSPARENCY
				part.Material = appearance.WRECK_MATERIAL
			elseif entity_state == "blueprint" then
				part.Color = appearance.blueprint_tint(def_color, team_color)
				part.Transparency = appearance.BLUEPRINT_TRANSPARENCY
				part.Material = appearance.BLUEPRINT_MATERIAL
			else
				part.Color = if source.team then appearance.team_tint(def_color, team_color) else source.color
				part.Transparency = 0
				part.Material = if source.neon then Enum.Material.Neon else MATERIAL
			end
		end
	end
end

-- `angle` brought into (-pi, pi].
local function wrap(angle: number): number
	return angle - TAU * math.floor((angle + math.pi) / TAU)
end

-- `current` turned toward `target` by at most `step`.
local function approach(current: number, target: number, step: number): number
	local off = wrap(target - current)
	if math.abs(off) <= step then
		return target
	end
	return wrap(current + if off > 0 then step else -step)
end

-- Where each moving piece of an entity's art should be turned to this frame.
local function animate(dressing: Dressing, origin: CFrame, dt: number)
	local model = dressing.model
	-- how far it has walked since the last frame, across the ground; nothing for a jump no walk would make, like the
	-- first frame or being set down by a transport
	local walked = 0
	-- and how far of that was forward, which is what turns wheels
	local driven = 0
	local last = dressing.origin
	if last ~= nil then
		local shift = origin.Position - last.Position
		local distance = Vector3.new(shift.X, 0, shift.Z).Magnitude
		if distance > WALK_MIN_SPEED * dt and distance < WALK_MAX_STEP then
			walked = distance
			-- a model faces +Z, the opposite of its CFrame's look vector
			driven = -shift:Dot(origin.LookVector)
		end
	end
	local finished = model:GetAttribute "state" ~= "blueprint" and model:GetAttribute "kind" ~= "wreck"
	local def = unit_defs.get(dressing.def_name)
	for _, group in dressing.groups do
		local kind = group.def.kind
		if kind == "turret" then
			local index = group.def.weapon :: number
			local aim = model:GetAttribute(group.aim_attribute :: string)
			local target = if finished and typeof(aim) == "number" then aim else 0
			local weapon = if def.weapons ~= nil then def.weapons[index] else nil
			local turret = if weapon ~= nil then weapon.turret else nil
			local rate = if turret ~= nil then turret.turn_rate else math.pi
			group.angle = approach(group.angle, target, rate * TURRET_CATCH_UP * dt)
		elseif kind == "work" then
			local target = 0
			local target_id = model:GetAttribute "work_target"
			local work = if finished and typeof(target_id) == "number" then world.get(target_id) else nil
			if work ~= nil then
				local seen = (origin * group.pivot):PointToObjectSpace(world.position_of(work))
				if seen.X * seen.X + seen.Z * seen.Z > 1e-4 then
					target = math.atan2(seen.X, seen.Z)
				end
			end
			group.angle = approach(group.angle, target, WORK_TURN_RATE * dt)
		elseif kind == "spin" and finished then
			group.angle = (group.angle + (group.def.speed or 0) * dt) % TAU
		elseif kind == "leg" then
			-- a plain swing, once a stride of ground covered, so the feet keep pace with the unit; standing still, the
			-- leg settles back to straight and the cycle waits where it was for the next step
			if walked > 0 and finished then
				group.cycle += walked / (group.def.stride or DEFAULT_STRIDE)
				group.angle = (group.def.swing or DEFAULT_SWING)
					* math.sin(TAU * (group.cycle + (group.def.phase or 0)))
			else
				group.angle = approach(group.angle, 0, LEG_SETTLE_RATE * dt)
			end
		elseif kind == "wheel" then
			-- rolls by the ground covered, backwards when reversing
			group.angle = (group.angle + driven / (group.def.radius or DEFAULT_WHEEL_RADIUS)) % TAU
		elseif kind == "hatch" then
			-- swings open each time its weapon fires, holds a moment, and closes again
			local fired = model:GetAttribute(group.fired_attribute :: string)
			if typeof(fired) == "number" then
				if group.fired ~= nil and fired ~= group.fired then
					group.open_until = os.clock() + HATCH_HOLD
				end
				group.fired = fired
			end
			local target = if os.clock() < group.open_until then group.def.open or 0 else 0
			group.angle = approach(group.angle, target, HATCH_RATE * dt)
		end
	end
end

-- Puts every piece where its group's pivot and angle say, relative to the art's origin. A piece is only moved when
-- its angle or the origin has changed.
local function place(dressing: Dressing, origin: CFrame)
	local moved = dressing.origin == nil or dressing.origin ~= origin
	dressing.origin = origin
	for _, group in dressing.groups do
		if moved == false and group.placed == group.angle then
			continue
		end
		group.placed = group.angle
		local turn: CFrame
		local kind = group.def.kind
		if kind == "spin" then
			turn = CFrame.fromAxisAngle(vector(group.def.axis or { 0, 1, 0 }), group.angle)
		elseif kind == "turret" or kind == "work" then
			turn = CFrame.Angles(0, group.angle, 0)
		elseif kind == "leg" or kind == "wheel" or kind == "hatch" then
			turn = CFrame.fromAxisAngle(vector(group.def.axis or { 1, 0, 0 }), group.angle)
		else
			turn = CFrame.identity
		end
		local frame = origin * group.pivot * turn
		for _, piece in group.pieces do
			piece.part.CFrame = frame * piece.source.offset
		end
	end
end

local function step(dt: number)
	for _, model in world.all() do
		local dressing = dressings[model]
		if dressing == nil then
			local def_name = model:GetAttribute "def_name"
			if typeof(def_name) ~= "string" or art.has(def_name) == false then
				continue
			end
			local template = templates[def_name]
			if template == nil then
				build_template(def_name)
				continue
			end
			dress(model, def_name, template)
			dressing = dressings[model]
		end
		local ready = dressing :: Dressing
		paint(ready)
		local origin = model:GetPivot() * CFrame.new(0, -ready.half_height, 0)
		animate(ready, origin, dt)
		place(ready, origin)
	end
end

local function forget(child: Instance)
	if child:IsA "Model" then
		dressings[child :: Model] = nil
	end
end

-- A see-through copy of `def_name`'s art for a ghost, laid out with its origin at the origin, or nil while there is
-- none: because it has no art, or because it is still being built (`pending` tells the two apart).
local function ghost(def_name: string): Model?
	local template = templates[def_name]
	if template == nil then
		if art.has(def_name) then
			build_template(def_name)
		end
		return nil
	end
	local model = Instance.new "Model"
	model.Name = def_name
	for name, group_def in template.art.groups do
		local pivot = CFrame.new(vector(group_def.pivot))
		for _, source in template.parts do
			if source.group == name then
				local part = copy_mesh(source)
				part.CFrame = pivot * source.offset
				part.Parent = model
			end
		end
	end
	model.WorldPivot = CFrame.identity
	return model
end

-- Builds the art of every def there is, all at once, and returns when it is all built, or failed, or `timeout`
-- seconds have gone by, whichever is first, with the names of any still not built. Called as the client starts, so
-- that nothing is ever seen before its meshes have been fetched.
local function preload(timeout: number): { string }
	local names = art.names()
	for _, def_name in names do
		build_template(def_name)
	end
	local deadline = os.clock() + timeout
	while next(building) ~= nil and os.clock() < deadline do
		task.wait()
	end
	local missing = {}
	for _, def_name in names do
		if templates[def_name] == nil then
			table.insert(missing, def_name)
		end
	end
	return missing
end

-- Whether `def_name` has art that is not built yet, so a ghost of it should be asked for again later.
local function pending(def_name: string): boolean
	return templates[def_name] == nil and failed[def_name] ~= true and art.has(def_name)
end

local function init()
	world.container().ChildRemoved:Connect(forget)
	-- just before the frame is drawn: after interpolation last pivoted the models (on Heartbeat) and after any
	-- replicated update has landed, so the art is placed against where each model really is when it is seen
	RunService.PreRender:Connect(step)
end

return table.freeze({
	init = init,
	ghost = ghost,
	pending = pending,
	preload = preload,
})
