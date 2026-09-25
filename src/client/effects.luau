-- Weapon visuals. The server decides hits and only tells clients where a shot went, so this is
-- cosmetic: beams that fade out over a fraction of a second, projectiles flown the way the server flies them and
-- drawn the way their def's `look` says, and the explosions they go off in.

local Debris = game:GetService "Debris"
local Lighting = game:GetService "Lighting"
local ReplicatedStorage = game:GetService "ReplicatedStorage"
local TweenService = game:GetService "TweenService"
local RunService = game:GetService "RunService"
local Workspace = game:GetService "Workspace"

local types = require(ReplicatedStorage.Shared.types)
local config = require(ReplicatedStorage.Shared.config)
local heightmap = require(ReplicatedStorage.Shared.heightmap)
local projectile_mod = require(ReplicatedStorage.Shared.projectile)

local world = require(ReplicatedStorage.Client.world)
local charged_beam = require(ReplicatedStorage.Client.charged_beam)
local sounds = require(ReplicatedStorage.Client.sounds)

local weapon_fired: RemoteEvent = ReplicatedStorage.Shared.WeaponFired

type EntityId = types.EntityId

type FlyingProjectile = {
	part: Part,
	-- what it leaves behind (`ProjectileLook`): a trail and puffs of flame and smoke, which are let fade out where
	-- they are when it is gone rather than vanishing with it, and how long the last of them lasts
	emitters: { ParticleEmitter },
	trail: Trail?,
	light: PointLight?,
	linger: number,
	flight: projectile_mod.Flight,
	params: types.ProjectileParams,
	-- the entity this steers toward every frame, for a homing weapon (an AA missile, say): drawing it
	-- on a plain ballistic path would have it visibly miss a target the server's own copy is curving
	-- to hit, since the server steers the same way (projectile.home, as projectiles.tick does).
	homing_target_id: EntityId?,
	-- where that entity was last frame: the server knows how fast it is going, and the client works it out from this
	homing_target_last: Vector3?,
	-- for an anti-nuke's interceptor, the id of the nuke it chases, which it steers toward the same way
	homing_projectile_id: number?,
}

-- How long a beam stays up when its weapon does not say, and how see-through it has become by the end.
local BEAM_LIFETIME = 0.18
local BEAM_FADE_TO = 0.5
local BEAM_THICKNESS = 0.25
local BLAST_LIFETIME = 0.6
local BLAST_COLOR = Color3.fromRGB(238, 60, 48)
local BLAST_HEIGHT = 3
-- A projectile the server has not reported back on is dropped after this long, in case its impact was lost.
local PROJECTILE_MAX_AGE = 35
-- Plasma is drawn glowing. Everything else that flies, rockets, missiles and bombs, is a casing of metal, a dull grey
-- that does not light up, with smooth faces rather than the studs a new part comes with.
local PLASMA_COLOR = Color3.fromRGB(255, 196, 96)
local CASING_COLOR = Color3.fromRGB(148, 154, 164)
-- A projectile that says how thick a line it is (`line_thickness`), an anti-air missile, is instead a purple
-- neon streak trailing back from its head, as long as the ground it covers in STREAK_SECONDS, within bounds.
local STREAK_COLOR = Color3.fromRGB(196, 92, 255)
local STREAK_SECONDS = 0.04
local STREAK_MIN_LENGTH = 1.5
local STREAK_MAX_LENGTH = 10
-- How long a blast of EXPLOSION_REFERENCE_RADIUS takes to die away, in seconds. Heat spreads out through the air
-- by diffusion, and the time it takes to spread across a distance grows with the square of it, so a blast's time
-- grows with the square of its size: twice as big, four times as long. The smallest are kept on screen long enough to
-- be seen, and the biggest are held to EXPLOSION_MAX_LIFETIME.
local EXPLOSION_LIFETIME = 1
local EXPLOSION_REFERENCE_RADIUS = 24
local EXPLOSION_MIN_LIFETIME = 0.35
local EXPLOSION_MAX_LIFETIME = 12
-- An explosion drawn at least this big is heard as a big one; a smaller one is heard louder the bigger it is, within
-- these bounds of its sound's own volume. A nuke is the big sound played slow and loud.
local LARGE_EXPLOSION_RADIUS = 40
local SMALL_EXPLOSION_QUIETEST = 0.5
local SMALL_EXPLOSION_LOUDEST = 1.3
local NUKE_SOUND_PITCH = 0.5
local NUKE_SOUND_VOLUME = 2
-- a missile's launch is the cannon's sound pitched up into more of a whoosh
local MISSILE_SOUND_PITCH = 1.5
-- a lightning bolt has no sound of its own yet, and is the laser's pitched down into a crack
local LIGHTNING_SOUND_PITCH = 0.55

local function dissipation_time(radius: number): number
	local lifetime = EXPLOSION_LIFETIME * (radius / EXPLOSION_REFERENCE_RADIUS) ^ 2
	return math.clamp(lifetime, EXPLOSION_MIN_LIFETIME, EXPLOSION_MAX_LIFETIME)
end

