--!strict
-- The shapes a map preset is made of (see map_presets), kept apart from the presets themselves so that the maps
-- in map_designs can be typed without requiring map_presets, which requires them.

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

-- Where a map comes from: brought over from Beyond All Reason (bar_maps), drawn by hand for this game, or generated from
-- the seed (both in map_designs).
export type PresetSource = "bar" | "design" | "generated"

export type Preset = {
	name: string,
	-- what a player is shown it as
	display_name: string,
	description: string,
	source: PresetSource,
	-- How big the map is, in studs along x and z: an even number of cells each way (map_presets checks), which puts its
	-- edges, and so every cell, on the terrain's voxel grid about the middle.
	size: Vector2,
	-- Gives the ground height at a world position.
	build: (seed: number) -> (x: number, z: number) -> number,
	-- Where each team ideally starts, as (x, z): one for every team the map is laid out for, and more teams than these
	-- share them, round again from the first. How many there are is how many starts the map has.
	starts: { Vector2 },
	-- The box each team's players choose where to start within, one to a team, in world (x, z): BAR's own for a map
	-- from BAR, and for any other laid over its starts by eye. More teams than boxes share them.
	start_boxes: { StartBox },
	-- The layers the middle spots are laid out in, each with its own count, in place of the usual scatter
	-- over the whole map and the spots on the sea floor.
	metal_layers: { MetalLayer }?,
	-- Every metal spot on the map, where the map says, in place of any laid out from the seed; nil to lay them out.
	metal_spots: { FixedMetalSpot }?,
	-- Every geothermal vent on the map, in world (x, z), where the map says. A map with neither this nor `geo_at_starts`
	-- has none: vents are as particular to a map as its metal is. Read only when the map is built, since a BAR map's are
	-- in its features module, which nothing else needs.
	geo_spots: (() -> { Vector2 })?,
	-- A vent beside every start, for a map that does not say where its vents are.
	geo_at_starts: boolean?,
	-- Whether the map is laid out the same for every side, turned half round about its middle: its ground (`build`
	-- is taken at (x, z) and at (-x, -z) and the two blended), its starts and its metal spots laid out from the seed,
	-- each paired with its twin across the middle, so that no side starts better off than another.
	symmetric: boolean?,
	-- The reclaimables the map starts with, where the map says, in place of any laid out from the seed; nil to lay them
	-- out. Read only when asked for, since only the server needs them and a map can have thousands.
	reclaimables: (() -> { FixedReclaimable })?,
	-- The wrecks the map starts with, besides its reclaimables; nil for none. Read only when asked for, like them.
	wrecks: (() -> { FixedWreck })?,
	theme: Theme,
	-- The least and most the wind blows, and how strong the tide is (see environment.luau); any left nil is the
	-- default there.
	conditions: environment.Conditions?,
	-- How the map looks: its time of day, light, haze and weather (see atmosphere.luau), all cosmetic; nil, or any field
	-- left nil, for the scene as it is lit without one.
	atmosphere: atmosphere.Atmosphere?,
	-- Only played as a campaign mission's map, never offered in a lobby.
	campaign_only: boolean?,
	-- Places on the map a campaign mission played on it refers to by name, in world (x, z): its "player_start" and
	-- "enemy_start", and whatever else the map is built around (the tutorial's "pass"). The map is the one place
	-- they are said; see shared/mission_map.luau.
	points: { [string]: Vector2 }?,
}

-- What an extractor on a rich metal spot makes, as a multiple of its own income: every few of the middle spots a map
-- lays out from its seed, and the ones a map that says where its metal is marks rich.
local RICH_MULTIPLIER = 4.0

return table.freeze({
	RICH_MULTIPLIER = RICH_MULTIPLIER,
})
