-- The pool skin's pool donuts (shared/skins/pool.luau): inflatable floats worn round the waist of every unit that wears
-- the skin, as big as the unit is; round an aircraft's fuselage, facing its nose; and on a ship, a row of small ones
-- hung down each side of its hull, all of which come and go together. Each unit wears one of the skin's floats (a striped ring, an iced donut, a
-- lifebuoy, now and then a rubber ducky), picked by weight from its entity id, so the same one for every player. It is
-- only drawn, and nothing of it touches the sim.
--
-- What happens to a donut is the server's to say (server/donuts.luau), so that every player sees the same: when it
-- pops (a hit), how hard it shakes and when it flies off (a fast aircraft), when it floats off (deep under the water),
-- and when a new one goes on. art.luau says, each frame, where the waist of each dressed unit is, how big the unit is,
-- and whether its skin puts a donut on it (where each of its rings goes and how big its hole is), and this keeps the donut there and plays what the server says: a pop is a
-- puff and a flutter of torn vinyl, flying off is the donut tumbling away to lie on the ground a while, floating off
-- is the donut rising to bob on the surface for `float_seconds`, and a new one inflates.
--
-- Where on what wears it a donut goes is worked out here from the wearer's body (ClientShared.art_pose's `body_of`):
-- round the fuselage of an aircraft, down the sides of a ship, round the waist of anything else (`wear`).
--
-- The floats are pipeline art (tools/model_pipeline/generators: pool_donut, pool_donut_iced, pool_lifebuoy and
-- rubber_ducky), uploaded, built once (ClientShared.art_models) and every donut is a copy of it.

local ReplicatedStorage = game:GetService "ReplicatedStorage"

local ground_levels = require(ReplicatedStorage.Shared.ground_levels)
local heightmap = require(ReplicatedStorage.Shared.heightmap)
local skins = require(ReplicatedStorage.Shared.skins)
local types = require(ReplicatedStorage.Shared.types)
local entity_attrs = require(ReplicatedStorage.Shared.entity_attrs)
local unit_defs = require(ReplicatedStorage.Shared.unit_defs)

local art_models = require(ReplicatedStorage.ClientShared.art_models)
local art_pose = require(ReplicatedStorage.ClientShared.art_pose)

local world_fx = require(ReplicatedStorage.Client.world_fx)
local loose_pieces = require(ReplicatedStorage.Client.loose_pieces)

type DonutSettings = skins.DonutSettings
type Skin = skins.Skin
type EntityDef = types.EntityDef
type DonutVariant = skins.DonutVariant
type Template = art_models.Template