local function effects_folder(): Instance
	local folder = Workspace:FindFirstChild "Effects"
	if folder ~= nil then
		return folder
	end
	return Workspace
end

-- The beam stays up for `lifetime` seconds, fading a little as it goes, and is then gone.
local function draw_beam(from: Vector3, to: Vector3, color: Color3, thickness: number, lifetime: number)
	local offset = to - from
	local length = offset.Magnitude
	if length < 1e-3 then
		return
	end

	local beam = Instance.new "Part"
	beam.Name = "LaserBeam"
	beam.Anchored = true
	beam.CanCollide = false
	beam.CanQuery = false
	beam.CanTouch = false
	beam.CastShadow = false
	beam.Material = Enum.Material.Neon
	beam.Color = color
	beam.Size = Vector3.new(thickness, thickness, length)
	beam.CFrame = CFrame.lookAt(from + offset / 2, to)
	beam.Parent = effects_folder()

	TweenService:Create(beam, TweenInfo.new(lifetime), { Transparency = BEAM_FADE_TO }):Play()
	Debris:AddItem(beam, lifetime)
end

-- The disintegrator: a red rectangle from the shooter out to the end of its range, as wide as the
-- area it destroys, that fades out where it stood.
local function draw_blast(from: Vector3, to: Vector3, half_width: number)
	local length = (to - from).Magnitude
	if length < 1e-3 then
		return
	end
	local slab = Instance.new "Part"
	slab.Name = "Disintegrator"
	slab.Anchored = true
	slab.CanCollide = false
	slab.CanQuery = false
	slab.CanTouch = false
	slab.CastShadow = false
	slab.Material = Enum.Material.Neon
	slab.Color = BLAST_COLOR
	slab.Transparency = 0.15
	-- tall enough that hills in the way do not swallow it
	slab.Size = Vector3.new(half_width * 2, BLAST_HEIGHT, length)
	-- tilted along the shot, level from side to side
	slab.CFrame = CFrame.lookAt((from + to) / 2, to)
	slab.Parent = effects_folder()

	TweenService:Create(slab, TweenInfo.new(BLAST_LIFETIME), { Transparency = 1 }):Play()
	Debris:AddItem(slab, BLAST_LIFETIME)
end

-- A death explosion: a fireball that swells to twice the blast radius, a white core that flashes and is
-- gone, and a shockwave that runs out along the ground past the edge of the blast.
local function draw_explosion(at: Vector3, radius: number)
	local function ball(color: Color3, from_size: number, to_size: number, lifetime: number)
		local part = Instance.new "Part"
		part.Name = "Explosion"
		part.Shape = Enum.PartType.Ball
		part.Anchored = true
		part.CanCollide = false
		part.CanQuery = false
		part.CanTouch = false
		part.CastShadow = false
		part.Material = Enum.Material.Neon
		part.Color = color
		part.Transparency = 0.05
		part.Size = Vector3.one * from_size
		part.Position = at + Vector3.new(0, radius * 0.3, 0)
		part.Parent = effects_folder()

		local info = TweenInfo.new(lifetime, Enum.EasingStyle.Quad, Enum.EasingDirection.Out)
		TweenService:Create(part, info, { Size = Vector3.one * to_size, Transparency = 1 }):Play()
		Debris:AddItem(part, lifetime)
	end

	local lifetime = dissipation_time(radius)
	ball(Color3.fromRGB(255, 132, 40), radius * 0.4, radius * 2, lifetime)
	ball(Color3.fromRGB(255, 244, 214), radius * 0.3, radius * 1.3, lifetime * 0.4)

	local ring = Instance.new "Part"
	ring.Name = "Shockwave"
	ring.Shape = Enum.PartType.Cylinder
	ring.Anchored = true
	ring.CanCollide = false
	ring.CanQuery = false
	ring.CanTouch = false
	ring.CastShadow = false
	ring.Material = Enum.Material.Neon
	ring.Color = Color3.fromRGB(255, 200, 120)
	ring.Transparency = 0.3
	ring.Size = Vector3.new(0.5, radius * 0.5, radius * 0.5)
	-- a Cylinder part's flat faces point along X, so it is rolled to lie flat on the ground
	ring.CFrame = CFrame.new(at + Vector3.new(0, 0.6, 0)) * CFrame.Angles(0, 0, math.pi / 2)
	ring.Parent = effects_folder()

	local info = TweenInfo.new(lifetime * 0.8, Enum.EasingStyle.Quad, Enum.EasingDirection.Out)
	TweenService:Create(ring, info, { Size = Vector3.new(0.5, radius * 2.8, radius * 2.8), Transparency = 1 }):Play()
	Debris:AddItem(ring, lifetime)
end

-- A part for the effects below, which never gets in the way of anything.
local function effect_part(name: string, color: Color3, material: Enum.Material): Part
	local part = Instance.new "Part"
	part.Name = name
	part.Anchored = true
	part.CanCollide = false
	part.CanQuery = false
	part.CanTouch = false
	part.CastShadow = false
	part.Material = material
	part.Color = color
	return part
end

