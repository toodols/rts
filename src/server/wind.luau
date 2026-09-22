-- Wind. It is a 2D vector, (x, z), that lives in an annulus: its length is never below MIN_WIND or above
-- MAX_WIND. Every WIND_INTERVAL seconds it moves to where it was plus a random delta, and then its length
-- is put back into the annulus, pulled in from beyond the outer edge or pushed out from inside the inner
-- one, keeping its direction. It is sent to clients as the `wind` attribute of Workspace.

local Workspace = game:GetService "Workspace"
local ReplicatedStorage = game:GetService "ReplicatedStorage"

local config = require(ReplicatedStorage.Shared.config)

local random = Random.new()

local current = Vector2.zero
local timer = 0

-- Puts `wind` back into the annulus by changing its length only. Something with no direction to keep, at
-- the very centre, gets the direction of `fallback`.
local function constrain(wind: Vector2, fallback: Vector2): Vector2
	local length = wind.Magnitude
	if length > config.MAX_WIND then
		return wind.Unit * config.MAX_WIND
	end
	if length < config.MIN_WIND then
		if length < 1e-6 then
			return fallback.Unit * config.MIN_WIND
		end
		return wind.Unit * config.MIN_WIND
	end
	return wind
end

local function publish()
	Workspace:SetAttribute("wind", current)
end

-- A random vector no longer than `max_length`, pointing anywhere.
local function random_vector(max_length: number): Vector2
	local angle = random:NextNumber(0, math.pi * 2)
	local length = random:NextNumber(0, max_length)
	return Vector2.new(math.cos(angle), math.sin(angle)) * length
end

-- Starts the wind somewhere in the annulus.
local function init()
	local angle = random:NextNumber(0, math.pi * 2)
	local length = random:NextNumber(config.MIN_WIND, config.MAX_WIND)
	current = Vector2.new(math.cos(angle), math.sin(angle)) * length
	timer = 0
	publish()
end

local function tick(delta: number)
	timer += delta
	if timer < config.WIND_INTERVAL then
		return
	end
	timer -= config.WIND_INTERVAL
	current = constrain(current + random_vector(config.WIND_MAX_DELTA), current)
	publish()
end

-- The wind now, as (x, z).
local function get(): Vector2
	return current
end

-- How hard it is blowing.
local function speed(): number
	return current.Magnitude
end

return table.freeze({
	init = init,
	tick = tick,
	get = get,
	speed = speed,
	constrain = constrain,
})
