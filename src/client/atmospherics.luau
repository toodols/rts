-- Lights this client's view by the map's atmosphere (see shared/atmosphere.luau): the time of day, the light and the
-- shade, the haze, a tint over everything, and whatever weather is falling. It is only how things look, lit here on each
-- client, and nothing in the game reads any of it.
--
-- The scene as the server lights it without a map's say (see server/lighting.luau) is taken as it stands when this
-- starts, before anything here has touched it, and whatever the map leaves nil is put back to that; so a map that sets
-- nothing looks exactly as maps always have.
--
-- The weather is a few particle emitters, each a box carried along with the camera: one in the air between the camera
-- and the ground it looks at, for what falls, and one lying on the ground it looks at, for what the weather does there
-- (rain splashing, snow and dust blown along, mist). However many units are on screen they cost the same few thousand
-- particles, and everything is drawn bigger and faster the farther out the camera is, so it reads the same at any zoom.
-- It drifts with the wind (the `wind` attribute of Workspace, see server/wind.luau), and it comes and goes in gusts: a
-- slow swell and ebb that thickens what falls, drives it harder and, for some weather, darkens or clouds the whole view
-- while it lasts.
--
-- The wind is also Roblox's own here (Workspace.GlobalWind), which sways the grass on the terrain, on every map, BAR's
-- too: the game's wind eased toward as the wind readout eases toward it, so the grass leans the way the turbines turn
-- and the rain blows, and swings round with them as the wind changes rather than jumping.

local Lighting = game:GetService "Lighting"
local ReplicatedStorage = game:GetService "ReplicatedStorage"
local RunService = game:GetService "RunService"
local Workspace = game:GetService "Workspace"

local atmosphere = require(ReplicatedStorage.Shared.atmosphere)
local config = require(ReplicatedStorage.Shared.config)
local heightmap = require(ReplicatedStorage.Shared.heightmap)