-- On the ground under `at`, `lift` above it, with a Cylinder part's flat faces turned up so it lies flat.
local function lying_flat(at: Vector3, lift: number): CFrame
	return CFrame.new(at.X, heightmap.height_at(at.X, at.Z) + lift, at.Z) * CFrame.Angles(0, 0, math.pi / 2)
end

local function tween(
	instance: Instance,
	seconds: number,
	goal: { [string]: any },
	style: Enum.EasingStyle?,
	delay: number?
)
	local info = TweenInfo.new(seconds, style or Enum.EasingStyle.Quad, Enum.EasingDirection.Out, 0, false, delay or 0)
	TweenService:Create(instance, info, goal):Play()
end

-- Puffs of `color` given off from `attachment` at `rate` a second, `size` across when they start and `grow` times
-- that by the time they are gone, `lifetime` seconds later. Glowing ones light up; smoke does not.
local function puffs(
	attachment: Attachment,
	color: Color3,
	size: number,
	grow: number,
	rate: number,
	lifetime: number,
	glowing: boolean
): ParticleEmitter
	local emitter = Instance.new "ParticleEmitter"
	emitter.Color = ColorSequence.new(color)
	emitter.Size = NumberSequence.new(size, size * grow)
	emitter.Transparency = NumberSequence.new(if glowing then 0 else 0.35, 1)
	emitter.LightEmission = if glowing then 1 else 0
	emitter.Lifetime = NumberRange.new(lifetime * 0.7, lifetime)
	emitter.Rate = rate
	emitter.Speed = if glowing then NumberRange.new(6, 10) else NumberRange.new(1, 3)
	emitter.SpreadAngle = Vector2.new(12, 12)
	emitter.Rotation = NumberRange.new(0, 360)
	emitter.RotSpeed = NumberRange.new(-40, 40)
	emitter.EmissionDirection = Enum.NormalId.Back
	emitter.Parent = attachment
	return emitter
end

-- Hangs on `part` whatever `look` gives it besides its body: the trail, the flame and smoke from its tail, and its
-- light. Also how long, once it is gone, the last of what it left behind takes to fade.
local function dress(part: Part, look: types.ProjectileLook?): ({ ParticleEmitter }, Trail?, PointLight?, number)
	local emitters: { ParticleEmitter } = {}
	if look == nil then
		return emitters, nil, nil, 0
	end
	local linger = 0
	-- its tail: a part looks along -Z, so behind it is +Z
	local tail = Instance.new "Attachment"
	tail.Name = "Tail"
	tail.Position = Vector3.new(0, 0, part.Size.Z / 2)
	tail.Parent = part

	local trail: Trail? = nil
	local ribbon = look.trail
	if ribbon ~= nil then
		local top = Instance.new "Attachment"
		top.Position = Vector3.new(0, ribbon.width / 2, part.Size.Z / 2)
		top.Parent = part
		local bottom = Instance.new "Attachment"
		bottom.Position = Vector3.new(0, -ribbon.width / 2, part.Size.Z / 2)
		bottom.Parent = part
		local made = Instance.new "Trail"
		made.Attachment0 = top
		made.Attachment1 = bottom
		made.FaceCamera = true
		made.Color = ColorSequence.new(ribbon.color)
		made.Transparency = NumberSequence.new(0.15, 1)
		made.WidthScale = NumberSequence.new(1, 0.4)
		made.Lifetime = ribbon.lifetime
		made.LightEmission = 0.3
		made.Parent = part
		trail = made
		linger = math.max(linger, ribbon.lifetime)
	end
	local flame = look.flame
	if flame ~= nil then
		table.insert(emitters, puffs(tail, flame.color, flame.size, 0.3, flame.rate, flame.lifetime, true))
		linger = math.max(linger, flame.lifetime)
	end
	local smoke = look.smoke
	if smoke ~= nil then
		table.insert(emitters, puffs(tail, smoke.color, smoke.size, 3, smoke.rate, smoke.lifetime, false))
		linger = math.max(linger, smoke.lifetime)
	end
	local light: PointLight? = nil
	local glow = look.light
	if glow ~= nil then
		local made = Instance.new "PointLight"
		made.Color = glow.color
		made.Range = glow.range
		made.Brightness = glow.brightness
		made.Parent = tail
		light = made
	end
	return emitters, trail, light, linger
end

