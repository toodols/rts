--!strict
-- Tests of piloting (shared/piloting.luau): a developer steering a unit, aiming it and firing it, and airlifting.
-- Nobody joins a test, so a player is seated for it (harness.join), whose client's word reaches possession.luau's
-- handlers as a real one's would (harness.send): taking a unit in hand, and what they ask of a hold. What they steer, aim
-- and fire is written to the pilot straight, as possession's input handler writes it: the test runs far faster than a
-- client sends its input, so the pilot never goes quiet. That handler's own checks are pilot_remotes'.

local ReplicatedStorage = game:GetService "ReplicatedStorage"
local ServerScriptService = game:GetService "ServerScriptService"

local types = require(ReplicatedStorage.Shared.types)
local tick_rate = require(ReplicatedStorage.Shared.tick_rate)
local heightmap = require(ReplicatedStorage.Shared.heightmap)
local unit_defs = require(ReplicatedStorage.Shared.unit_defs)
local piloting = require(ReplicatedStorage.Shared.piloting)
local geometry = require(ReplicatedStorage.Shared.geometry)

local state = require(ServerScriptService.Server.state)
local damage = require(ServerScriptService.Server.damage)
local orders = require(ServerScriptService.Server.orders)
local pilots = require(ServerScriptService.Server.pilots)

local harness = require(script.Parent.harness)

local OWN = harness.OWN
local ENEMY = harness.ENEMY
local UNKILLABLE = harness.UNKILLABLE
local NOCOST = harness.NOCOST
local advance = harness.advance
local round = harness.round
local spawn = harness.spawn
local unkillable = harness.unkillable
local damage_to = harness.damage_to
local with_switch = harness.with_switch
local in_flight = harness.in_flight
local shots_of = harness.shots_of

type Entity = types.Entity
type Args = harness.Args
type Findings = harness.Findings
type Test = harness.Test

