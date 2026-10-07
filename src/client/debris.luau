-- The pieces of something that dies without leaving a wreck fly apart, tumble to the ground, and fade away. An aircraft
-- shot down in the air first falls out of the sky whole, tumbling and trailing smoke, and breaks up where it hits.
--
-- The server says when something has shattered (deaths.luau's `shatter`); art.luau hands over copies of the pieces of
-- art it was last drawn in, and they are flung out from the middle of its body, harder the more violent its death,
-- carrying whatever speed it had. It is only drawn: the pieces are anchored, client-only, and touch nothing, and the
-- ground they bounce on is the heightmap's (client/loose_pieces.luau).

local Debris = game:GetService "Debris"
local ReplicatedStorage = game:GetService "ReplicatedStorage"

local ground_levels = require(ReplicatedStorage.Shared.ground_levels)
local heightmap = require(ReplicatedStorage.Shared.heightmap)
local types = require(ReplicatedStorage.Shared.types)

local art = require(ReplicatedStorage.Client.art)
local world_fx = require(ReplicatedStorage.Client.world_fx)
local loose_pieces = require(ReplicatedStorage.Client.loose_pieces)

type EntityId = types.EntityId
type Piece = loose_pieces.Piece

local unit_shattered: RemoteEvent = ReplicatedStorage.Shared.UnitShattered

-- How fast a piece flies out across the ground and up, in studs a second, from the gentlest death to one of
-- FULL_SEVERITY or worse (severity as the server's `kill` has it, a percentage of the thing's health taken lately),
-- each piece somewhere between SPREAD_LOW and SPREAD_HIGH times that.
local OUT_SPEED_GENTLE = 8
local OUT_SPEED_VIOLENT = 26
local UP_SPEED_GENTLE = 12
local UP_SPEED_VIOLENT = 28
local FULL_SEVERITY = 100
local SPREAD_LOW = 0.6
local SPREAD_HIGH = 1.25
-- How fast a piece tumbles, in radians a second, at most and at least.
local SPIN_LOW = 3
local SPIN_HIGH = 11
-- How a piece falls: pulled down lighter than Roblox's own gravity, which reads as too heavy at this scale, and
-- bouncing, keeping some of its speed up off the ground and of its speed along it and its tumbling, until it comes down
-- too slowly to bounce and settles.
local FALL =
	loose_pieces.fall(80, 0, { kind = "bounce", keep_up = 0.35, keep_along = 0.55, settle = 4 }, heightmap.height_at)
-- How long a piece is whole, in seconds, and how long it then takes to fade away.
local FADE_AFTER = 1.2
local FADE_TIME = 0.9
-- The most pieces loose at once, so that a great many deaths together cost no more than this.
local MAX_PIECES = 800

-- How an aircraft shot down comes down: pulled down lighter than a piece, so that it arcs on along its way before it
-- drops, the air taking CRASH_DRAG of its speed each second, and rolling over at between CRASH_SPIN_LOW and
-- CRASH_SPIN_HIGH radians a second about roughly the way it was flying. It never falls for longer than CRASH_LONGEST
-- seconds, whatever is under it.
local CRASH_FALL = loose_pieces.fall(60, 0.3, nil, heightmap.height_at)
local CRASH_SPIN_LOW = 1.5
local CRASH_SPIN_HIGH = 4
local CRASH_LONGEST = 30
-- How violently it breaks up where it hits, as a death's severity, and how much of its speed its pieces carry on with.
local CRASH_SEVERITY = 60
local CRASH_CARRY = 0.4
-- The smoke it trails as it falls: its colour, how big a puff starts and how many times that it grows, how many puffs
-- a second, and how long each lasts, in seconds.
local CRASH_SMOKE_COLOR = Color3.fromRGB(58, 54, 52)
local CRASH_SMOKE_SIZE = 1.6
local CRASH_SMOKE_GROW = 3
local CRASH_SMOKE_RATE = 40
local CRASH_SMOKE_LIFETIME = 1.6
-- The fireball where it hits: from how big to how big against the aircraft's size (within CRASH_SIZE_LOW and
-- CRASH_SIZE_HIGH studs), over how many seconds.
local CRASH_FIRE_COLOR = Color3.fromRGB(255, 132, 40)
local CRASH_SIZE_LOW = 2
local CRASH_SIZE_HIGH = 12
local CRASH_FIRE_FROM = 0.4
local CRASH_FIRE_TO = 2.2
local CRASH_FIRE_TIME = 0.7

