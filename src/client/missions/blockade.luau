--!strict
-- Blockade's guide: land a bot lab on the island with the construction ship, and put Agitators on the island, which
-- reach both straits. Once both are done, or the first wave arrives, what is left is the objective: sink the fleets
-- before too many get through.

local ReplicatedStorage = game:GetService "ReplicatedStorage"

local mission_state = require(ReplicatedStorage.Shared.mission_state)
local mission_map = require(ReplicatedStorage.Shared.mission_map)
local mission_forces = require(ReplicatedStorage.Shared.mission_forces)
local types = require(ReplicatedStorage.Shared.types)

local world = require(ReplicatedStorage.Client.world)

local kit = require(script.Parent.kit)

type EntityDef = types.EntityDef
type Guide = kit.Guide

-- How many Agitators the second step asks for.
local AGITATORS = 4
-- How wide the ring on the island's west shore is.
local LANDING_RING = 12
-- The island, in world x: whatever of the player's stands between these is on it.
local ISLAND_WEST_X = -65
local ISLAND_EAST_X = 85

-- How many finished `def_name`s of yours stand on the island.
local function on_island(def_name: string): number
	local count = 0
	for _, model in
		kit.mine(function(def: EntityDef): boolean
			return def.name == def_name
		end, false)
	do
		local x = world.position_of(model).X
		if x > ISLAND_WEST_X and x < ISLAND_EAST_X then
			count += 1
		end
	end
	return count
end

local GUIDE: Guide = {
	steps = {
		{
			id = "landing",
			title = "Land on the island",
			cards = {
				{
					id = "landing",
					caption = "Construction Ship: Bot Lab on the marked shore",
					mark = "check",
					picture = { kind = "unit", def_name = "construction_ship" },
				},
			},
			select = { def_name = "construction_ship" },
			click = { kind = "build", def_name = "bot_lab", next = "Now click on the marked shore" },
			watch = kit.with_marker(
				function(): Vector2
					return mission_map.here "island_west"
				end,
				LANDING_RING,
				kit.watch_count("landing", 1, function(): number
					return on_island "bot_lab"
				end)
			),
		},
		{
			id = "agitators",
			title = "Build Agitators on the island",
			cards = {
				{
					id = "agitators",
					caption = "Agitators on the island",
					mark = "check",
					picture = { kind = "unit", def_name = "agitator" },
				},
			},
			select = { def_name = "construction_bot" },
			click = { kind = "build", def_name = "agitator" },
			watch = kit.watch_count("agitators", AGITATORS, function(): number
				return on_island "agitator"
			end),
		},
	},
	objective = {
		title = "Hold the channel",
		lines = { `Don't let {mission_forces.BLOCKADE_LAYOUT.escape_limit} ships through` },
	},
	finish = nil,
	-- the guide stops when the first wave arrives
	is_over = function(): boolean
		local waves = mission_state.waves()
		return waves ~= nil and waves.wave > 0
	end,
	preload = nil,
}

return table.freeze(GUIDE)
