-- Weapon visuals. The server decides hits and only tells clients where a shot went, so this is
-- cosmetic: beams that fade out over a fraction of a second, projectiles flown the way the server flies them and
-- drawn the way their def's `look` says, and the explosions they go off in. What each weapon is heard firing as is its
-- kind's (Shared.weapon_kinds' `sound`).

local Debris = game:GetService "Debris"
local Lighting = game:GetService "Lighting"
local ReplicatedStorage = game:GetService "ReplicatedStorage"
local RunService = game:GetService "RunService"

local types = require(ReplicatedStorage.Shared.types)
local tick_rate = require(ReplicatedStorage.Shared.tick_rate)
local heightmap = require(ReplicatedStorage.Shared.heightmap)
local projectile_mod = require(ReplicatedStorage.Shared.projectile)
local weapon_kinds = require(ReplicatedStorage.Shared.weapon_kinds)
local shot_events = require(ReplicatedStorage.Shared.shot_events)
local game_phase = require(ReplicatedStorage.Shared.game_phase)

local world = require(ReplicatedStorage.Client.world)
local charged_beam = require(ReplicatedStorage.Client.charged_beam)
local world_fx = require(ReplicatedStorage.Client.world_fx)
local sounds = require(ReplicatedStorage.ClientShared.sounds)
local palette = require(ReplicatedStorage.ClientShared.palette)
local frame_profile = require(ReplicatedStorage.Client.frame_profile)

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
	delivery: types.ProjectileDelivery,
	-- the entity this steers toward every frame, for a homing weapon (an AA missile, say): drawing it
	-- on a plain ballistic path would have it visibly miss a target the server's own copy is curving
	-- to hit, since the server steers the same way (projectile.home, as projectiles.tick does).
	homing_target_id: EntityId?,
	-- where that entity was last frame: the server knows how fast it is going, and the client works it out from this
	homing_target_last: Vector3?,
	-- for an anti-nuke's interceptor, the id of the nuke it chases, which it steers toward the same way
	homing_projectile_id: number?,
}

-- How a nuclear blast's first moments are drawn (`draw_nuke`): how hard the view is flashed and for how long, and the
-- flash and the fireball, how far above where it went off each is and how big, against the blast's radius, and how
-- long each part of them takes, the fireball's against its `slow`: how long it swells (rising `rise`) and how long it
-- then burns away.
type NukeLook = {
	flash_brightness: number,
	flash_contrast: number,
	flash_seconds: number,
	flash_ball: { lift: number, from: number, to: number, seconds: number },
	fireball: { lift: number, rise: number, from: number, to: number, grow: number, burn: number, brightness: number },
}

local WHITE = Color3.new(1, 1, 1)
-- How long a beam stays up when its weapon does not say, and how see-through it has become by the end.
local BEAM_LIFETIME = 0.18
local BEAM_FADE_TO = 0.5
local BEAM_THICKNESS = 0.25
local BLAST_LIFETIME = 0.6
local BLAST_HEIGHT = 3
-- How much longer than the server flies a projectile (`projectile.max_age`) one it has not reported back on is kept, in
-- case its impact was lost.
local IMPACT_GRACE = 5
-- Plasma is drawn glowing. Everything else that flies, rockets, missiles and bombs, is a casing of metal, a dull grey
-- that does not light up, with smooth faces rather than the studs a new part comes with.
local PLASMA_COLOR = Color3.fromRGB(255, 196, 96)
local CASING_COLOR = Color3.fromRGB(148, 154, 164)
-- A projectile BAR draws as a line (`line_thickness`) is a neon streak trailing back from its head, as long as the
-- ground it covers in STREAK_SECONDS, within bounds, in its look's colour or else this purple.
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
-- A fireball's colours: its body, its white-hot core, and its shockwave.
local FIRE_COLOR = Color3.fromRGB(255, 132, 40)
local FIRE_CORE_COLOR = Color3.fromRGB(255, 244, 214)
local SHOCKWAVE_COLOR = Color3.fromRGB(255, 200, 120)
-- An explosion drawn at least this big is heard as a big one; a smaller one is heard louder the bigger it is, within
-- these bounds of its sound's own volume. A nuke is the big sound played slow and loud.
local LARGE_EXPLOSION_RADIUS = 40
local SMALL_EXPLOSION_QUIETEST = 0.5
local SMALL_EXPLOSION_LOUDEST = 1.3
local NUKE_SOUND_PITCH = 0.5
local NUKE_SOUND_VOLUME = 2

