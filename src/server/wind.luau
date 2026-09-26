-- Wind. It is a 2D vector, (x, z), that lives in an annulus: its length is never below the least wind or above the
-- most, which the map sets (`environment`). Every WIND_INTERVAL seconds it moves to where it was plus a random delta, and then its length
-- is put back into the annulus, pulled in from beyond the outer edge or pushed out from inside the inner
-- one, keeping its direction. It is sent to clients as environment's wind (shared/environment.luau).

local ReplicatedStorage = game:GetService "ReplicatedStorage"

local environment = require(ReplicatedStorage.Shared.environment)

local rng = require(script.Parent.rng)

-- How often the wind moves, in seconds, and the longest random delta it moves by.
local WIND_INTERVAL = 5
local WIND_MAX_DELTA = 4

local current = Vector2.zero
local timer = 0

-- Puts `wind` back into the annulus by changing its length only. Something with no direction to keep, at
-- the very centre, gets the direction of `fallback`.
local function constrain(wind: Vector2, fallback: Vector2): Vector2
	local least = environment.min_wind()
	local most = environment.max_wind()
	local length = wind.Magnitude
	if length > most then
		return if length < 1e-6 then Vector2.zero else wind.Unit * most
	end
	if length < least then
		if length < 1e-6 then
			return if fallback.Magnitude < 1e-6 then Vector2.new(least, 0) else fallback.Unit * least
		end
		return wind.Unit * least
	end
	return wind
end

local function publish()
	environment.blow(current)
end

-- A random vector no longer than `max_length`, pointing anywhere.
local function random_vector(max_length: number): Vector2
	local random = rng.stream "wind"
	local angle = random:NextNumber(0, math.pi * 2)
	local length = random:NextNumber(0, max_length)
	return Vector2.new(math.cos(angle), math.sin(angle)) * length
end

-- Starts the wind somewhere in the annulus.
local function init()
	local random = rng.stream "wind"
	local angle = random:NextNumber(0, math.pi * 2)
	local length = random:NextNumber(environment.min_wind(), environment.max_wind())
	current = Vector2.new(math.cos(angle), math.sin(angle)) * length
	timer = 0
	publish()
end

local function tick(delta: number)
	timer += delta
	if timer < WIND_INTERVAL then
		return
	end
	timer -= WIND_INTERVAL
	current = constrain(current + random_vector(WIND_MAX_DELTA), current)
	publish()
end

-- Puts the wind back inside the range at once, for a range that has just changed, as when a map is built.
local function refit()
	current = constrain(current, current)
	publish()
end

-- How hard it is blowing.
local function speed(): number
	return current.Magnitude
end

return table.freeze({
	init = init,
	tick = tick,
	speed = speed,
	refit = refit,
})
