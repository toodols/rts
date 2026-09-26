--!strict
-- The overlook, on the "overlook" map: the player's commander on the plateau, and below its cliff an enemy which only
-- stands there: fifteen things (shared/mission_forces.luau's OVERLOOK_ENEMY, and an extractor on each of its two metal
-- spots), some within reach of a thug
-- at the cliff's edge and the rest beyond it. Its energy storage starts full, so that its guards have the energy to
-- fire for some time. In its hard mode it has OVERLOOK_HARD_ENEMY as well: an agitator in its base, whose shells reach
-- the plateau. The counterattack (counterattack.luau) lays the same base down again, wrecked.

local ReplicatedStorage = game:GetService "ReplicatedStorage"
local ServerScriptService = game:GetService "ServerScriptService"

local types = require(ReplicatedStorage.Shared.types)
local mission_map = require(ReplicatedStorage.Shared.mission_map)
local mission_forces = require(ReplicatedStorage.Shared.mission_forces)

local state = require(ServerScriptService.Server.state)

local kit = require(script.Parent.kit)

type TeamId = types.TeamId
type Placed = kit.Placed
type Thing = mission_forces.Thing

-- One of the enemy's things (mission_forces.OVERLOOK_ENEMY): what is out in front stands `from_edge` studs east of
-- wherever the cliff's edge is at its z (mission_map.brink_x), since the edge wanders.
local ENEMY = mission_forces.OVERLOOK_ENEMY

-- Enough energy to fill whatever the enemy can store.
local ENEMY_ENERGY = 1e6

-- Where one of ENEMY stands, in world (x, z).
local function enemy_at(each: Thing): Vector2
	local x = if each.from_edge ~= nil then mission_map.brink_x(each.at.Y) + each.from_edge else each.at.X
	return Vector2.new(x, each.at.Y)
end

-- Whether the metal spot at `spot` is below the cliff, the enemy's.
local function is_below(spot: Vector3): boolean
	return spot.X >= mission_map.brink_x(spot.Z)
end

local function setup(enemy: TeamId, playing: kit.Playing)
	-- first, so that nothing else takes their spots
	kit.place_extractors(enemy, kit.extractor_sites(is_below, kit.WEST), kit.WEST)
	local placed: { Placed } = {}
	for _, each in ENEMY do
		table.insert(placed, { def_name = each.def_name, at = enemy_at(each) })
	end
	if playing.hard then
		for _, each in mission_forces.OVERLOOK_HARD_ENEMY do
			table.insert(placed, { def_name = each.def_name, at = enemy_at(each) })
		end
	end
	kit.place_all(placed, enemy, kit.WEST)
	-- it has built nothing, so its storages start as full as the economy lets them be
	local team = state.get_team(enemy)
	if team ~= nil then
		team.energy = ENEMY_ENERGY
	end
end

local handler: kit.Handler = { setup = setup }

return table.freeze({
	handler = table.freeze(handler),
	enemy_at = enemy_at,
	is_below = is_below,
})
