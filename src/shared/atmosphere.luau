-- How a map looks, as against what it plays like (that is environment.luau): the time of day and so the angle of the
-- sun, the colour of the light and of the shade, the haze over the distance, a tint over the whole view, and the
-- weather falling through it. None of it changes anything a unit can do or see; it is only how the map is dressed.
--
-- Each map may set its own (`map_presets`), over DEFAULT, which is how a map that sets none looks, as none of BAR's do.
-- The server sets them when the map is built and they reach the clients as replicated fields (shared/replicated.luau),
-- as the wind and the tide do, and each client lights its own view from them (see client/atmospherics.luau). What neither the map nor
-- DEFAULT says is left as the place is lit.

local ReplicatedStorage = game:GetService "ReplicatedStorage"

local replicated = require(ReplicatedStorage.Shared.replicated)

-- What falls through the view: rain in streaks splashing on the ground, snow in flakes with spindrift blown along the
-- ground, dust blown in grit and in clouds low over the ground, pale ash drifting down, or glowing embers rising. Every
-- kind comes and goes in gusts.
export type Weather = "rain" | "snow" | "dust" | "ash" | "embers"

export type Atmosphere = {
	-- the hour, 0 to 24, and how far north the map is, which between them put the sun in the sky (Lighting's
	-- ClockTime and GeographicLatitude)
	clock_time: number?,
	latitude: number?,
	-- how strong the sunlight is, and how bright the whole view is exposed
	brightness: number?,
	exposure: number?,
	-- the light in the shade, indoors and out
	ambient: Color3?,
	outdoor_ambient: Color3?,
	-- the tint the sun gives what it lights from above, as a low sun turns everything gold
	sun_color: Color3?,
	-- the haze over the distance (the Atmosphere): its colour, the colour it takes far off, how thick it is, how much it
	-- hazes, and how much it glows around the sun
	haze_color: Color3?,
	decay_color: Color3?,
	density: number?,
	haze: number?,
	glare: number?,
	-- a colour correction over the whole view: a tint, and the saturation and contrast, each 0 for none
	tint: Color3?,
	saturation: number?,
	contrast: number?,
	-- what falls, and how much of it, 1 for an ordinary fall; it drifts with the wind
	weather: Weather?,
	weather_amount: number?,
	-- mist lying low over the ground, how much of it (1 for a thick mist) and its colour, with or without weather
	mist: number?,
	mist_color: Color3?,
}

-- The late-afternoon light every map has unless it says otherwise: the sun fairly high, a cool grey-blue shade, and a
-- haze over the distance of the horizon's colour, which the fog fades into (server/lighting.luau).
local DEFAULT: Atmosphere = table.freeze({
	clock_time = 15.5,
	latitude = 20,
	brightness = 2,
	exposure = -0.1,
	ambient = Color3.fromRGB(88, 96, 110),
	outdoor_ambient = Color3.fromRGB(104, 114, 130),
	haze_color = Color3.fromRGB(108, 124, 142),
	decay_color = Color3.fromRGB(84, 96, 112),
	density = 0.32,
	haze = 1.4,
	glare = 0.15,
})

-- Every field and the codec its value is replicated with, so the server writes and the clients read the same set.
local CODECS: { [string]: replicated.Codec<any> } = {
	clock_time = replicated.NUMBER,
	latitude = replicated.NUMBER,
	brightness = replicated.NUMBER,
	exposure = replicated.NUMBER,
	ambient = replicated.COLOR3,
	outdoor_ambient = replicated.COLOR3,
	sun_color = replicated.COLOR3,
	haze_color = replicated.COLOR3,
	decay_color = replicated.COLOR3,
	density = replicated.NUMBER,
	haze = replicated.NUMBER,
	glare = replicated.NUMBER,
	tint = replicated.COLOR3,
	saturation = replicated.NUMBER,
	contrast = replicated.NUMBER,
	weather = replicated.STRING,
	weather_amount = replicated.NUMBER,
	mist = replicated.NUMBER,
	mist_color = replicated.COLOR3,
}
local FIELDS: { [string]: replicated.WorldField<any> } = {}
for field, codec in CODECS do
	FIELDS[field] = replicated.world("atmosphere", field, codec)
end

-- Sets them all from `atmosphere`, and what it leaves out from DEFAULT, as a map does when it is built.
local function apply(atmosphere: Atmosphere?)
	local given = (atmosphere or {}) :: { [string]: any }
	local defaults = DEFAULT :: { [string]: any }
	for name, field in FIELDS do
		local value = given[name]
		field.set(if value ~= nil then value else defaults[name])
	end
end

-- What is set now, with whatever is not, or is not the type it should be, left nil.
local function read(): Atmosphere
	local found: { [string]: any } = {}
	for name, field in FIELDS do
		found[name] = field.get()
	end
	return found :: Atmosphere
end

-- Calls `listener` whenever any of it changes, until the returned function is called.
local function changed(listener: () -> ()): () -> ()
	local all: { replicated.WorldField<any> } = {}
	for _, field in FIELDS do
		table.insert(all, field)
	end
	return replicated.any_changed(all, listener)
end

return table.freeze({
	DEFAULT = DEFAULT,
	apply = apply,
	read = read,
	changed = changed,
})
