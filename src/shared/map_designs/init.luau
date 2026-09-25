-- Maps drawn by hand, each to show off one part of the game that the others make little of (see map_presets.luau,
-- which offers them with the rest):
--
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

local ALL = {
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
