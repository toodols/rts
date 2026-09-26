--!strict
-- Channel Crossing's guide: put a shipyard in the harbour, build a fleet, build Garpikes, which drive under the water to
-- the enemy's shore and up onto it, and land on one of its beaches with a bot lab put down from a construction ship. By
-- this mission the player knows how to build an economy, so the guide does not ask for one. What is left is the
-- objective: the enemy's commander, before the time runs out (the HUD shows how long is left).

local ReplicatedStorage = game:GetService "ReplicatedStorage"

local mission_map = require(ReplicatedStorage.Shared.mission_map)
local types = require(ReplicatedStorage.Shared.types)

local world = require(ReplicatedStorage.Client.world)

local kit = require(script.Parent.kit)

type EntityDef = types.EntityDef
type Guide = kit.Guide

-- How many warships the fleet step asks for, and how many Garpikes the step after it.
local FLEET = 6
local GARPIKES = 4
-- How wide the rings on the harbour and on each beach are.
local HARBOR_RING = 12
local BEACH_RING = 10

local function is_warship(def: EntityDef): boolean
	return def.category == "ships" and def.weapons ~= nil and #def.weapons > 0
end

-- The enemy's shore is east of this.
local ENEMY_SHORE_X = 150

-- How many finished bot labs of yours stand on the enemy's shore.
local function labs_ashore(): number
	local count = 0
	for _, model in
		kit.mine(function(def: EntityDef): boolean
			return def.name == "bot_lab"
		end, false)
	do
		if world.position_of(model).X > ENEMY_SHORE_X then
			count += 1
		end
	end
	return count
end

local function point(name: string): () -> Vector2
	return function(): Vector2
		return mission_map.here(name)
	end
end

local GUIDE: Guide = {
	steps = {
		{
			id = "shipyard",
			title = "Build a Shipyard",
			cards = {
				{
					id = "shipyard",
					caption = "Shipyard in the harbor",
					mark = "check",
					picture = { kind = "unit", def_name = "shipyard" },
				},
			},
			select = { def_name = "commander" },
			click = { kind = "build", def_name = "shipyard", next = "Now click in the marked harbor" },
			watch = kit.with_marker(
				point "harbor",
				HARBOR_RING,
				kit.watch_count("shipyard", 1, function(): number
					return kit.count_mine "shipyard"
				end)
			),
		},
		{
			id = "fleet",
			title = "Build a fleet",
			cards = {
				{
					id = "fleet",
					caption = "Warships",
					mark = "check",
					picture = { kind = "unit", def_name = "riptide" },
				},
			},
			click = { kind = "build", def_name = "riptide" },
			watch = kit.watch_count("fleet", FLEET, function(): number
				return #kit.mine(is_warship, false)
			end),
		},
		{
			id = "garpikes",
			title = "Build Garpikes",
			cards = {
				{
					id = "garpikes",
					caption = "Garpikes drive under the water",
					mark = "check",
					picture = { kind = "unit", def_name = "garpike" },
				},
			},
			click = { kind = "build", def_name = "garpike" },
			watch = kit.watch_count("garpikes", GARPIKES, function(): number
				return kit.count_mine "garpike"
			end),
		},
		{
			id = "landing",
			title = "Land on a beach",
			cards = {
				{
					id = "landing",
					caption = "Construction Ship: Bot Lab on a marked beach",
					mark = "check",
					picture = { kind = "unit", def_name = "construction_ship" },
				},
			},
			click = { kind = "build", def_name = "bot_lab" },
			watch = kit.with_marker(
				point "beach_north",
				BEACH_RING,
				kit.with_marker(point "beach_south", BEACH_RING, kit.watch_count("landing", 1, labs_ashore))
			),
		},
	},
	objective = { title = "Kill the enemy commander", lines = { "Before time runs out" } },
	finish = nil,
	is_over = nil,
	preload = nil,
}

return table.freeze(GUIDE)
