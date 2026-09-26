-- Lights this client's view by the map's atmosphere (see shared/atmosphere.luau): the time of day, the light and the
-- shade, the haze, a tint over everything, and whatever weather is falling. It is only how things look, lit here on each
-- client, and nothing in the game reads any of it.
--
-- What a map leaves nil is atmosphere.DEFAULT's, which the server fills in; what neither says is put back to the scene
-- as it stands when this starts, before anything here has touched it.
--
-- The weather is a few particle emitters, each a box carried along with the camera: one in the air between the camera
-- and the ground it looks at, for what falls, and one lying on the ground it looks at, for what the weather does there
-- (rain splashing, snow and dust blown along, mist). However many units are on screen they cost the same few thousand
-- particles, and everything is drawn bigger and faster the farther out the camera is, so it reads the same at any zoom.
-- It drifts with the wind (as the server blows it, see server/wind.luau), and it comes and goes in gusts: a
-- slow swell and ebb that thickens what falls, drives it harder and, for some weather, darkens or clouds the whole view
-- while it lasts.
--
-- The wind is also Roblox's own here (Workspace.GlobalWind), which sways the grass on the terrain, on every map, BAR's
-- too: the game's wind as it is drawn (Client.wind), which the wind readout shows, so the grass leans the way the
-- turbines turn and the rain blows, and swings round with them as the wind changes rather than jumping.

local Lighting = game:GetService "Lighting"
local ReplicatedStorage = game:GetService "ReplicatedStorage"
local RunService = game:GetService "RunService"
local Workspace = game:GetService "Workspace"

local atmosphere = require(ReplicatedStorage.Shared.atmosphere)
local heightmap = require(ReplicatedStorage.Shared.heightmap)

local rts_camera = require(ReplicatedStorage.Client.camera)
local wind = require(ReplicatedStorage.Client.wind)
local world_fx = require(ReplicatedStorage.Client.world_fx)
local weather_looks = require(ReplicatedStorage.Client.weather_looks)

