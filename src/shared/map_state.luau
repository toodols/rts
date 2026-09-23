-- Which map the game is on, as the server says and every client follows.
--
-- The ground is never sent: both sides build it from the same few numbers, the preset and the seed, so the server
-- only replicates those, as one Workspace attribute so that a client can never see half of a change. With them goes a
-- generation, counted up every time a map is built, which is what tells a client its ground is out of date - loading
-- the same map again is still a new map, with its craters gone - and what the edits made to the ground are labelled
-- with, so a client never lays an edit made to one map onto another.
--
-- A client catches up the same way whether it has just joined or the map has just been replaced under it: it builds
-- the generation it sees, then asks for every edit made to that generation so far (see server/deformation.luau).

local Workspace = game:GetService "Workspace"

local heightmap = require(script.Parent.heightmap)
local metal_spots = require(script.Parent.metal_spots)
local geo_spots = require(script.Parent.geo_spots)

export type MapState = {
	generation: number,
	seed: number,
	preset: string,
}

local ATTRIBUTE = "map"
local SEPARATOR = "|"

-- What this side has built, nil until it has built anything.
local current: MapState? = nil

local function encode(state: MapState): string
	return `{state.generation}{SEPARATOR}{state.seed}{SEPARATOR}{state.preset}`
end

local function decode(value: any): MapState?
	if typeof(value) ~= "string" then
		return nil
	end
	local parts = string.split(value, SEPARATOR)
	if #parts ~= 3 then
		return nil
	end
	local generation = tonumber(parts[1])
	local seed = tonumber(parts[2])
	if generation == nil or seed == nil then
		return nil
	end
	return table.freeze({ generation = generation, seed = seed, preset = parts[3] })
end

-- The map the server has published, if it has published one yet.
local function published(): MapState?
	return decode(Workspace:GetAttribute(ATTRIBUTE))
end

-- Fires whenever the server publishes a map.
local function changed(): RBXScriptSignal
	return Workspace:GetAttributeChangedSignal(ATTRIBUTE)
end

-- Builds the shared half of a map on this side: the heightmap, the starts, the metal spots and the geothermal vents.
local function apply(state: MapState)
	heightmap.initialize(state.seed, state.preset)
	metal_spots.initialize(state.seed)
	geo_spots.initialize(state.seed)
	current = state
end

-- Tells every client which map to build. The server calls it once it has built the map itself.
local function publish(state: MapState)
	Workspace:SetAttribute(ATTRIBUTE, encode(state))
end

local function get(): MapState?
	return current
end

-- The generation this side has built, 0 before it has built one.
local function generation(): number
	local state = current
	return if state ~= nil then state.generation else 0
end

return table.freeze({
	published = published,
	changed = changed,
	apply = apply,
	publish = publish,
	get = get,
	generation = generation,
})