-- An EMP blast: a pulse in the EMP's colour, and how many arcs of lightning it throws.
local EMP_ARCS = 7

-- A lightning gun's bolt: kinked every LIGHTNING_SEGMENT studs or so, each kink thrown off the straight line at random,
-- by at most LIGHTNING_JITTER of a segment's length, flickering out almost at once. Its sparks are thinner bolts of the
-- same. The colour is BAR's `rgbcolor` for the Thor's, 0.5 0.5 1.
local LIGHTNING_COLOR = Color3.fromRGB(128, 128, 255)
local LIGHTNING_LIFETIME = 0.15
local LIGHTNING_SEGMENT = 4
local LIGHTNING_MOST_SEGMENTS = 20
local LIGHTNING_JITTER = 0.4
local LIGHTNING_THICKNESS = 0.4
-- a spark is this much as thick as its bolt
local SPARK_THICKNESS = 0.5

-- The blast radius the timings of a nuclear explosion are for, the Apocalypse's. A bigger one lasts longer by the
-- square of how much bigger it is, as any explosion does (`dissipation_time`), within NUKE_SLOWEST.
local NUKE_REFERENCE_RADIUS = 35
local NUKE_SLOWEST = 2.5
-- The colours of a nuclear blast: the view tinted hot, its flash, its fire and where the fire burns out to, the fire
-- still in its cloud, the cloud's smoke and its churning, its shockwaves, and the scorch it leaves.
local NUKE_TINT = Color3.fromRGB(255, 236, 210)
local NUKE_FLASH_COLOR = Color3.fromRGB(255, 252, 240)
local NUKE_FIRE = Color3.fromRGB(255, 150, 60)
local NUKE_BURNT = Color3.fromRGB(255, 90, 30)
local NUKE_CORE = Color3.fromRGB(255, 190, 90)
local NUKE_SMOKE = Color3.fromRGB(82, 76, 72)
local NUKE_CHURN = Color3.fromRGB(120, 108, 100)
local NUKE_SHOCKWAVE = Color3.fromRGB(255, 226, 180)
local NUKE_SCORCH = Color3.fromRGB(28, 22, 20)
local NUKE_LIGHT_RANGE = 60

-- A nuke on the ground, and one caught by an interceptor and going off up in the air, which is a smaller flash.
local GROUND_NUKE: NukeLook = table.freeze({
	flash_brightness = 0.7,
	flash_contrast = 0.3,
	flash_seconds = 3,
	flash_ball = { lift = 0.5, from = 0.5, to = 3.5, seconds = 0.8 },
	fireball = { lift = 0.6, rise = 0.5, from = 0.6, to = 2.2, grow = 2.5, burn = 3, brightness = 12 },
})
local AIRBURST: NukeLook = table.freeze({
	flash_brightness = 0.5,
	flash_contrast = 0.2,
	flash_seconds = 2,
	flash_ball = { lift = 0, from = 0.3, to = 2.5, seconds = 0.6 },
	fireball = { lift = 0, rise = 0, from = 0.4, to = 1.4, grow = 1.5, burn = 2, brightness = 10 },
})

local emp_arc_roll = Random.new()
local lightning_roll = Random.new()

local function dissipation_time(radius: number): number
	local lifetime = EXPLOSION_LIFETIME * (radius / EXPLOSION_REFERENCE_RADIUS) ^ 2
	return math.clamp(lifetime, EXPLOSION_MIN_LIFETIME, EXPLOSION_MAX_LIFETIME)
