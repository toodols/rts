--!strict
-- Which map the game is on, as the server says and every client follows.
--
-- The ground is never sent: both sides build it from the same few numbers, the preset and the seed, so the server
-- only replicates those, as one replicated field (shared/replicated.luau) so that a client can never see half of a
-- change. With them goes a
-- generation, counted up every time a map is built, which is what tells a client its ground is out of date - loading
-- the same map again is still a new map, with its craters gone - and what the edits made to the ground are labelled
-- with, so a client never lays an edit made to one map onto another.
--
-- A client catches up the same way whether it has just joined or the map has just been replaced under it: it builds
-- the generation it sees, then asks for every edit made to that generation so far (see server/deformation.luau).

local ReplicatedStorage = game:GetService "ReplicatedStorage"

local replicated = require(ReplicatedStorage.Shared.replicated)

local heightmap = require(script.Parent.heightmap)
local map_presets = require(script.Parent.map_presets)
local starts = require(script.Parent.starts)
local spots = require(script.Parent.spots)

type Preset = map_presets.Preset

export type MapState = {
	generation: number,
	seed: number,
	preset: string,
}

local PUBLISHED = replicated.world(
	"map",
	"state",
	replicated.json(function(decoded: any): MapState?
		if
			typeof(decoded) ~= "table"
			or typeof(decoded.generation) ~= "number"
			or typeof(decoded.seed) ~= "number"
			or typeof(decoded.preset) ~= "string"
		then
			return nil
		end
		return table.freeze({ generation = decoded.generation, seed = decoded.seed, preset = decoded.preset })
	end)
)

-- What this side has built, nil until it has built anything, and the preset it was built from.
local current: MapState? = nil
local current_preset: Preset? = nil

-- The map the server has published, if it has published one yet.
local function published(): MapState?
	return PUBLISHED.get()
end

-- Calls `listener` whenever the server publishes a map, until the returned function is called.
local function changed(listener: () -> ()): () -> ()
	return PUBLISHED.changed(listener)
end

-- Builds the shared half of a map on this side, each part from the ones before it: the heightmap, then the starts,
-- found on its ground, then the metal spots and geothermal vents, laid out round the starts. This is the one place
-- they are built, and so the one place their order is kept.
local function apply(state: MapState)
	local preset = map_presets.get(state.preset)
	heightmap.initialize(preset.size, preset.build(state.seed))
	starts.initialize(preset)
	spots.lay_out(preset, state.seed)
	current = state
	current_preset = preset
end

-- Tells every client which map to build. The server calls it once it has built the map itself.
local function publish(state: MapState)
	PUBLISHED.set({ generation = state.generation, seed = state.seed, preset = state.preset })
end

local function get(): MapState?
	return current
end

-- The preset of the map this side has built. Only asked for once it has built one.
local function preset(): Preset
	return current_preset :: Preset
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
	preset = preset,
	generation = generation,
})