-- what a map asks for (not the Atmosphere instance, which is Roblox's haze)
type Settings = atmosphere.Atmosphere
type Layer = weather_looks.Layer
type Look = weather_looks.Look

-- The air layers fill a box between the camera and the ground it looks at: its middle SLAB_SHARE of the way out along
-- the line of sight, as wide as the view there and SLAB_MARGIN more, so the edges are not bare, and as deep as its
-- layer says (weather_looks.Layer.depth) and as tall as those shares of that distance. The particles are born anywhere in it, so they
-- are spread over the whole of the ground in view rather than bunched near the lens.
local SLAB_SHARE = 0.6
local SLAB_MARGIN = 1.3
local SLAB_HEIGHT = 0.45

local RENDER_STEP = "rts_weather"
local CORRECTION_NAME = "Atmospherics"

-- The ground layers lie on a patch as wide as the view where the camera looks and GROUND_MARGIN more, reaching
-- GROUND_REACH of the way to that point beyond it and GROUND_REACH short of it, since the far half of the view covers
-- more ground than the near.
local GROUND_MARGIN = 1.5
local GROUND_REACH = 1.1
-- How far the camera looks to the ground at its ordinary height, which is the distance the looks above are for.
local REFERENCE_DISTANCE = rts_camera.CAMERA_HEIGHT / math.sin(math.rad(-rts_camera.CAMERA_PITCH))
-- How much the zoom has to change before the particles are resized for it, as a share.
local RESCALE_STEP = 0.08
-- The biggest a particle is drawn (ParticleEmitter.Size stops at 100), and the most times as many as usual given off
-- to make up for it when zoomed far out.
local MAX_PARTICLE_SIZE = 100
local MAX_FILL = 6
-- How much of its squash a streak keeps with no wind at all (see squash_now), and how much that has to change before
-- the emitter is given the new one.
local STILL_SQUASH = 0.8
local SQUASH_STEP = 0.1
-- How much of a push up or down the screen a streak takes from the wind, and the least it runs down the screen, as a
-- share of its own fall (see streak_velocity).
local STREAK_VIEW_PUSH = 0.3
local STREAK_LEAST_FALL = 0.5
-- The biggest a part can be along any side, which the boxes of weather are held to when zoomed far out.
local MAX_PART_SIZE = 2048
-- How often the gusts are followed, in seconds, and how fast they come and go: a gust builds and dies away over some
-- ten or twenty seconds.
local GUST_INTERVAL = 0.1
local GUST_PACE = 0.07
-- Roblox's wind is the game's as drawn (Client.wind) times GRASS_WIND, which sways the grass about as hard as the wind
-- turns the turbines: gently in a light air, hard in a gale; it is only set again once it has moved this much.
local GRASS_WIND = 1.6
local GRASS_MIN_CHANGE = 0.1

-- The scene as it was lit before anything here touched it.
local lighting_base: LightingLook? = nil
local haze_base: HazeLook? = nil
-- what the map asks for now, and whether a change to it is already waiting to be lit
local current: Settings = {}
local refresh_pending = false

-- An emitter in the world, what it gives off and how much, and the zoom it is drawn for.
type Running = {
	layer: Layer,
	amount: number,
	part: Part,
	emitter: ParticleEmitter,
	scale: number,
	-- how many times as many it gives off, to make up for particles held down to the biggest the engine draws
	fill: number,
	-- the squash it is drawn with now, which a streak's is cut back from when the wind is light
	squashed: number,
}

local running: { Running } = {}
-- which weather and mist the running emitters are for, so they are only made again when that changes
local running_key: string? = nil
local running_look: Look? = nil
-- how far into its gusts the weather is, from nothing to the height of one, and when they were last followed
local gust = 0.5
local since_gust = 0
local gust_seed = math.random() * 100
-- the colour correction the map asks for, which the gusts move away from and back to
local correction_base = { tint = Color3.new(1, 1, 1), saturation = 0, contrast = 0 }

-- How Lighting lights the scene, of what a map may set.
type LightingLook = {
	clock_time: number,
	latitude: number,
	brightness: number,
	exposure: number,
	ambient: Color3,
	outdoor_ambient: Color3,
	sun_color: Color3,
}

-- How the haze (the Atmosphere) hangs over the distance, of what a map may set.
type HazeLook = {
	haze_color: Color3,
	decay_color: Color3,
	density: number,
	haze: number,
	glare: number,
}

local function lighting_now(): LightingLook
	return {
		clock_time = Lighting.ClockTime,
		latitude = Lighting.GeographicLatitude,
		brightness = Lighting.Brightness,
		exposure = Lighting.ExposureCompensation,
		ambient = Lighting.Ambient,
		outdoor_ambient = Lighting.OutdoorAmbient,
		sun_color = Lighting.ColorShift_Top,
	}
end

local function haze_now(haze: Atmosphere): HazeLook
	return {
		haze_color = haze.Color,
		decay_color = haze.Decay,
		density = haze.Density,
		haze = haze.Haze,
		glare = haze.Glare,
	}
end

-- Lights the scene as `given` says, and as `base` has it for what `given` leaves nil.
local function light(given: Settings, base: LightingLook)
	Lighting.ClockTime = given.clock_time or base.clock_time
	Lighting.GeographicLatitude = given.latitude or base.latitude
	Lighting.Brightness = given.brightness or base.brightness
	Lighting.ExposureCompensation = given.exposure or base.exposure
	Lighting.Ambient = given.ambient or base.ambient
	Lighting.OutdoorAmbient = given.outdoor_ambient or base.outdoor_ambient
	Lighting.ColorShift_Top = given.sun_color or base.sun_color
end

-- Hangs `haze` as `given` says, and as `base` has it for what `given` leaves nil.
local function hang_haze(haze: Atmosphere, given: Settings, base: HazeLook)
	haze.Color = given.haze_color or base.haze_color
	haze.Decay = given.decay_color or base.decay_color
	haze.Density = given.density or base.density
	haze.Haze = given.haze or base.haze
	haze.Glare = given.glare or base.glare
end

-- The haze the server hung in Lighting, with what it was like before this touched it taken the first time it is seen.
local function find_haze(): Atmosphere?
	local found = Lighting:FindFirstChildOfClass "Atmosphere"
	if found ~= nil and haze_base == nil then
		haze_base = haze_now(found)
	end
	return found
end

-- The colour correction, made when a map asks for one or has weather whose gusts move it, and taken away when neither.
local function correct(given: Settings)
	local existing = Lighting:FindFirstChild(CORRECTION_NAME)
	correction_base = {
		tint = given.tint or Color3.new(1, 1, 1),
		saturation = given.saturation or 0,
		contrast = given.contrast or 0,
	}
	if given.tint == nil and given.saturation == nil and given.contrast == nil and given.weather == nil then
		if existing ~= nil then
			existing:Destroy()
		end
		return
	end
	local correction: ColorCorrectionEffect
	if existing ~= nil then
		correction = existing :: ColorCorrectionEffect
	else
		correction = Instance.new "ColorCorrectionEffect"
		correction.Name = CORRECTION_NAME
		correction.Parent = Lighting
	end
	correction.TintColor = correction_base.tint
	correction.Saturation = correction_base.saturation
	correction.Contrast = correction_base.contrast
	correction.Brightness = 0
end

local function scaled(sequence: NumberSequence, by: number): NumberSequence
	local points = {}
	for _, point in sequence.Keypoints do
		table.insert(points, NumberSequenceKeypoint.new(point.Time, point.Value * by, point.Envelope * by))
	end
	return NumberSequence.new(points)
end

-- what Roblox's wind was last set to
local grass_wind = Vector3.zero

-- Roblox's wind, after the game's as it is drawn.
local function sway_grass()
	local grass = wind.now() * GRASS_WIND
	if (grass - grass_wind).Magnitude >= GRASS_MIN_CHANGE then
		grass_wind = grass
		Workspace.GlobalWind = grass
	end
end

-- How much of its usual self a layer is at the gust's height now, for a layer the gusts swell by `swell`.
local function gusting(swell: number): number
	return 1 - swell + 2 * swell * gust
end

-- A streak's own fall, turned to lie across the view rather than straight down. From the RTS camera, looking down at
-- fifty five degrees, the upright runs away toward a point at the foot of the screen, so rain falling straight down is
-- drawn as needles bursting out from there every which way. Turned square to the line of sight, and just as fast, it is
-- drawn as streaks running down the screen side by side, which reads as a steady downpour; the wind then leans them.
local function fall_on_screen(each: Layer): Vector3
	local camera = Workspace.CurrentCamera
	if each.streaks == false or camera == nil then
		return each.fall
	end
	local look = camera.CFrame.LookVector
	local across = each.fall - look * each.fall:Dot(look)
	if across.Magnitude < 1e-3 then
		return each.fall
	end
	return across.Unit * each.fall.Magnitude
end

-- A streak's way, pushed by the wind as it is seen. Any part of its motion toward or away from the camera draws the
-- streaks in perspective, fanning out from the point the view runs away to, so that rain blown straight at or away from
-- the camera bursts out of the middle of the screen like stars past a spaceship. So the push is kept square to the line
-- of sight: all of it that leans the rain across the screen, and only STREAK_VIEW_PUSH of what runs up and down it
-- (a wind blowing away from the camera slows the rain on the screen, one blowing toward it hurries it), and whatever
-- it does the rain still runs down the screen at no less than STREAK_LEAST_FALL of its own speed.
local function streak_velocity(each: Layer, push: Vector3): Vector3
	local camera = Workspace.CurrentCamera
	local own = fall_on_screen(each)
	if camera == nil then
		return own + push
	end
	local right = camera.CFrame.RightVector
	local up = camera.CFrame.UpVector
	local moved = own + right * push:Dot(right) + up * (push:Dot(up) * STREAK_VIEW_PUSH)
	local down_screen = -moved:Dot(up)
	local least = own.Magnitude * STREAK_LEAST_FALL
	if down_screen < least then
		moved -= up * (least - down_screen)
	end
	return moved
end

-- How far a streak is drawn out now: as far as its squash goes in a wind as fast as it falls, and back to STILL_SQUASH
-- of that when there is none, so that calm rain falls in short strokes rather than long needles.
local function squash_now(each: Layer): number
	local fall = each.fall.Magnitude
	local push = (wind.now() * each.drift).Magnitude
	local windy = if fall > 1e-3 then math.clamp(push / fall, 0, 1) else 1
	return each.squash * (STILL_SQUASH + (1 - STILL_SQUASH) * windy)
end

-- The way a layer's particles go now, in studs a second at the ordinary zoom: its own fall or flow, pushed by the wind,
-- all as hard as the gust drives it.
local function velocity_of(each: Layer): Vector3
	local blowing = wind.now()
	local push = blowing * each.drift * gusting(each.gust)
	if each.in_air and each.streaks then
		return streak_velocity(each, push)
	end
	if each.in_air then
		return fall_on_screen(each) + push
	end
	local along = if blowing.Magnitude > 1e-3 then blowing.Unit else Vector3.new(1, 0, 0)
	return along * each.flow * gusting(each.gust) + push
end

local function stop_weather()
	RunService:UnbindFromRenderStep(RENDER_STEP)
	for _, each in running do
		each.part:Destroy()
	end
	running = {}
	running_key = nil
	running_look = nil
end

-- A box that turns so its bottom face points along `velocity`, so that ParticleEmitter's Bottom sends what it gives
-- off that way, with `ahead` as the way the camera faces over the ground.
local function turned_along(center: Vector3, velocity: Vector3, ahead: Vector3): CFrame
	local down = if velocity.Magnitude > 1e-3 then velocity.Unit else Vector3.new(0, -1, 0)
	local side = ahead:Cross(down)
	if side.Magnitude < 1e-3 then
		side = ahead:Cross(Vector3.new(0, -1, 0))
	end
	return CFrame.fromMatrix(center, side.Unit, -down)
end

-- Follows the gusts: every emitter's rate and speed, and the view's colour correction, for how hard it is blowing now.
local function follow_gusts()
	local look = running_look
	gust = math.clamp(0.5 + 1.6 * math.noise(os.clock() * GUST_PACE, gust_seed), 0, 1)
	for _, each in running do
		each.emitter.Rate = each.layer.rate * each.amount * each.fill * gusting(each.layer.gust)
		local speed = velocity_of(each.layer).Magnitude * each.scale
		each.emitter.Speed = NumberRange.new(speed * 0.9, speed * 1.1)
		if each.layer.streaks then
			local squash = squash_now(each.layer)
			if math.abs(squash - each.squashed) > SQUASH_STEP then
				each.squashed = squash
				each.emitter.Squash = NumberSequence.new({
					NumberSequenceKeypoint.new(0, squash, each.layer.squash_give),
					NumberSequenceKeypoint.new(1, squash, each.layer.squash_give),
				})
			end
		end
	end
	local correction = Lighting:FindFirstChild(CORRECTION_NAME) :: ColorCorrectionEffect?
	if correction ~= nil and look ~= nil then
		local strength = gust * (current.weather_amount or 1)
		correction.TintColor = correction_base.tint:Lerp(look.gust_tint, math.clamp(look.gust_tinting * strength, 0, 1))
		correction.Brightness = look.gust_brightness * strength
		correction.Contrast = correction_base.contrast + look.gust_contrast * strength
	end
end

-- Carries every emitter along with the camera: the air layers between it and the ground it looks at, the ground
-- layers on that ground, each turned the way its particles go and drawn at the size for how far out the camera is.
local function carry(delta: number)
	local camera = Workspace.CurrentCamera
	if camera == nil or #running == 0 then
		return
	end
	local view = camera.CFrame
	local look = view.LookVector
	-- how far the line of sight runs before it meets the ground (near enough: to the height of the ground where it
	-- meets sea level), or the ordinary distance should it never
	local to_ground = REFERENCE_DISTANCE
	if look.Y < -0.05 then
		local at_sea = view.Position + look * (math.max(view.Position.Y, 0) / -look.Y)
		local ground = heightmap.height_at(at_sea.X, at_sea.Z)
		to_ground = math.max(view.Position.Y - ground, 1) / -look.Y
	end
	local by = math.clamp(to_ground / REFERENCE_DISTANCE, 0.25, 10)
	local aspect = if camera.ViewportSize.Y > 0 then camera.ViewportSize.X / camera.ViewportSize.Y else 16 / 9
	local half_view = math.tan(math.rad(camera.FieldOfView) / 2)
	local flat = Vector3.new(look.X, 0, look.Z)
	local ahead = if flat.Magnitude > 1e-3 then flat.Unit else Vector3.new(0, 0, -1)
	local target = view.Position + look * to_ground

	since_gust += delta
	local gusts_due = since_gust >= GUST_INTERVAL
	for _, each in running do
		if math.abs(by - each.scale) > each.scale * RESCALE_STEP then
			-- a particle can be drawn no bigger than the engine allows, so what would be bigger is drawn at that and
			-- more of them are given off to cover as much of the view
			local biggest = 0
			for _, point in each.layer.size.Keypoints do
				biggest = math.max(biggest, point.Value * by)
			end
			local shrink = if biggest > MAX_PARTICLE_SIZE then MAX_PARTICLE_SIZE / biggest else 1
			each.emitter.Size = scaled(each.layer.size, by * shrink)
			each.fill = math.min(1 / (shrink * shrink), MAX_FILL)
			each.scale = by
			gusts_due = true
		end
		local velocity = velocity_of(each.layer)
		-- how far the wind carries a particle across the ground in its life, half of which the box is moved back into
		-- the wind, so that what blows out of it is spread over the view rather than all piled downwind
		local lifetime = (each.layer.lifetime.Min + each.layer.lifetime.Max) / 2
		local upwind = -Vector3.new(velocity.X, 0, velocity.Z) * by * lifetime / 2
		if each.layer.in_air then
			local distance = to_ground * SLAB_SHARE
			local across = 2 * distance * half_view * SLAB_MARGIN
			each.part.Size = Vector3.new(
				math.min(across * aspect, MAX_PART_SIZE),
				math.min(to_ground * SLAB_HEIGHT, MAX_PART_SIZE),
				math.min(to_ground * each.layer.depth, MAX_PART_SIZE)
			)
			each.part.CFrame = turned_along(view.Position + look * distance + upwind, velocity, ahead)
		else
			-- flat on the ground, turned about the upright only, so it gives off along the ground
			local across = 2 * to_ground * half_view * aspect * GROUND_MARGIN
			local reach = to_ground * GROUND_REACH * 2
			local wide = math.min(math.max(across, reach), MAX_PART_SIZE)
			local height = each.layer.height * by
			each.part.Size = Vector3.new(wide, height, wide)
			local center = target + ahead * (to_ground * GROUND_REACH * 0.4) + upwind + Vector3.new(0, height / 2, 0)
			local along = Vector3.new(velocity.X, 0, velocity.Z)
			local facing = if along.Magnitude > 1e-3 then along.Unit else ahead
			each.part.CFrame = CFrame.lookAt(center, center + facing)
		end
	end
	if gusts_due then
		since_gust = 0
		follow_gusts()
	end
end

local function start_layer(each: Layer, amount: number): Running
	local part = world_fx.part "Weather"
	part.Transparency = 1
	local made = Instance.new "ParticleEmitter"
	made.Shape = Enum.ParticleEmitterShape.Box
	made.ShapeStyle = Enum.ParticleEmitterShapeStyle.Volume
	-- the air layers are turned so their bottom faces the way they fall; the ground layers face the way they blow
	made.EmissionDirection = if each.in_air then Enum.NormalId.Bottom else Enum.NormalId.Front
	made.Texture = each.texture
	made.Color = ColorSequence.new(each.color)
	made.Transparency = each.transparency
	made.Size = each.size
	made.Squash = NumberSequence.new({
		NumberSequenceKeypoint.new(0, each.squash, each.squash_give),
		NumberSequenceKeypoint.new(1, each.squash, each.squash_give),
	})
	made.Lifetime = each.lifetime
	made.SpreadAngle = Vector2.new(each.spread, each.spread)
	-- A streak lies along the way it moves, and a turn about that would spin each one off it at random, so that the
	-- rain is drawn as needles pointing every which way; only what is round or soft turns. It is turned a quarter
	-- once, though: VelocityParallel draws a particle's height square across its motion, so the height Squash
	-- draws out would lie across the way it falls, and calm rain falling down the screen would streak sideways.
	made.Rotation = if each.streaks then NumberRange.new(90) else NumberRange.new(0, 360)
	made.RotSpeed = if each.streaks then NumberRange.new(0) else NumberRange.new(-each.turn, each.turn)
	made.LightEmission = each.glow
	made.LightInfluence = 1 - each.glow
	made.Orientation = if each.streaks
		then Enum.ParticleOrientation.VelocityParallel
		else Enum.ParticleOrientation.FacingCamera
	made.Rate = 0
	made.Parent = part
	-- under the camera, so it is only ever this client's and nothing that looks through Workspace comes across it
	part.Parent = Workspace.CurrentCamera
	return { layer = each, amount = amount, part = part, emitter = made, scale = 1, fill = 1, squashed = each.squash }
end

-- Starts the weather and the mist `given` asks for, or stops them; the emitters are only made again when what they
-- give off changes, and otherwise only how much of it they give off is changed.
local function weather(given: Settings)
	local kind = given.weather
	local look = if kind ~= nil then weather_looks.LOOKS[kind] else nil
	if kind ~= nil and look == nil then
		warn(`there is no weather "{kind}"`)
	end
	local mist = math.max(given.mist or 0, 0)
	local mist_color = given.mist_color or weather_looks.MIST_COLOR
	if look == nil and mist <= 0 then
		stop_weather()
		return
	end
	local key = `{kind}/{mist > 0}/{mist_color}`
	if key ~= running_key then
		stop_weather()
		local amount = math.max(given.weather_amount or 1, 0)
		if look ~= nil then
			for _, each in look.layers do
				table.insert(running, start_layer(each, amount))
			end
		end
		if mist > 0 then
			table.insert(running, start_layer(weather_looks.mist_layer(mist_color), mist))
		end
		running_key = key
		running_look = look
		RunService:BindToRenderStep(RENDER_STEP, Enum.RenderPriority.Camera.Value + 1, carry)
	else
		for _, each in running do
			each.amount = if look ~= nil and table.find(look.layers, each.layer) ~= nil
				then math.max(given.weather_amount or 1, 0)
				else mist
		end
	end
	-- drawn at the size for the zoom, and set going, on the next frame
	for _, each in running do
		each.scale = 0
	end
end

local function refresh()
	refresh_pending = false
	local given = atmosphere.read()
	if lighting_base ~= nil then
		light(given, lighting_base)
	end
	local found = find_haze()
	if found ~= nil and haze_base ~= nil then
		hang_haze(found, given, haze_base)
	end
	current = given
	correct(given)
	weather(given)
end

-- Lights the view again once whatever is changing it has finished, since a new map sets every field one at a time.
local function refresh_soon()
	if refresh_pending == false then
		refresh_pending = true
		task.defer(refresh)
	end
end

local function init()
	lighting_base = lighting_now()
	find_haze()
	refresh()
	RunService.Heartbeat:Connect(sway_grass)
	-- the wind is read afresh as the gusts are followed, so a change to it needs nothing here
	atmosphere.changed(refresh_soon)
	-- the haze, should it only get here after this has started
	Lighting.ChildAdded:Connect(function(child: Instance)
		if child:IsA "Atmosphere" then
			refresh_soon()
		end
	end)
end

return table.freeze({
	init = init,
})