end

-- A glowing part called `name` in `color`, `shape` if not a block, in the Effects folder: what every effect is made of.
local function glow(name: string, color: Color3, shape: Enum.PartType?): Part
	local part = world_fx.part(name)
	part.Color = color
	if shape ~= nil then
		part.Shape = shape
	end
	part.Parent = world_fx.folder()
	return part
end

-- A glowing stick from `from` to `to`, `thickness` across; nil where they are the same point.
local function stick(name: string, color: Color3, from: Vector3, to: Vector3, thickness: number): Part?
	local length = (to - from).Magnitude
	if length < 1e-3 then
		return nil
	end
	local part = glow(name, color)
	part.Size = Vector3.new(thickness, thickness, length)
	part.CFrame = CFrame.lookAt((from + to) / 2, to)
	return part
end

-- The beam stays up for `lifetime` seconds, fading a little as it goes, and is then gone.
local function draw_beam(from: Vector3, to: Vector3, color: Color3, thickness: number, lifetime: number)
	local beam = stick("LaserBeam", color, from, to, thickness)
	if beam ~= nil then
		world_fx.fade(beam, lifetime, { Transparency = BEAM_FADE_TO })
	end
end

-- The disintegrator: a rectangle in its colour from the shooter out to the end of its range, as wide as the area it
-- destroys, that fades out where it stood.
local function draw_blast(from: Vector3, to: Vector3, half_width: number)
	local length = (to - from).Magnitude
	if length < 1e-3 then
		return
	end
	local slab = glow("Disintegrator", palette.disintegrator)
	slab.Transparency = 0.15
	-- tall enough that hills in the way do not swallow it
	slab.Size = Vector3.new(half_width * 2, BLAST_HEIGHT, length)
	-- tilted along the shot, level from side to side
	slab.CFrame = CFrame.lookAt((from + to) / 2, to)
	world_fx.fade(slab, BLAST_LIFETIME, { Transparency = 1 })
end

-- A ball of `color` at `at`, `transparency` see-through, that swells from `from` to `to` across as it fades away over
-- `seconds`, easing out as `style` says.
local function burst(
	name: string,
	color: Color3,
	at: Vector3,
	transparency: number,
	from: number,
	to: number,
	seconds: number,
	style: Enum.EasingStyle?
)
	local ball = glow(name, color, Enum.PartType.Ball)
	ball.Transparency = transparency
	ball.Size = Vector3.one * from
	ball.Position = at
	world_fx.fade(ball, seconds, { Size = Vector3.one * to, Transparency = 1 }, style)
end

-- A ring of `color` lying flat at `at`, `transparency` see-through and `thickness` thick, that runs out from `from` to
-- `to` across as it fades away over `seconds`, after `delay`, easing out as `style` says.
local function shockwave(
	name: string,
	color: Color3,
	at: Vector3,
	transparency: number,
	thickness: number,
	from: number,
	to: number,
	seconds: number,
	style: Enum.EasingStyle?,
	delay: number?
)
	local ring = glow(name, color, Enum.PartType.Cylinder)
	ring.Transparency = transparency
	ring.Size = Vector3.new(thickness, from, from)
	ring.CFrame = world_fx.lying_flat(at)
	world_fx.fade(ring, seconds, { Size = Vector3.new(thickness, to, to), Transparency = 1 }, style, delay)
end

