-- The conditions a game is played in: the least and most the wind blows, and how strong the tide is. Each map may set
-- its own (`map_presets`), and they can be changed while the game runs; whatever is not set is config's default. A
-- wind turbine makes as much energy as the wind speed (`wind`) and a tidal generator as much as the tidal strength,
-- as BAR's do.
--
-- The server sets them and they reach the clients as attributes of Workspace, so reading them works the same on both
-- sides.

local ReplicatedStorage = game:GetService "ReplicatedStorage"
local Workspace = game:GetService "Workspace"

local config = require(ReplicatedStorage.Shared.config)

local MIN_WIND_ATTRIBUTE = "min_wind"
local MAX_WIND_ATTRIBUTE = "max_wind"
local TIDAL_ATTRIBUTE = "tidal_strength"

-- What a map, or anything else, sets; anything left nil is config's default.
export type Conditions = {
	min_wind: number?,
	max_wind: number?,
	tidal_strength: number?,
}

local function read(attribute: string, default: number): number
	local value = Workspace:GetAttribute(attribute)
	return if typeof(value) == "number" then value else default
end

local function min_wind(): number
	return read(MIN_WIND_ATTRIBUTE, config.MIN_WIND)
end

local function max_wind(): number
	return read(MAX_WIND_ATTRIBUTE, config.MAX_WIND)
end

local function tidal_strength(): number
	return read(TIDAL_ATTRIBUTE, config.TIDAL_STRENGTH)
end

-- Fires when the tidal strength is set, so a readout of it can follow.
local function tidal_strength_changed(): RBXScriptSignal
	return Workspace:GetAttributeChangedSignal(TIDAL_ATTRIBUTE)
end

-- Sets the wind's range. It is refused, with a reason, unless it runs from nothing or more up to at least that.
local function set_wind(least: number, most: number): (boolean, string?)
	if least < 0 or most < least then
		return false, `the wind has to run from 0 or more up to at least that, not {least} to {most}`
	end
	Workspace:SetAttribute(MIN_WIND_ATTRIBUTE, least)
	Workspace:SetAttribute(MAX_WIND_ATTRIBUTE, most)
	return true, nil
end

local function set_tidal(strength: number): (boolean, string?)
	if strength < 0 then
		return false, `the tide cannot be weaker than nothing, not {strength}`
	end
	Workspace:SetAttribute(TIDAL_ATTRIBUTE, strength)
	return true, nil
end

-- Sets all of them from `conditions`, putting back config's default for any it leaves out, as a map does when it is
-- built.
local function apply(conditions: Conditions): (boolean, string?)
	local ok, reason = set_wind(conditions.min_wind or config.MIN_WIND, conditions.max_wind or config.MAX_WIND)
	if ok == false then
		return false, reason
	end
	return set_tidal(conditions.tidal_strength or config.TIDAL_STRENGTH)
end

return table.freeze({
	min_wind = min_wind,
	max_wind = max_wind,
	tidal_strength = tidal_strength,
	tidal_strength_changed = tidal_strength_changed,
	set_wind = set_wind,
	set_tidal = set_tidal,
	apply = apply,
})
