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
local skins = require(ReplicatedStorage.Shared.skins)
local types = require(ReplicatedStorage.Shared.types)
local unit_defs = require(ReplicatedStorage.Shared.unit_defs)
local charged_beam = require(ReplicatedStorage.Client.charged_beam)
local donuts = require(ReplicatedStorage.Client.donuts)
local world = require(ReplicatedStorage.Client.world)

type DonutSettings = types.DonutSettings
type EntityDef = types.EntityDef
type Skin = types.Skin
type SkinAttachment = types.SkinAttachment

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
-- art does not say; the least speed, in studs a second, that counts as walking, and the most ground one frame's walk
-- can cover before it is a jump instead. Legs go by how fast the unit has been walking over the last WALK_SMOOTHING
-- seconds rather than by each frame's step, which even interpolated is uneven, and their swing grows in as it sets
-- off and dies away as it stops over GAIT_BLEND seconds, never jumping.
local DEFAULT_SWING = math.rad(25)
local DEFAULT_STRIDE = 3
local WALK_MIN_SPEED = 0.3
local WALK_MAX_STEP = 5
local WALK_SMOOTHING = 0.12
local GAIT_BLEND = 0.2
-- A wheel whose art does not give its radius; how long a hatch stays open after its weapon fires, in seconds, and how
-- fast it swings, in radians a second.
local DEFAULT_WHEEL_RADIUS = 0.5
local HATCH_HOLD = 1.5
local HATCH_RATE = math.rad(240)
-- A pool donut's turn from lying flat (its hole facing up) to its hole facing the nose (+Z), as round a fuselage, or
-- facing out of a side, as hung on a ship's: port is +X, looking to the nose.
local NOSE_UP = CFrame.Angles(math.pi / 2, 0, 0)
local PORT_UP = CFrame.Angles(0, 0, -math.pi / 2)
local STARBOARD_UP = CFrame.Angles(0, 0, math.pi / 2)
-- How few and how many a ship hangs down each side.
local SIDE_FLOATS_LEAST = 2
local SIDE_FLOATS_MOST = 4

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

-- The body of a def's art, which what a skin hangs on it is worn round: the piece it belongs to, the middle of its
-- bulk across the ground in that piece's own frame, the heights of its bottom and its top there, the box round all
-- of it, and its fuselage, if it has one.
type Body = {
	group: string,
	middle: Vector3,
	bottom: number,
	top: number,
	low: Vector3,
	high: Vector3,
	fuselage: Fuselage?,
}

-- The long, thin run of a body from tail to nose (+Z), which on a plane is its fuselage: the middle of it, how long it
-- is, and how far it reaches out from its middle across, at the most.
type Fuselage = {
	middle: Vector3,
	length: number,
	radius: number,
}

type Template = {
	art: art.Art,
	parts: { TemplatePart },
	body: Body?,
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
	-- where it was last placed, in the world, with its turn
	frame: CFrame,
}

type Dressing = {
	model: Model,
	def_name: string,
	-- the art it is dressed in, which its skin may have swapped for another, and that skin
	art_name: string,
	skin: Skin,
	folder: Folder,
	groups: { Group },
	-- the group its body is in, and where on it things sit (Template.body); nil for art with no body
	body_group: Group?,
	body: Body?,
	-- half the collider's height: the art's origin is on the ground, the model's pivot is the collider's middle
	half_height: number,
	-- what it was last painted as, and where its origin last was
	paint_key: string?,
	origin: CFrame?,
	-- how fast it has been walking lately, in studs a second, and how far into its walk its legs are, from 0 standing
	-- to 1 in full stride
	walk_speed: number,
	gait: number,
	-- whether its pieces have already been flung apart (`shatter`), so that they are not twice
	shattered: boolean,
	-- its turrets whose weapon is a charged beam, whose muzzles glow (client/charged_beam.luau), and where on each
	-- the muzzle is
	charged: { ChargedMuzzle },
}

type ChargedMuzzle = {
	group: Group,
	weapon: types.Weapon,
	muzzle: CFrame,
}