-- A death explosion: a fireball that swells to twice the blast radius, a white core that flashes and is
-- gone, and a shockwave that runs out along the ground past the edge of the blast.
local function draw_explosion(at: Vector3, radius: number)
	local lifetime = dissipation_time(radius)
	local centre = at + Vector3.new(0, radius * 0.3, 0)
	burst("Explosion", FIRE_COLOR, centre, 0.05, radius * 0.4, radius * 2, lifetime)
	burst("Explosion", FIRE_CORE_COLOR, centre, 0.05, radius * 0.3, radius * 1.3, lifetime * 0.4)
	shockwave(
		"Shockwave",
		SHOCKWAVE_COLOR,
		at + Vector3.new(0, 0.6, 0),
		0.3,
		0.5,
		radius * 0.5,
		radius * 2.8,
		lifetime * 0.8
	)
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
	local glow_look = look.light
	if glow_look ~= nil then
		local made = Instance.new "PointLight"
		made.Color = glow_look.color
		made.Range = glow_look.range
		made.Brightness = glow_look.brightness
		made.Parent = tail
		light = made
	end
	return emitters, trail, light, linger
end

-- An EMP blast of `radius`: a pale turquoise pulse that swells to the edge of the blast and fades, a white flash at its
-- heart, and arcs of lightning thrown out along the ground.
local function draw_emp(at: Vector3, radius: number)
	local lifetime = dissipation_time(radius)
	local centre = at + Vector3.new(0, radius * 0.2, 0)
	burst("EmpPulse", palette.emp, centre, 0.35, radius * 0.3, radius * 2, lifetime)
	burst("EmpFlash", WHITE, centre, 0, radius * 0.25, radius * 0.6, lifetime * 0.3)
	for _ = 1, EMP_ARCS do
		local angle = emp_arc_roll:NextNumber() * 2 * math.pi
		local reach = radius * emp_arc_roll:NextNumber(0.5, 1)
		local tip = at + Vector3.new(math.cos(angle) * reach, 0, math.sin(angle) * reach)
		tip = Vector3.new(tip.X, heightmap.height_at(tip.X, tip.Z) + 0.3, tip.Z)
		local arc = stick("EmpArc", palette.emp, centre, tip, 0.25)
		if arc ~= nil then
			world_fx.fade(arc, lifetime * 0.5, { Transparency = 1 })
		end
	end
end

-- A lightning gun's bolt: a jagged line from `from` to `to` that flickers out almost at once.
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
		local segment = stick("Lightning", LIGHTNING_COLOR, previous, point, thickness)
		if segment ~= nil then
			world_fx.fade(segment, LIGHTNING_LIFETIME, { Transparency = 1 })
		end
		previous = point
	end
end

-- How much longer than the Apocalypse's a nuclear blast of `radius` takes.
local function nuke_slow(radius: number): number
	return math.clamp((radius / NUKE_REFERENCE_RADIUS) ^ 2, 1 / NUKE_SLOWEST, NUKE_SLOWEST)
end

-- A nuclear blast's first moments, as `look` has them, of `radius` going off at `at`: everything goes white and hot for
-- a moment, a flash, and a fireball that swells, burns, and fades.
local function draw_nuke(at: Vector3, radius: number, look: NukeLook)
	local slow = nuke_slow(radius)
	local correction = Instance.new "ColorCorrectionEffect"
	correction.Name = "NuclearFlash"
	correction.Brightness = look.flash_brightness
	correction.Contrast = look.flash_contrast
	correction.TintColor = NUKE_TINT
	correction.Parent = Lighting
	world_fx.fade(correction, look.flash_seconds * slow, { Brightness = 0, Contrast = 0, TintColor = WHITE })

	local flash = look.flash_ball
	local flash_at = at + Vector3.new(0, radius * flash.lift, 0)
	burst("NuclearFlash", NUKE_FLASH_COLOR, flash_at, 0, radius * flash.from, radius * flash.to, flash.seconds)

	local fire = look.fireball
	local grow, burn = fire.grow * slow, fire.burn * slow
	local fire_at = at + Vector3.new(0, radius * fire.lift, 0)
	local fireball = glow("NuclearFireball", NUKE_FIRE, Enum.PartType.Ball)
	fireball.Size = Vector3.one * radius * fire.from
	fireball.Position = fire_at
	world_fx.tween(fireball, grow, {
		Size = Vector3.one * radius * fire.to,
		Position = fire_at + Vector3.new(0, radius * fire.rise, 0),
	})
	world_fx.fade(fireball, burn, { Transparency = 1, Color = NUKE_BURNT }, nil, grow)
	local heat = Instance.new "PointLight"
	heat.Color = NUKE_FIRE
	heat.Range = NUKE_LIGHT_RANGE
	heat.Brightness = fire.brightness
	heat.Parent = fireball
	world_fx.tween(heat, grow + burn - 0.5 * slow, { Brightness = 0 })
