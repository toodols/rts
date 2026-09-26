--!strict
-- The maps made for this game (see map_presets, which offers them with BAR's), one module each with its ground,
-- theme, starts and start boxes. Some are generated from the seed, a new map for every seed:
--
-- highlands: rolling hills with basins that dip below the sea in places, the map as it always was.
-- continents: two continents side by side, joined by two narrow land bridges, with sea all around.
-- islands: islands in an ocean, one under every start, more scattered between, and at least one volcano.
-- koth: a mountain in the sea, in three terraces. The teams start on the lowest and the top is to be held.
--
-- The rest are drawn by hand, each to show off one part of the game that the others make little of:
--
-- tutorial: the campaign's first mission, a small valley split by a ridge with one narrow pass through it.
-- overlook: the campaign's second mission, a plateau whose cliff overlooks the low ground, with a ramp down at each end
-- and a road down its face between them.
-- switchbacks: a plateau that bots climb straight up and everything else by switchback roads, with rivers round it.
-- tidal_flats: shallow water between two coasts that only hovercraft and amphibious units cross, but for one causeway.
-- boneyard: an old battlefield with little metal in the ground and hundreds of wrecks on it, to reclaim or raise again.
-- caldera: a volcano whose crater, reached by two gorges, holds the vents and the richest metal; the wind barely blows.
-- mesas: desert mesas too sheer for anything on the ground, with the rich metal on top for transports and aircraft.
-- trenches: two ridges across a sunken no man's land, so that shells have to arc and shields hold the line.
-- canyons: a maze of sheer canyons through a tableland, where nothing sees past the next bend.
-- gale: a small, bare tundra for one against one, where the wind is the energy.
-- last_stand: a walled fortress with three ramps for each side, on open ground the scavengers spread over.
-- pinwheel: four arms spiralling out from a hub between four lakes, for a free for all of up to eight.
-- prairie: wide, gently rolling grassland with its metal spread thin over it, for vehicles, and for two to eight.

local ReplicatedStorage = game:GetService "ReplicatedStorage"

local map_types = require(ReplicatedStorage.Shared.map_types)

local highlands = require(script.highlands)
local continents = require(script.continents)
local islands = require(script.islands)
local koth = require(script.koth)
local tutorial = require(script.tutorial)
local overlook = require(script.overlook)
local switchbacks = require(script.switchbacks)
local tidal_flats = require(script.tidal_flats)
local boneyard = require(script.boneyard)
local caldera = require(script.caldera)
local mesas = require(script.mesas)
local trenches = require(script.trenches)
local canyons = require(script.canyons)
local gale = require(script.gale)
local last_stand = require(script.last_stand)
local pinwheel = require(script.pinwheel)
local prairie = require(script.prairie)

type Preset = map_types.Preset

local ALL: { Preset } = {
	highlands,
	continents,
	islands,
	koth,
	tutorial,
	overlook,
	switchbacks,
	tidal_flats,
	boneyard,
	caldera,
	mesas,
	trenches,
	canyons,
	gale,
	last_stand,
	pinwheel,
	prairie,
}

return table.freeze({
	ALL = ALL,
})