-- How far out, as a share of its weapon's range, a piloted bolt may come down: fired level from a plane's height it arcs
-- down about as far again as its range (unit_defs/air_t2.luau's BOLT_SPENT_DRAG), a little more for a pellet its
-- spread throws upward, where one that flew on as BAR's do would go on for as long as it was watched.
local MOST_OVER_RANGE = 3

-- `entity` taken in hand by `player`, or by a developer of its team seated for it, as their client asks (Possess): a
-- pilot who never goes quiet.
local function take_over(entity: Entity, player: Player?): pilots.Pilot
	harness.send("Possess", player or harness.join(entity.team, true), entity.id)
	local pilot = pilots.get(entity.id)
	assert(pilot ~= nil, `{entity.def_name} could not be taken in hand`)
	pilot.heard_at = math.huge
	return pilot
end

-- Has the pilot of `entity_id` ask for `request` of a hold, on the next step, as their client asks (PilotCargo).
local function ask_hold(entity_id: types.EntityId, request: pilots.CargoRequest)
	harness.send("PilotCargo", (pilots.get(entity_id) :: pilots.Pilot).player, request)
end

-- A piloted commander walks where it is steered, at its own top speed, and faces where its pilot looks, whatever its
-- orders say; its weapon holds its fire until the trigger is held, then fires at the enemy aimed at, or at the ground
-- aimed at; its disintegrator fires when asked; and once let go it carries on with its orders.
local function pilot_test(_args: Args): Findings
	local findings: Findings = {}
	local commander = unkillable(spawn("commander", OWN, 0, 0))
	local def = commander.def
	local primary = piloting.primary_weapon(def) :: number
	orders.issue(
		commander,
		{ { kind = "move", position = heightmap.ground_position(200, 0), target_id = nil } },
		false,
		false
	)
	local pilot = take_over(commander)
	pilot.steer = Vector3.new(0, 0, 1)

	local start = commander.position
	advance(3)
	findings.walked = { x = round(commander.position.X - start.X, 2), z = round(commander.position.Z - start.Z, 2) }
	findings.top_speed = round(def.max_speed :: number, 2)
	findings.speed = round(commander.velocity.Magnitude, 2)
	findings.orders_kept = #commander.orders

	pilot.steer = Vector3.zero
	pilot.facing = math.pi / 2
	advance(0.5)
	findings.facing = round(commander.facing, 3)

	-- an enemy well within reach, off the way it now faces
	local weapon = (def.weapons :: { types.Weapon })[primary]
	local here = commander.position
	local enemy = unkillable(spawn("grunt", ENEMY, here.X + weapon.range * 0.6, here.Z))
	-- aimed at a point on the near side of it, as a crosshair on it would be, and not at it: whatever the shot's line
	-- goes into there is what it hits
	pilot.aim = enemy.position - Vector3.new(unit_defs.collider_radius(enemy.def) * 0.9, 0, 0)
	pilot.target_id = nil
	local shots = shots_of(commander.id, primary)
	advance(2)
	findings.held_fire = shots_of(commander.id, primary) == shots and enemy.health == UNKILLABLE

	pilot.firing = true
	advance(2)
	findings.shots_at_enemy = shots_of(commander.id, primary) - shots
	findings.enemy_damage = round(damage_to(enemy), 1)

	-- the ground, off to the side, with no enemy aimed at
	pilot.target_id = nil
	pilot.aim = heightmap.ground_position(here.X, here.Z + weapon.range * 0.5)
	shots = shots_of(commander.id, primary)
	advance(2)
	findings.shots_at_ground = shots_of(commander.id, primary) - shots

	-- the disintegrator, the other way, at something it has never been ordered to shoot
	pilot.firing = false
	local manual = def.manual_weapon :: types.ManualWeapon
	local victim = spawn("grunt", ENEMY, here.X - manual.range * 0.5, here.Z)
	-- it spends energy a shot, which a team in a test has none of
	with_switch(NOCOST, true, function()
		pilot.ability = victim.position
		advance(0.2)
	end)
	findings.disintegrated = victim.alive == false
	findings.manual_reloading = commander.manual_reload_remaining > 0

	-- let go, it takes up its move order again
	pilots.clear(commander.id)
	local before = commander.position.X
	advance(2)
	findings.resumed_orders = round(commander.position.X - before, 2)
	findings.pass = math.abs(findings.walked.x) < 0.5
		and findings.walked.z > 0
		and math.abs(findings.speed - findings.top_speed) <= findings.top_speed * 0.05
		and findings.orders_kept > 0
		and math.abs(findings.facing - math.pi / 2) < 0.05
		and findings.held_fire
		and findings.shots_at_enemy > 0
		and findings.enemy_damage > 0
		and findings.shots_at_ground > 0
		and findings.disintegrated
		and findings.manual_reloading
		and findings.resumed_orders > 0
	return findings
end

-- A piloted anti air bot with its trigger held, aimed near an enemy aircraft coming at it, `args.prey` or a Whirlwind:
-- well off it, 40 degrees, it fires where it is aimed, unguided, and misses; within a few degrees of it, it locks on to
-- it and hits it. Then a piloted Tyrannus with its plasma chosen and the trigger up, with that aircraft over it: its
-- anti air missiles, not chosen, hold their fire.
local function pilot_aa(args: Args): Findings
	local findings: Findings = {}
	local launcher = unkillable(spawn("trasher", OWN, 0, 0))
	local bait = unkillable(spawn("solar_collector", OWN, 30, 0))
	local prey = unkillable(spawn(args.prey or "whirlwind", ENEMY, -250, 40))
	advance(tick_rate.TICK_DELTA)
	orders.issue(prey, { { kind = "attack", target_id = bait.id } }, false, false)
	local pilot = take_over(launcher)
	pilot.firing = true
	pilot.weapon = 1
	-- aims `angle` round from the aircraft, as far again past it
	local function aim_off(angle: number): () -> ()
		return function()
			local to = prey.position - launcher.position
			pilot.aim = launcher.position + CFrame.Angles(0, angle, 0):VectorToWorldSpace(to) * 2
		end
	end
	aim_off(math.rad(40))()
	advance(10, aim_off(math.rad(40)))
	local shots = shots_of(launcher.id, 1)
	findings.shots_aimed_40_off = shots
	findings.damage_aimed_40_off = round(damage_to(prey), 1)
	local health = prey.health
	advance(10, aim_off(math.rad(6)))
	findings.shots_aimed_6_off = shots_of(launcher.id, 1) - shots
	findings.damage_aimed_6_off = round(health - prey.health, 1)
	pilots.clear(launcher.id)

	local fortress = unkillable(spawn("tyrannus", OWN, 10, 10))
	advance(tick_rate.TICK_DELTA)
	local fortress_pilot = take_over(fortress)
	fortress_pilot.weapon = 1
	advance(5)
	findings.unchosen_aa_shots = shots_of(fortress.id, 3)
	pilots.clear(fortress.id)
	findings.pass = findings.shots_aimed_40_off > 0
		and findings.damage_aimed_40_off == 0
		and findings.shots_aimed_6_off > 0
		and findings.damage_aimed_6_off > 0
		and findings.unchosen_aa_shots == 0
	return findings
end

-- Airlifting while piloting. A piloted Hercules over a Grunt, brought down onto it, has it in its hook's reach and picks
-- it up when asked (J); taken back up it cannot set it down, and brought down again it can, and does (U). Then the
-- Grunt, piloted, calls the Hercules over (G), is picked up, and its pilot finds themself piloting the Hercules; set
-- down again, they are back in the Grunt. Called again from further off, the Hercules is shot down on its way, and the
-- Grunt's pilot is told so.
local function pilot_airlift(_args: Args): Findings
	local findings: Findings = {}
	local grunt = spawn("grunt", OWN, 0, 0)
	local hercules = spawn("hercules", OWN, 0, 0)
	advance(tick_rate.TICK_DELTA)
	local player = harness.join(OWN, true)

	local flying = take_over(hercules, player)
	flying.lift = 1
	advance(3)
	findings.climbed_to = round(flying.height or 0, 2)
	findings.can_load_high = flying.loadable ~= nil
	flying.lift = -1
	advance(6)
	findings.can_load_low = flying.loadable ~= nil
	ask_hold(hercules.id, "load")
	advance(tick_rate.TICK_DELTA * 2)
	findings.loaded = state.carrier_of(grunt.id) == hercules.id
	flying.lift = 1
	advance(3)
	findings.can_unload_high = flying.can_unload
	flying.lift = -1
	advance(6)
	findings.can_unload_low = flying.can_unload
	ask_hold(hercules.id, "unload")
	advance(tick_rate.TICK_DELTA * 2)
	findings.unloaded = state.carrier_of(grunt.id) == nil and state.get(grunt.id) ~= nil
	pilots.clear(hercules.id)

	-- the Hercules goes back up and off to one side, and the Grunt, piloted, calls it
	orders.issue(
		hercules,
		{ { kind = "move", position = heightmap.ground_position(40, 0), target_id = nil } },
		false,
		false
	)
	advance(8)
	local walking = take_over(grunt, player)
	advance(tick_rate.TICK_DELTA * 2)
	findings.transporter_near = walking.transporter == hercules.id
	ask_hold(grunt.id, "call")
	local waited = 0
	while state.carrier_of(grunt.id) == nil and waited < 30 do
		advance(0.5)
		waited += 0.5
	end
	advance(tick_rate.TICK_DELTA * 2)
	findings.called_and_carried = state.carrier_of(grunt.id) == hercules.id
	findings.call_seconds = waited
	findings.now_piloting_hercules = pilots.get(hercules.id) ~= nil
		and pilots.get(grunt.id) == nil
		and piloting.piloted_by(player) == hercules.id

	-- brought down and set down, the pilot is back in the Grunt
	local carrying = pilots.get(hercules.id)
	if carrying ~= nil then
		carrying.lift = -1
		advance(6)
		ask_hold(hercules.id, "unload")
		advance(tick_rate.TICK_DELTA * 2)
	end
	findings.back_in_grunt = pilots.get(grunt.id) ~= nil
		and pilots.get(hercules.id) == nil
		and piloting.piloted_by(player) == grunt.id

	local again = pilots.get(grunt.id)
	if again ~= nil then
		orders.issue(
			hercules,
			{ { kind = "move", position = heightmap.ground_position(40, 0), target_id = nil } },
			false,
			false
		)
		advance(8)
		ask_hold(grunt.id, "call")
		advance(tick_rate.TICK_DELTA * 2)
		findings.call_coming = again.called == hercules.id
		damage.apply(hercules, hercules.health * 10, nil, ENEMY)
		advance(tick_rate.TICK_DELTA * 3)
		findings.call_lost = again.called == nil and again.call_lost_at ~= nil
	end
	pilots.clear(grunt.id)
	pilots.clear(hercules.id)
	findings.pass = findings.can_load_high == false
		and findings.can_load_low
		and findings.loaded
		and findings.can_unload_high == false
		and findings.can_unload_low
		and findings.unloaded
		and findings.transporter_near
		and findings.called_and_carried
		and findings.now_piloting_hercules
		and findings.back_in_grunt
		and findings.call_coming == true
		and findings.call_lost == true
	return findings
end

-- A piloted `args.unit`, a Stronghold unless told otherwise, up at its usual height, firing level at a point far past its
-- range: how far along the ground from it any of its shots got before it came down, against its range, which it should
-- not get far past.
local function bolt_falloff(args: Args): Findings
	local unit = spawn(args.unit or "stronghold", OWN, -200, 0)
	local def = unit_defs.get(unit.def_name)
	local weapon = (def.weapons :: { types.Weapon })[1]
	local pilot = take_over(unit)
	pilot.facing = math.pi / 2
	pilot.weapon = 1
	-- up to its height first
	advance(6)
	pilot.firing = true
	local furthest = 0
	advance(6, function()
		pilot.aim = unit.position + Vector3.new(weapon.range * 20, 0, 0)
		for _, projectile in in_flight() do
			if projectile.owner_id == unit.id then
				furthest = math.max(furthest, geometry.distance_2d(projectile.flight.position, unit.position))
			end
		end
	end)
	pilots.clear(unit.id)
	local shots = shots_of(unit.id, 1)
	return {
		range = round(weapon.range, 1),
		furthest = round(furthest, 1),
		furthest_over_range = round(furthest / weapon.range, 2),
		shots = shots,
		pass = shots > 0 and furthest > 0 and furthest <= weapon.range * MOST_OVER_RANGE,
	}
end

-- What a pilot's client sends is only heard from a developer, for a unit of their own team, and only as far as it is
-- what it should be (server/possession.luau, through server_shared/remotes.luau): someone who is not a developer,
-- a unit of the enemy's, an id that is no number, an input with a steer that is not a real vector, a hold request that
-- is not one and a manual-weapon aim that is not a real point are all refused and change nothing; what is sent right is
-- taken.
local function pilot_remotes(_args: Args): Findings
	local grunt = spawn("grunt", OWN, 0, 0)
	local enemy = spawn("grunt", ENEMY, 40, 0)
	advance(tick_rate.TICK_DELTA)
	local outsider = harness.join(OWN, false)
	harness.send("Possess", outsider, grunt.id)
	local refused_outsider = pilots.get(grunt.id) == nil
	local player = harness.join(OWN, true)
	harness.send("Possess", player, enemy.id)
	harness.send("Possess", player, 0 / 0)
	harness.send("Possess", player, tostring(grunt.id))
	local refused_bad = pilots.get(enemy.id) == nil and piloting.piloted_by(player) == nil
	harness.send("Possess", player, grunt.id)
	local pilot = pilots.get(grunt.id)
	local taken = pilot ~= nil and piloting.piloted_by(player) == grunt.id
	if pilot == nil then
		return { refused_outsider = refused_outsider, refused_bad = refused_bad, taken = false, pass = false }
	end
	harness.send("PilotInput", player, { steer = Vector3.new(0 / 0, 0, 1), firing = true })
	harness.send("PilotInput", player, { steer = Vector3.new(0, 0, 1), facing = math.huge, firing = true })
	local input_refused = pilot.steer == Vector3.zero and pilot.firing == false
	harness.send("PilotInput", player, { steer = Vector3.new(0, 0, 2), facing = 1, firing = true })
	local input_taken = pilot.steer == Vector3.new(0, 0, 1) and pilot.facing == 1 and pilot.firing
	harness.send("PilotCargo", player, "fly")
	harness.send("PilotAbility", player, Vector3.new(math.huge, 0, 0))
	local asks_refused = pilot.cargo == nil and pilot.ability == nil
	harness.send("PilotCargo", player, "call")
	harness.send("PilotAbility", player, Vector3.new(10, 0, 0))
	local asks_taken = pilot.cargo == "call" and pilot.ability == Vector3.new(10, 0, 0)
	pilots.clear(grunt.id)
	return {
		refused_outsider = refused_outsider,
		refused_bad = refused_bad,
		taken = taken,
		input_refused = input_refused,
		input_taken = input_taken,
		asks_refused = asks_refused,
		asks_taken = asks_taken,
		pass = refused_outsider
			and refused_bad
			and taken
			and input_refused
			and input_taken
			and asks_refused
			and asks_taken,
	}
end

local TESTS: { [string]: Test } = {
	pilot = { run = pilot_test },
	pilot_remotes = { run = pilot_remotes },
	pilot_aa = { run = pilot_aa },
	pilot_airlift = { run = pilot_airlift },
	bolt_falloff = { run = bolt_falloff },
}

return table.freeze(TESTS)