end

-- A nuclear blast of `radius` on the ground: the flash and the fireball (`draw_nuke`), a mushroom cloud that climbs
-- over it and darkens from fire to smoke as it goes, two shockwaves racing out along the ground far past the blast,
-- and a scorch left on the ground once it has all cleared.
local function draw_nuclear(at: Vector3, radius: number)
	local slow = nuke_slow(radius)
	local ground = Vector3.new(at.X, heightmap.height_at(at.X, at.Z), at.Z)
	draw_nuke(ground, radius, GROUND_NUKE)

	-- the stem climbs from the ground and the cap rides up on top of it, both darkening from fire to smoke, and then
	-- the whole of the cloud thins away
	local rise = 6 * slow
	local stem_height = radius * 4
	local stem = glow("NuclearStem", NUKE_FIRE, Enum.PartType.Cylinder)
	stem.Material = Enum.Material.SmoothPlastic
	stem.Size = Vector3.new(radius * 0.5, radius * 0.5, radius * 0.5)
	stem.CFrame = world_fx.lying_flat(ground + Vector3.new(0, radius * 0.25, 0))
	world_fx.tween(stem, rise, {
		Size = Vector3.new(stem_height, radius * 0.8, radius * 0.8),
		CFrame = world_fx.lying_flat(ground + Vector3.new(0, stem_height / 2, 0)),
		Color = NUKE_SMOKE,
	}, Enum.EasingStyle.Sine)
	world_fx.fade(stem, 8 * slow, { Transparency = 1 }, nil, rise)

	local cap = glow("NuclearCap", NUKE_FIRE)
	cap.Material = Enum.Material.SmoothPlastic
	local cap_shape = Instance.new "SpecialMesh"
	cap_shape.MeshType = Enum.MeshType.Sphere
	cap_shape.Parent = cap
	cap.Size = Vector3.new(radius * 2, radius * 1.1, radius * 2)
	cap.Position = ground + Vector3.new(0, radius, 0)
	world_fx.tween(cap, rise, {
		Size = Vector3.new(radius * 4.2, radius * 2, radius * 4.2),
		Position = ground + Vector3.new(0, stem_height + radius * 0.6, 0),
		Color = NUKE_SMOKE,
	}, Enum.EasingStyle.Sine)
	world_fx.fade(cap, 8 * slow, { Transparency = 1 }, nil, rise + slow)

	-- fire still burning inside the cap as it climbs
	local core = glow("NuclearCore", NUKE_CORE)
	cap_shape:Clone().Parent = core
	core.Size = cap.Size * 0.7
	core.Position = cap.Position
	core.Transparency = 0.2
	world_fx.fade(core, rise, {
		Size = Vector3.new(radius * 3, radius * 1.3, radius * 3),
		Position = ground + Vector3.new(0, stem_height + radius * 0.4, 0),
		Transparency = 1,
	}, Enum.EasingStyle.Sine)

	-- the cloud billows as it climbs
	local billow = Instance.new "Attachment"
	billow.Parent = cap
	local churn = puffs(billow, NUKE_CHURN, radius * 0.8, 2.5, 25, 4 * slow, false)
	churn.EmissionDirection = Enum.NormalId.Top
	churn.SpreadAngle = Vector2.new(80, 80)
	task.delay(rise + slow, function()
		churn.Enabled = false
	end)

	-- two shockwaves, the second slower and wider
	local waves_at = ground + Vector3.new(0, 0.8, 0)
	shockwave(
		"NuclearShockwave",
		NUKE_SHOCKWAVE,
		waves_at,
		0.3,
		0.6,
		radius,
		radius * 14,
		1.6 * slow,
		Enum.EasingStyle.Quart
	)
	shockwave(
		"NuclearShockwave",
		NUKE_SHOCKWAVE,
		waves_at,
		0.4,
		0.6,
		radius,
		radius * 22,
		3 * slow,
		Enum.EasingStyle.Quart,
		0.4 * slow
	)

	-- scorched ground, once the fire has gone
	local scorch = glow("NuclearScorch", NUKE_SCORCH, Enum.PartType.Cylinder)
	scorch.Material = Enum.Material.Slate
	scorch.Transparency = 1
	scorch.Size = Vector3.new(0.3, radius * 2.4, radius * 2.4)
	scorch.CFrame = world_fx.lying_flat(ground + Vector3.new(0, 0.25, 0))
	world_fx.tween(scorch, 2 * slow, { Transparency = 0.25 }, nil, slow)
	world_fx.fade(scorch, 10 * slow, { Transparency = 1 }, nil, rise + 10 * slow)