-- An EMP blast of `radius`: a pale turquoise pulse that swells to the edge of the blast and fades, a white flash at its
-- heart, and arcs of lightning thrown out along the ground.
local EMP_COLOR = Color3.fromRGB(130, 215, 255)
local EMP_ARCS = 7
local emp_arc_roll = Random.new()
local function draw_emp(at: Vector3, radius: number)
	local lifetime = dissipation_time(radius)
	local centre = at + Vector3.new(0, radius * 0.2, 0)

	local pulse = effect_part("EmpPulse", EMP_COLOR, Enum.Material.Neon)
	pulse.Shape = Enum.PartType.Ball
	pulse.Transparency = 0.35
	pulse.Size = Vector3.one * radius * 0.3
	pulse.Position = centre
	pulse.Parent = effects_folder()
	tween(pulse, lifetime, { Size = Vector3.one * radius * 2, Transparency = 1 }, Enum.EasingStyle.Quad)
	Debris:AddItem(pulse, lifetime)

	local flash = effect_part("EmpFlash", Color3.new(1, 1, 1), Enum.Material.Neon)
	flash.Shape = Enum.PartType.Ball
	flash.Size = Vector3.one * radius * 0.25
	flash.Position = centre
	flash.Parent = effects_folder()
	tween(flash, lifetime * 0.3, { Size = Vector3.one * radius * 0.6, Transparency = 1 }, Enum.EasingStyle.Quad)
	Debris:AddItem(flash, lifetime * 0.3)

	for _ = 1, EMP_ARCS do
		local angle = emp_arc_roll:NextNumber() * 2 * math.pi
		local reach = radius * emp_arc_roll:NextNumber(0.5, 1)
		local tip = at + Vector3.new(math.cos(angle) * reach, 0, math.sin(angle) * reach)
		tip = Vector3.new(tip.X, heightmap.height_at(tip.X, tip.Z) + 0.3, tip.Z)
		local arc = effect_part("EmpArc", EMP_COLOR, Enum.Material.Neon)
		arc.Size = Vector3.new(0.25, 0.25, (tip - centre).Magnitude)
		arc.CFrame = CFrame.lookAt((centre + tip) / 2, tip)
		arc.Parent = effects_folder()
		tween(arc, lifetime * 0.5, { Transparency = 1 }, Enum.EasingStyle.Quad)
		Debris:AddItem(arc, lifetime * 0.5)
	end
end

-- A lightning gun's bolt: a jagged line from `from` to `to`, kinked every LIGHTNING_SEGMENT studs or so, each kink
-- thrown off the straight line at random, that flickers out almost at once. Its sparks are thinner bolts of the same.
-- The colour is BAR's `rgbcolor` for the Thor's, 0.5 0.5 1.
local LIGHTNING_COLOR = Color3.fromRGB(128, 128, 255)
local LIGHTNING_LIFETIME = 0.15
local LIGHTNING_SEGMENT = 4
local LIGHTNING_MOST_SEGMENTS = 20
-- how far a kink may be thrown off the line, as a fraction of the length of a segment
local LIGHTNING_JITTER = 0.4
local LIGHTNING_THICKNESS = 0.4
-- a spark is this much as thick as its bolt
local SPARK_THICKNESS = 0.5
local lightning_roll = Random.new()
local function draw_bolt(from: Vector3, to: Vector3, thickness: number)
	local offset = to - from
	local length = offset.Magnitude
	if length < 1e-3 then
		return
	end
	local count = math.clamp(math.ceil(length / LIGHTNING_SEGMENT), 2, LIGHTNING_MOST_SEGMENTS)
	local direction = offset.Unit
	local side = direction:Cross(Vector3.yAxis)
	side = if side.Magnitude < 1e-3 then Vector3.xAxis else side.Unit
	local up = side:Cross(direction)
	local spread = length / count * LIGHTNING_JITTER
	local previous = from
	for index = 1, count do
		local point = from + offset * (index / count)
		if index < count then
			point += side * lightning_roll:NextNumber(-spread, spread) + up * lightning_roll:NextNumber(-spread, spread)
		end
		local segment = effect_part("Lightning", LIGHTNING_COLOR, Enum.Material.Neon)
		segment.Size = Vector3.new(thickness, thickness, (point - previous).Magnitude)
		segment.CFrame = CFrame.lookAt((previous + point) / 2, point)
		segment.Parent = effects_folder()
		tween(segment, LIGHTNING_LIFETIME, { Transparency = 1 }, Enum.EasingStyle.Quad)
		Debris:AddItem(segment, LIGHTNING_LIFETIME)
		previous = point
	end
end

-- The blast radius the timings of a nuclear explosion below are for, the Apocalypse's. A bigger one lasts longer by
-- the square of how much bigger it is, as any explosion does (`dissipation_time`), within NUKE_SLOWEST.
local NUKE_REFERENCE_RADIUS = 35
local NUKE_SLOWEST = 2.5

