-- The conditions a game is played in: the least and most the wind blows, and how strong the tide is. Each map may set
-- its own (`map_presets`), and they can be changed while the game runs; whatever is not set is the default here. A
-- wind turbine makes as much energy as the wind speed (`wind`) and a tidal generator as much as the tidal strength,
-- as BAR's do.
--
-- With them goes the wind blowing now, which the server moves about within that range (server/wind.luau).
--
-- The server sets them and they reach the clients as replicated fields (shared/replicated.luau), so reading them works
-- the same on both sides.

local ReplicatedStorage = game:GetService "ReplicatedStorage"

local replicated = require(ReplicatedStorage.Shared.replicated)

-- The least and most wind, and the energy a tidal generator makes, on a map that does not set its own.
local DEFAULT_MIN_WIND = 1
local DEFAULT_MAX_WIND = 15
local DEFAULT_TIDAL_STRENGTH = 15

local MIN_WIND = replicated.world("environment", "min_wind", replicated.NUMBER)
local MAX_WIND = replicated.world("environment", "max_wind", replicated.NUMBER)
local TIDAL_STRENGTH = replicated.world("environment", "tidal_strength", replicated.NUMBER)
-- the wind blowing now, as (x, z) in studs a second
local WIND = replicated.world("environment", "wind", replicated.VECTOR2)

-- What a map, or anything else, sets; anything left nil is the default.
export type Conditions = {
	min_wind: number?,
	max_wind: number?,
	tidal_strength: number?,
}

local function min_wind(): number
	return MIN_WIND.get() or DEFAULT_MIN_WIND
end

local function max_wind(): number
	return MAX_WIND.get() or DEFAULT_MAX_WIND
end

local function tidal_strength(): number
	return TIDAL_STRENGTH.get() or DEFAULT_TIDAL_STRENGTH
end

-- Calls `listener` when the tidal strength is set, so a readout of it can follow, until the returned function is called.
local function tidal_strength_changed(listener: () -> ()): () -> ()
	return TIDAL_STRENGTH.changed(listener)
end

-- The wind blowing now, as (x, z), still before the server has said.
local function wind(): Vector2
	return WIND.get() or Vector2.zero
end

-- Sets the wind's range. It is refused, with a reason, unless it runs from nothing or more up to at least that.
local function set_wind(least: number, most: number): (boolean, string?)
	if least < 0 or most < least then
		return false, `the wind has to run from 0 or more up to at least that, not {least} to {most}`
	end
	MIN_WIND.set(least)
	MAX_WIND.set(most)
	return true, nil
end

local function set_tidal(strength: number): (boolean, string?)
	if strength < 0 then
		return false, `the tide cannot be weaker than nothing, not {strength}`
	end
	TIDAL_STRENGTH.set(strength)
	return true, nil
end

-- The server's: the wind blowing now.
local function blow(now: Vector2)
	WIND.set(now)
end

-- Sets all of them from `conditions`, putting back the default for any it leaves out, as a map does when it is
-- built.
local function apply(conditions: Conditions): (boolean, string?)
	local ok, reason = set_wind(conditions.min_wind or DEFAULT_MIN_WIND, conditions.max_wind or DEFAULT_MAX_WIND)
	if ok == false then
		return false, reason
	end
	return set_tidal(conditions.tidal_strength or DEFAULT_TIDAL_STRENGTH)
end

return table.freeze({
	min_wind = min_wind,
	max_wind = max_wind,
	tidal_strength = tidal_strength,
	tidal_strength_changed = tidal_strength_changed,
	wind = wind,
	blow = blow,
	set_wind = set_wind,
	set_tidal = set_tidal,
	apply = apply,
})
