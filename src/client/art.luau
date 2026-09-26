-- Dresses entity models in their procedural art, and moves it.
--
-- Where a def has art (ReplicatedStorage.Shared.art), the server's model is only an invisible hitbox, and each client
-- dresses it itself: a def's meshes are built once (ClientShared.art_models), the first time something of it appears,
-- and every entity of that def gets its own copy of them, parented into its model. The copy is client-only, so it
-- moves with the model wherever interpolation.luau pivots it, and the server never touches it.
--
-- Everything the art shows comes from what the server already replicates, the same attributes the rest of the
-- client reads: `kind`, `state` and `team_color` for how it is painted (the same way the server paints its own
-- models, see Shared.appearance), `aim_<n>` for where each turret points, and `work_target` for what a builder is
-- working on. The sim decides all of it, and a shot waits on its turret in the sim (server/turrets.luau); this
-- only turns the meshes to match, smoothly, between the server's updates.

local ReplicatedStorage = game:GetService "ReplicatedStorage"
local RunService = game:GetService "RunService"

local art = require(ReplicatedStorage.Shared.art)
local appearance = require(ReplicatedStorage.Shared.appearance)
local art_build = require(ReplicatedStorage.Shared.art_build)
local skins = require(ReplicatedStorage.Shared.skins)
local types = require(ReplicatedStorage.Shared.types)
local unit_defs = require(ReplicatedStorage.Shared.unit_defs)
local entity_attrs = require(ReplicatedStorage.Shared.entity_attrs)

local art_models = require(ReplicatedStorage.ClientShared.art_models)
local art_pose = require(ReplicatedStorage.ClientShared.art_pose)

local charged_beam = require(ReplicatedStorage.Client.charged_beam)
local skin_wear = require(ReplicatedStorage.Client.skin_wear)
local world = require(ReplicatedStorage.Client.world)
local frame_profile = require(ReplicatedStorage.Client.frame_profile)

local vector = art_build.vector

type EntityId = types.EntityId
type Skin = skins.Skin
type Template = art_models.Template
type TemplatePart = art_models.TemplatePart

local TAU = 2 * math.pi
-- How much faster than its turret really turns the drawn one may, to catch up with an update it has fallen behind.
local TURRET_CATCH_UP = 1.5
-- How fast a builder's head turns toward its work, in radians a second. It is only drawn, so it is not in a def.
local WORK_TURN_RATE = math.rad(150)
-- Walking legs (their swing and stride are ClientShared.art_pose's): the least speed, in studs a second, that counts
-- as walking, and the most ground one frame's walk can cover before it is a jump instead. Legs go by how fast the unit has been walking over the last WALK_SMOOTHING
-- seconds rather than by each frame's step, which even interpolated is uneven, and their swing grows in as it sets
-- off and dies away as it stops over GAIT_BLEND seconds, never jumping.
local WALK_MIN_SPEED = 0.3
local WALK_MAX_STEP = 5
local WALK_SMOOTHING = 0.12
local GAIT_BLEND = 0.2
-- How long a hatch stays open after its weapon fires, in seconds, and how fast it swings, in radians a second.
local HATCH_HOLD = 1.5
local HATCH_RATE = math.rad(240)
-- The attributes a dressing's paint, skin and pose are read from (`Dressing.stale`).
local READ_ATTRIBUTES: { [string]: boolean } = {
	def_name = true,
	skin = true,
	kind = true,
	state = true,
	team_color = true,
	carried = true,
}
-- How many frames apart art at rest looks at whether its model has been moved, as a wreck is when the ground under it is
-- blown out, each on a frame of its own so that they do not all look at once.
local RESTING_PIVOT_FRAMES = 16

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
	aim_attribute: entity_attrs.WeaponName?,
	-- for a leg, how many strides it has walked
	cycle: number,
	-- for a hatch: the attribute its weapon's shots are counted in, the count it last saw, and until when it stays open
	fired_attribute: entity_attrs.WeaponName?,
	fired: number?,
	open_until: number,
	-- where it was last placed, in the world, with its turn
	frame: CFrame,
}

type Dressing = {
	model: Model,
	id: EntityId,
	def_name: string,
	-- the art it is dressed in, which its skin may have swapped for another, and that skin
	art_name: string,
	skin: Skin,
	folder: Folder,
	groups: { Group },
	-- the group its body is in, and where on it things sit (`art_pose.body_of`); nil for art with no body
	body_group: Group?,
	body: art_pose.Body?,
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
	-- what it was last read as, from the attributes in READ_ATTRIBUTES, and whether one of those has changed since
	-- (`stale`), which is when they are read again
	stale: boolean,
	finished: boolean,
	carried: boolean,
	-- anything but a unit, which never walks, drives or flies anywhere
	still_kind: boolean,
	-- the model's pivot as it was last drawn at, and whether its art is at rest there: something that is not a unit,
	-- with every piece turned where it is going and nothing that goes on moving by itself, is not looked at again until
	-- one of its attributes changes or its pivot does (`step`)
	pivot: CFrame?,
	resting: boolean,
}

