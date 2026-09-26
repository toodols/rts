--!strict
-- A mission played as a game against the computer, on one of the usual maps (Prairie Skirmish): its campaign.Mission has
-- an `ai_profile`. The players choose their starts in their start box as in any game (its map names no PLAYER_START,
-- mission_map.player_start), and once the game has begun the enemy is handed to the AI (server/ai), playing by the
-- mission's profile, or in its hard mode by its `hard_mode_ai_profile` if it has one, with a commander put down at the
-- start furthest from everyone (spawning.free_start). It is played to the commanders end mode both ways: the enemy is
-- beaten once its commander is dead, as the players are once theirs are.

local ReplicatedStorage = game:GetService "ReplicatedStorage"
local ServerScriptService = game:GetService "ServerScriptService"

local types = require(ReplicatedStorage.Shared.types)
local ai_profiles = require(ReplicatedStorage.Shared.ai_profiles)

local ai = require(ServerScriptService.Server.ai)

local kit = require(script.Parent.kit)

type TeamId = types.TeamId
type Profile = ai_profiles.Profile

-- The enemy's team, and the profile it plays by, until it has been handed to the AI.
local waiting: { team: TeamId, profile: Profile }? = nil

local function reset()
	waiting = nil
end

-- The enemy plays as `enemy`, with nothing on the field until the game has begun (`tick`).
local function setup(enemy: TeamId, playing: kit.Playing)
	local mission = playing.mission
	local name = if playing.hard and mission.hard_mode_ai_profile ~= nil
		then mission.hard_mode_ai_profile
		else mission.ai_profile
	local profile = if name ~= nil then ai_profiles.get(name) else nil
	if profile == nil then
		warn(`{mission.id}'s AI profile "{name}" is not one there is`)
		waiting = nil
		return
	end
	waiting = { team = enemy, profile = profile }
end

-- Once the game has begun, and so the players have chosen their starts, the enemy is handed to the AI.
local function tick(_delta: number)
	local enemy = waiting
	if enemy == nil then
		return
	end
	waiting = nil
	if ai.take_over(enemy.team, nil, enemy.profile) == false then
		warn "the mission found no start for its enemy's commander"
	end
end

local handler: kit.Handler = {
	setup = setup,
	reset = reset,
	tick = tick,
	end_mode = "commanders",
	enemy_end_mode = "commanders",
}

return table.freeze({
	handler = table.freeze(handler),
})
