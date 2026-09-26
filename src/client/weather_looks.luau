--!strict
-- What each kind of weather looks like (shared/atmosphere.luau's `weather`), and mist, as client/atmospherics.luau
-- draws them: content, the layers of particles each is made of and what its gusts do to the view.

local ReplicatedStorage = game:GetService "ReplicatedStorage"

local atmosphere = require(ReplicatedStorage.Shared.atmosphere)

type Weather = atmosphere.Weather

-- One emitter's worth of weather, as it is seen from the ordinary height of the camera (client/camera.luau's
-- CAMERA_HEIGHT); from higher up it is all drawn bigger and moves faster by as much as the ground is farther away, so
-- that it looks the same on screen at any zoom.
--
-- `in_air` layers fill the air between the camera and the ground and move by `fall`, in studs a second, pushed sideways
-- by `drift` times the wind. The others lie on the ground where the camera looks, `height` studs deep, and blow along
-- the ground the way the wind does, at `flow` studs a second and `drift` times the wind more.
--
-- `rate` is how many a second on an ordinary day, `size` is across, and `squash` draws it out along the way it moves
-- (as ParticleEmitter.Squash), so that rain falls in streaks. `turn` is how many degrees a second it tumbles, and
-- `glow` how much it lights itself. `gust` is how much the gusts swell it: at 0.5 it runs from half as much as usual,
-- and half as fast a push from the wind, to half as much again.
export type Layer = {
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
export type Look = {
	layers: { Layer },
	gust_tint: Color3,
	gust_tinting: number,
	gust_brightness: number,
	gust_contrast: number,
}

-- How deep a box between the camera and the ground an air layer fills unless it says, as a share of the distance to
-- the ground (client/atmospherics.luau).
local SLAB_DEPTH = 0.9

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

-- A layer as the kinds below give it: the look of what it gives off, and whichever of the rest it has that is not
-- nothing (or, for `in_air`, true, and for `height`, 1, and for `depth`, SLAB_DEPTH).
type LayerSpec = {
	texture: string,
	color: Color3,
	transparency: NumberSequence,
	size: NumberSequence,
	lifetime: NumberRange,
	rate: number,
	squash: number?,
	in_air: boolean?,
	fall: Vector3?,
	flow: number?,
	height: number?,
	spread: number?,
	drift: number?,
	turn: number?,
	glow: number?,
	gust: number?,
	streaks: boolean?,
	squash_give: number?,
	depth: number?,
}

local function layer(spec: LayerSpec): Layer
	return table.freeze({
		texture = spec.texture,
		color = spec.color,
		transparency = spec.transparency,
		size = spec.size,
		squash = spec.squash or 0,
		lifetime = spec.lifetime,
		in_air = spec.in_air ~= false,
		fall = spec.fall or Vector3.zero,
		flow = spec.flow or 0,
		height = spec.height or 1,
		spread = spec.spread or 0,
		drift = spec.drift or 0,
		rate = spec.rate,
		turn = spec.turn or 0,
		glow = spec.glow or 0,
		gust = spec.gust or 0,
		streaks = spec.streaks == true,
		squash_give = spec.squash_give or 0,
		depth = spec.depth or SLAB_DEPTH,
	})
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

return table.freeze({
	LOOKS = LOOKS,
	MIST_COLOR = MIST_COLOR,
	mist_layer = mist_layer,
})