type ChargedMuzzle = {
	group: Group,
	beam: types.Beam,
	muzzle: CFrame,
}

-- By entity id, not by model: the server takes a model away in the same frame it says the thing shattered, and the
-- model can already be unparented when that word is handled, before the world has said it went (`shatter`).
local dressings: { [EntityId]: Dressing } = {}

local function dress(model: Model, id: EntityId, def_name: string, art_name: string, skin: Skin, template: Template)
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
			aim_attribute = if group_def.weapon ~= nil then entity_attrs.aim_name(group_def.weapon) else nil,
			cycle = 0,
			fired_attribute = if group_def.kind == "hatch" and group_def.weapon ~= nil
				then entity_attrs.fired_name(group_def.weapon)
				else nil,
			fired = nil,
			open_until = 0,
			frame = CFrame.identity,
		}
		by_name[name] = group
		table.insert(groups, group)
	end
	for _, source in template.parts do
		local part = source.mesh:Clone()
		part.Parent = folder
		table.insert(by_name[source.group].pieces, { part = part, source = source })
	end

	local charged: { ChargedMuzzle } = {}
	for _, group in groups do
		local index = group.def.weapon
		local weapon = if group.def.kind == "turret"
				and index ~= nil
				and def.weapons ~= nil
			then def.weapons[index]
			else nil
		local beam = if weapon ~= nil then weapon.delivery else nil
		local mount = if weapon ~= nil then weapon.turret_mount else nil
		if beam ~= nil and beam.kind == "beam" and beam.charged == true and mount ~= nil then
			table.insert(charged, { group = group, beam = beam, muzzle = CFrame.new(mount.muzzle) })
		end
	end

	folder.Parent = model
	local body = art_pose.body_of(template)
	dressings[id] = {
		model = model,
		id = id,
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
		stale = true,
		finished = false,
		carried = false,
		still_kind = false,
		pivot = nil,
		resting = false,
	}
end

local function paint(dressing: Dressing)
	local model = dressing.model
	local kind = entity_attrs.kind(model)
	local entity_state = entity_attrs.state(model)
	local team_color = entity_attrs.color(model, "team_color") or appearance.team_color(0)
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
					local over = skin_paint :: skins.SkinPaint
					part.Color = over.color
					part.Material = over.material
					part.Reflectance = over.reflectance or 0
				else
					part.Color = if source.team then appearance.team_tint(def_color, team_color) else source.color
					part.Material = if source.neon then Enum.Material.Neon else art_build.MATERIAL
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