-- How long, in seconds, the dressing of a model that has gone is kept for `shatter`, which the server's word that it
-- shattered can reach the client after the model's removal.
local DEPARTED_KEEP = 2

local templates: { [string]: Template } = {}
local building: { [string]: boolean } = {}
local failed: { [string]: boolean } = {}
local dressings: { [Model]: Dressing } = {}
-- The dressings of models that have gone lately, by entity id, and when each went (os.clock()).
local departed: { [number]: { dressing: Dressing, at: number } } = {}
-- Called once a def's art has been built, or has failed to, by def name.
local waiting_for: { [string]: { () -> () } } = {}

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

-- Where on `data` its body is: the bulkiest piece that holds still, or turns as a turret or a builder's head does
-- (never a leg, a wheel, a hatch or a spinning piece), which on a bot is its torso, on a tank its hull and on a plane
-- its fuselage. Its middle is the middle of its bulk, which a long thin gun barrel or a wing barely moves. Nil for art
-- with no such piece.
local function find_body(data: art.Art): Body?
	type Box = { low: Vector3, high: Vector3, bulk: Vector3, volume: number }
	local boxes: { [string]: Box } = {}
	for _, part in data.parts do
		local group = data.groups[part.group]
		if group == nil or (group.kind ~= nil and group.kind ~= "turret" and group.kind ~= "work") then
			continue
		end
		local middle, size = vector(part.offset), vector(part.size)
		local volume = size.X * size.Y * size.Z
		local box = boxes[part.group]
		if box == nil then
			boxes[part.group] =
				{ low = middle - size / 2, high = middle + size / 2, bulk = middle * volume, volume = volume }
		else
			box.low = box.low:Min(middle - size / 2)
			box.high = box.high:Max(middle + size / 2)
			box.bulk += middle * volume
			box.volume += volume
		end
	end
	local found: string? = nil
	local most = -1
	for name, box in boxes do
		if box.volume > most then
			found, most = name, box.volume
		end
	end
	if found == nil then
		return nil
	end
	local box = boxes[found]
	local middle = if box.volume > 0 then box.bulk / box.volume else (box.low + box.high) / 2
	-- its fuselage: the piece of it longest from tail to nose against how thick it is across, and long for that too.
	-- Pieces are merged by colour, so a wing may share one with the fuselage's paint; it is wide for how long it is.
	-- A flat panel has no thickness and is no fuselage.
	local fuselage: Fuselage? = nil
	local best = 0
	for _, part in data.parts do
		local size = vector(part.size)
		local across = math.max(size.X, size.Y)
		if part.group ~= found or math.min(size.X, size.Y) <= 0 then
			continue
		end
		local score = size.Z * size.Z / across
		if score > best then
			best = score
			fuselage = { middle = vector(part.offset), length = size.Z, radius = across / 2 }
		end
	end
	return {
		group = found,
		middle = Vector3.new(middle.X, 0, middle.Z),
		bottom = box.low.Y,
		top = box.high.Y,
		low = box.low,
		high = box.high,
		fuselage = fuselage,
	}
end

-- Builds the meshes of the art called `def_name` (a def's own, or one a skin draws instead), once. It yields, so it
-- runs in a thread of its own, and anything in that art is dressed once it is done. Its meshes are fetched all at
-- once rather than one after another.
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
			return { art = data :: art.Art, parts = parts, body = find_body(data :: art.Art) }
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
		local callbacks = waiting_for[def_name]
		waiting_for[def_name] = nil
		if callbacks ~= nil then
			for _, callback in callbacks do
				task.spawn(callback)
			end
		end
	end)
end

-- A copy of a template mesh for one entity. A MeshPart made from an EditableMesh copies like any other.
local function copy_mesh(source: TemplatePart): MeshPart
	return source.mesh:Clone()
end

