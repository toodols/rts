--!strict
-- Tests of air transports: picking things up where the ground is awkward, carrying a commander, and what can be done to
-- something while it hangs from one.

local ReplicatedStorage = game:GetService "ReplicatedStorage"
local ServerScriptService = game:GetService "ServerScriptService"

local types = require(ReplicatedStorage.Shared.types)
local ground_levels = require(ReplicatedStorage.Shared.ground_levels)
local tick_rate = require(ReplicatedStorage.Shared.tick_rate)
local heightmap = require(ReplicatedStorage.Shared.heightmap)
local unit_defs = require(ReplicatedStorage.Shared.unit_defs)

local state = require(ServerScriptService.Server.state)
local damage = require(ServerScriptService.Server.damage)
local deaths = require(ServerScriptService.Server.deaths)
local orders = require(ServerScriptService.Server.orders)
local targeting = require(ServerScriptService.Server.targeting)

local harness = require(script.Parent.harness)

local OWN = harness.OWN
local ENEMY = harness.ENEMY
local advance = harness.advance
local now = harness.now
local round = harness.round
local spawn = harness.spawn
local unkillable = harness.unkillable
local clear_world = harness.clear_world
local until_idle = harness.until_idle

type Entity = types.Entity
type Args = harness.Args
type Findings = harness.Findings
type Test = harness.Test

-- A transport more than this far from what it is fetching flies at its usual height, at least this far over the
-- ground under it.
local CRUISING_CLEARANCE = 2
-- A wreck left by something that fell lies within this many studs of the ground, and of where it fell from.
local WRECK_ON_GROUND = 1
local WRECK_UNDER = 5

-- How far the underside of `entity` is above the highest ground under any part of it, read at `samples` points
-- round its edge and under its middle: below zero, it is in the ground.
local function clearance(entity: Entity, samples: number): number
	local def = unit_defs.get(entity.def_name)
	local radius = unit_defs.collider_radius(def)
	local at = entity.position
	local ground = heightmap.height_at(at.X, at.Z)
	for index = 0, samples - 1 do
		local angle = index * (2 * math.pi / samples)
		ground = math.max(ground, heightmap.height_at(at.X + math.cos(angle) * radius, at.Z + math.sin(angle) * radius))
	end
	return at.Y - unit_defs.collider_height(def) / 2 - ground
end