local random = Random.new()

local function random_axis(): Vector3
	local axis = random:NextUnitVector()
	return if axis.Magnitude > 1e-3 then axis else Vector3.yAxis
end

-- Flings `parts` out from `middle`, as violently as `severity` says, each carrying `inherited` speed too.
local function scatter(parts: { BasePart }, middle: Vector3, severity: number, inherited: Vector3)
	local room = MAX_PIECES - loose_pieces.count()
	local violence = math.clamp(severity / FULL_SEVERITY, 0, 1)
	local out_speed = OUT_SPEED_GENTLE + (OUT_SPEED_VIOLENT - OUT_SPEED_GENTLE) * violence
	local up_speed = UP_SPEED_GENTLE + (UP_SPEED_VIOLENT - UP_SPEED_GENTLE) * violence
	local parent = world_fx.folder "Debris"
	for _, part in parts do
		if room <= 0 then
			part:Destroy()
			continue
		end
		room -= 1
		-- out from the middle across the ground, or any way at all for a piece right over it
		local offset = part.Position - middle
		local across = Vector3.new(offset.X, 0, offset.Z)
		local direction = if across.Magnitude > 0.05
			then across.Unit
			else CFrame.Angles(0, random:NextNumber(0, 2 * math.pi), 0).LookVector
		local velocity = direction * out_speed * random:NextNumber(SPREAD_LOW, SPREAD_HIGH)
			+ Vector3.yAxis * up_speed * random:NextNumber(SPREAD_LOW, SPREAD_HIGH)
			+ inherited
		part.Anchored = true
		part.CanCollide = false
		part.CanQuery = false
		part.CanTouch = false
		part.Parent = parent
		local size = part.Size
		loose_pieces.add({
			parts = { part },
			offsets = { CFrame.identity },
			transparencies = { part.Transparency },
			position = part.Position,
			rotation = part.CFrame.Rotation,
			velocity = velocity,
			spin_axis = random_axis(),
			spin = random:NextNumber(SPIN_LOW, SPIN_HIGH),
			half_height = math.min(size.X, size.Y, size.Z) / 2,
			age = 0,
			lifetime = FADE_AFTER + FADE_TIME,
			fade_at = FADE_AFTER,
			fade_time = FADE_TIME,
			resting = false,
			grow = nil,
			motion = FALL,
		})
	end
end

-- The ground, or the water over it, under (x, z): where something falling out of the sky comes down.
local function surface_at(x: number, z: number): number
	return math.max(heightmap.height_at(x, z), ground_levels.WATER_LEVEL)
end

-- An invisible part that trails smoke wherever it goes.
local function smoke_trail(): (Part, ParticleEmitter)
	local carrier = world_fx.part "CrashSmoke"
	carrier.Transparency = 1
	carrier.Size = Vector3.one * 0.2
	local attachment = Instance.new "Attachment"
	attachment.Parent = carrier
	local emitter = Instance.new "ParticleEmitter"
	emitter.Color = ColorSequence.new(CRASH_SMOKE_COLOR)
	emitter.Size = NumberSequence.new(CRASH_SMOKE_SIZE, CRASH_SMOKE_SIZE * CRASH_SMOKE_GROW)
	emitter.Transparency = NumberSequence.new(0.25, 1)
	emitter.LightEmission = 0
	emitter.Lifetime = NumberRange.new(CRASH_SMOKE_LIFETIME * 0.7, CRASH_SMOKE_LIFETIME)
	emitter.Rate = CRASH_SMOKE_RATE
	emitter.Speed = NumberRange.new(0.5, 2)
	emitter.SpreadAngle = Vector2.new(180, 180)
	emitter.Rotation = NumberRange.new(0, 360)
	emitter.RotSpeed = NumberRange.new(-40, 40)
	emitter.Parent = attachment
	return carrier, emitter
end