local function dress(model: Model, def_name: string, art_name: string, skin: Skin, template: Template)
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
			frame = CFrame.identity,
		}
		by_name[name] = group
		table.insert(groups, group)
	end
	for _, source in template.parts do
		local part = copy_mesh(source)
		part.Parent = folder
		table.insert(by_name[source.group].pieces, { part = part, source = source })
	end

	local charged: { ChargedMuzzle } = {}
	for _, group in groups do
		local index, muzzle = group.def.weapon, group.def.muzzle
		local weapon = if group.def.kind == "turret"
				and index ~= nil
				and def.weapons ~= nil
			then def.weapons[index]
			else nil
		if weapon ~= nil and weapon.charged_beam == true and muzzle ~= nil then
			table.insert(charged, { group = group, weapon = weapon, muzzle = CFrame.new(vector(muzzle)) })
		end
	end

	folder.Parent = model
	local body = template.body
	dressings[model] = {
		model = model,
		def_name = def_name,
		art_name = art_name,
		skin = skin,
		folder = folder,
		groups = groups,
		body_group = if body ~= nil then by_name[body.group] else nil,
		body = body,
		half_height = unit_defs.collider_height(def) / 2,
		paint_key = nil,
		origin = nil,
		walk_speed = 0,
		gait = 0,
		shattered = false,
		charged = charged,
	}
end

local function paint(dressing: Dressing)
	local model = dressing.model
	local kind = model:GetAttribute "kind"
	local entity_state = model:GetAttribute "state"
	local team = model:GetAttribute "team_color"
	local team_color = if typeof(team) == "Color3" then team else appearance.team_color(0)
	local skin = dressing.skin
	local key = `{kind}|{entity_state}|{team_color}|{skin.name}`
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
				-- a skin's paint goes over everything but what glows, and, if it keeps them, the team's colours
				local skin_paint = skin.paint
				local painted = skin_paint ~= nil
					and source.neon == false
					and (source.team == false or skin_paint.keep_team ~= true)
				if painted then
					local over = skin_paint :: types.SkinPaint
					part.Color = over.color
					part.Material = over.material
					part.Reflectance = over.reflectance or 0
				else
					part.Color = if source.team then appearance.team_tint(def_color, team_color) else source.color
					part.Material = if source.neon then Enum.Material.Neon else MATERIAL
					part.Reflectance = 0
				end
				part.Transparency = 0
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
	-- something being carried is inactive: everything on it holds still where it was, and being flown about is not
	-- walking, so its legs do not take up a stride when it is set down
	if model:GetAttribute "carried" == true then
		dressing.walk_speed = 0
		return
	end
	-- how far it has walked forward since the last frame, which is what turns wheels; nothing for a jump no walk
	-- would make, like the first frame or being set down by a transport, which the legs ignore too
	local driven = 0
	local last = dressing.origin
	if last ~= nil and dt > 0 then
		local shift = origin.Position - last.Position
		local distance = Vector3.new(shift.X, 0, shift.Z).Magnitude
		if distance < WALK_MAX_STEP then
			if distance > WALK_MIN_SPEED * dt then
				-- a model faces +Z, the opposite of its CFrame's look vector
				driven = -shift:Dot(origin.LookVector)
			end
			dressing.walk_speed += (distance / dt - dressing.walk_speed) * (1 - math.exp(-dt / WALK_SMOOTHING))
		end
	end
	local finished = model:GetAttribute "state" ~= "blueprint" and model:GetAttribute "kind" ~= "wreck"
	local walking = finished and dressing.walk_speed > WALK_MIN_SPEED
	dressing.gait = math.clamp(dressing.gait + (if walking then dt else -dt) / GAIT_BLEND, 0, 1)
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
			-- a plain swing, once a stride of ground covered, so the feet keep pace with the unit; stopping, the swing
			-- dies away to straight and the cycle waits where it was for the next step
			if walking then
				group.cycle += dressing.walk_speed * dt / (group.def.stride or DEFAULT_STRIDE)
			end
			group.angle = dressing.gait
				* (group.def.swing or DEFAULT_SWING)
				* math.sin(TAU * (group.cycle + (group.def.phase or 0)))
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
		group.frame = frame
		for _, piece in group.pieces do
			piece.part.CFrame = frame * piece.source.offset
		end
	end
