-- The shapes a map preset is made of (see map_presets.luau), kept apart from the presets themselves so that the maps
-- designed in map_designs can be typed without requiring map_presets, which requires them.

local ReplicatedStorage = game:GetService "ReplicatedStorage"

local environment = require(ReplicatedStorage.Shared.environment)
local atmosphere = require(ReplicatedStorage.Shared.atmosphere)

-- One band of ground that has metal spots of its own, so that each layer of a map is worth a set number of them.
export type MetalLayer = {
	name: string,
	-- the spots stand on ground between these heights
	min_height: number,
	max_height: number,
	count: number,
	-- how far apart its spots keep, in studs
	spacing: number,
	-- on the sea floor rather than dry land
	underwater: boolean,
	-- what an extractor's income is multiplied by there; nil for the ordinary amount
	multiplier: number?,
	-- kept clear of the start positions, as the spots on the open ground are
	clear_of_starts: boolean,
}

-- What the ground of a map is made of. Terrain paints every column from this (see server/terrain.luau): the
-- map's own features decide first, then the steepness, so the routes read off the ground, then the height, then
-- patches of noise.
export type Theme = {
	-- open ground, which everything can drive over, and the second material it is mottled with
	ground: Enum.Material,
	ground_patches: Enum.Material,
	-- too steep for tanks, not for bots
	slope: Enum.Material,
	-- too steep for anything that walks
	cliff: Enum.Material,
	-- ground within a stud or two of the waterline, and the sea floor below that
	shore: Enum.Material,
	seabed: Enum.Material,
	-- open ground from about this height up is `high_ground` instead, like snow on the peaks; nil for none
	high_ground: Enum.Material?,
	high_from: number?,
	-- the colours the map gives its materials; any it leaves out keep Roblox's own
	colors: { [Enum.Material]: Color3 },
	water_color: Color3,
	-- the map's own features, given the seed: a material for a place, told whether the ground there is too steep for
	-- bots, or nil to leave it to the rules above
	paint: ((seed: number) -> (x: number, z: number, height: number, too_steep: boolean) -> Enum.Material?)?,
}

-- A team's start box, its corners in world (x, z).
export type StartBox = {
	min: Vector2,
	max: Vector2,
}

-- A metal spot a map puts in a place of its own choosing, in world (x, z).
export type FixedMetalSpot = {
	position: Vector2,
	-- nil for the ordinary amount
	multiplier: number?,
}

-- A reclaimable a map puts in a place of its own choosing, in world (x, z), with what it holds (see scenery.luau).
export type FixedReclaimable = {
	def_name: string,
	position: Vector2,
	facing: number,
	metal: number,
	energy: number,
	buildpower: number,
}

-- The wreck of a unit a map starts with, in world (x, z), lying there as though it had died there: holding what any wreck
-- of that unit holds, and there to be reclaimed or raised again like one (see server/scenery.luau).
export type FixedWreck = {
	-- the unit it is the wreck of
	def_name: string,
	position: Vector2,
	facing: number,
}

export type Preset = {
	name: string,
	description: string,
	-- How big the map is, in studs along x and z, rounded to an even number of cells; nil for config's MAP_CELLS_X by
	-- MAP_CELLS_Z.
	size: Vector2?,
	-- Gives the ground height at a world position.
	build: (seed: number) -> (x: number, z: number) -> number,
	-- Where a team's start ideally is, as (x, z); nil puts them on a ring around the middle.
	start_position: ((slot: number) -> Vector2)?,
	-- The box each team's players choose where to start within, one to a team, in world (x, z): BAR's own for a map
	-- from BAR, and for any other laid over its starts by eye. More teams than boxes share them.
	start_boxes: { StartBox },
	-- The layers the middle spots are laid out in, each with its own count, in place of the usual scatter
	-- over the whole map and the spots on the sea floor.
	metal_layers: { MetalLayer }?,
	-- Every metal spot on the map, where the map says, in place of any laid out from the seed; nil to lay them out.
	metal_spots: { FixedMetalSpot }?,
	-- Every geothermal vent on the map, in world (x, z), where the map says. A map with neither this nor `geo_at_starts`
	-- has none: vents are as particular to a map as its metal is.
	geo_spots: { Vector2 }?,
	-- A vent beside every start, for a map that does not say where its vents are.
	geo_at_starts: boolean?,
	-- The reclaimables the map starts with, where the map says, in place of any laid out from the seed; nil to lay them
	-- out. Read only when asked for, since only the server needs them and a map can have thousands.
	reclaimables: (() -> { FixedReclaimable })?,
	-- The wrecks the map starts with, besides its reclaimables; nil for none. Read only when asked for, like them.
	wrecks: (() -> { FixedWreck })?,
	theme: Theme,
	-- The least and most the wind blows, and how strong the tide is (see environment.luau); any left nil is config's
	-- default.
	conditions: environment.Conditions?,
	-- How the map looks: its time of day, light, haze and weather (see atmosphere.luau), all cosmetic; nil, or any field
	-- left nil, for the scene as it is lit without one.
	atmosphere: atmosphere.Atmosphere?,
	-- Only played as a campaign mission's map, never offered in a lobby.
	campaign_only: boolean?,
}

return table.freeze({})