-- Where each moving piece of an entity's art should be turned to this frame; what is not `finished` holds still.
-- Returns whether every piece is where it is going and stays there until something changes: none turned this frame,
-- and none goes on by itself (a spinning piece, an open hatch, or a builder's head, whose work may be moving).
local function animate(dressing: Dressing, origin: CFrame, finished: boolean, dt: number): boolean
	local model = dressing.model
	-- something being carried is inactive: everything on it holds still where it was, and being flown about is not
	-- walking, so its legs do not take up a stride when it is set down
	if dressing.carried then
		dressing.walk_speed = 0
		return false
	end
	local still = dt > 0
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
	local walking = finished and dressing.walk_speed > WALK_MIN_SPEED
	dressing.gait = math.clamp(dressing.gait + (if walking then dt else -dt) / GAIT_BLEND, 0, 1)
	local def = unit_defs.get(dressing.def_name)
	for _, group in dressing.groups do
		local kind = group.def.kind
		local before = group.angle
		if kind == "turret" then
			local index = group.def.weapon :: number
			local aim = entity_attrs.weapon_number(model, group.aim_attribute :: entity_attrs.WeaponName)
			local target = if finished and aim ~= nil then aim else 0
			local weapon = if def.weapons ~= nil then def.weapons[index] else nil
			local turret = if weapon ~= nil then weapon.turret else nil
			local rate = if turret ~= nil then turret.turn_rate else math.pi
			group.angle = approach(group.angle, target, rate * TURRET_CATCH_UP * dt)
		elseif kind == "work" then
			local target = 0
			local target_id = entity_attrs.number(model, "work_target")
			local work = if finished and target_id ~= nil then world.get(target_id) else nil
			if target_id ~= nil then
				still = false
			end
			if work ~= nil then
				local seen = (origin * group.pivot):PointToObjectSpace(world.position_of(work))
				if seen.X * seen.X + seen.Z * seen.Z > 1e-4 then
					target = math.atan2(seen.X, seen.Z)
				end
			end
			group.angle = approach(group.angle, target, WORK_TURN_RATE * dt)
		elseif kind == "spin" and finished then
			group.angle = art_pose.spin(group.def, group.angle, dt)
		elseif kind == "leg" then
			-- a plain swing, once a stride of ground covered, so the feet keep pace with the unit; stopping, the swing
			-- dies away to straight and the cycle waits where it was for the next step
			if walking then
				group.cycle += dressing.walk_speed * dt / art_pose.stride(group.def)
			end
			group.angle = art_pose.leg_swing(group.def, group.cycle, dressing.gait)
		elseif kind == "wheel" then
			-- rolls by the ground covered, backwards when reversing
			group.angle = (group.angle + art_pose.wheel_turn(group.def, driven)) % TAU
		elseif kind == "hatch" then
			-- swings open each time its weapon fires, holds a moment, and closes again
			local fired = entity_attrs.weapon_number(model, group.fired_attribute :: entity_attrs.WeaponName)
			if fired ~= nil then
				if group.fired ~= nil and fired ~= group.fired then
					group.open_until = os.clock() + HATCH_HOLD
				end
				group.fired = fired
			end
			local open = os.clock() < group.open_until
			if open then
				still = false
			end
			local target = if open then group.def.open or 0 else 0
			group.angle = approach(group.angle, target, HATCH_RATE * dt)
		end
		if group.angle ~= before then
			still = false
		end
	end
	return still
end

-- Puts every piece where its group's pivot and angle say, relative to the art's origin. A piece is only moved when
-- its angle or the origin has changed. Returns whether any was.
local function place(dressing: Dressing, origin: CFrame): boolean
	local moved = dressing.origin == nil or dressing.origin ~= origin
	local placed_any = moved
	dressing.origin = origin
	for _, group in dressing.groups do
		if moved == false and group.placed == group.angle then
			continue
		end
		placed_any = true
		group.placed = group.angle
		local frame = origin * group.pivot * art_build.turn_of_group(group.def, group.angle)
		group.frame = frame
		for _, piece in group.pieces do
			piece.part.CFrame = frame * piece.source.offset
		end
	end
	return placed_any
end

-- The art `def_name` is drawn in when it wears `skin`: its own, unless the skin swaps it for another that there is.
local function art_for(def_name: string, skin: Skin): string
	local swapped = if skin.art ~= nil then skin.art[def_name] else nil
	if swapped ~= nil and art.has(swapped) then
		return swapped
	end
	return def_name
end

-- Takes `dressing` off its model, and whatever its skin hung on it, for good: the model is going, or is to be dressed
-- afresh.
local function undress(dressing: Dressing)
	dressings[dressing.id] = nil
	skin_wear.forget(dressing.model)
	charged_beam.forget(dressing.model)
	dressing.folder:Destroy()
end

-- What `dressing`'s skin hangs on it, kept on it for this frame (client/skin_wear.luau), while it is `finished`.
local function attach(dressing: Dressing, finished: boolean, dt: number)
	local group, body = dressing.body_group, dressing.body
	if group == nil or body == nil then
		return
	end
	local def = unit_defs.get(dressing.def_name)
	skin_wear.wear(dressing.model, def, body, group.frame, dressing.skin, finished, dressing.folder, dt)
end

-- Places the glow on the muzzle of each of its charged beams, facing along the barrel (the art's +Z), while it is
-- `finished` and not being carried.
local function glow(dressing: Dressing, finished: boolean, dt: number)
	if #dressing.charged == 0 then
		return
	end
	local model = dressing.model
	local showing = finished and dressing.carried == false
	for _, charged in dressing.charged do
		local frame = charged.group.frame
		local at = (frame * charged.muzzle).Position
		local facing = CFrame.lookAt(at, at + frame:VectorToWorldSpace(Vector3.zAxis))
		charged_beam.step_muzzle(model, charged.beam, facing, showing, dressing.folder, dt)
	end
end

-- Frames drawn so far, which spreads out the frames art at rest looks at its pivot on (RESTING_PIVOT_FRAMES).
local frame_count = 0

local function step(dt: number)
	frame_count += 1
	for _, model in world.all() do
		local id = world.id_of(model)
		if id == nil then
			continue
		end
		local dressing = dressings[id]
		if dressing ~= nil and dressing.resting then
			if (frame_count + id) % RESTING_PIVOT_FRAMES ~= 0 or model:GetPivot() == dressing.pivot then
				continue
			end
			dressing.resting = false
		end
		if dressing == nil or dressing.stale then
			local def_name = entity_attrs.def_name(model)
			if def_name == nil then
				continue
			end
			local skin_name = entity_attrs.text(model, "skin")
			local skin = skins.get(skin_name)
			-- a new skin can mean other art altogether, which is dressed afresh
			if dressing ~= nil and dressing.skin ~= skin then
				if dressing.art_name ~= art_for(def_name, skin) then
					undress(dressing)
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
				local template = art_models.template(art_name)
				if template == nil then
					continue
				end
				dress(model, id, def_name, art_name, skin, template)
				dressing = dressings[id]
			end
			local read = dressing :: Dressing
			read.stale = false
			paint(read)
			-- a blueprint or a wreck is not the thing itself yet, or any more
			read.finished = entity_attrs.state(model) ~= "blueprint" and world.is_remains(model) == false
			read.carried = entity_attrs.flag(model, "carried") == true
			read.still_kind = entity_attrs.kind(model) ~= "unit"
		end
		local ready = dressing :: Dressing
		local pivot = model:GetPivot()
		local origin = pivot * CFrame.new(0, -ready.half_height, 0)
		local still = animate(ready, origin, ready.finished, dt)
		local moved = place(ready, origin)
		attach(ready, ready.finished, dt)
		glow(ready, ready.finished, dt)
		ready.pivot = pivot
		ready.resting = ready.still_kind
			and still
			and moved == false
			and #ready.charged == 0
			and ready.skin.donut == nil
	end
end

-- One of an entity's attributes has changed (the world's `subscribe_changed`): its art wakes, whatever it was, and
-- reads what it is drawn as again if that is what changed.
local function changed(id: EntityId, attribute: string)
	local dressing = dressings[id]
	if dressing == nil then
		return
	end
	dressing.resting = false
	if READ_ATTRIBUTES[attribute] == true then
		dressing.stale = true
	end
end

-- An entity has gone (the world's `subscribe_removed`), and its art with it.
local function forget(model: Model, id: EntityId)
	local dressing = dressings[id]
	if dressing ~= nil and dressing.model == model then
		undress(dressing)
	end
end

-- Copies of every piece of the art entity `id` was last drawn in, painted as it was and where it was, for its pieces
-- to be flung apart as it dies, and the middle of its body then; nil when it was never dressed, or has been
-- shattered already. Its own art is taken off, since the copies stand in for it now. The server takes the model away
-- in the same frame it says the thing shattered, so the model is often unparented by now, but the world may not have
-- told `forget` it has gone yet: its dressing is kept under its id, which is how it is found.
local function shatter(id: EntityId): ({ MeshPart }?, Vector3?)
	local dressing = dressings[id]
	if dressing == nil or dressing.shattered or dressing.origin == nil then
		return nil, nil
	end
	dressing.shattered = true
	local shards: { MeshPart } = {}
	for _, group in dressing.groups do
		for _, piece in group.pieces do
			local shard = piece.source.mesh:Clone()
			shard.Color = piece.part.Color
			shard.Material = piece.part.Material
			shard.Transparency = piece.part.Transparency
			shard.CFrame = group.frame * piece.source.offset
			table.insert(shards, shard)
		end
	end
	-- the pieces go wherever the stand-ins do from here, and the model is only an invisible hitbox until it goes
	dressing.folder.Parent = nil
	local origin = dressing.origin :: CFrame
	return shards, origin.Position + Vector3.new(0, dressing.half_height, 0)
end

-- Builds the art of every def there is, all at once, and returns when it is all built, or failed, or `timeout`
-- seconds have gone by, whichever is first, with the names of any still not built. Called as the client starts, so
-- that nothing is ever seen before its meshes have been fetched.
local function preload(timeout: number): { string }
	-- what skins hang on units too, so that no unit is seen without it
	skin_wear.preload(timeout)
	return art_models.preload(art.names(), timeout)
end

local function init()
	world.subscribe_removed(forget)
	world.subscribe_changed(changed)
	-- just before the frame is drawn, after any replicated update has landed and right after interpolation has
	-- pivoted the models past it, so the art is placed where each model is seen, never at a raw update
	RunService:BindToRenderStep("art", Enum.RenderPriority.First.Value + 1, frame_profile.wrap("art", step))
end

return table.freeze({
	init = init,
	shatter = shatter,
	preload = preload,
})