end

-- A nuke caught by an interceptor going off where it was, up in the air: the flash and the fireball (`draw_nuke`), a
-- shockwave swelling out all round, and a ball of smoke left to thin away. Nothing rises from the ground and nothing
-- scorches it.
local function draw_airburst(at: Vector3, radius: number)
	local slow = nuke_slow(radius)
	draw_nuke(at, radius, AIRBURST)
	burst("NuclearShockwave", NUKE_SHOCKWAVE, at, 0.6, radius, radius * 5, 1.4 * slow, Enum.EasingStyle.Quart)

	local smoke = glow("NuclearSmoke", NUKE_CHURN, Enum.PartType.Ball)
	smoke.Material = Enum.Material.SmoothPlastic
	smoke.Transparency = 1
	smoke.Size = Vector3.one * radius
	smoke.Position = at
	world_fx.tween(smoke, 1.5 * slow, { Transparency = 0.35, Size = Vector3.one * radius * 1.6 }, nil, slow)
	world_fx.fade(smoke, 6 * slow, { Transparency = 1, Size = Vector3.one * radius * 2.2 }, nil, 2.5 * slow)
end

local projectiles: { [number]: FlyingProjectile } = {}

-- Puts a projectile's part where its flight is: a casing is centred on it, and a streak trails back from it.
local function place_projectile(projectile: FlyingProjectile)
	local at = projectile.flight.position
	local velocity = projectile.flight.velocity
	local thickness = projectile.delivery.projectile.line_thickness
	if thickness == nil or velocity.Magnitude < 1e-3 then
		projectile.part.CFrame = CFrame.lookAt(at, at + velocity)
		return
	end
	local length = math.clamp(velocity.Magnitude * STREAK_SECONDS, STREAK_MIN_LENGTH, STREAK_MAX_LENGTH)
	projectile.part.Size = Vector3.new(thickness, thickness, length)
	projectile.part.CFrame = CFrame.lookAt(at - velocity.Unit * (length / 2), at)
end