local TAU = 2 * math.pi
-- Vinyl: a little shiny.
local MATERIAL = Enum.Material.SmoothPlastic
local REFLECTANCE = 0.12
-- The colour a team-coloured stripe has before its team is known.
local NO_TEAM = Color3.fromRGB(230, 60, 50)
-- A donut's turn from lying flat (its hole facing up) to its hole facing the nose (+Z), as round a fuselage, or facing
-- out of a side, as hung on a ship's: port is +X, looking to the nose.
local NOSE_UP = CFrame.Angles(math.pi / 2, 0, 0)
local PORT_UP = CFrame.Angles(0, 0, -math.pi / 2)
local STARBOARD_UP = CFrame.Angles(0, 0, math.pi / 2)
-- How few and how many a ship hangs down each side.
local SIDE_FLOATS_LEAST = 2
local SIDE_FLOATS_MOST = 4
-- How far the donut's tube reaches either way from its ring, and so how wide its art is, in its own units: every
-- float is a ring 1 out (tools/model_pipeline/generators/pool_float_common).
local ART_TUBE = 0.42
local ART_WIDTH = 2 * (1 + ART_TUBE)
-- Inflating: how many seconds it takes, and how far past full size it swells before it settles.
local GROW_TIME = 0.45
local GROW_OVERSHOOT = 0.15
-- Shaking on a fast aircraft, at its hardest (just before it flies off): how many shakes a second, and how far it
-- tips and slides, the slide as a fraction of its width.
local SHAKE_FREQUENCY = 22
local SHAKE_MAX_ANGLE = math.rad(16)
local SHAKE_MAX_SLIDE = 0.08
-- How quickly its speed is smoothed, per second, and the most a frame can move it before it counts as a jump (being
-- set down by a transport, or the first frame) rather than speed.
local SPEED_SMOOTHING = 8
local MAX_FRAME_STEP = 20
-- Something loose: how hard it falls, in studs a second a second. A donut that has flown off keeps some of its
-- aircraft's speed, is thrown up and aside, loses some of its speed to the air each second, and tumbles, in radians a
-- second. It lies where it lands for `LOOSE_REST` seconds and then fades out over `LOOSE_FADE`, and is gone after
-- `LOOSE_LIFETIME` whatever happens.
local GRAVITY = 45
local LOOSE_DRAG = 0.6
local LOOSE_KEEP = 0.75
local LOOSE_THROW_UP = 7
local LOOSE_THROW_SIDE = 3
local LOOSE_SPIN = 7
local LOOSE_REST = 2
local LOOSE_FADE = 0.6
local LOOSE_LIFETIME = 8
-- A pop: how many scraps of vinyl, how big against the ring's width, how fast they fly out and up, how much of their
-- speed the air takes each second (a lot: they flutter), how fast they twist, and how long they last. The puff is a
-- white burst of air that swells and fades in `POP_TIME`.
local SCRAPS = 10
-- the fewest scraps each ring of a donut of several rings (a ship's) tears into; they share `SCRAPS` otherwise
local SCRAPS_LEAST = 4
local SCRAP_SIZE = 0.2
local SCRAP_SPEED = 12
local SCRAP_UP = 8
local SCRAP_DRAG = 2.5
local SCRAP_SPIN = 14
local SCRAP_LIFETIME = 1.2
local POP_TIME = 0.15
local POP_COLOR = Color3.fromRGB(255, 255, 255)
-- A donut floating off something under the water: how fast it rises, in studs a second, how much of its wearer's speed
-- it keeps, how high its middle rides above the surface against its own half height (a float rides high), how fast it
-- turns flat as it rises, and on the surface how far it bobs against its size, how many bobs a second, how far it
-- rocks, in radians, and how fast it turns, in radians a second. It fades out over LOOSE_FADE at the end.
local FLOAT_RISE = 5
local FLOAT_KEEP = 0.3
local FLOAT_RIDE = 0.35
local FLOAT_LEVEL_RATE = 3
local FLOAT_BOB = 0.06
local FLOAT_BOB_RATE = 0.7
local FLOAT_ROCK = math.rad(5)
local FLOAT_TURN = 0.25
-- The longest it may take to reach the surface, in seconds: past that it is on it, wherever it is.
local FLOAT_MAX_RISE = 6

-- One mesh of the donut's art, in vinyl: a MeshPart to copy, where its middle sits against the donut's middle and how
-- it is turned there, how big it is, and its colour, or the team's.
type Piece = {
	mesh: MeshPart,
	offset: Vector3,
	turn: CFrame,
	size: Vector3,
	color: Color3,
	team: boolean,
}

-- The donut's art, loaded: its pieces, and how far its underside is below its middle, in its own units.
type Shape = {
	pieces: { Piece },
	half_height: number,
}

-- What a donut on a unit is doing: on it ("on"), gone and waiting to reinflate ("off"), or inflating.
type Status = "on" | "off" | "growing"

type Donut = {
	model: Model,
	settings: DonutSettings,
	-- which of the settings' floats it is (`variant_of`)
	variant: DonutVariant,
	shape: Shape,
	folder: Folder,
	-- the parts of each of its rings, one for each place it is worn
	rings: { { MeshPart } },
	status: Status,
	-- seconds it has been inflating, while it is
	grown: number,
	-- the server's word on how it last came off (`donut_event`), to see a new one by
	event: string?,
	-- where its first ring was last frame, and how fast it is going, smoothed
	last_position: Vector3?,
	velocity: Vector3,
	-- how big it is drawn against its art, and what its parts were last sized at (that times how inflated it is)
	scale: number,
	sized: number?,
	-- the team colour its stripes were last painted
	painted: Color3?,
	-- whether its parts are showing
	shown: boolean,
	-- sets its shaking apart from every other donut's
	seed: number,
}

local donuts: { [Model]: Donut } = {}
-- The donut's art, in vinyl, by art name.
local shapes: { [string]: Shape } = {}
local random = Random.new()

-- The donut drawn in the art `template`, each mesh in vinyl: a little shiny, and too thin to cast a shadow.
local function shape_of(template: Template): Shape
	local pieces: { Piece } = table.create(#template.parts)
	local half_height = 0
	for _, source in template.parts do
		half_height = math.max(half_height, math.abs(source.position.Y) + source.size.Y / 2)
		local mesh = source.mesh:Clone()
		mesh.Name = "Donut"
		mesh.CastShadow = false
		mesh.Material = MATERIAL
		mesh.Reflectance = REFLECTANCE
		table.insert(pieces, {
			mesh = mesh,
			offset = source.position,
			turn = source.turn,
			size = source.size,
			color = source.color,
			team = source.team,
		})
	end
	return { pieces = pieces, half_height = half_height }
end

-- The donut drawn in the art called `name`, or nil while it is still being built (which this starts) or if it could
-- not be.
local function shape_for(name: string): Shape?
	local shape = shapes[name]
	if shape == nil then
		local template = art_models.template(name)
		if template ~= nil then
			shape = shape_of(template)
			shapes[name] = shape
		end
	end
	return shape
end

-- A fresh copy of the donut, hidden, parented to `parent`.
local function copy_parts(shape: Shape, parent: Instance): { MeshPart }
	local parts = table.create(#shape.pieces)
	for index, piece in shape.pieces do
		local part = piece.mesh:Clone()
		part.Color = piece.color
		part.Transparency = 1
		part.Parent = parent
		parts[index] = part
	end
	return parts
end

-- Paints the team's stripes `team`.
local function paint(parts: { MeshPart }, shape: Shape, team: Color3)
	for index, piece in shape.pieces do
		if piece.team then
			parts[index].Color = team
		end
	end
end

-- Sizes `parts` for a donut drawn at `scale`, and returns where each sits relative to the donut's middle.
local function size_parts(parts: { MeshPart }, shape: Shape, scale: number): { CFrame }
	local offsets = table.create(#parts)
	for index, part in parts do
		local piece = shape.pieces[index]
		part.Size = (piece.size * scale):Max(Vector3.one * 0.001)
		offsets[index] = CFrame.new(piece.offset * scale) * piece.turn
	end
	return offsets
end

local function show(donut: Donut, shown: boolean)
	if donut.shown == shown then
		return
	end
	donut.shown = shown
	for _, parts in donut.rings do
		for _, part in parts do
			part.Transparency = if shown then 0 else 1
		end
	end
end

-- Gives `donut` new rings to reinflate, once its old ones have gone loose.
local function renew(donut: Donut)
	for index in donut.rings do
		donut.rings[index] = copy_parts(donut.shape, donut.folder)
	end
	donut.sized = nil
	donut.painted = nil
	donut.shown = false
	donut.status = "off"
end

-- Lets go of `parts`, which are loose now (client/loose_pieces.luau).
local function loosen(parts: { MeshPart }): { BasePart }
	local loosened: { BasePart } = {}
	for _, part in parts do
		part.Parent = world_fx.folder "DonutDebris"
		table.insert(loosened, part)
	end
	return loosened
end

local function effect_part(name: string, color: Color3): Part
	local part = world_fx.part(name)
	part.Material = MATERIAL
	part.Color = color
	part.Parent = world_fx.folder "DonutDebris"
	return part
end

-- The ground a donut lands on: the water's surface where the ground is under it.
local function ground_under(x: number, z: number): number
	return math.max(heightmap.height_at(x, z), ground_levels.WATER_LEVEL)
end

-- How the puff of a pop moves, how a scrap flutters down, and how a donut flown off tumbles down to lie on the ground.
local PUFF_MOTION = loose_pieces.fall(GRAVITY, 0, nil, ground_under)
local SCRAP_MOTION = loose_pieces.fall(GRAVITY, SCRAP_DRAG, nil, ground_under)
local FLOWN_OFF_MOTION = loose_pieces.fall(GRAVITY, LOOSE_DRAG, { kind = "lie", rest = LOOSE_REST }, ground_under)

-- How a donut floated off something under the water moves: up to `surface`, the height its middle rides at on the
-- surface, turning flat, then bobbing on it by `size`, for `float_seconds`, `seed` setting its bobbing apart from any
-- other's.
local function float_motion(
	surface: number,
	size: number,
	float_seconds: number,
	seed: number
): (piece: loose_pieces.Piece, dt: number) -> ()
	local surfaced = false
	return function(piece: loose_pieces.Piece, dt: number)
		local _, yaw, _ = piece.rotation:ToEulerAnglesYXZ()
		local flat = CFrame.Angles(0, yaw + piece.spin * dt, 0)
		if surfaced == false then
			piece.position += Vector3.new(piece.velocity.X, FLOAT_RISE, piece.velocity.Z) * dt
			piece.rotation = piece.rotation:Lerp(flat, 1 - math.exp(-FLOAT_LEVEL_RATE * dt))
			if piece.position.Y >= surface or piece.age >= FLOAT_MAX_RISE then
				surfaced = true
				piece.fade_at = piece.age + float_seconds
				piece.lifetime = piece.fade_at + piece.fade_time
			end
			return
		end
		piece.velocity *= math.exp(-0.3 * dt)
		local bob = math.sin(piece.age * TAU * FLOAT_BOB_RATE + seed) * FLOAT_BOB * size
		piece.position = Vector3.new(
			piece.position.X + piece.velocity.X * dt,
			surface + bob,
			piece.position.Z + piece.velocity.Z * dt
		)
		piece.rotation = flat
			* CFrame.Angles(
				math.sin(piece.age * 1.3 + seed) * FLOAT_ROCK,
				0,
				math.cos(piece.age * 1.1 + seed) * FLOAT_ROCK
			)
	end
end

-- The see-through each of `count` parts starts from as it fades: none.
local function opaque(count: number): { number }
	return table.create(count, 0)
end

-- One ring of a pop, worn at `frame`, `width` across: a puff of air, and `scraps` scraps of vinyl `scrap` long in the
-- first `stripes` of `colors`, torn from all round it.
local function pop_ring(
	frame: CFrame,
	width: number,
	colors: { Color3 },
	stripes: number,
	scrap: number,
	scraps: number
)
	local center = frame.Position
	local puff = effect_part("DonutPop", POP_COLOR)
	puff.Shape = Enum.PartType.Ball
	puff.Material = Enum.Material.Neon
	puff.Transparency = 0.5
	loose_pieces.add({
		parts = { puff },
		offsets = { CFrame.identity },
		transparencies = { 0.5 },
		position = center,
		rotation = CFrame.identity,
		velocity = Vector3.zero,
		spin_axis = Vector3.yAxis,
		spin = 0,
		half_height = 0,
		age = 0,
		lifetime = POP_TIME,
		fade_at = 0,
		fade_time = POP_TIME,
		resting = false,
		grow = { from = Vector3.one * width * 0.5, to = Vector3.one * width * 1.3 },
		motion = PUFF_MOTION,
	})

	for index = 1, scraps do
		local angle = (index - 1 + random:NextNumber(0, 0.6)) / scraps * TAU
		local out = frame:VectorToWorldSpace(Vector3.new(math.cos(angle), 0, math.sin(angle)))
		local part = effect_part("DonutScrap", colors[(index - 1) % stripes + 1])
		part.Size = Vector3.new(scrap * random:NextNumber(0.7, 1.3), scrap * 0.12, scrap * random:NextNumber(0.4, 0.8))
		local axis = random:NextUnitVector()
		loose_pieces.add({
			parts = { part },
			offsets = { CFrame.identity },
			transparencies = { 0 },
			position = center + out * width * 0.4,
			rotation = CFrame.fromAxisAngle(axis, random:NextNumber(0, TAU)),
			velocity = out * SCRAP_SPEED * random:NextNumber(0.6, 1.2)
				+ Vector3.yAxis * SCRAP_UP * random:NextNumber(0.6, 1.2),
			spin_axis = axis,
			spin = random:NextNumber(-SCRAP_SPIN, SCRAP_SPIN),
			half_height = 0,
			age = 0,
			lifetime = SCRAP_LIFETIME,
			fade_at = SCRAP_LIFETIME * 0.5,
			fade_time = SCRAP_LIFETIME * 0.5,
			resting = false,
			grow = nil,
			motion = SCRAP_MOTION,
		})
	end
end

-- Pops the donut's rings, worn at `frames`: they are gone, and in the place of each a puff of air and scraps of vinyl
-- fluttering off.
local function pop(donut: Donut, frames: { CFrame })
	local width = ART_WIDTH * donut.scale
	-- scraps in the donut's two stripe colours
	local colors = {}
	for _, part in donut.rings[1] do
		table.insert(colors, part.Color)
	end
	local stripes = math.min(2, #colors)
	local scrap = width * SCRAP_SIZE
	local scraps = math.max(SCRAPS_LEAST, math.ceil(SCRAPS / #frames))
	for _, frame in frames do
		pop_ring(frame, width, colors, stripes, scrap, scraps)
	end

	show(donut, false)
	donut.status = "off"
end

-- Lets the donut's rings, worn at `frames`, go under the water: their parts go loose and float up to lie on the
-- surface a while, and it gets new ones to reinflate.
local function float_away(donut: Donut, frames: { CFrame })
	local shape = donut.shape
	local half_height = shape.half_height * donut.scale
	local float_seconds = donut.settings.float_seconds
	local drift = donut.velocity * FLOAT_KEEP
	for index, parts in donut.rings do
		local frame = frames[index]
		-- the water's surface, or the ground where there is none over it (floated off by pow's `donut_float`)
		local surface = ground_under(frame.Position.X, frame.Position.Z) + half_height * FLOAT_RIDE
		loose_pieces.add({
			offsets = size_parts(parts, shape, donut.scale),
			transparencies = opaque(#parts),
			parts = loosen(parts),
			position = frame.Position,
			rotation = frame.Rotation,
			velocity = Vector3.new(drift.X, 0, drift.Z),
			spin_axis = Vector3.yAxis,
			spin = FLOAT_TURN * (if random:NextNumber() < 0.5 then -1 else 1),
			half_height = half_height,
			age = 0,
			lifetime = FLOAT_MAX_RISE + float_seconds + LOOSE_FADE,
			fade_at = FLOAT_MAX_RISE + float_seconds,
			fade_time = LOOSE_FADE,
			resting = false,
			grow = nil,
			motion = float_motion(surface, ART_WIDTH * donut.scale, float_seconds, random:NextNumber(0, TAU)),
		})
	end
	renew(donut)
end

-- Throws the donut's rings, worn at `frames`, off its aircraft: their parts go loose, and it gets new ones to
-- reinflate.
local function fly_off(donut: Donut, frames: { CFrame })
	local shape = donut.shape
	for index, parts in donut.rings do
		local frame = frames[index]
		local side = frame:VectorToWorldSpace(Vector3.new(random:NextNumber(-1, 1), 0, random:NextNumber(-1, 1)))
		local axis = random:NextUnitVector()
		loose_pieces.add({
			offsets = size_parts(parts, shape, donut.scale),
			transparencies = opaque(#parts),
			parts = loosen(parts),
			position = frame.Position,
			rotation = frame.Rotation,
			velocity = donut.velocity * LOOSE_KEEP + Vector3.yAxis * LOOSE_THROW_UP + side * LOOSE_THROW_SIDE,
			spin_axis = axis,
			spin = LOOSE_SPIN * random:NextNumber(0.6, 1.2),
			half_height = shape.half_height * donut.scale,
			age = 0,
			lifetime = LOOSE_LIFETIME,
			fade_at = LOOSE_LIFETIME - LOOSE_FADE,
			fade_time = LOOSE_FADE,
			resting = false,
			grow = nil,
			motion = FLOWN_OFF_MOTION,
		})
	end
	renew(donut)
end

local function remove(model: Model)
	local donut = donuts[model]
	if donut == nil then
		return
	end
	donuts[model] = nil
	for _, parts in donut.rings do
		for _, part in parts do
			part:Destroy()
		end
	end
end

-- How inflated a reinflating donut is, from nothing to a little past full size and back to it.
-- Which of `settings`' floats `model` wears: drawn by weight, but from its entity id, so it is the same every time and
-- for every player.
local function variant_of(model: Model, settings: DonutSettings): DonutVariant
	local variants = settings.variants
	local id = entity_attrs.id(model)
	local total = 0
	for _, variant in variants do
		total += variant.weight
	end
	-- Knuth's multiplicative hash, to spread neighbouring ids over the whole range
	local hashed = if typeof(id) == "number" then (id * 2654435761) % 4294967296 else 0
	local roll = hashed / 4294967296 * total
	for _, variant in variants do
		roll -= variant.weight
		if roll < 0 then
			return variant
		end
	end
	return variants[#variants]
end

local function growth(seconds: number): number
	local t = math.clamp(seconds / GROW_TIME, 0, 1)
	return math.sin(t * math.pi * 0.5) + GROW_OVERSHOOT * math.sin(t * math.pi)
end

-- Keeps `model`'s donut on it for this frame, as the server says it is (server/donuts.luau, through the `donut`,
-- `donut_shake` and `donut_event` attributes), so every player sees the same. `mounts` are where the middle of each of
-- its rings goes, turned the way the ring lies (its hole along their up), one for a unit's waist or an aircraft's
-- fuselage and a row down each side for a ship, and `hole` how wide each ring's hole is, in studs; `folder` is where
-- its parts go. With no `settings`, or not `wearing` (a blueprint, a wreck, or a skin with no donut), it has no donut.
local function step(
	model: Model,
	mounts: { CFrame },
	hole: number,
	settings: DonutSettings?,
	wearing: boolean,
	folder: Folder,
	dt: number
)
	if settings == nil or wearing == false or #mounts == 0 then
		remove(model)
		return
	end
	local variant = variant_of(model, settings)
	local shape = shape_for(variant.art)
	if shape == nil then
		return
	end
	local event = entity_attrs.text(model, "donut_event")
	local donut = donuts[model]
	if
		donut == nil
		or donut.settings ~= settings
		or donut.variant ~= variant
		or donut.folder ~= folder
		or #donut.rings ~= #mounts
	then
		remove(model)
		local rings = table.create(#mounts)
		for index in mounts do
			rings[index] = copy_parts(shape, folder)
		end
		donut = {
			model = model,
			settings = settings,
			variant = variant,
			shape = shape,
			folder = folder,
			rings = rings,
			-- a new donut inflates, on a unit just finished or just come into sight alike
			status = "growing",
			grown = 0,
			-- how it last came off is old news to something just seen
			event = if typeof(event) == "string" then event else nil,
			last_position = nil,
			velocity = Vector3.zero,
			scale = 1,
			sized = nil,
			painted = nil,
			shown = false,
			seed = random:NextNumber(0, 1000),
		}
		donuts[model] = donut
	end
	local current = donut :: Donut
	current.scale = hole / variant.hole

	local team_color = entity_attrs.color(model, "team_color") or NO_TEAM
	if current.painted ~= team_color then
		current.painted = team_color
		for _, parts in current.rings do
			paint(parts, shape, team_color)
		end
	end

	-- how fast it is going, from how far its first ring moved, which is what a donut flying off keeps
	local position = mounts[1].Position
	local last = current.last_position
	current.last_position = position
	if last ~= nil and dt > 0 then
		local moved = position - last
		if moved.Magnitude < MAX_FRAME_STEP then
			local blend = 1 - math.exp(-SPEED_SMOOTHING * dt)
			current.velocity = current.velocity:Lerp(moved / dt, blend)
		end
	end

	-- it came off: popped, flown off or floated off, where it is now. Until the server has said anything, it is on.
	local now_event = if typeof(event) == "string" then event else nil
	if now_event ~= current.event then
		current.event = now_event
		if now_event ~= nil and current.status ~= "off" then
			local how = string.match(now_event, ":(%a+)$")
			if how == "fly" then
				fly_off(current, mounts)
			elseif how == "float" then
				float_away(current, mounts)
			else
				pop(current, mounts)
			end
		end
	end
	local on = entity_attrs.flag(model, "donut") ~= false
	if on == false then
		current.status = "off"
		show(current, false)
		return
	end
	if current.status == "off" then
		current.status = "growing"
		current.grown = 0
	end

	local grown = 1
	if current.status == "growing" then
		current.grown += dt
		if current.grown >= GROW_TIME then
			current.status = "on"
		else
			grown = math.max(0.01, growth(current.grown))
		end
	end

	-- shaking: tipping and sliding about, as hard as the server says it is shaking
	local wobble = CFrame.identity
	local shake = entity_attrs.number(model, "donut_shake")
	local hard = if shake ~= nil then math.clamp(shake, 0, 1) else 0
	if hard > 0 then
		local t = os.clock() * SHAKE_FREQUENCY
		local seed = current.seed
		local tip = SHAKE_MAX_ANGLE * hard
		local slide = SHAKE_MAX_SLIDE * ART_WIDTH * current.scale * hard
		wobble = CFrame.new(math.noise(t, seed, 1) * slide, 0, math.noise(t, seed, 2) * slide)
			* CFrame.Angles(math.noise(t, seed, 3) * tip, math.noise(t, seed, 4) * tip, math.noise(t, seed, 5) * tip)
	end

	local scale = current.scale * grown
	local offsets: { CFrame } = {}
	if current.sized ~= scale then
		current.sized = scale
		for _, parts in current.rings do
			offsets = size_parts(parts, shape, scale)
		end
	else
		for index, piece in shape.pieces do
			offsets[index] = CFrame.new(piece.offset * scale) * piece.turn
		end
	end
	for ring, parts in current.rings do
		local frame = mounts[ring] * wobble
		for index, part in parts do
			part.CFrame = frame * offsets[index]
		end
	end
	show(current, true)
end

-- How far a ring of `settings`' float that `model` wears reaches out from its middle along its hole, in studs, when
-- its hole is `hole` wide: half the thickness of its tube, to hang it against a ship's side by.
local function tube(model: Model, settings: DonutSettings, hole: number): number
	return ART_TUBE * hole / variant_of(model, settings).hole
end

-- The donut `skin` puts on something of `kind`, if it puts one on.
local function donut_of(skin: Skin, kind: unknown): DonutSettings?
	local donut = skin.donut
	return if donut ~= nil and table.find(donut.kinds, kind :: any) ~= nil then donut else nil
end

-- Where the rings of `settings`' donut go on `model`, of `def`, with its body `body` in `frame`, and how wide each
-- one's hole is, in studs. An aircraft wears one round its fuselage, its hole facing the nose; a ship (not a
-- submarine, which wears one round its waist to lose when it dives) hangs a row of small ones flat against each side
-- of its hull; anything else wears one round its waist.
local function mounts_of(
	model: Model,
	def: EntityDef,
	body: art_pose.Body,
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
	if unit_defs.floats(def) and unit_defs.is_submarine(def) == false then
		local width = body.high.X - body.low.X
		local hole = settings.side_hole * width
		local reach = tube(model, settings, hole)
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

-- Keeps the donut `skin` puts on something of `def` (`model`) on it for this frame, if it puts one on: its rings where
-- `mounts_of` puts them round its body `body`, which is at `frame` this frame, in `folder`, while it is `wearing` one
-- at all (finished, not a blueprint or a wreck).
local function wear(
	model: Model,
	def: EntityDef,
	body: art_pose.Body,
	frame: CFrame,
	skin: Skin,
	wearing: boolean,
	folder: Folder,
	dt: number
)
	local settings = donut_of(skin, entity_attrs.kind(model))
	local mounts: { CFrame }, hole = {}, 0
	if settings ~= nil then
		mounts, hole = mounts_of(model, def, body, frame, settings)
	end
	step(model, mounts, hole, settings, wearing, folder, dt)
end

-- Loads the donut of every skin that has one, and returns once they are all loaded or failed, or `timeout` seconds
-- have gone by, so that nothing is seen without it.
local function preload(timeout: number)
	local names = {}
	for _, name in skins.names() do
		local donut = skins.get(name).donut
		if donut ~= nil then
			for _, variant in donut.variants do
				table.insert(names, variant.art)
			end
		end
	end
	art_models.preload(names, timeout)
end

return table.freeze({
	preload = preload,
	wear = wear,
	forget = remove,
})
