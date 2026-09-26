--!strict
-- The overlook's guide: a few suggestions, on the full HUD. Develop the economy, take the high ground with thugs at the
-- cliff's edge, where they outrange the guards below, make aggravators, which outrange the guards covering the feet of
-- the ramps, and destroy the enemy.

local ReplicatedStorage = game:GetService "ReplicatedStorage"

local mission_map = require(ReplicatedStorage.Shared.mission_map)
local types = require(ReplicatedStorage.Shared.types)

local world = require(ReplicatedStorage.Client.world)

local kit = require(script.Parent.kit)

type EntityDef = types.EntityDef
type Card = kit.Card
type Guide = kit.Guide

-- The income the economy step asks for, as the resource bar shows it: the metal is what the commander and an
-- extractor on each of the player's four spots make together.
local METAL = 10
local ENERGY = 60
-- How many of what the high ground step asks for have to stand at the edge, and how far back from it one may stand and
-- count.
local EDGE_UNITS = 4
local EDGE_DEPTH = 8
-- How wide the ring on the cliff's edge is.
local EDGE_RING = 11
-- How many aggravators the step after the high ground asks for.
local AGGRAVATORS = 4

local METAL_CARD: Card = {
	id = "metal",
	caption = "Metal income: Metal Extractors on the marked spots",
	mark = "check",
	picture = { kind = "unit", def_name = "metal_extractor" },
	rate = { resource = "metal", goal = METAL },
}
local ENERGY_CARD: Card = {
	id = "energy",
	caption = "Energy income: Solar Collectors or Wind Turbines",
	mark = "check",
	picture = { kind = "unit", def_name = "solar_collector" },
	rate = { resource = "energy", goal = ENERGY },
}

local function on_plateau(spot: Vector3): boolean
	return mission_map.above_brink(spot.X, spot.Z)
end

-- How many finished `def_name` of yours stand at the cliff's edge, on the plateau.
local function at_edge(def_name: string): number
	local count = 0
	for _, model in
		kit.mine(function(def: EntityDef): boolean
			return def.name == def_name
		end, false)
	do
		local at = world.position_of(model)
		local edge = mission_map.brink_x(at.Z)
		if at.X <= edge + 1 and at.X >= edge - EDGE_DEPTH then
			count += 1
		end
	end
	return count
end

local GUIDE: Guide = {
	steps = {
		{
			id = "economy",
			title = "Develop your economy",
			cards = { METAL_CARD, ENERGY_CARD },
			every_card = true,
			select = { def_name = "commander" },
			click = { kind = "build", def_name = "metal_extractor", next = "Now click a marked metal spot" },
			watch = kit.watch_all({
				kit.watch_spots(on_plateau),
				kit.watch_rate(METAL_CARD),
				kit.watch_rate(ENERGY_CARD),
			}),
		},
		{
			id = "high_ground",
			title = "Take the high ground",
			cards = {
				{
					id = "edge_thugs",
					caption = "Thugs at the cliff edge outrange the guards below",
					mark = "check",
					picture = { kind = "unit", def_name = "thug" },
				},
			},
			click = { kind = "build", def_name = "thug" },
			-- Done once enough thugs stand at the edge. The edge in front of the enemy is marked.
			watch = kit.with_marker(
				function(): Vector2
					return Vector2.new(mission_map.brink_x(0) - EDGE_DEPTH / 2, 0)
				end,
				EDGE_RING,
				kit.watch_count("edge_thugs", EDGE_UNITS, function(): number
					return at_edge "thug"
				end)
			),
		},
		{
			id = "aggravators",
			title = "Make Aggravators",
			cards = {
				{
					id = "aggravators",
					caption = "Aggravators outrange the guards by the ramps",
					mark = "check",
					picture = { kind = "unit", def_name = "aggravator" },
				},
			},
			click = { kind = "build", def_name = "aggravator" },
			watch = kit.watch_count("aggravators", AGGRAVATORS, function(): number
				return kit.count_mine "aggravator"
			end),
		},
		{
			id = "destroy",
			title = "Destroy the enemy",
			cards = {
				{
					id = "destroy",
					caption = "Every enemy unit and building",
					mark = "check",
					picture = { kind = "unit", def_name = "grunt" },
				},
			},
			watch = kit.watch_destroy(),
		},
	},
	objective = nil,
	finish = nil,
	is_over = nil,
	preload = nil,
}

return table.freeze(GUIDE)