-- Starts drawing a projectile the server has launched, flying it as the server does, of `delivery`, the delivery of the
-- weapon that fired it, `weapon`.
local function launch_projectile(event: shot_events.Launched, weapon: types.Weapon, delivery: types.ProjectileDelivery)
	local part = world_fx.part "Projectile"
	part.TopSurface = Enum.SurfaceType.Smooth
	part.BottomSurface = Enum.SurfaceType.Smooth
	local params = delivery.projectile
	local missile = delivery.kind == "missile"
	if params.line_thickness ~= nil then
		part.Color = STREAK_COLOR
	elseif weapon_kinds.get(weapon.kind).plasma == true then
		part.Color = PLASMA_COLOR
	else
		part.Material = Enum.Material.Metal
		part.Color = CASING_COLOR
	end
	-- a missile is bigger, and is drawn as it leaves, pointing up
	part.Size = if missile then Vector3.new(0.9, 0.9, 3.4) else Vector3.new(0.5, 0.5, 1.8)
	local look = params.look
	if look ~= nil then
		part.Size = look.size or part.Size
		part.Color = look.color or part.Color
		part.Material = look.material or part.Material
	end
	local from = event.from
	part.CFrame = CFrame.lookAt(from, from + (if missile then Vector3.yAxis else event.direction))
	local emitters, trail, light, linger = dress(part, look)
	part.Parent = world_fx.folder()
	-- it was fired partway through the server's tick, and has flown the rest of it already, as the server's copy has
	local flight = projectile_mod.launch(from, event.direction, delivery, event.shot, event.aim, event.inherited)
	if event.late > 0 then
		projectile_mod.step(flight, delivery, event.late)
	end
	local projectile: FlyingProjectile = {
		part = part,
		emitters = emitters,
		trail = trail,
		light = light,
		linger = linger,
		flight = flight,
		delivery = delivery,
		homing_target_id = event.homing_target_id,
		homing_target_last = nil,
		homing_projectile_id = event.homing_projectile_id,
	}
	projectiles[event.id] = projectile
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
	return projectile.delivery.projectile.look
end

-- Flies every projectile the same way the server does, so it is drawn where it really is without being told.
-- It flies them at the game's pace and not the clock's, so that they keep up with a game that is warping, in
-- steps no longer than the server's own so that a frame's worth of warped time does not fly them any differently.
-- The game's pace is what the server says (game_phase.sim_rate): 1 normally, more while it is warping ahead, and
-- nothing while it is paused.
local function fly_projectiles(real_delta: number)
	local elapsed = real_delta * game_phase.sim_rate()
	if elapsed <= 0 then
		return
	end
	local steps = math.ceil(elapsed / tick_rate.TICK_DELTA)
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
				projectile_mod.home(
					projectile.flight,
					projectile.delivery.projectile,
					target_position,
					target_velocity,
					delta
				)
			elseif nuke ~= nil then
				projectile_mod.home(
					projectile.flight,
					projectile.delivery.projectile,
					nuke.flight.position,
					nuke.flight.velocity,
					delta
				)
			end
			projectile_mod.step(projectile.flight, projectile.delivery, delta)
		end
		local at = projectile.flight.position
		-- a shell with a fuse is gone once it has burst (the server sends where, as an impact)
		local fuse = projectile.delivery.projectile.fuse
		-- anything else a little longer than the server flies it, so that the server's impact is what takes it down
		local max_age = if fuse ~= nil then fuse else projectile_mod.max_age(projectile.delivery) + IMPACT_GRACE
		if projectile.flight.age > max_age or at.Y < heightmap.height_at(at.X, at.Z) - 2 then
			remove_projectile(id)
		else
			place_projectile(projectile)
		end
	end
end

-- The sound of an explosion drawn `radius` across at `at`: under water (a torpedo's or a depth charge's), a muffled boom
-- of any size.
local function explosion_sound(at: Vector3, radius: number, underwater: boolean?)
	if underwater == true then
		local loudness =
			math.clamp(radius / EXPLOSION_REFERENCE_RADIUS, SMALL_EXPLOSION_QUIETEST, SMALL_EXPLOSION_LOUDEST)
		sounds.play_at("torpedo_hit", at, loudness)
	elseif radius >= LARGE_EXPLOSION_RADIUS then
		sounds.play_at("explosion_large", at)
	else
		local loudness =
			math.clamp(radius / EXPLOSION_REFERENCE_RADIUS, SMALL_EXPLOSION_QUIETEST, SMALL_EXPLOSION_LOUDEST)
		sounds.play_at("explosion_small", at, loudness)
	end
end

