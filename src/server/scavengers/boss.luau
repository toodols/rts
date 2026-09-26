--!strict
-- The scavengers' end, and so the game's: their boss comes, once a game, when their last beacon falls or the game's
-- progress runs out (`summon`), with the difficulty's health like everything else of theirs, and hunts as their units
-- do; and when it has been destroyed, and not only cleared away with the map, every side but theirs has won. A game
-- that is already over, played on after, stays over as it ended.

local ReplicatedStorage = game:GetService "ReplicatedStorage"
local ServerScriptService = game:GetService "ServerScriptService"

local types = require(ReplicatedStorage.Shared.types)
local teams = require(ReplicatedStorage.Shared.teams)
local unit_defs = require(ReplicatedStorage.Shared.unit_defs)
local heightmap = require(ReplicatedStorage.Shared.heightmap)
local game_phase = require(ReplicatedStorage.Shared.game_phase)

local state = require(ServerScriptService.Server.state)
local deaths = require(ServerScriptService.Server.deaths)

local progress = require(script.Parent.progress)
local sites = require(script.Parent.sites)

type Entity = types.Entity
type EntityId = types.EntityId

-- What the players are told when it falls.
local DEFEATED = "The Scavenger Overlord has fallen"
-- It comes down this far from where it is summoned, or further out if there is no room.
local RING_START = 12

-- Their boss: the def whose role is "boss".
local function find_boss(): string
	for name, def in unit_defs.defs do
		if unit_defs.is_boss(def) then
			return name
		end
	end
	error "the scavengers have no boss"
end
local BOSS = find_boss()

-- Whether it has come this game; and once it has been destroyed, which one it was, until it is gone (`forget`).
local came = false
local fallen: EntityId? = nil

-- Their boss comes near `near`, if it has not come this game.
local function summon(near: Vector3)
	if came then
		return
	end
	local spot = sites.spot_near(BOSS, near, RING_START)
	local at = if spot ~= nil then spot.position else heightmap.ground_position(near.X, near.Z)
	local facing = if spot ~= nil then spot.facing else 0
	progress.toughen(state.create_entity(BOSS, teams.SCAVENGER, at, facing, "active"))
	came = true
end

local function has_come(): boolean
	return came
end

-- `entity` is leaving the map for `cause`: their boss destroyed, and not only cleared away with the map, has lost them
-- the game once it is gone.
local function note_destroyed(entity: Entity, cause: deaths.DeathCause)
	if cause ~= "removed" and unit_defs.is_boss(entity.def) then
		fallen = entity.id
	end
end

-- Every side but the scavengers has won.
local function defeated()
	if game_phase.phase() == "ended" then
		return
	end
	local winners = {}
	for id in state.all_teams() do
		if id ~= teams.SCAVENGER then
			table.insert(winners, id)
		end
	end
	table.sort(winners)
	game_phase.set_ended(winners, DEFEATED)
end

local function forget(id: EntityId)
	if fallen == id then
		fallen = nil
		defeated()
	end
end

-- A new game on a new map: it has not come.
local function reset()
	came = false
	fallen = nil
end

return table.freeze({
	summon = summon,
	has_come = has_come,
	note_destroyed = note_destroyed,
	forget = forget,
	reset = reset,
})