-- A nuclear blast of `radius`: a flash that whites out the view, a fireball, a mushroom cloud that climbs over it and
-- darkens from fire to smoke as it goes, two shockwaves racing out along the ground far past the blast, and a scorch
-- left on the ground once it has all cleared.
local function draw_nuclear(at: Vector3, radius: number)
	local slow = math.clamp((radius / NUKE_REFERENCE_RADIUS) ^ 2, 1 / NUKE_SLOWEST, NUKE_SLOWEST)
	local folder = effects_folder()
	local ground = Vector3.new(at.X, heightmap.height_at(at.X, at.Z), at.Z)
	local fire = Color3.fromRGB(255, 150, 60)
	local smoke_color = Color3.fromRGB(82, 76, 72)

	-- the flash: everything goes white and hot for a moment
	local correction = Instance.new "ColorCorrectionEffect"
	correction.Name = "NuclearFlash"
	correction.Brightness = 0.7
	correction.Contrast = 0.3
	correction.TintColor = Color3.fromRGB(255, 236, 210)
	correction.Parent = Lighting
	tween(correction, 3 * slow, { Brightness = 0, Contrast = 0, TintColor = Color3.new(1, 1, 1) })
	Debris:AddItem(correction, 3 * slow)

	local flash = effect_part("NuclearFlash", Color3.fromRGB(255, 252, 240), Enum.Material.Neon)
	flash.Shape = Enum.PartType.Ball
	flash.Size = Vector3.one * radius * 0.5
	flash.Position = ground + Vector3.new(0, radius * 0.5, 0)
	flash.Parent = folder
	tween(flash, 0.8, { Size = Vector3.one * radius * 3.5, Transparency = 1 })
	Debris:AddItem(flash, 0.8)

	-- the fireball swells, burns, and fades into the cloud
	local fireball = effect_part("NuclearFireball", fire, Enum.Material.Neon)
	fireball.Shape = Enum.PartType.Ball
	fireball.Size = Vector3.one * radius * 0.6
	fireball.Position = ground + Vector3.new(0, radius * 0.6, 0)
	fireball.Parent = folder
	tween(
		fireball,
		2.5 * slow,
		{ Size = Vector3.one * radius * 2.2, Position = ground + Vector3.new(0, radius * 1.1, 0) }
	)
	tween(fireball, 3 * slow, { Transparency = 1, Color = Color3.fromRGB(255, 90, 30) }, nil, 2.5 * slow)
	local heat = Instance.new "PointLight"
	heat.Color = fire
	heat.Range = 60
	heat.Brightness = 12
	heat.Parent = fireball
	tween(heat, 5 * slow, { Brightness = 0 })
	Debris:AddItem(fireball, 5.5 * slow)

	-- the stem climbs from the ground and the cap rides up on top of it, both darkening from fire to smoke
	local rise = 6 * slow
	local stem_height = radius * 4
	local stem = effect_part("NuclearStem", fire, Enum.Material.SmoothPlastic)
	stem.Shape = Enum.PartType.Cylinder
	stem.Size = Vector3.new(radius * 0.5, radius * 0.5, radius * 0.5)
	stem.CFrame = CFrame.new(ground + Vector3.new(0, radius * 0.25, 0)) * CFrame.Angles(0, 0, math.pi / 2)
	stem.Parent = folder
	tween(stem, rise, {
		Size = Vector3.new(stem_height, radius * 0.8, radius * 0.8),
		CFrame = CFrame.new(ground + Vector3.new(0, stem_height / 2, 0)) * CFrame.Angles(0, 0, math.pi / 2),
		Color = smoke_color,
	}, Enum.EasingStyle.Sine)

	local cap = effect_part("NuclearCap", fire, Enum.Material.SmoothPlastic)
	local cap_shape = Instance.new "SpecialMesh"
	cap_shape.MeshType = Enum.MeshType.Sphere
	cap_shape.Parent = cap
	cap.Size = Vector3.new(radius * 2, radius * 1.1, radius * 2)
	cap.Position = ground + Vector3.new(0, radius, 0)
	cap.Parent = folder
	tween(cap, rise, {
		Size = Vector3.new(radius * 4.2, radius * 2, radius * 4.2),
		Position = ground + Vector3.new(0, stem_height + radius * 0.6, 0),
		Color = smoke_color,
	}, Enum.EasingStyle.Sine)

	-- fire still burning inside the cap as it climbs
	local core = effect_part("NuclearCore", Color3.fromRGB(255, 190, 90), Enum.Material.Neon)
	local core_shape = cap_shape:Clone()
	core_shape.Parent = core
	core.Size = cap.Size * 0.7
	core.Position = cap.Position
	core.Transparency = 0.2
	core.Parent = folder
	tween(core, rise, {
		Size = Vector3.new(radius * 3, radius * 1.3, radius * 3),
		Position = ground + Vector3.new(0, stem_height + radius * 0.4, 0),
		Transparency = 1,
	}, Enum.EasingStyle.Sine)
	Debris:AddItem(core, rise)

	-- the cloud billows as it climbs, and then the whole of it thins away
	local billow = Instance.new "Attachment"
	billow.Parent = cap
	local churn = puffs(billow, Color3.fromRGB(120, 108, 100), radius * 0.8, 2.5, 25, 4 * slow, false)
	churn.EmissionDirection = Enum.NormalId.Top
	churn.SpreadAngle = Vector2.new(80, 80)
	task.delay(rise + slow, function()
		churn.Enabled = false
	end)
	local gone = rise + 10 * slow
	tween(stem, 8 * slow, { Transparency = 1 }, nil, rise)
	tween(cap, 8 * slow, { Transparency = 1 }, nil, rise + slow)
	Debris:AddItem(stem, gone)
	Debris:AddItem(cap, gone)

	-- two shockwaves, the second slower and wider
	local waves = {
		{ reach = radius * 7, seconds = 1.6 * slow, delay = 0, transparency = 0.3 },
		{ reach = radius * 11, seconds = 3 * slow, delay = 0.4 * slow, transparency = 0.4 },
	}
	for _, wave in waves do
		local ring = effect_part("NuclearShockwave", Color3.fromRGB(255, 226, 180), Enum.Material.Neon)
		ring.Shape = Enum.PartType.Cylinder
		ring.Transparency = wave.transparency
		ring.Size = Vector3.new(0.6, radius, radius)
		ring.CFrame = lying_flat(ground, 0.8)
		ring.Parent = folder
		tween(
			ring,
			wave.seconds,
			{ Size = Vector3.new(0.6, wave.reach * 2, wave.reach * 2), Transparency = 1 },
			Enum.EasingStyle.Quart,
			wave.delay
		)
		Debris:AddItem(ring, wave.seconds + wave.delay)
	end

	-- scorched ground, once the fire has gone
	local scorch = effect_part("NuclearScorch", Color3.fromRGB(28, 22, 20), Enum.Material.Slate)
	scorch.Shape = Enum.PartType.Cylinder
	scorch.Transparency = 1
	scorch.Size = Vector3.new(0.3, radius * 2.4, radius * 2.4)
	scorch.CFrame = lying_flat(ground, 0.25)
	scorch.Parent = folder
	tween(scorch, 2 * slow, { Transparency = 0.25 }, nil, slow)
	tween(scorch, 10 * slow, { Transparency = 1 }, nil, gone)
	Debris:AddItem(scorch, gone + 10 * slow)