-- A fireball `size` across (as big as what hit), where it hit at `at`.
local function draw_crash_fire(at: Vector3, size: number)
	local ball = world_fx.part "CrashFire"
	ball.Shape = Enum.PartType.Ball
	ball.Color = CRASH_FIRE_COLOR
	ball.Transparency = 0.05
	ball.Size = Vector3.one * size * CRASH_FIRE_FROM
	ball.Position = at
	ball.Parent = world_fx.folder()
	world_fx.fade(ball, CRASH_FIRE_TIME, { Size = Vector3.one * size * CRASH_FIRE_TO, Transparency = 1 })
end

-- Brings `parts` down out of the sky as one, from `middle`, going at `inherited` as it was flying: it rolls over and
-- trails smoke as it falls, and where it hits the ground or the water it goes up in a fireball and flies to pieces.
local function crash(parts: { BasePart }, middle: Vector3, inherited: Vector3)
	local parent = world_fx.folder "Debris"
	local body: { BasePart } = {}
	local offsets: { CFrame } = {}
	local transparencies: { number } = {}
	local size = CRASH_SIZE_LOW
	local from = CFrame.new(middle)
	for _, part in parts do
		part.Anchored = true
		part.CanCollide = false
		part.CanQuery = false
		part.CanTouch = false
		part.Parent = parent
		table.insert(body, part)
		table.insert(offsets, from:ToObjectSpace(part.CFrame))
		table.insert(transparencies, part.Transparency)
		local extent = part.Size
		size = math.max(size, 2 * (part.Position - middle).Magnitude + math.max(extent.X, extent.Y, extent.Z))
	end
	size = math.min(size, CRASH_SIZE_HIGH)
	local carrier, smoke = smoke_trail()
	carrier.CFrame = from
	carrier.Parent = parent
	table.insert(body, carrier)
	table.insert(offsets, CFrame.identity)
	table.insert(transparencies, 1)

	-- rolling about the way it was flying, give or take
	local flat = Vector3.new(inherited.X, 0, inherited.Z)
	local heading = if flat.Magnitude > 0.1 then flat.Unit else random_axis()
	local roll_axis = heading + random:NextUnitVector() * 0.35
	local spin_axis = if roll_axis.Magnitude > 1e-3 then roll_axis.Unit else Vector3.yAxis

	local function falling(piece: Piece, dt: number)
		CRASH_FALL(piece, dt)
		local position = piece.position
		local ground = surface_at(position.X, position.Z)
		if position.Y > ground then
			return
		end
		-- down: the smoke hangs where it hit and thins away, and the rest goes up and flies to pieces
		local at = Vector3.new(position.X, ground, position.Z)
		local frame = CFrame.new(at) * piece.rotation
		smoke.Enabled = false
		carrier.CFrame = frame
		Debris:AddItem(carrier, CRASH_SMOKE_LIFETIME)
		local wreckage: { BasePart } = {}
		for index, part in piece.parts do
			if part ~= carrier then
				part.CFrame = frame * piece.offsets[index]
				table.insert(wreckage, part)
			end
		end
		draw_crash_fire(at, size)
		piece.parts = {}
		piece.offsets = {}
		piece.transparencies = {}
		piece.resting = true
		piece.lifetime = piece.age
		scatter(wreckage, at, CRASH_SEVERITY, piece.velocity * CRASH_CARRY)
	end

	loose_pieces.add({
		parts = body,
		offsets = offsets,
		transparencies = transparencies,
		position = middle,
		rotation = CFrame.identity,
		velocity = inherited,
		spin_axis = spin_axis,
		spin = random:NextNumber(CRASH_SPIN_LOW, CRASH_SPIN_HIGH),
		half_height = 0,
		age = 0,
		lifetime = CRASH_LONGEST,
		fade_at = CRASH_LONGEST,
		fade_time = FADE_TIME,
		resting = false,
		grow = nil,
		motion = falling,
	})
end

local function fling(id: EntityId, severity: number, inherited: Vector3, falls: boolean)
	local parts, middle = art.shatter(id)
	if parts == nil or middle == nil then
		return
	end
	if falls then
		crash(parts, middle, inherited)
	else
		scatter(parts, middle, severity, inherited)
	end
end

local function init()
	unit_shattered.OnClientEvent:Connect(
		function(event: { id: EntityId, severity: number, velocity: Vector3?, falls: boolean? })
			fling(event.id, event.severity, event.velocity or Vector3.zero, event.falls == true)
		end
	)
end

return table.freeze({
	init = init,
})
