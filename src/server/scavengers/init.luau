--!strict
-- The scavengers gamemode. As the game begins a beacon stands in a start nobody took, and every few minutes another goes
-- up near one already standing, so that they spread out over the map. Once the game is far enough along, every beacon
-- keeps producing hostile units and defences around itself, so the more beacons stand the more come (beacons.luau,
-- which puts them where sites.luau says), and the wrecks near them stand up again as theirs (revival.luau). The units
-- scatter across the map and hunt: anything of a player's that one notices, and has a way to, it attacks (units.luau).
-- What they field is worked out from the defs (roster.luau), and how hard it may be from how far the game has got
-- (progress.luau). Their boss is their end, and the game's (boss.luau). Every number of theirs is settings.luau's.
--
-- The scavengers are a team of their own (`teams.SCAVENGER`), so everything `combat` already knows about enemies
-- applies to them without a special case: defences shoot whatever comes into range, and a player's units shoot them
-- back. Only the beacons' schedule and what the units decide to do live here.
--
-- A new map is a new game (`reset`): nothing of the last is kept but the pace and the health the match set.

local ReplicatedStorage = game:GetService "ReplicatedStorage"
local ServerScriptService = game:GetService "ServerScriptService"

local types = require(ReplicatedStorage.Shared.types)
local teams = require(ReplicatedStorage.Shared.teams)
local switches = require(ReplicatedStorage.Shared.switches)
local scavenger_state = require(ReplicatedStorage.Shared.scavenger_state)

local state = require(ServerScriptService.Server.state)
local deaths = require(ServerScriptService.Server.deaths)
local economy = require(ServerScriptService.Server.economy)

local progress = require(script.progress)
local roster = require(script.roster)
local units = require(script.units)
local beacons = require(script.beacons)
local boss = require(script.boss)
local revival = require(script.revival)
local settings = require(script.settings)

type EntityId = types.EntityId

-- What the client is told: the scavengers' budget, the hardest thing they may make now (shared/scavenger_state.luau),
-- and nothing at all while the gamemode is off, which is how the client knows whether to show it. It is rounded to two
-- significant figures, so it changes every twenty seconds or so at most rather than every tick.
local SHOWN_DIGITS = 2

-- `value` to `digits` significant figures, which is how a number that grows by orders of magnitude is shown without
-- changing every tick.
local function round_significant(value: number, digits: number): number
	if value < 1 then
		return 0
	end
	local step = 10 ^ (math.floor(math.log10(value)) - digits + 1)
	return math.round(value / step) * step
end

-- Called once per step, after income and before orders, so what a unit decides here is what it does this step.
local function tick(delta: number)
	local shown: number? = if switches.is_on "scavengers"
		then round_significant(progress.budget(), SHOWN_DIGITS)
		else nil
	scavenger_state.publish_difficulty(shown)

	beacons.open_once()
	if switches.is_on "scavengers" then
		-- what they have out, looked at once for the step
		local tally: beacons.Tally = { units = units.count(), enemy_air = beacons.enemy_air_exists() }
		beacons.run_boss()
		beacons.run_schedule()
		beacons.run(tally)
		beacons.run_reroll(tally)
		revival.run(delta, beacons.standing(), tally)
	end
	units.run()
end

-- A new map is a new game: everything of the last is forgotten, and the progress starts over.
local function reset()
	progress.reset()
	units.reset()
	beacons.reset()
	boss.reset()
end

-- Makes the scavengers' team, which has no economy: their weapons never want for metal or energy, however many are
-- firing or however much a single shot costs (the Calamity's 18000 energy is past any store). And counts what is
-- destroyed from now on.
local function init()
	if state.get_team(teams.SCAVENGER) == nil then
		local team = state.create_team(teams.SCAVENGER)
		team.name = "Scavengers"
	end
	economy.set_unlimited(teams.SCAVENGER, true)
	deaths.on_destroyed(beacons.note_destroyed)
	deaths.on_destroyed(boss.note_destroyed)
end

-- What a beacon on the sea, or on the land, would make of its units, or its defences, if it made one now, and the
-- chance of each from 0 to 1, likeliest first. Whether there are aircraft about is taken as it stands, so what only
-- shoots at them is in it only while there are.
local function spawn_chances(
	defense: boolean,
	sea: boolean
): { { def_name: string, chance: number, difficulty: number } }
	return roster.spawn_chances(defense, progress.budget(), sea, beacons.enemy_air_exists())
end

-- How the scavengers are set up this game, and where they have got to, for the `gameconfig` command.
local function status(): {
	enabled: boolean,
	progress: number,
	budget: number,
	game_length: number,
	pace: number,
	health_multiplier: number,
	beacons: number,
	units: number,
	next_beacon_in: number?,
	boss: boolean,
}
	return {
		enabled = switches.is_on "scavengers",
		progress = progress.progress(),
		budget = progress.budget(),
		game_length = progress.length(),
		pace = progress.pace(),
		health_multiplier = progress.health_multiplier(),
		beacons = beacons.count(),
		units = units.count(),
		next_beacon_in = beacons.next_beacon_in(),
		boss = boss.has_come(),
	}
end

-- Takes everything of theirs off the map, as if it had never been, whatever the gamemode is doing: what a benchmark
-- clears away before and after it runs.
local function clear()
	for _, entity in state.all() do
		if entity.alive and entity.team == teams.SCAVENGER then
			deaths.destroy(entity, "removed")
		end
	end
end

-- Everything that is gone is forgotten; what was destroyed, and not only cleared away with the map, counts: a beacon
-- moves the game on, and their boss wins it (beacons.luau).
local function forget(entity_id: EntityId)
	units.forget(entity_id)
	beacons.forget(entity_id)
	boss.forget(entity_id)
end

return table.freeze({
	init = init,
	tick = tick,
	forget = forget,
	reset = reset,
	clear = clear,
	set_pace = progress.set_pace,
	set_health_multiplier = progress.set_health_multiplier,
	reroll_credit = units.reroll_credit,
	summon_beacon = beacons.summon_beacon,
	force_beacon = beacons.force_beacon,
	progress = progress.progress,
	set_progress = progress.set_progress,
	set_difficulty = progress.set_difficulty,
	budget = progress.budget,
	spawn_chances = spawn_chances,
	status = status,
	SETTINGS = settings,
})