end

-- A nuke caught by an interceptor going off where it was, up in the air: the flash and the fireball, a shockwave
-- swelling out all round, and a ball of smoke left to thin away. Nothing rises from the ground and nothing scorches it.
local function draw_airburst(at: Vector3, radius: number)
	local slow = math.clamp((radius / NUKE_REFERENCE_RADIUS) ^ 2, 1 / NUKE_SLOWEST, NUKE_SLOWEST)
	local folder = effects_folder()
	local fire = Color3.fromRGB(255, 150, 60)

	local correction = Instance.new "ColorCorrectionEffect"
	correction.Name = "NuclearFlash"
	correction.Brightness = 0.5
	correction.Contrast = 0.2
	correction.TintColor = Color3.fromRGB(255, 236, 210)
	correction.Parent = Lighting
	tween(correction, 2 * slow, { Brightness = 0, Contrast = 0, TintColor = Color3.new(1, 1, 1) })
	Debris:AddItem(correction, 2 * slow)

	local flash = effect_part("NuclearFlash", Color3.fromRGB(255, 252, 240), Enum.Material.Neon)
	flash.Shape = Enum.PartType.Ball
	flash.Size = Vector3.one * radius * 0.3
	flash.Position = at
	flash.Parent = folder
	tween(flash, 0.6, { Size = Vector3.one * radius * 2.5, Transparency = 1 })
	Debris:AddItem(flash, 0.6)

	local fireball = effect_part("NuclearFireball", fire, Enum.Material.Neon)
	fireball.Shape = Enum.PartType.Ball
	fireball.Size = Vector3.one * radius * 0.4
	fireball.Position = at
	fireball.Parent = folder
	tween(fireball, 1.5 * slow, { Size = Vector3.one * radius * 1.4 })
	tween(fireball, 2 * slow, { Transparency = 1, Color = Color3.fromRGB(255, 90, 30) }, nil, 1.5 * slow)
	local heat = Instance.new "PointLight"
	heat.Color = fire
	heat.Range = 60
	heat.Brightness = 10
	heat.Parent = fireball
	tween(heat, 3 * slow, { Brightness = 0 })
	Debris:AddItem(fireball, 3.5 * slow)

	local wave = effect_part("NuclearShockwave", Color3.fromRGB(255, 226, 180), Enum.Material.Neon)
	wave.Shape = Enum.PartType.Ball
	wave.Transparency = 0.6
	wave.Size = Vector3.one * radius
	wave.Position = at
	wave.Parent = folder
	tween(wave, 1.4 * slow, { Size = Vector3.one * radius * 5, Transparency = 1 }, Enum.EasingStyle.Quart)
	Debris:AddItem(wave, 1.4 * slow)

	local smoke = effect_part("NuclearSmoke", Color3.fromRGB(120, 108, 100), Enum.Material.SmoothPlastic)
	smoke.Shape = Enum.PartType.Ball
	smoke.Transparency = 1
	smoke.Size = Vector3.one * radius
	smoke.Position = at
	smoke.Parent = folder
	tween(smoke, 1.5 * slow, { Transparency = 0.35, Size = Vector3.one * radius * 1.6 }, nil, slow)
	tween(smoke, 6 * slow, { Transparency = 1, Size = Vector3.one * radius * 2.2 }, nil, 2.5 * slow)
	Debris:AddItem(smoke, 8.5 * slow)
end

local projectiles: { [number]: FlyingProjectile } = {}