-- The sound of `weapon` firing, from `at`.
local function firing_sound(weapon: types.Weapon, at: Vector3)
	local sound = weapon_kinds.sound_of(weapon)
	sounds.play_at(sound.name, at, 1, sound.pitch)
end

-- A projectile was launched: it is drawn flying, and heard leaving, unless it is one of the shots a shell split into,
-- which leave nothing to be heard.
local function on_launched(event: shot_events.Launched)
	local weapon = shot_events.weapon_of(event, event.split)
	local delivery = weapon.delivery
	if delivery.kind == "beam" then
		return
	end
	launch_projectile(event, weapon, delivery)
	if event.split ~= true then
		firing_sound(weapon, event.from)
	end
end

-- A projectile went off. A piercing shot going off inside what it is going through flies on, and is not heard for
-- every time it does; anything else is gone, and goes off the way it looks (`ProjectileLook.explosion`).
local function on_impact(event: shot_events.Impact)
	if event.how == "through" then
		draw_explosion(event.at, event.radius * 2)
		return
	end
	local flying = projectiles[event.id]
	local underwater = flying ~= nil and flying.delivery.kind == "torpedo"
	local look = remove_projectile(event.id)
	if event.how == "airburst" then
		draw_airburst(event.at, event.radius)
		explosion_sound(event.at, event.radius)
	elseif look ~= nil and look.explosion == "nuclear" then
		draw_nuclear(event.at, event.radius)
		sounds.play_at("explosion_large", event.at, NUKE_SOUND_VOLUME, NUKE_SOUND_PITCH)
	elseif look ~= nil and look.explosion == "emp" then
		draw_emp(event.at, event.radius)
		explosion_sound(event.at, event.radius)
	else
		draw_explosion(event.at, event.radius * 2)
		explosion_sound(event.at, event.radius * 2, underwater)
	end
end

local function on_blast(event: shot_events.Blast)
	draw_explosion(event.at, event.radius)
	explosion_sound(event.at, event.radius)
end

local function on_sweep(event: shot_events.Sweep)
	draw_blast(event.from, event.to, event.radius)
	sounds.play_at("dgun", event.from)
end

-- The beam of the weapon that fired `fired`.
local function beam_of(fired: shot_events.Fired): types.Beam?
	local delivery = shot_events.weapon_of(fired).delivery
	return if delivery.kind == "beam" then delivery else nil
end

local function on_beam(event: shot_events.BeamFired)
	local beam = beam_of(event)
	if beam == nil then
		return
	end
	local color = charged_beam.color_of(beam.color, event.team)
	local thickness, lifetime = beam.thickness or BEAM_THICKNESS, beam.time or BEAM_LIFETIME
	if beam.charged == true then
		charged_beam.draw(event.from, event.to, color, thickness, lifetime)
	else
		draw_beam(event.from, event.to, color, thickness, lifetime)
	end
	firing_sound(shot_events.weapon_of(event), event.from)
end

local function on_lightning(event: shot_events.LightningFired)
	local beam = beam_of(event)
	if beam == nil then
		return
	end
	local thickness = beam.thickness or LIGHTNING_THICKNESS
	draw_bolt(event.from, event.to, thickness)
	for _, tip in event.sparks do
		draw_bolt(event.to, tip, thickness * SPARK_THICKNESS)
	end
	firing_sound(shot_events.weapon_of(event), event.from)
end

local function init()
	RunService.Heartbeat:Connect(frame_profile.wrap("projectiles", fly_projectiles))
	weapon_fired.OnClientEvent:Connect(function(event: shot_events.Event)
		if event.kind == "projectile" then
			on_launched(event)
		elseif event.kind == "impact" then
			on_impact(event)
		elseif event.kind == "blast" then
			on_blast(event)
		elseif event.kind == "sweep" then
			on_sweep(event)
		elseif event.kind == "beam" then
			on_beam(event)
		elseif event.kind == "lightning" then
			on_lightning(event)
		end
	end)
end

return table.freeze({
	init = init,
})