-- what a map asks for (not the Atmosphere instance, which is Roblox's haze)
type Settings = atmosphere.Atmosphere
type Weather = atmosphere.Weather

local RENDER_STEP = "rts_weather"
local CORRECTION_NAME = "Atmospherics"

-- One emitter's worth of weather, as it is seen from the ordinary height of the camera (config.CAMERA_HEIGHT); from
-- higher up it is all drawn bigger and moves faster by as much as the ground is farther away, so that it looks the
-- same on screen at any zoom.
--
-- `in_air` layers fill the air between the camera and the ground and move by `fall`, in studs a second, pushed sideways
-- by `drift` times the wind. The others lie on the ground where the camera looks, `height` studs deep, and blow along
-- the ground the way the wind does, at `flow` studs a second and `drift` times the wind more.
--
-- `rate` is how many a second on an ordinary day, `size` is across, and `squash` draws it out along the way it moves
-- (as ParticleEmitter.Squash), so that rain falls in streaks. `turn` is how many degrees a second it tumbles, and
-- `glow` how much it lights itself. `gust` is how much the gusts swell it: at 0.5 it runs from half as much as usual,
-- and half as fast a push from the wind, to half as much again.
type Layer = {
	texture: string,
	color: Color3,
	transparency: NumberSequence,
	size: NumberSequence,
	squash: number,
	lifetime: NumberRange,
	in_air: boolean,
	fall: Vector3,
	flow: number,
	height: number,
	spread: number,
	drift: number,
	rate: number,
	turn: number,
	glow: number,
	gust: number,
	-- lies along the way it moves, as rain does, rather than facing the camera
	streaks: boolean,
	-- how much its squash varies at random either way, so that flakes are not all the same shape
	squash_give: number,
	-- for the air layers, how deep a box between the camera and the ground they fill, as a share of the distance to the
	-- ground; shallower keeps them off the lens, where they would be drawn huge
	depth: number,
}

-- A kind of weather: its layers, and what a gust does to the whole view at its height: tints it toward `gust_tint` by
-- `gust_tinting`, and brightens it and changes its contrast by those amounts.
type Look = {
	layers: { Layer },
	gust_tint: Color3,
	gust_tinting: number,
	gust_brightness: number,
	gust_contrast: number,
}

-- The air layers fill a box between the camera and the ground it looks at: its middle SLAB_SHARE of the way out along
-- the line of sight, as wide as the view there and SLAB_MARGIN more, so the edges are not bare, and as deep (unless a
-- layer says otherwise) and as tall as those shares of that distance. The particles are born anywhere in it, so they
-- are spread over the whole of the ground in view rather than bunched near the lens.
local SLAB_SHARE = 0.6
local SLAB_MARGIN = 1.3
local SLAB_DEPTH = 0.9
local SLAB_HEIGHT = 0.45

local SQUARE = "rbxasset://textures/particles/SquareParticle.png"
local SPARK = "rbxasset://textures/particles/sparkles_main.dds"
local SMOKE = "rbxasset://textures/particles/smoke_main.dds"
-- a soft round dot, fading from its middle, which drawn out at random and tumbling makes a flake
local SOFT = "rbxasset://textures/particles/explosion01_implosion_main.dds"

-- Fades in as it appears and out before it goes, `solid` at its most solid, so that nothing pops in or out of the air.
local function fading(solid: number): NumberSequence
	return NumberSequence.new({
		NumberSequenceKeypoint.new(0, 1),
		NumberSequenceKeypoint.new(0.15, solid),
		NumberSequenceKeypoint.new(0.8, solid),
		NumberSequenceKeypoint.new(1, 1),
	})
end

-- `size` across, give or take up to `give` at random, the same all its life.
local function varied(size: number, give: number): NumberSequence
	return NumberSequence.new({
		NumberSequenceKeypoint.new(0, size, give),
		NumberSequenceKeypoint.new(1, size, give),
	})
end

-- A layer with nothing set but the look of what it gives off, for the kinds below to fill in.
local function layer(fields: { [string]: any }): Layer
	local made: { [string]: any } = {
		squash = 0,
		in_air = true,
		fall = Vector3.zero,
		flow = 0,
		height = 1,
		spread = 0,
		drift = 0,
		turn = 0,
		glow = 0,
		gust = 0,
		streaks = false,
		squash_give = 0,
		depth = SLAB_DEPTH,
	}
	for key, value in fields do
		made[key] = value
	end
	return table.freeze(made) :: any
end

local LOOKS: { [Weather]: Look } = {
	-- streaks of rain through the air, and splashes where it lands; a downpour darkens and cools the view
	rain = {
		layers = {
			layer({
				-- a square drawn out as far as Squash goes, lying along its fall: a fine streak some two studs long and
				-- an eighth of one across from the ordinary height, brighter and bluer than any ground it falls on
				texture = SQUARE,
				color = Color3.fromRGB(218, 232, 250),
				transparency = fading(0.25),
				size = varied(0.6, 0.12),
				squash = 3,
				lifetime = NumberRange.new(0.45, 0.6),
				fall = Vector3.new(0, -70, 0),
				spread = 2,
				-- blown hard enough that the slant shows from above: some thirty degrees off the upright in a fresh
				-- wind, and near half way over in a gale
				drift = 3,
				rate = 1400,
				glow = 0.2,
				gust = 0.45,
				streaks = true,
			}),
			layer({
				texture = SPARK,
				color = Color3.fromRGB(226, 234, 244),
				transparency = NumberSequence.new(0.25, 1),
				size = NumberSequence.new(0.35, 0.9),
				lifetime = NumberRange.new(0.12, 0.2),
				in_air = false,
				height = 0.6,
				rate = 900,
				glow = 0.3,
				gust = 0.45,
			}),
		},
		gust_tint = Color3.fromRGB(176, 188, 204),
		gust_tinting = 0.35,
		gust_brightness = -0.04,
		gust_contrast = 0.04,
	},
	-- flakes tumbling down, and spindrift blown along the ground; a gust whites out the view
	snow = {
		layers = {
			layer({
				-- a little blue-grey, so the flakes still show against snow on the ground
				texture = SPARK,
				color = Color3.fromRGB(214, 226, 242),
				transparency = fading(0),
				size = varied(0.8, 0.4),
				lifetime = NumberRange.new(1.6, 2.2),
				fall = Vector3.new(0, -12, 0),
				spread = 18,
				drift = 1.8,
				rate = 700,
				turn = 90,
				glow = 0.4,
				gust = 0.55,
			}),
			layer({
				texture = SMOKE,
				color = Color3.fromRGB(240, 246, 255),
				transparency = fading(0.6),
				size = NumberSequence.new(10, 18),
				lifetime = NumberRange.new(2, 3),
				in_air = false,
				flow = 10,
				height = 4,
				spread = 10,
				drift = 1.6,
				rate = 40,
				turn = 25,
				glow = 0.3,
				gust = 0.8,
			}),
		},
		gust_tint = Color3.fromRGB(236, 244, 255),
		gust_tinting = 0.3,
		gust_brightness = 0.1,
		gust_contrast = -0.15,
	},
	-- grit streaking through the air, and clouds of dust rolling over the ground; a gust browns out the view
	dust = {
		layers = {
			layer({
				-- darker and greyer than sand, so it shows against it
				texture = SQUARE,
				color = Color3.fromRGB(150, 118, 82),
				transparency = fading(0.15),
				size = varied(0.35, 0.15),
				squash = 3,
				lifetime = NumberRange.new(0.8, 1.2),
				fall = Vector3.new(0, -4, 0),
				spread = 6,
				drift = 3.5,
				rate = 700,
				gust = 0.8,
				streaks = true,
			}),
			layer({
				-- long, low wisps racing along the ground, a darker ochre than the sand
				texture = SMOKE,
				color = Color3.fromRGB(156, 122, 84),
				transparency = fading(0.4),
				size = NumberSequence.new(20, 34),
				squash = -1.5,
				lifetime = NumberRange.new(2, 3),
				in_air = false,
				flow = 22,
				height = 6,
				spread = 8,
				drift = 2.5,
				rate = 70,
				turn = 20,
				gust = 0.85,
			}),
		},
		gust_tint = Color3.fromRGB(236, 196, 146),
		gust_tinting = 0.5,
		gust_brightness = 0,
		gust_contrast = -0.12,
	},
	-- pale flakes of ash drifting down, and a thin grey smoke over the ground
	ash = {
		layers = {
			layer({
				-- pale, as falling ash is, so it shows against dark ground: soft flakes, each drawn out its own way and
				-- some fainter than others, tumbling as they fall, and kept back from the lens
				texture = SOFT,
				color = Color3.fromRGB(222, 218, 212),
				transparency = NumberSequence.new({
					NumberSequenceKeypoint.new(0, 1),
					NumberSequenceKeypoint.new(0.15, 0.3, 0.25),
					NumberSequenceKeypoint.new(0.8, 0.3, 0.25),
					NumberSequenceKeypoint.new(1, 1),
				}),
				size = varied(0.5, 0.25),
				squash_give = 1.2,
				depth = 0.55,
				lifetime = NumberRange.new(1.8, 2.4),
				fall = Vector3.new(0, -9, 0),
				spread = 20,
				drift = 1.4,
				rate = 420,
				turn = 160,
				gust = 0.4,
			}),
			layer({
				texture = SMOKE,
				color = Color3.fromRGB(120, 116, 112),
				transparency = fading(0.75),
				size = NumberSequence.new(18, 28),
				lifetime = NumberRange.new(4, 6),
				in_air = false,
				flow = 3,
				height = 6,
				spread = 10,
				drift = 0.6,
				rate = 18,
				turn = 10,
				gust = 0.3,
			}),
		},
		gust_tint = Color3.fromRGB(200, 196, 190),
		gust_tinting = 0.2,
		gust_brightness = -0.03,
		gust_contrast = 0,
	},
	-- glowing embers rising off the ground, and sparks thrown up where they start; a gust reddens the view
	embers = {
		layers = {
			layer({
				texture = SPARK,
				color = Color3.fromRGB(255, 140, 52),
				transparency = fading(0),
				size = NumberSequence.new(0.8, 0.3),
				lifetime = NumberRange.new(1.6, 2.4),
				fall = Vector3.new(0, 9, 0),
				spread = 30,
				drift = 1.2,
				rate = 320,
				turn = 120,
				glow = 1,
				gust = 0.5,
			}),
			layer({
				texture = SPARK,
				color = Color3.fromRGB(255, 180, 90),
				transparency = NumberSequence.new(0, 1),
				size = NumberSequence.new(0.6, 0.2),
				lifetime = NumberRange.new(0.4, 0.8),
				in_air = false,
				flow = 4,
				height = 2,
				spread = 40,
				drift = 0.5,
				rate = 160,
				glow = 1,
				gust = 0.6,
			}),
		},
		gust_tint = Color3.fromRGB(255, 214, 190),
		gust_tinting = 0.3,
		gust_brightness = 0.02,
		gust_contrast = 0.03,
	},
}

-- Mist lying low over the ground, in the colour the map gives it: slow, soft and thin enough that whatever stands in it
-- shows through, so it settles in the low ground and leaves the high standing out of it.
local function mist_layer(color: Color3): Layer
	return layer({
		texture = SMOKE,
		color = color,
		transparency = fading(0.8),
		size = NumberSequence.new(40, 60),
		lifetime = NumberRange.new(7, 10),
		in_air = false,
		flow = 1.5,
		height = 8,
		spread = 20,
		drift = 0.25,
		rate = 9,
		turn = 6,
		gust = 0.25,
	})
end
local MIST_COLOR = Color3.fromRGB(214, 218, 222)

-- The ground layers lie on a patch as wide as the view where the camera looks and GROUND_MARGIN more, reaching
-- GROUND_REACH of the way to that point beyond it and GROUND_REACH short of it, since the far half of the view covers
-- more ground than the near.
local GROUND_MARGIN = 1.5
local GROUND_REACH = 1.1
-- How far the camera looks to the ground at its ordinary height, which is the distance the looks above are for.
local REFERENCE_DISTANCE = config.CAMERA_HEIGHT / math.sin(math.rad(-config.CAMERA_PITCH))
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
-- The wind eases toward the one the server sends, closing most of the gap in a couple of these, as the wind readout
-- does (see ui/wind_block.luau). Roblox's wind is the game's times GRASS_WIND, which sways the grass about as hard as
-- the wind turns the turbines: gently in a light air, hard in a gale; it is only set again once it has moved this much.
local WIND_EASE_SECONDS = 1
local GRASS_WIND = 1.6
local GRASS_MIN_CHANGE = 0.1

-- The scene as it was lit before anything here touched it.
local lighting_base: { [string]: any } = {}
local atmosphere_base: { [string]: any }? = nil
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

local LIGHTING_FIELDS: { [string]: string } = {
	clock_time = "ClockTime",
	latitude = "GeographicLatitude",
	brightness = "Brightness",
	exposure = "ExposureCompensation",
	ambient = "Ambient",
	outdoor_ambient = "OutdoorAmbient",
	sun_color = "ColorShift_Top",
}

local ATMOSPHERE_FIELDS: { [string]: string } = {
	haze_color = "Color",
	decay_color = "Decay",
	density = "Density",
	haze = "Haze",
	glare = "Glare",
}

-- Sets each of `instance`'s properties named in `fields` to what `given` says for it, or else back to `base`.
local function dress(
	instance: Instance,
	fields: { [string]: string },
	given: { [string]: any },
	base: { [string]: any }
)
	for field, property in fields do
		local value = given[field]
		if value == nil then
			value = base[property]
		end
		if value ~= nil then
			(instance :: any)[property] = value
		end
	end
end

-- The haze the server hung in Lighting, with what it was like before this touched it taken the first time it is seen.
local function find_haze(): Atmosphere?
	local found = Lighting:FindFirstChildOfClass "Atmosphere"
	if found ~= nil and atmosphere_base == nil then
		local base = {}
		for _, property in ATMOSPHERE_FIELDS do
			base[property] = (found :: any)[property]
		end
		atmosphere_base = base
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
	local correction = existing :: ColorCorrectionEffect?
	if correction == nil then
		local made = Instance.new "ColorCorrectionEffect"
		made.Name = CORRECTION_NAME
		made.Parent = Lighting
		correction = made
	end
	assert(correction ~= nil)
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

-- The wind the server sends, as it lies over the ground, in studs a second.
local function wind_sent(): Vector3
	local wind = Workspace:GetAttribute "wind"
	return if typeof(wind) == "Vector2" then Vector3.new(wind.X, 0, wind.Y) else Vector3.zero
end

-- the wind as it is drawn, eased toward the one sent, and what Roblox's wind was last set to from it
local eased_wind = Vector3.zero
local grass_wind = Vector3.zero

local function wind_now(): Vector3
	return eased_wind
end

-- Eases the wind toward the one sent, and Roblox's with it.
local function ease_wind(delta: number)
	eased_wind = eased_wind:Lerp(wind_sent(), 1 - math.exp(-delta / WIND_EASE_SECONDS))
	local grass = eased_wind * GRASS_WIND
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
	local push = (wind_now() * each.drift).Magnitude
	local windy = if fall > 1e-3 then math.clamp(push / fall, 0, 1) else 1
	return each.squash * (STILL_SQUASH + (1 - STILL_SQUASH) * windy)
end

-- The way a layer's particles go now, in studs a second at the ordinary zoom: its own fall or flow, pushed by the wind,
-- all as hard as the gust drives it.
local function velocity_of(each: Layer): Vector3
	local wind = wind_now()
	local push = wind * each.drift * gusting(each.gust)
	if each.in_air and each.streaks then
		return streak_velocity(each, push)
	end
	if each.in_air then
		return fall_on_screen(each) + push
	end
	local along = if wind.Magnitude > 1e-3 then wind.Unit else Vector3.new(1, 0, 0)
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
	local part = Instance.new "Part"
	part.Name = "Weather"
	part.Anchored = true
	part.CanCollide = false
	part.CanQuery = false
	part.CanTouch = false
	part.CastShadow = false
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
	local look = if kind ~= nil then LOOKS[kind] else nil
	if kind ~= nil and look == nil then
		warn(`there is no weather "{kind}"`)
	end
	local mist = math.max(given.mist or 0, 0)
	local mist_color = given.mist_color or MIST_COLOR
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
			table.insert(running, start_layer(mist_layer(mist_color), mist))
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
	dress(Lighting, LIGHTING_FIELDS, given :: any, lighting_base)
	local found = find_haze()
	if found ~= nil and atmosphere_base ~= nil then
		dress(found, ATMOSPHERE_FIELDS, given :: any, atmosphere_base)
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
	for _, property in LIGHTING_FIELDS do
		lighting_base[property] = (Lighting :: any)[property]
	end
	find_haze()
	refresh()
	-- starting where the wind is, rather than swinging up to it from a calm
	eased_wind = wind_sent()
	RunService.Heartbeat:Connect(ease_wind)
	-- the wind is read afresh as the gusts are followed, so a change to it needs nothing here
	Workspace.AttributeChanged:Connect(function(attribute: string)
		if atmosphere.is_attribute(attribute) then
			refresh_soon()
		end
	end)
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
