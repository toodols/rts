--!strict
-- Channel Crossing's guide, which follows the mission as it is built (shared/mission_forces.luau's CHANNEL_ENEMY): put
-- a shipyard in the harbour; destroy the island's Agitators with Riptides, then the enemy shore's; and land Garpikes on
-- that shore. By this mission the player knows how to build an economy, so the guide does not ask for
-- one. What is left is the objective: the enemy's commander, before the time runs out (the HUD shows how long is left).

local ReplicatedStorage = game:GetService "ReplicatedStorage"

local mission_map = require(ReplicatedStorage.Shared.mission_map)
local mission_state = require(ReplicatedStorage.Shared.mission_state)
local mission_forces = require(ReplicatedStorage.Shared.mission_forces)
local entity_attrs = require(ReplicatedStorage.Shared.entity_attrs)
local types = require(ReplicatedStorage.Shared.types)

local world = require(ReplicatedStorage.Client.world)

local kit = require(script.Parent.kit)

type EntityDef = types.EntityDef
type Guide = kit.Guide

-- How many Garpikes the landing step asks for ashore.
local LANDING = 6
-- How wide the rings on the harbour, the island and the enemy's shore are.
local HARBOR_RING = 12
local ISLAND_RING = 40
local SHORE_RING = 40
-- What is east of this is the enemy's shore; west of it, the island or the water.
local ENEMY_SHORE_X = 150
-- Ashore on the enemy's side: east of its waterline.
local ASHORE_X = 180

-- How many Agitators the mission lays out on the island (`on_island`) or on the enemy's shore.
local function laid_agitators(on_island: boolean): number
	local count = 0
	for _, each in mission_forces.CHANNEL_ENEMY do
		if each.def_name == "agitator" and (each.at.X < ENEMY_SHORE_X) == on_island then
			count += 1
		end
	end
	return count
end

-- How many of the enemy's Agitators on the island (`on_island`) or on its shore are gone, of how many it has there. It
-- counts none gone until it has seen one standing, so that a field not yet loaded does not count as cleared.
local function agitators_gone(on_island: boolean): () -> number
	local total = laid_agitators(on_island)
	local seen = false
	return function(): number
		local enemy = mission_state.enemy_team()
		if enemy == nil then
			return 0
		end
		local left = 0
		for _, model in world.all() do
			local def = world.def_of(model)
			if
				def ~= nil
				and def.name == "agitator"
				and entity_attrs.team(model) == enemy
				and (world.position_of(model).X < ENEMY_SHORE_X) == on_island
			then
				left += 1
			end
		end
		if left > 0 then
			seen = true
		end
		return if seen then total - left else 0
	end
end

-- How many of your Garpikes are ashore on the enemy's side.
local function garpikes_ashore(): number
	local count = 0
	for _, model in
		kit.mine(function(def: EntityDef): boolean
			return def.name == "garpike"
		end, false)
	do
		if world.position_of(model).X > ASHORE_X then
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
			id = "island",
			title = "Destroy the island's Agitators",
			cards = {
				{
					id = "island",
					caption = "Riptides",
					mark = "check",
					picture = { kind = "unit", def_name = "riptide" },
				},
			},
			click = { kind = "build", def_name = "riptide" },
			watch = kit.with_marker(
				point "island",
				ISLAND_RING,
				kit.watch_count("island", laid_agitators(true), agitators_gone(true))
			),
		},
		{
			id = "shore",
			title = "Destroy the shore's Agitators",
			cards = {
				{
					id = "shore",
					caption = "Riptides",
					mark = "check",
					picture = { kind = "unit", def_name = "riptide" },
				},
			},
			watch = kit.with_marker(
				point "east_shore",
				SHORE_RING,
				kit.watch_count("shore", laid_agitators(false), agitators_gone(false))
			),
		},
		{
			id = "landing",
			title = "Land Garpikes",
			cards = {
				{
					id = "landing",
					caption = "Garpikes ashore",
					mark = "check",
					picture = { kind = "unit", def_name = "garpike" },
				},
			},
			click = { kind = "build", def_name = "garpike" },
			watch = kit.with_marker(
				point "east_shore",
				SHORE_RING,
				kit.watch_count("landing", LANDING, garpikes_ashore)
			),
		},
	},
	objective = { title = "Kill the enemy commander", lines = { "Before time runs out" } },
	finish = nil,
	is_over = nil,
	preload = nil,
}

return table.freeze(GUIDE)