end

-- The art `def_name` is drawn in when it wears `skin`: its own, unless the skin swaps it for another that there is.
local function art_for(def_name: string, skin: Skin): string
	local swapped = if skin.art ~= nil then skin.art[def_name] else nil
	if swapped ~= nil and art.has(swapped) then
		return swapped
	end
	return def_name
end

local function undress(model: Model)
	local dressing = dressings[model]
	if dressing == nil then
		return
	end
	dressings[model] = nil
	donuts.forget(model)
	charged_beam.forget(model)
	dressing.folder:Destroy()
end

-- The donut `skin` puts on something of `kind`, if it puts one on.
local function donut_of(skin: Skin, kind: unknown): SkinAttachment?
	for _, attachment in skin.attachments do
		if attachment.kind == "donut" and table.find(attachment.kinds, kind :: any) ~= nil then
			return attachment
		end
	end
	return nil
end

-- Where the rings of `settings`' donut go on `model`, of `def`, with its body `body` in `frame`, and how wide each
-- one's hole is, in studs. An aircraft wears one round its fuselage, its hole facing the nose; a ship (not a
-- submarine, which wears one round its waist to lose when it dives) hangs a row of small ones flat against each side
-- of its hull; anything else wears one round its waist.
local function mounts_of(
	model: Model,
	def: EntityDef,
	body: Body,
	frame: CFrame,
	settings: DonutSettings
): ({ CFrame }, number)
	local fuselage = body.fuselage
	if unit_defs.is_air(def) and fuselage ~= nil then
		local along = fuselage.middle.Z + fuselage.length * (settings.nose - 0.5)
		local at = CFrame.new(fuselage.middle.X, fuselage.middle.Y, along)
		-- its up, the way its hole faces, turned from straight up to the nose (+Z)
		return { frame * at * NOSE_UP }, settings.fuselage_hug * fuselage.radius
	end
	if unit_defs.floats(def) and def.waterline == nil then
		local width = body.high.X - body.low.X
		local hole = settings.side_hole * width
		local reach = donuts.tube(model, settings, hole)
		local across = width / 2 + reach
		local span = (body.high.Z - body.low.Z) * settings.side_span
		local wide = 2 * (hole + 2 * reach)
		local apart = settings.side_spacing * wide
		local count = math.clamp(math.floor(span / apart) + 1, SIDE_FLOATS_LEAST, SIDE_FLOATS_MOST)
		local height = math.max(
			body.bottom,
			body.bottom + (body.top - body.bottom) * settings.side_height - settings.side_drop * wide
		)
		local mounts = table.create(count * 2)
		for index = 1, count do
			local along = body.middle.Z + (index - (count + 1) / 2) * apart
			table.insert(mounts, frame * CFrame.new(body.middle.X + across, height, along) * PORT_UP)
			table.insert(mounts, frame * CFrame.new(body.middle.X - across, height, along) * STARBOARD_UP)
		end
		return mounts, hole
	end
	local height = body.bottom + (body.top - body.bottom) * settings.waist
	return { frame * CFrame.new(body.middle.X, height, body.middle.Z) }, settings.hug * unit_defs.collider_radius(def)
end

-- What `dressing`'s skin hangs on it, kept on it for this frame.
local function attach(dressing: Dressing, dt: number)
	local model = dressing.model
	local group, body = dressing.body_group, dressing.body
	if group == nil or body == nil then
		return
	end
	local kind = model:GetAttribute "kind"
	local attachment = donut_of(dressing.skin, kind)
	local settings = if attachment ~= nil then attachment.donut else nil
	local wearing = model:GetAttribute "state" ~= "blueprint" and kind ~= "wreck"
	local mounts: { CFrame }, hole = {}, 0
	if settings ~= nil then
		mounts, hole = mounts_of(model, unit_defs.get(dressing.def_name), body, group.frame, settings)
	end
	donuts.step(model, mounts, hole, settings, wearing, dressing.folder, dt)
end

