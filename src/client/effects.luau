-- Weapon visuals. The server decides hits and only tells clients where a shot went, so this is
-- cosmetic: a beam that fades out over a fraction of a second.

local Debris = game:GetService "Debris"
local ReplicatedStorage = game:GetService "ReplicatedStorage"
local TweenService = game:GetService "TweenService"
local RunService = game:GetService "RunService"
local Workspace = game:GetService "Workspace"

local types = require(ReplicatedStorage.Shared.types)
local config = require(ReplicatedStorage.Shared.config)
local heightmap = require(ReplicatedStorage.Shared.heightmap)
local projectile_mod = require(ReplicatedStorage.Shared.projectile)

local weapon_fired: RemoteEvent = ReplicatedStorage.Shared.WeaponFired

type FlyingProjectile = {
	part: Part,
	flight: projectile_mod.Flight,
	params: types.ProjectileParams,
}

-- How long a beam stays up when its weapon does not say, and how see-through it has become by the end.
local BEAM_LIFETIME = 0.18
local BEAM_FADE_TO = 0.5
local BEAM_THICKNESS = 0.25
local BLAST_LIFETIME = 0.6
local BLAST_COLOR = Color3.fromRGB(238, 60, 48)
local BLAST_HEIGHT = 3
-- A rocket the server has not reported back on is dropped after this long, in case its impact was lost.
local ROCKET_MAX_AGE = 35
-- Plasma is drawn glowing. Everything else that flies, rockets, missiles and bombs, is a casing of metal: plastic, and
-- a dull grey that does not light up.
local PLASMA_COLOR = Color3.fromRGB(255, 196, 96)
local CASING_COLOR = Color3.fromRGB(148, 154, 164)
local EXPLOSION_LIFETIME = 1

local TEAM_BEAM_COLORS: { [number]: Color3 } = {
	[1] = Color3.fromRGB(140, 200, 255),
	[2] = Color3.fromRGB(255, 150, 130),
	[config.SCAVENGER_TEAM] = Color3.fromRGB(206, 130, 255),
}

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
	slab.CFrame = CFrame.lookAt((from + to) / 2, Vector3.new(to.X, (from.Y + to.Y) / 2, to.Z))
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

	-- a small blast is over quickly
	local lifetime = EXPLOSION_LIFETIME * math.clamp(radius / 24, 0.35, 1)
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

local projectiles: { [number]: FlyingProjectile } = {}

local function launch_projectile(
	id: number,
	from: Vector3,
	direction: Vector3,
	params: types.ProjectileParams,
	aim: Vector3?
)
	local part = Instance.new "Part"
	part.Name = "Rocket"
	part.Anchored = true
	part.CanCollide = false
	part.CanQuery = false
	part.CanTouch = false
	part.CastShadow = false
	if params.plasma == true then
		part.Material = Enum.Material.Neon
		part.Color = PLASMA_COLOR
	else
		part.Material = Enum.Material.Plastic
		part.Color = CASING_COLOR
	end
	-- a missile is bigger, and is drawn as it leaves, pointing up
	part.Size = if params.missile ~= nil then Vector3.new(0.9, 0.9, 3.4) else Vector3.new(0.5, 0.5, 1.8)
	part.CFrame = CFrame.lookAt(from, from + (if params.missile ~= nil then Vector3.yAxis else direction))
	part.Parent = effects_folder()
	projectiles[id] = { part = part, flight = projectile_mod.launch(from, direction, params, aim), params = params }
end

local function remove_projectile(id: number)
	local projectile = projectiles[id]
	if projectile ~= nil then
		projectile.part:Destroy()
		projectiles[id] = nil
	end
end

-- Flies every projectile the same way the server does, so it is drawn where it really is without being told.
local function fly_projectiles(delta: number)
	for id, projectile in projectiles do
		projectile_mod.step(projectile.flight, projectile.params, delta)
		local at = projectile.flight.position
		local max_age = if projectile.params.missile ~= nil then config.MISSILE_MAX_AGE else ROCKET_MAX_AGE
		if projectile.flight.age > max_age or at.Y < heightmap.height_at(at.X, at.Z) - 2 then
			remove_projectile(id)
		else
			projectile.part.CFrame = CFrame.lookAt(at, at + projectile.flight.velocity)
		end
	end
end

local function init()
	RunService.Heartbeat:Connect(fly_projectiles)
	weapon_fired.OnClientEvent:Connect(function(shot: {
		from: Vector3,
		to: Vector3,
		team: number,
		radius: number?,
		explosion: number?,
		beam_time: number?,
		beam_thickness: number?,
		beam_color: Color3?,
		rocket: { id: number, from: Vector3, direction: Vector3, params: types.ProjectileParams, aim: Vector3? }?,
		impact: { id: number, at: Vector3, radius: number }?,
	})
		if shot.rocket ~= nil then
			launch_projectile(
				shot.rocket.id,
				shot.rocket.from,
				shot.rocket.direction,
				shot.rocket.params,
				shot.rocket.aim
			)
			return
		end
		if shot.impact ~= nil then
			remove_projectile(shot.impact.id)
			draw_explosion(shot.impact.at, shot.impact.radius * 2)
			return
		end
		if shot.explosion ~= nil then
			draw_explosion(shot.to, shot.explosion)
			return
		end
		if shot.radius ~= nil then
			draw_blast(shot.from, shot.to, shot.radius)
			return
		end
		local color = shot.beam_color or TEAM_BEAM_COLORS[shot.team]
		if color == nil then
			color = Color3.fromRGB(255, 255, 255)
		end
		draw_beam(shot.from, shot.to, color, shot.beam_thickness or BEAM_THICKNESS, shot.beam_time or BEAM_LIFETIME)
	end)
end

return table.freeze({
	init = init,
})
