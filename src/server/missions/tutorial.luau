--!strict
-- The tutorial, on the "tutorial" map: the boulder (`tutorial_boulder`, nobody's) in the map's pass, a wall until it is
-- disintegrated (see obstacles.luau and the def's `damage_immunity`), and on the far side an enemy which only stands
-- there: a bot lab, two solar collectors, four grunts, and a metal extractor on each of the metal spots on its side of
-- the pass.

local ReplicatedStorage = game:GetService "ReplicatedStorage"
local ServerScriptService = game:GetService "ServerScriptService"

local types = require(ReplicatedStorage.Shared.types)
local mission_map = require(ReplicatedStorage.Shared.mission_map)
local teams = require(ReplicatedStorage.Shared.teams)

local state = require(ServerScriptService.Server.state)
local placement = require(ServerScriptService.Server.placement)

local kit = require(script.Parent.kit)

type TeamId = types.TeamId
type Placed = kit.Placed

local BOULDER_DEF = "tutorial_boulder"
-- Turned a quarter turn, so that its long side is across the pass, which runs east to west.
local BOULDER_FACING = math.pi / 2

-- The enemy, from its start: what, and where, in studs east and north of it. They face west, at the player.
local ENEMY: { Placed } = {
	{ def_name = "bot_lab", at = Vector2.new(8, 0) },
	{ def_name = "solar_collector", at = Vector2.new(24, -20) },
	{ def_name = "solar_collector", at = Vector2.new(24, 20) },
	{ def_name = "grunt", at = Vector2.new(-14, -18) },
	{ def_name = "grunt", at = Vector2.new(-14, -6) },
	{ def_name = "grunt", at = Vector2.new(-14, 6) },
	{ def_name = "grunt", at = Vector2.new(-14, 18) },
}

-- The boulder, with its middle in the pass, belonging to nobody. It is a building, so a wall (obstacles.luau).
local function place_boulder(at: Vector2)
	local center = placement.ground_center(BOULDER_DEF, at.X, at.Y)
	state.create_entity(BOULDER_DEF, teams.NEUTRAL, center, BOULDER_FACING, "active")
end

local function setup(enemy: TeamId)
	local pass = mission_map.here "pass"
	place_boulder(pass)
	-- first, so that nothing else takes their spots
	kit.place_extractors(
		enemy,
		kit.extractor_sites(function(spot: Vector3): boolean
			return spot.X >= pass.X
		end, kit.WEST),
		kit.WEST
	)
	local enemy_start = mission_map.here(mission_map.ENEMY_START)
	local placed: { Placed } = {}
	for _, each in ENEMY do
		table.insert(placed, { def_name = each.def_name, at = enemy_start + each.at })
	end
	kit.place_all(placed, enemy, kit.WEST)
end

local handler: kit.Handler = { setup = setup }

return table.freeze({
	handler = table.freeze(handler),
})
