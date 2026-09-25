-- How a map looks, as against what it plays like (that is environment.luau): the time of day and so the angle of the
-- sun, the colour of the light and of the shade, the haze over the distance, a tint over the whole view, and the
-- weather falling through it. None of it changes anything a unit can do or see; it is only how the map is dressed.
--
-- Each map may set its own (`map_presets`). The server sets them when the map is built and they reach the clients as
-- attributes of Workspace, as the wind and the tide do, and each client lights its own view from them (see
-- client/atmospherics.luau). Whatever a map leaves nil is left as the scene is lit without one (see
-- server/lighting.luau), so a map that sets none, as none of BAR's do, looks exactly as maps always have.

local Workspace = game:GetService "Workspace"

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

local PREFIX = "atmosphere_"

-- Every field and the type its attribute holds, so the server writes and the clients read the same set.
local FIELDS: { [string]: string } = {
	clock_time = "number",
	latitude = "number",
	brightness = "number",
	exposure = "number",
	ambient = "Color3",
	outdoor_ambient = "Color3",
	sun_color = "Color3",
	haze_color = "Color3",
	decay_color = "Color3",
	density = "number",
	haze = "number",
	glare = "number",
	tint = "Color3",
	saturation = "number",
	contrast = "number",
	weather = "string",
	weather_amount = "number",
	mist = "number",
	mist_color = "Color3",
}

-- Sets them all from `atmosphere`, clearing any it leaves out, as a map does when it is built; nil clears the lot.
local function apply(atmosphere: Atmosphere?)
	local given = (atmosphere or {}) :: { [string]: any }
	for field in FIELDS do
		Workspace:SetAttribute(PREFIX .. field, given[field])
	end
end

-- What is set now, with whatever is not, or is not the type it should be, left nil.
local function read(): Atmosphere
	local found: { [string]: any } = {}
	for field, kind in FIELDS do
		local value = Workspace:GetAttribute(PREFIX .. field)
		if typeof(value) == kind then
			found[field] = value
		end
	end
	return found :: Atmosphere
end

-- Whether `attribute`, a Workspace attribute's name, is one of these, so a client can follow them as they change.
local function is_attribute(attribute: string): boolean
	return string.sub(attribute, 1, #PREFIX) == PREFIX and FIELDS[string.sub(attribute, #PREFIX + 1)] ~= nil
end

return table.freeze({
	apply = apply,
	read = read,
	is_attribute = is_attribute,
})