-- Puts a projectile's part where its flight is: a casing is centred on it, and a streak trails back from it.
local function place_projectile(projectile: FlyingProjectile)
	local at = projectile.flight.position
	local velocity = projectile.flight.velocity
	local thickness = projectile.params.line_thickness
	if thickness == nil or velocity.Magnitude < 1e-3 then
		projectile.part.CFrame = CFrame.lookAt(at, at + velocity)
		return
	end
	local length = math.clamp(velocity.Magnitude * STREAK_SECONDS, STREAK_MIN_LENGTH, STREAK_MAX_LENGTH)
	projectile.part.Size = Vector3.new(thickness, thickness, length)
	projectile.part.CFrame = CFrame.lookAt(at - velocity.Unit * (length / 2), at)
end

local function launch_projectile(
	id: number,
	from: Vector3,
	direction: Vector3,
	params: types.ProjectileParams,
	aim: Vector3?,
	inherited: Vector3?,
	late: number?,
	homing_target_id: EntityId?,
	homing_projectile_id: number?
)
	local part = Instance.new "Part"
	part.Name = "Projectile"
	part.Anchored = true
	part.CanCollide = false
	part.CanQuery = false
	part.CanTouch = false
	part.CastShadow = false
	part.TopSurface = Enum.SurfaceType.Smooth
	part.BottomSurface = Enum.SurfaceType.Smooth
	if params.line_thickness ~= nil then
		part.Material = Enum.Material.Neon
		part.Color = STREAK_COLOR
	elseif params.plasma == true then
		part.Material = Enum.Material.Neon
		part.Color = PLASMA_COLOR
	else
		part.Material = Enum.Material.Metal
		part.Color = CASING_COLOR
	end
	-- a missile is bigger, and is drawn as it leaves, pointing up
	part.Size = if params.missile ~= nil then Vector3.new(0.9, 0.9, 3.4) else Vector3.new(0.5, 0.5, 1.8)
	local look = params.look
	if look ~= nil then
		part.Size = look.size or part.Size
		part.Color = look.color or part.Color
		part.Material = look.material or part.Material
	end
	part.CFrame = CFrame.lookAt(from, from + (if params.missile ~= nil then Vector3.yAxis else direction))
	local emitters, trail, light, linger = dress(part, look)
	part.Parent = effects_folder()
	-- it was fired partway through the server's tick, and has flown the rest of it already, as the server's copy has
	local flight = projectile_mod.launch(from, direction, params, aim, inherited)
	if late ~= nil and late > 0 then
		projectile_mod.step(flight, params, late)
	end
	local projectile: FlyingProjectile = {
		part = part,
		emitters = emitters,
		trail = trail,
		light = light,
		linger = linger,
		flight = flight,
		params = params,
		homing_target_id = homing_target_id,
		homing_target_last = nil,
		homing_projectile_id = homing_projectile_id,
	}
	projectiles[id] = projectile
	if params.line_thickness ~= nil then
		place_projectile(projectile)
	end
end

-- Takes a projectile out of the air, and gives back how it was to look going off. What it left behind stays where it
-- is and fades on its own: the body goes at once, and the part carrying the trail and the puffs goes once the last of
-- them has.
local function remove_projectile(id: number): types.ProjectileLook?
	local projectile = projectiles[id]
	if projectile == nil then
		return nil
	end
	projectiles[id] = nil
	if projectile.linger <= 0 then
		projectile.part:Destroy()
	else
		projectile.part.Transparency = 1
		for _, emitter in projectile.emitters do
			emitter.Enabled = false
		end
		if projectile.trail ~= nil then
			projectile.trail.Enabled = false
		end
		if projectile.light ~= nil then
			projectile.light.Enabled = false
		end
		Debris:AddItem(projectile.part, projectile.linger)
	end
	return projectile.params.look
end

-- How many seconds of the game pass in a second of real time, as the server says (`sim_rate`): 1 normally, more
-- while it is warping ahead, and nothing while it is paused.
local function sim_rate(): number
	local rate = Workspace:GetAttribute "sim_rate"
	return if typeof(rate) == "number" then rate else 1
end

-- Flies every projectile the same way the server does, so it is drawn where it really is without being told.
-- It flies them at the game's pace and not the clock's, so that they keep up with a game that is warping, in
-- steps no longer than the server's own so that a frame's worth of warped time does not fly them any differently.
local function fly_projectiles(real_delta: number)
	local elapsed = real_delta * sim_rate()
	if elapsed <= 0 then
		return
	end
	local steps = math.ceil(elapsed / config.TICK_DELTA)
	local delta = elapsed / steps
	for id, projectile in projectiles do
		local target = if projectile.homing_target_id ~= nil then world.get(projectile.homing_target_id) else nil
		local target_position, target_velocity = Vector3.zero, Vector3.zero
		if target == nil then
			projectile.homing_target_id = nil
		else
			target_position = world.position_of(target)
			local last = projectile.homing_target_last
			if last ~= nil then
				target_velocity = (target_position - last) / elapsed
			end
			projectile.homing_target_last = target_position
		end
		local nuke = if projectile.homing_projectile_id ~= nil
			then projectiles[projectile.homing_projectile_id]
			else nil
		for _ = 1, steps do
			-- the server steers it the same way (projectile.home), so the drawn missile curves in step with the one that hits
			if target ~= nil then
				projectile_mod.home(projectile.flight, projectile.params, target_position, target_velocity, delta)
			elseif nuke ~= nil then
				projectile_mod.home(
					projectile.flight,
					projectile.params,
					nuke.flight.position,
					nuke.flight.velocity,
					delta
				)
			end
			projectile_mod.step(projectile.flight, projectile.params, delta)
		end
		local at = projectile.flight.position
		local max_age = if projectile.params.missile ~= nil then config.MISSILE_MAX_AGE else PROJECTILE_MAX_AGE
		if projectile.flight.age > max_age or at.Y < heightmap.height_at(at.X, at.Z) - 2 then
			remove_projectile(id)
		else
			place_projectile(projectile)
		end
	end