-- A Hephaestus sent to load a commander: once off the ledge above the low ground at the foot of the plateau, and
-- then at `args.slope_feet` (10 by default) spots at the foot of steep slopes, where the ground rises 5 to 12 studs
-- within 3.5. For each: whether it loaded, how long it took, how low it came while still more than 8 studs away
-- (it should be at its usual height), and how low it came at all once it had taken off (below zero is in the ground).
-- It should load every one, never in the ground.
local function transport_pickup(args: Args): Findings
	local function attempt(x: number, z: number, from_x: number): Findings
		local cargo = spawn("commander", OWN, x, z)
		local carrier = spawn("hephaestus", OWN, x + from_x, z)
		advance(tick_rate.TICK_DELTA)
		orders.issue(carrier, { { kind = "load", target_id = cargo.id } }, false, false)

		local started = now()
		local lowest_far, lowest = math.huge, math.huge
		local loaded = until_idle(carrier, 20, function()
			if now() - started < 3 then
				return
			end
			local height = clearance(carrier, 16)
			lowest = math.min(lowest, height)
			local offset = cargo.position - carrier.position
			if Vector3.new(offset.X, 0, offset.Z).Magnitude > 8 then
				lowest_far = math.min(lowest_far, height)
			end
		end) and #state.cargo_of(carrier.id) > 0
		local findings = {
			x = x,
			z = z,
			loaded = loaded,
			seconds = round(now() - started, 2),
			lowest_while_far = round(lowest_far, 2),
			lowest = round(lowest, 2),
			ok = loaded and lowest >= 0 and lowest_far >= CRUISING_CLEARANCE,
		}
		clear_world()
		return findings
	end

	local feet = {}
	local extent = math.min(heightmap.half_extents()) - 20
	for x = -extent, extent, 3 do
		-- the whole map is a lot of ground to read
		if x % 150 == 0 then
			harness.settle()
		end
		for z = -extent, extent, 3 do
			local low = heightmap.height_at(x, z)
			if low <= ground_levels.WATER_LEVEL + 1 then
				continue
			end
			local rise = 0
			for index = 0, 7 do
				local angle = index * math.pi / 4
				rise = math.max(rise, heightmap.height_at(x + math.cos(angle) * 3.5, z + math.sin(angle) * 3.5) - low)
			end
			if rise > 5 and rise < 12 then
				table.insert(feet, { x = x, z = z, rise = round(rise, 1) })
			end
		end
	end

	local count = args.slope_feet or 10
	local at_feet = {}
	local all_ok = true
	for index = 1, math.min(count, #feet) do
		local foot = feet[math.floor(index * #feet / (count + 1))]
		local findings = attempt(foot.x, foot.z, -40)
		findings.rise = foot.rise
		table.insert(at_feet, findings)
		all_ok = all_ok and findings.ok
	end
	local below_ledge = attempt(176, -120, -50)
	return {
		below_ledge = below_ledge,
		slope_feet = at_feet,
		pass = below_ledge.ok and all_ok,
	}
end

-- A commander and transports: an enemy Hephaestus sent to load it should never get it aboard, and its own Hephaestus,
-- shot down with it aboard, should take it down with it, leaving its wreck on the ground below and both as kills for
-- whoever shot the transport down.
local function transport_commander(_args: Args): Findings
	local commander = spawn("commander", OWN, 0, 0)
	local thief = unkillable(spawn("hephaestus", ENEMY, 6, 0))
	advance(tick_rate.TICK_DELTA)
	orders.issue(thief, { { kind = "load", target_id = commander.id } }, false, false)
	until_idle(thief, 10)
	local enemy_loaded = #state.cargo_of(thief.id) > 0
	deaths.destroy(thief, "removed")

	local carrier = spawn("hephaestus", OWN, 6, 0)
	local shooter = unkillable(spawn("commander", ENEMY, 300, 300))
	advance(tick_rate.TICK_DELTA)
	orders.issue(carrier, { { kind = "load", target_id = commander.id } }, false, false)
	until_idle(carrier, 20)
	local own_loaded = #state.cargo_of(carrier.id) > 0
	-- up and away from where it was picked up before it is shot down
	orders.issue(
		carrier,
		{ { kind = "move", position = heightmap.ground_position(40, 0), target_id = nil } },
		false,
		false
	)
	advance(4)
	local hung_at = commander.position
	local kills_before = shooter.kills
	damage.apply(carrier, carrier.health + 1, shooter.id)
	advance(tick_rate.TICK_DELTA)

	local wreck: Entity? = nil
	for _, entity in state.all() do
		if entity.alive and entity.kind == "wreck" and entity.def_name == "commander" then
			wreck = entity
		end
	end
	local ground = heightmap.height_at(hung_at.X, hung_at.Z)
	local wreck_height = if wreck ~= nil
		then wreck.position.Y - unit_defs.collider_height(wreck.def) / 2 - ground
		else nil
	local wreck_offset = if wreck ~= nil then ((wreck.position - hung_at) * Vector3.new(1, 0, 1)).Magnitude else nil
	local kills = shooter.kills - kills_before
	return {
		enemy_loaded = enemy_loaded,
		own_loaded = own_loaded,
		hung_height = round(hung_at.Y - ground, 2),
		commander_alive = commander.alive,
		still_carried = #state.carried(),
		wreck = wreck ~= nil,
		wreck_height = if wreck_height ~= nil then round(wreck_height, 2) else nil,
		wreck_offset = if wreck_offset ~= nil then round(wreck_offset, 2) else nil,
		kills = kills,
		pass = enemy_loaded == false
			and own_loaded
			and commander.alive == false
			and #state.carried() == 0
			and wreck_height ~= nil
			and math.abs(wreck_height) <= WRECK_ON_GROUND
			and (wreck_offset :: number) <= WRECK_UNDER
			and kills == 2,
	}
end

-- Something hanging from a transport can still be targeted: a grunt carried by its own Hephaestus, hovering where it
-- picked it up, is attacked by an enemy grunt told to, shot at by one left to pick its own targets, reclaimed by an
-- enemy construction bot, and sent for by an enemy Hephaestus, each in a spot of its own. The carried grunt should die
-- to the first two, leaving its wreck on the ground under it, be taken apart by the third, paying out its metal and
-- leaving nothing, and never be taken from its transport by the fourth.
local function transport_targets(_args: Args): Findings
	local function carried_grunt(x: number): (Entity, Entity, boolean)
		local cargo = spawn("grunt", OWN, x, 0)
		local carrier = unkillable(spawn("hephaestus", OWN, x + 6, 0))
		advance(tick_rate.TICK_DELTA)
		orders.issue(carrier, { { kind = "load", target_id = cargo.id } }, false, false)
		until_idle(carrier, 20)
		advance(1)
		return cargo, carrier, #state.cargo_of(carrier.id) > 0
	end

	local function wreck_under(at: Vector3): Findings?
		for _, entity in state.all() do
			if entity.alive and entity.kind == "wreck" and entity.def_name == "grunt" then
				local offset = (entity.position - at) * Vector3.new(1, 0, 1)
				if offset.Magnitude < 10 then
					local ground = heightmap.height_at(entity.position.X, entity.position.Z)
					return {
						height = round(entity.position.Y - unit_defs.collider_height(entity.def) / 2 - ground, 2),
						offset = round(offset.Magnitude, 2),
					}
				end
			end
		end
		return nil
	end

	local function shot_at(x: number, ordered: boolean): Findings
		local cargo, carrier, loaded = carried_grunt(x)
		-- well within a grunt's reach of where the transport hovers
		local shooter = unkillable(spawn("grunt", ENEMY, x + 15, 0))
		advance(tick_rate.TICK_DELTA)
		if ordered then
			orders.issue(shooter, { { kind = "attack", target_id = cargo.id } }, false, false)
		end
		local hung_at = cargo.position
		local started = now()
		-- what the shooter makes of it a moment in, while it still hangs there
		local seen: Findings? = nil
		while cargo.alive and now() - started < 30 do
			hung_at = cargo.position
			advance(tick_rate.TICK_DELTA)
			if seen == nil and now() - started >= 1 and cargo.alive then
				seen = {
					has_target = targeting.has_target(shooter),
					can_shoot = targeting.can_shoot(shooter, cargo),
					distance = round(((cargo.position - shooter.position) * Vector3.new(1, 0, 1)).Magnitude, 1),
					cargo_damage = round(cargo.max_health - cargo.health, 1),
				}
			end
		end
		local killed_after = now() - started
		advance(tick_rate.TICK_DELTA)
		local wreck = wreck_under(hung_at)
		local findings: Findings = {
			loaded = loaded,
			hung_height = round(hung_at.Y - heightmap.height_at(hung_at.X, hung_at.Z), 2),
			killed = cargo.alive == false,
			seconds = round(killed_after, 2),
			wreck = wreck,
			still_aboard = #state.cargo_of(carrier.id),
			carrier_alive = carrier.alive,
			seen = seen,
			damage_dealt = round(shooter.damage_dealt, 1),
		}
		findings.ok = loaded
			and cargo.alive == false
			and wreck ~= nil
			and math.abs(wreck.height) <= WRECK_ON_GROUND
			and findings.still_aboard == 0
		clear_world()
		return findings
	end

	local findings: Findings = {
		attacked = shot_at(-200, true),
		auto_targeted = shot_at(0, false),
	}

	local cargo, carrier, loaded = carried_grunt(200)
	local reclaimer = unkillable(spawn("construction_bot", ENEMY, 230, 0))
	advance(tick_rate.TICK_DELTA)
	harness.set_bank(ENEMY, { metal = 0 })
	local team = harness.ensure_team(ENEMY)
	orders.issue(reclaimer, { { kind = "reclaim", target_id = cargo.id } }, false, false)
	local hung_at = cargo.position
	local started = now()
	while cargo.alive and now() - started < 60 do
		hung_at = cargo.position
		advance(tick_rate.TICK_DELTA)
	end
	advance(tick_rate.TICK_DELTA)
	local grunt_metal = unit_defs.get("grunt").metal_cost
	findings.reclaimed = {
		loaded = loaded,
		gone = cargo.alive == false,
		seconds = round(now() - started, 2),
		metal = round(team.metal, 1),
		grunt_metal = grunt_metal,
		wreck = wreck_under(hung_at) ~= nil,
		still_aboard = #state.cargo_of(carrier.id),
	}
	clear_world()

	local held, owner, owner_loaded = carried_grunt(0)
	local thief = unkillable(spawn("hephaestus", ENEMY, 20, 0))
	advance(tick_rate.TICK_DELTA)
	orders.issue(thief, { { kind = "load", target_id = held.id } }, false, false)
	until_idle(thief, 10)
	findings.stolen = {
		loaded = owner_loaded,
		thief_holds = #state.cargo_of(thief.id),
		owner_holds = #state.cargo_of(owner.id),
	}
	local reclaimed = findings.reclaimed
	findings.pass = findings.attacked.ok
		and findings.auto_targeted.ok
		and reclaimed.loaded
		and reclaimed.gone
		and math.abs(reclaimed.metal - grunt_metal) < 1
		and reclaimed.wreck == false
		and reclaimed.still_aboard == 0
		and findings.stolen.loaded
		and findings.stolen.thief_holds == 0
		and findings.stolen.owner_holds == 1
	return findings
end

local TESTS: { [string]: Test } = {
	transport_pickup = { run = transport_pickup },
	transport_commander = { run = transport_commander },
	transport_targets = { run = transport_targets },
}

return table.freeze(TESTS)
