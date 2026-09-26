--!strict
-- What the server publishes of the campaign mission being played (shared/campaign.luau), for the clients to show:
-- which mission it is, the team its enemy plays as, what its HUD shows (a mission's own: an enemy zone, waves), and
-- once it is over, how the vote on going on to the next, or on retrying it, stands. Each is a replicated field
-- (shared/replicated.luau). The server's missions (server/missions) keep the real state and write it here one way;
-- nothing on the server reads it back.

local ReplicatedStorage = game:GetService "ReplicatedStorage"

local replicated = require(ReplicatedStorage.Shared.replicated)

-- How a mission's waves stand.
export type Waves = {
	-- how many have arrived, 0 while the player prepares, and how many there are
	wave: number,
	waves: number,
	-- whole seconds to the next, none once the last has arrived
	wave_in: number?,
	-- how many of the enemy's things are left standing
	left: number,
}

-- What the HUD shows of a mission, as its handler has it (server/missions/kit.luau): each part only for a mission that
-- has one.
export type Hud = {
	-- the x the enemy zone begins at: whatever is east of it is inside
	zone_x: number?,
	waves: Waves?,
}

-- What a vote is on: going on to the next mission, or trying this one again.
export type VoteKind = "next" | "retry"

-- How the vote on going on to the next mission, or on retrying this one, stands (server/campaign_exit.luau): which it
-- is, who votes and who of them has agreed, by user id, how many it takes, and whether it has been carried.
export type Vote = {
	kind: VoteKind,
	voters: { number },
	agreed: { number },
	needed: number,
	passed: boolean,
}

-- The mission being played, whether in its hard mode, and which run of missions this is: counted up every time one
-- begins, so that a client sees a mission begin again even when it is the same one.
type Run = {
	id: string?,
	hard: boolean,
	run: number,
}

local RUN = replicated.world(
	"mission",
	"run",
	replicated.json(function(decoded: any): Run?
		if typeof(decoded) ~= "table" or typeof(decoded.run) ~= "number" then
			return nil
		end
		return {
			id = if typeof(decoded.id) == "string" then decoded.id else nil,
			hard = decoded.hard == true,
			run = decoded.run,
		}
	end)
)
local ENEMY_TEAM = replicated.world("mission", "enemy_team", replicated.NUMBER)
local HUD = replicated.world(
	"mission",
	"hud",
	replicated.json(function(decoded: any): Hud?
		if typeof(decoded) ~= "table" then
			return nil
		end
		local waves = decoded.waves
		local read_waves: Waves? = nil
		if typeof(waves) == "table" and typeof(waves.wave) == "number" and typeof(waves.waves) == "number" then
			read_waves = {
				wave = waves.wave,
				waves = waves.waves,
				wave_in = if typeof(waves.wave_in) == "number" then waves.wave_in else nil,
				left = if typeof(waves.left) == "number" then waves.left else 0,
			}
		end
		return {
			zone_x = if typeof(decoded.zone_x) == "number" then decoded.zone_x else nil,
			waves = read_waves,
		}
	end)
)
local VOTE = replicated.world(
	"mission",
	"vote",
	replicated.json(function(decoded: any): Vote?
		if typeof(decoded) ~= "table" or typeof(decoded.voters) ~= "table" or typeof(decoded.needed) ~= "number" then
			return nil
		end
		return {
			kind = if decoded.kind == "retry" then "retry" else "next",
			voters = decoded.voters,
			agreed = if typeof(decoded.agreed) == "table" then decoded.agreed else {},
			needed = decoded.needed,
			passed = decoded.passed == true,
		}
	end)
)

-- The server's --------------------------------------------------------------------------------------------------

-- `mission_id` is being played from now, in its hard mode for `hard`, or none for nil: a new run of missions, even when
-- it is the same one.
local function publish_mission(mission_id: string?, hard: boolean)
	local last: Run? = RUN.get()
	RUN.set({ id = mission_id, hard = mission_id ~= nil and hard, run = if last ~= nil then last.run + 1 else 1 })
end

local function publish_enemy(team_id: number?)
	ENEMY_TEAM.set(team_id)
end

local function publish_hud(hud: Hud?)
	HUD.set(hud)
end

local function publish_vote(vote: Vote?)
	VOTE.set(vote)
end

-- The clients' ---------------------------------------------------------------------------------------------------

-- The mission being played, or nil for any other game.
local function mission(): string?
	local run = RUN.get()
	return if run ~= nil then run.id else nil
end

-- Whether the mission being played is in its hard mode.
local function hard(): boolean
	local run = RUN.get()
	return run ~= nil and run.id ~= nil and run.hard
end

-- Calls `listener` with the mission whenever it changes, and when it begins again. Returns a function that stops it.
local function subscribe_mission(listener: (mission_id: string?) -> ()): () -> ()
	return RUN.changed(function()
		listener(mission())
	end)
end

-- The team the mission's enemy plays as, once the server has said.
local function enemy_team(): number?
	return ENEMY_TEAM.get()
end

-- What the HUD shows of the mission being played, or nil when it shows nothing.
local function hud(): Hud?
	return HUD.get()
end

-- Where the enemy zone begins, for a mission that has one.
local function zone_x(): number?
	local shown = hud()
	return if shown ~= nil then shown.zone_x else nil
end

-- How the waves stand, or nil outside a mission with waves.
local function waves(): Waves?
	local shown = hud()
	return if shown ~= nil then shown.waves else nil
end

-- Calls `listener` with where the enemy zone begins whenever that changes, until the returned function is called.
local function subscribe_zone(listener: (x: number?) -> ()): () -> ()
	local last = zone_x()
	return HUD.changed(function()
		local now = zone_x()
		if now ~= last then
			last = now
			listener(now)
		end
	end)
end

-- Calls `listener` with how the waves stand whenever what the HUD shows changes, until the returned function is called.
local function subscribe_waves(listener: (waves: Waves?) -> ()): () -> ()
	return HUD.changed(function()
		listener(waves())
	end)
end

-- How the vote on going on or retrying stands, or nil while there is none.
local function vote(): Vote?
	return VOTE.get()
end

local function subscribe_vote(listener: (vote: Vote?) -> ()): () -> ()
	return VOTE.changed(function()
		listener(vote())
	end)
end

return table.freeze({
	publish_mission = publish_mission,
	publish_enemy = publish_enemy,
	publish_hud = publish_hud,
	publish_vote = publish_vote,
	mission = mission,
	hard = hard,
	subscribe_mission = subscribe_mission,
	enemy_team = enemy_team,
	hud = hud,
	zone_x = zone_x,
	waves = waves,
	subscribe_zone = subscribe_zone,
	subscribe_waves = subscribe_waves,
	vote = vote,
	subscribe_vote = subscribe_vote,
})