end

-- The sound of an explosion drawn `radius` across at `at`.
local function explosion_sound(at: Vector3, radius: number)
	if radius >= LARGE_EXPLOSION_RADIUS then
		sounds.play_at("explosion_large", at)
	else
		local loudness =
			math.clamp(radius / EXPLOSION_REFERENCE_RADIUS, SMALL_EXPLOSION_QUIETEST, SMALL_EXPLOSION_LOUDEST)
		sounds.play_at("explosion_small", at, loudness)
	end
end

local function init()
	RunService.Heartbeat:Connect(fly_projectiles)
	-- `lightning` is set for a lightning gun's bolt: where each of its sparks jumped to from where it struck
	weapon_fired.OnClientEvent:Connect(function(shot: {
		from: Vector3,
		to: Vector3,
		team: number,
		radius: number?,
		explosion: number?,
		beam_time: number?,
		beam_thickness: number?,
		beam_color: Color3?,
		charged: boolean?,
		lightning: { Vector3 }?,
		projectile: {
			id: number,
			from: Vector3,
			direction: Vector3,
			params: types.ProjectileParams,
			aim: Vector3?,
			inherited: Vector3?,
			late: number?,
			homing_target_id: EntityId?,
			homing_projectile_id: number?,
		}?,
		impact: { id: number, at: Vector3, radius: number, airburst: boolean?, through: boolean? }?,
	})
		if shot.projectile ~= nil then
			launch_projectile(
				shot.projectile.id,
				shot.projectile.from,
				shot.projectile.direction,
				shot.projectile.params,
				shot.projectile.aim,
				shot.projectile.inherited,
				shot.projectile.late,
				shot.projectile.homing_target_id,
				shot.projectile.homing_projectile_id
			)
			local params = shot.projectile.params
			-- anti-air is what is drawn as a streak
			if params.line_thickness ~= nil then
				sounds.play_at("anti_air", shot.projectile.from)
			else
				local pitch = if params.missile ~= nil then MISSILE_SOUND_PITCH else 1
				sounds.play_at("cannon", shot.projectile.from, 1, pitch)
			end
			return
		end
		-- a piercing shot going off inside what it is going through flies on, and is not heard for every time it does
		if shot.impact ~= nil and shot.impact.through == true then
			draw_explosion(shot.impact.at, shot.impact.radius * 2)
			return
		end
		if shot.impact ~= nil then
			local look = remove_projectile(shot.impact.id)
			if shot.impact.airburst == true then
				draw_airburst(shot.impact.at, shot.impact.radius)
				explosion_sound(shot.impact.at, shot.impact.radius)
			elseif look ~= nil and look.explosion == "nuclear" then
				draw_nuclear(shot.impact.at, shot.impact.radius)
				sounds.play_at("explosion_large", shot.impact.at, NUKE_SOUND_VOLUME, NUKE_SOUND_PITCH)
			elseif look ~= nil and look.explosion == "emp" then
				draw_emp(shot.impact.at, shot.impact.radius)
				explosion_sound(shot.impact.at, shot.impact.radius)
			else
				draw_explosion(shot.impact.at, shot.impact.radius * 2)
				explosion_sound(shot.impact.at, shot.impact.radius * 2)
			end
			return
		end
		if shot.explosion ~= nil then
			draw_explosion(shot.to, shot.explosion)
			explosion_sound(shot.to, shot.explosion)
			return
		end
		if shot.radius ~= nil then
			draw_blast(shot.from, shot.to, shot.radius)
			sounds.play_at("dgun", shot.from)
			return
		end
		if shot.lightning ~= nil then
			local thickness = shot.beam_thickness or LIGHTNING_THICKNESS
			draw_bolt(shot.from, shot.to, thickness)
			for _, tip in shot.lightning do
				draw_bolt(shot.to, tip, thickness * SPARK_THICKNESS)
			end
			sounds.play_at("laser", shot.from, 1, LIGHTNING_SOUND_PITCH)
			return
		end
		local color = charged_beam.color_of(shot.beam_color, shot.team)
		local thickness, lifetime = shot.beam_thickness or BEAM_THICKNESS, shot.beam_time or BEAM_LIFETIME
		if shot.charged == true then
			charged_beam.draw(shot.from, shot.to, color, thickness, lifetime)
		else
			draw_beam(shot.from, shot.to, color, thickness, lifetime)
		end
		sounds.play_at("laser", shot.from)
	end)
end

return table.freeze({
	init = init,
})