-- Places the glow on the muzzle of each of its charged beams, facing along the barrel (the art's +Z).
local function glow(dressing: Dressing, dt: number)
	if #dressing.charged == 0 then
		return
	end
	local model = dressing.model
	local showing = model:GetAttribute "state" ~= "blueprint"
		and model:GetAttribute "kind" ~= "wreck"
		and model:GetAttribute "carried" ~= true
	for _, charged in dressing.charged do
		local frame = charged.group.frame
		local at = (frame * charged.muzzle).Position
		local facing = CFrame.lookAt(at, at + frame:VectorToWorldSpace(Vector3.zAxis))
		charged_beam.step_muzzle(model, charged.weapon, facing, showing, dressing.folder, dt)
	end
end

local function step(dt: number)
	-- let go of the dressings of models gone for longer than `shatter` could still want them
	local now = os.clock()
	for id, gone in departed do
		if now - gone.at > DEPARTED_KEEP then
			departed[id] = nil
		end
	end
	for _, model in world.all() do
		local def_name = model:GetAttribute "def_name"
		if typeof(def_name) ~= "string" then
			continue
		end
		local skin_name = model:GetAttribute "skin"
		local skin = skins.get(if typeof(skin_name) == "string" then skin_name else nil)
		local dressing = dressings[model]
		-- a new skin can mean other art altogether, which is dressed afresh
		if dressing ~= nil and dressing.skin ~= skin then
			if dressing.art_name ~= art_for(def_name, skin) then
				undress(model)
				dressing = nil
			else
				dressing.skin = skin
				dressing.paint_key = nil
			end
		end
		if dressing == nil then
			local art_name = art_for(def_name, skin)
			if art.has(art_name) == false then
				continue
			end
			local template = templates[art_name]
			if template == nil then
				build_template(art_name)
				continue
			end
			dress(model, def_name, art_name, skin, template)
			dressing = dressings[model]
		end
		local ready = dressing :: Dressing
		paint(ready)
		local origin = model:GetPivot() * CFrame.new(0, -ready.half_height, 0)
		animate(ready, origin, dt)
		place(ready, origin)
		attach(ready, dt)
		glow(ready, dt)
	end
end

local function forget(child: Instance)
	if child:IsA "Model" then
		local dressing = dressings[child :: Model]
		local id = child:GetAttribute "entity_id"
		if dressing ~= nil and dressing.shattered == false and typeof(id) == "number" then
			departed[id] = { dressing = dressing, at = os.clock() }
		end
		dressings[child :: Model] = nil
		donuts.forget(child :: Model)
		charged_beam.forget(child :: Model)
	end
end

-- Copies of every piece of the art entity `id` was last drawn in, painted as it was and where it was, for its pieces
-- to be flung apart as it dies, and the middle of its body then; nil when it was never dressed, or has been
-- shattered already. A model still standing has its own art taken off, since the copies stand in for it now.
local function shatter(id: number): ({ MeshPart }?, Vector3?)
	local dressing: Dressing? = nil
	local model = world.get(id)
	if model ~= nil then
		dressing = dressings[model]
	end
	-- the server takes the model away in the same frame it says the thing shattered, and the model can already be
	-- unparented when that word is handled while `forget` has not yet heard it go, so it is neither in the world nor
	-- among the departed
	if dressing == nil then
		for dressed, candidate in dressings do
			if dressed:GetAttribute "entity_id" == id then
				dressing = candidate
				break
			end
		end
	end
	if dressing == nil then
		local gone = departed[id]
		departed[id] = nil
		if gone ~= nil and os.clock() - gone.at <= DEPARTED_KEEP then
			dressing = gone.dressing
		end
	end
	if dressing == nil or dressing.shattered or dressing.origin == nil then
		return nil, nil
	end
	dressing.shattered = true
	local shards: { MeshPart } = {}
	for _, group in dressing.groups do
		for _, piece in group.pieces do
			local shard = copy_mesh(piece.source)
			shard.Color = piece.part.Color
			shard.Material = piece.part.Material
			shard.Transparency = piece.part.Transparency
			shard.CFrame = group.frame * piece.source.offset
			table.insert(shards, shard)
		end
	end
	-- the pieces go wherever the stand-ins do from here, and the model is only an invisible hitbox until it goes
	if model ~= nil and dressings[model] == dressing then
		dressing.folder.Parent = nil
	end
	local origin = dressing.origin :: CFrame
	return shards, origin.Position + Vector3.new(0, dressing.half_height, 0)
end

-- A copy of `def_name`'s art at rest, laid out with its origin at the origin, or nil while there is none: because it
-- has no art, or because it is still being built (`pending` tells the two apart). Its team parts take `team`'s
-- colour if one is given; a ghost repaints it all anyway.
local function ghost(def_name: string, team: Color3?): Model?
	local template = templates[def_name]
	if template == nil then
		if art.has(def_name) then
			build_template(def_name)
		end
		return nil
	end
	local model = Instance.new "Model"
	model.Name = def_name
	local def_color = unit_defs.get(def_name).color
	for name, group_def in template.art.groups do
		local pivot = CFrame.new(vector(group_def.pivot))
		for _, source in template.parts do
			if source.group == name then
				local part = copy_mesh(source)
				part.CFrame = pivot * source.offset
				if team ~= nil and source.team then
					part.Color = appearance.team_tint(def_color, team)
				end
				part.Parent = model
			end
		end
	end
	model.WorldPivot = CFrame.identity
	return model
end

-- Builds `data`, art that belongs to no def (the HUD's own pictures, Shared.ui_art), into a model at rest with its
-- origin at the origin, the way `ghost` lays one out: each MeshPart named after its group. It yields until every mesh
-- is built, and errors if any cannot be. The built meshes are returned with it, to be kept for as long as the model or
-- any copy of it is shown.
local function build_model(data: art.Art, name: string): (Model, { EditableMesh })
	local model = Instance.new "Model"
	model.Name = name
	local editables: { EditableMesh } = {}
	for _, part in data.parts do
		local mesh, editable = build_mesh(part)
		mesh.Name = part.group
		local group = data.groups[part.group]
		local pivot = if group ~= nil then CFrame.new(vector(group.pivot)) else CFrame.identity
		local offset = if part.mesh ~= nil
			then CFrame.new(vector(part.offset)) * UPLOADED_TURN
			else CFrame.new(vector(part.offset))
		mesh.CFrame = pivot * offset
		mesh.Parent = model
		if editable ~= nil then
			table.insert(editables, editable)
		end
	end
	model.WorldPivot = CFrame.identity
	return model, editables
end

-- Builds the art of every def there is, all at once, and returns when it is all built, or failed, or `timeout`
-- seconds have gone by, whichever is first, with the names of any still not built. Called as the client starts, so
-- that nothing is ever seen before its meshes have been fetched.
local function preload(timeout: number): { string }
	-- the skins' pool donuts too, so that no unit is seen without its donut
	donuts.preload(timeout)
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

-- Calls `callback` once `def_name`'s art has been built or has failed, starting it building if it had not yet. Only
-- for art that is `pending`. Returns a function that cancels the call.
local function when_built(def_name: string, callback: () -> ()): () -> ()
	local callbacks = waiting_for[def_name]
	if callbacks == nil then
		callbacks = {}
		waiting_for[def_name] = callbacks
	end
	table.insert(callbacks, callback)
	build_template(def_name)
	return function()
		local index = table.find(callbacks, callback)
		if index ~= nil then
			table.remove(callbacks, index)
		end
	end
end

local function init()
	donuts.init()
	world.container().ChildRemoved:Connect(forget)
	-- just before the frame is drawn, after any replicated update has landed and right after interpolation has
	-- pivoted the models past it, so the art is placed where each model is seen, never at a raw update
	RunService:BindToRenderStep("art", Enum.RenderPriority.First.Value + 1, step)
end

return table.freeze({
	init = init,
	ghost = ghost,
	shatter = shatter,
	build_model = build_model,
	pending = pending,
	preload = preload,
	when_built = when_built,
})
