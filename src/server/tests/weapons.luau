--!strict
-- Tests of what weapons do: bombs, EMP, beams, turrets, arcs, stockpiled missiles and interceptors, self-destruct, and
-- who a shot may hurt; and what a new unit's weapons do, from its lab to a duel (the Janus and the Pounder).

local ReplicatedStorage = game:GetService "ReplicatedStorage"
local ServerScriptService = game:GetService "ServerScriptService"

local types = require(ReplicatedStorage.Shared.types)
local ground_levels = require(ReplicatedStorage.Shared.ground_levels)
local tick_rate = require(ReplicatedStorage.Shared.tick_rate)
local teams = require(ReplicatedStorage.Shared.teams)
local heightmap = require(ReplicatedStorage.Shared.heightmap)
local unit_defs = require(ReplicatedStorage.Shared.unit_defs)
local art = require(ReplicatedStorage.Shared.art)
local surface = require(ReplicatedStorage.Shared.surface)
local starts = require(ReplicatedStorage.Shared.starts)
local geometry = require(ReplicatedStorage.Shared.geometry)
local entity_attrs = require(ReplicatedStorage.Shared.entity_attrs)

local state = require(ServerScriptService.Server.state)
local match_stats = require(ServerScriptService.Server.match_stats)
local damage = require(ServerScriptService.Server.damage)
local deaths = require(ServerScriptService.Server.deaths)
local orders = require(ServerScriptService.Server.orders)
local muzzles = require(ServerScriptService.Server.muzzles)
local manual_weapons = require(ServerScriptService.Server.manual_weapons)
local targeting = require(ServerScriptService.Server.targeting)
local emp = require(ServerScriptService.Server.emp)
local alliances = require(ServerScriptService.Server.alliances)
local placement = require(ServerScriptService.Server.placement)
local self_destruct = require(ServerScriptService.Server.self_destruct)
local production = require(ServerScriptService.Server.production)

local harness = require(script.Parent.harness)

local OWN = harness.OWN
local ENEMY = harness.ENEMY
local ALLY = harness.ALLY
local UNKILLABLE = harness.UNKILLABLE
local NOCOST = harness.NOCOST
local ALLY_GRIEFING = harness.ALLY_GRIEFING
local advance = harness.advance
local now = harness.now
local round = harness.round
local spawn = harness.spawn
local spawn_resting = harness.spawn_resting
local unkillable = harness.unkillable
local damage_to = harness.damage_to
local clear_world = harness.clear_world
local with_switch = harness.with_switch
local in_flight = harness.in_flight
local interceptors_in_flight = harness.interceptors_in_flight
local shots_of = harness.shots_of
local stun_left = harness.stun_left
local countdown_left = harness.countdown_left

type Entity = types.Entity
type TeamId = types.TeamId
type Args = harness.Args
type Findings = harness.Findings
type Test = harness.Test

-- Bombs let go further apart than this, in seconds, are from different bursts.
local BURST_GAP = 1
-- A homing missile that stops closing on its target within this many studs of it has flown past it (`aa_missiles`).
local OVERSHOOT_RANGE = 10
-- Of the homing missiles that reach their target's end of the flight, at least this share should hit it.
local AA_HIT_SHARE = 0.75
-- A timer read after a number of ticks is right to within this many seconds.
local TIMING_SLACK = 2 * tick_rate.TICK_DELTA
-- Bearings off a Starlight's nose, in degrees, inside the half its beam fires into, and outside it.
local STARLIGHT_AHEAD = { 0, 60, 85 }
local STARLIGHT_BEHIND = { 95, 135, 180 }

-- A Whirlwind on an attack order against a building it cannot kill, for `args.seconds` (45 by default). For every
-- burst: how many bombs, how far apart in time they were let go, and where each came down along and across the
-- bomber's path, measured from the target (where it was last seen, within a tick of landing). With `args.decoy`, another
-- enemy building sits on its way there, which it should leave alone. It should bomb and hurt the target.
local function bombing(args: Args): Findings
	local target = unkillable(spawn("solar_collector", ENEMY, 150, -60))
	local decoy = if args.decoy then unkillable(spawn("solar_collector", ENEMY, 45, -60)) else nil
	local bomber = spawn("whirlwind", OWN, -60, -60)
	advance(tick_rate.TICK_DELTA)
	orders.issue(bomber, { { kind = "attack", target_id = target.id } }, false, false)

	type Bomb = { released: number, heading: Vector3, last: Vector3 }
	local bombs: { [number]: Bomb } = {}
	local order: { number } = {}
	advance(args.seconds or 45, function()
		for _, projectile in in_flight() do
			if projectile.owner_id ~= bomber.id then
				continue
			end
			local bomb = bombs[projectile.id]
			if bomb == nil then
				local velocity = bomber.velocity
				bomb = {
					released = now() - projectile.flight.age,
					heading = Vector3.new(velocity.X, 0, velocity.Z).Unit,
					last = projectile.flight.position,
				}
				bombs[projectile.id] = bomb
				table.insert(order, projectile.id)
			end
			bomb.last = projectile.flight.position
		end
	end)

	local bursts = {}
	local burst: { [string]: any } = {}
	local previous: Bomb? = nil
	for _, id in order do
		local bomb = bombs[id]
		if previous ~= nil and bomb.released - previous.released <= BURST_GAP then
			table.insert(burst.gaps, round(bomb.released - previous.released, 4))
		else
			burst = { at = round(bomb.released, 2), gaps = {}, landed_along = {}, landed_across = {} }
			table.insert(bursts, burst)
		end
		local offset = Vector3.new(bomb.last.X - target.position.X, 0, bomb.last.Z - target.position.Z)
		local along = offset:Dot(bomb.heading)
		table.insert(burst.landed_along, round(along, 1))
		table.insert(burst.landed_across, round((offset - bomb.heading * along).Magnitude, 1))
		previous = bomb
	end
	local findings: Findings = {
		bombs = #order,
		bursts = bursts,
		damage_to_target = round(damage_to(target), 0),
		damage_to_decoy = if decoy ~= nil then round(damage_to(decoy), 0) else nil,
	}
	findings.pass = #order > 0 and findings.damage_to_target > 0 and (decoy == nil or findings.damage_to_decoy == 0)
	return findings
end

-- EMP (server/emp.luau). A Stiletto bombs a Thug standing beside an enemy commander, which EMP cannot stun; once the
-- Thug is stunned it is ordered away and the Stiletto is shot down, and the Thug is watched: it should hold still until
-- it recovers, and then walk. Then a Grunt is filled with EMP by hand: it is capped at 1 + 20 / 40 of its max health
-- and drains a fortieth of it a second, so it is stunned for 20 seconds, 10 after 10 and not at all after 21. Another
-- is stunned for 5 seconds by hand beside an enemy: it should hold its fire until it is not.
local function emp_test(args: Args): Findings
	local thug = spawn("thug", ENEMY, 100, 0)
	local commander = spawn("commander", ENEMY, 104, 0)
	local bomber = spawn("stiletto", OWN, -150, 0)
	advance(tick_rate.TICK_DELTA)
	orders.issue(bomber, { { kind = "attack", target_id = thug.id } }, false, false)

	local stunned_at: number? = nil
	local held_at: Vector3? = nil
	local drift_while_stunned = 0
	local most_emp, most_stun = 0, 0
	local recovered_at: number? = nil
	local moved_after = 0
	local thug_health = thug.health
	advance(args.seconds or 60, function()
		most_emp = math.max(most_emp, thug.emp / thug.max_health)
		most_stun = math.max(most_stun, stun_left(thug) or 0)
		if stunned_at == nil and emp.is_stunned(thug) then
			stunned_at = now()
			held_at = thug.position
			orders.issue(thug, { { kind = "move", position = heightmap.ground_position(100, 150) } }, false, false)
			if bomber.alive then
				damage.apply(bomber, 1e9)
			end
		elseif held_at ~= nil and recovered_at == nil then
			if emp.is_stunned(thug) then
				drift_while_stunned = math.max(drift_while_stunned, (thug.position - held_at).Magnitude)
			else
				recovered_at = now()
				held_at = thug.position
			end
		elseif held_at ~= nil then
			moved_after = (thug.position - held_at).Magnitude
		end
	end)

	local grunt = spawn("grunt", ENEMY, -100, 100)
	emp.add(grunt, 1e9, 20)
	local capped = grunt.emp / grunt.max_health
	local stun_full = stun_left(grunt)
	advance(10)
	local stun_after_10 = stun_left(grunt)
	advance(11)
	local after_21 = grunt.emp / grunt.max_health

	local guard = spawn("grunt", ENEMY, -100, -100)
	local bait = unkillable(spawn("grunt", OWN, -100, -80))
	advance(tick_rate.TICK_DELTA)
	emp.add(guard, guard.max_health * (1 + 5 / 40), 5)
	orders.issue(guard, { { kind = "attack", target_id = bait.id } }, false, false)
	local before = shots_of(guard.id, 1)
	advance(4.5)
	local shots_stunned = shots_of(guard.id, 1) - before
	advance(args.after or 3)
	local shots_after = shots_of(guard.id, 1) - before - shots_stunned

	local findings: Findings = {
		thug_stunned_at = if stunned_at ~= nil then round(stunned_at, 2) else nil,
		thug_health_lost = round(thug_health - thug.health, 1),
		thug_most_emp = round(most_emp, 3),
		thug_most_stun = round(most_stun, 2),
		thug_drift_while_stunned = round(drift_while_stunned, 2),
		thug_recovered_at = if recovered_at ~= nil then round(recovered_at, 2) else nil,
		thug_moved_after = round(moved_after, 1),
		commander_emp = commander.emp,
		grunt_capped = round(capped, 3),
		grunt_stun_full = if stun_full ~= nil then round(stun_full, 2) else nil,
		grunt_stun_after_10 = if stun_after_10 ~= nil then round(stun_after_10, 2) else nil,
		grunt_after_21 = round(after_21, 3),
		grunt_stunned_after_21 = emp.is_stunned(grunt),
		guard_shots_stunned = shots_stunned,
		guard_shots_after = shots_after,
		guard_stunned_after = emp.is_stunned(guard),
		bait_alive = bait.alive,
	}
	findings.pass = stunned_at ~= nil
		and drift_while_stunned < 0.5
		and recovered_at ~= nil
		and moved_after > 1
		and commander.emp == 0
		and math.abs(capped - 1.5) < 1e-3
		and stun_full ~= nil
		and math.abs(stun_full - 20) < TIMING_SLACK
		and stun_after_10 ~= nil
		and math.abs(stun_after_10 - 10) < TIMING_SLACK
		and math.abs(after_21 - (1.5 - 21 / 40)) < 1e-2
		and findings.grunt_stunned_after_21 == false
		and shots_stunned == 0
		and shots_after > 0
		and findings.guard_stunned_after == false
	return findings
end

-- An anti-air launcher, a Thistle or `args.launcher`, and an enemy bomber, a Whirlwind or `args.prey`, making bombing
-- runs over it for `args.seconds` (60 by default), both unkillable. Of the homing missiles it fires: how many hit, how
-- many times one flew past its target without hitting it (`overshoots`: its distance to the target stopped falling and
-- began to rise again, within OVERSHOOT_RANGE studs of it), how many came round through more than 120 degrees from the
-- way they were launched to go back for it (`circled_back`), and how long those that hit took to. It should fire, and
-- at least AA_HIT_SHARE of its missiles should hit.
local function aa_missiles(args: Args): Findings
	local launcher = unkillable(spawn(args.launcher or "thistle", OWN, 0, 0))
	local bait = unkillable(spawn("solar_collector", OWN, 30, 0))
	local prey = unkillable(spawn(args.prey or "whirlwind", ENEMY, -250, 40))
	advance(tick_rate.TICK_DELTA)
	orders.issue(prey, { { kind = "attack", target_id = bait.id } }, false, false)
	local prey_def = unit_defs.get(prey.def_name)
	local reach = unit_defs.collider_radius(prey_def) + unit_defs.collider_height(prey_def) / 2 + 1

	type Shot = {
		launched: number,
		first: Vector3,
		last: Vector3,
		speed: number,
		distance: number,
		closing: boolean,
		overshoots: number,
		turned: number,
	}
	local shots: { [number]: Shot } = {}
	local fired, hits, overshoots, circled, misses = 0, 0, 0, 0, 0
	local hit_times = {}
	local overshot_at = {}
	local function finish(shot: Shot)
		-- it was last seen a tick before it went off, so as far off as it flies in a tick is near enough
		if (shot.last - prey.position).Magnitude <= reach + shot.speed * tick_rate.TICK_DELTA then
			hits += 1
			table.insert(hit_times, now() - shot.launched)
		else
			misses += 1
		end
		overshoots += shot.overshoots
		if shot.turned > math.rad(120) then
			circled += 1
		end
	end
	advance(args.seconds or 60, function()
		local seen = {}
		for _, projectile in in_flight() do
			if projectile.owner_id ~= launcher.id then
				continue
			end
			seen[projectile.id] = true
			local flight = projectile.flight
			local distance = (flight.position - prey.position).Magnitude
			local shot = shots[projectile.id]
			if shot == nil then
				fired += 1
				shot = {
					launched = now() - flight.age,
					first = flight.velocity.Unit,
					last = flight.position,
					speed = 0,
					distance = distance,
					closing = true,
					overshoots = 0,
					turned = 0,
				}
				shots[projectile.id] = shot
			end
			local closing = distance < shot.distance
			-- a missile that has only just left, and is still slow, can fall behind something quick going away from it for a
			-- moment; flying past it is only ever done close to it
			if shot.closing and closing == false and shot.distance <= OVERSHOOT_RANGE then
				shot.overshoots += 1
				if #overshot_at < 20 then
					table.insert(overshot_at, `{round(shot.distance, 1)} studs off after {round(flight.age, 2)}s`)
				end
			end
			shot.closing = closing
			shot.distance = distance
			shot.last = flight.position
			shot.speed = flight.velocity.Magnitude
			shot.turned = math.max(shot.turned, math.acos(math.clamp(shot.first:Dot(flight.velocity.Unit), -1, 1)))
		end
		for id, shot in shots do
			if seen[id] == nil then
				finish(shot)
				shots[id] = nil
			end
		end
	end)
	local total = 0
	for _, t in hit_times do
		total += t
	end
	return {
		fired = fired,
		hits = hits,
		misses = misses,
		overshoots = overshoots,
		overshot_at = overshot_at,
		circled_back = circled,
		mean_time_to_hit = if #hit_times > 0 then round(total / #hit_times, 2) else nil,
		hits_by_damage = round(
			damage_to(prey) / ((unit_defs.get(launcher.def_name).weapons :: any)[1].damage :: number),
			1
		),
		pass = fired > 0 and hits >= AA_HIT_SHARE * (hits + misses),
	}
end

-- A `args.shooter` (a Pulsar by default) against a commander it cannot kill, `args.distance` (60 by default) away on
-- open ground, until its first beam has gone out: the damage the commander took on each tick from the first shot on,
-- which should come as the weapon's damage split evenly over its beam's time, a slice a tick.
local function beam(args: Args): Findings
	local shooter_def = args.shooter or "pulsar"
	local target = unkillable(spawn_resting("commander", ENEMY, 0, 0))
	spawn_resting(shooter_def, OWN, args.distance or 60, 0)
	local weapon = (unit_defs.get(shooter_def).weapons :: { types.Weapon })[1]
	local delivery = weapon.delivery
	local beam_time = if delivery.kind == "beam" then delivery.time or 0 else 0
	local per_tick = {}
	local last = target.health
	local started = false
	advance(weapon.reload + 5, function()
		local took = last - target.health
		last = target.health
		if took > 0 then
			started = true
		end
		if started and #per_tick * tick_rate.TICK_DELTA < beam_time + 0.5 then
			table.insert(per_tick, round(took, 1))
		end
	end)
	-- the beam's ticks, each a slice of the damage, and nothing after them
	local slices = math.max(1, math.round(beam_time / tick_rate.TICK_DELTA))
	local slice = weapon.damage / slices
	local even = #per_tick > slices
	for index, took in per_tick do
		local want = if index <= slices then slice else 0
		if math.abs(took - want) > 0.1 + want * 0.01 then
			even = false
		end
	end
	return {
		damage = weapon.damage,
		beam_time = beam_time,
		damage_per_tick = per_tick,
		pass = even,
	}
end

-- Each laser tower in turn (or just `args.def`), on the same spot, with an unkillable, unarmed Construction Bot straight
-- behind it at 60% of its first weapon's range, run for `args.seconds` (3 by default). For each weapon with a turret:
-- how long it took to fire its first shot, how long a half turn takes at its turn rate, and where it pointed when it
-- fired (pi or -pi is straight behind): every weapon should turn round and fire at it.
local function turret(args: Args): Findings
	local findings: Findings = {}
	local all_fired = true

	-- lasers are paid for in energy, so the tower's team has to exist
	harness.ensure_team(OWN)
	local def_names: { string } = if typeof(args.def) == "string"
		then { args.def }
		else { "guard", "twin_guard", "warden" }
	for _, def_name in def_names do
		-- every tower in turn on the same spot, which is dry land, cleared between them
		local x = 0
		local tower = unkillable(spawn_resting(def_name, OWN, x, 0))
		local weapons = unit_defs.get(def_name).weapons :: { types.Weapon }
		local behind = unkillable(spawn_resting("construction_bot", ENEMY, x, -weapons[1].range * 0.6))

		local started = now()
		local first_shot: { [number]: number } = {}
		local aim_at_shot: { [number]: number } = {}
		local reloads: { [number]: number } = {}
		advance(args.seconds or 3, function()
			for index in weapons do
				local reload = tower.weapon_reloads[index] or 0
				-- a reload that jumps up is a shot just fired
				if first_shot[index] == nil and reload > (reloads[index] or 0) + 1e-6 then
					first_shot[index] = round(now() - started, 2)
					aim_at_shot[index] = round(tower.weapon_aims[index] or 0, 3)
				end
				reloads[index] = reload
			end
		end)

		local report: { Findings } = {}
		for index, weapon in weapons do
			local turn = weapon.turret
			table.insert(report, {
				first_shot = first_shot[index] or "never",
				half_turn = if turn ~= nil then round(math.pi / turn.turn_rate, 2) else "no turret",
				aim_at_shot = aim_at_shot[index],
				final_aim = round(tower.weapon_aims[index] or 0, 3),
			})
			local aim = aim_at_shot[index]
			if aim == nil or math.abs(math.abs(aim) - math.pi) > 0.2 then
				all_fired = false
			end
		end
		local team = state.get_team(OWN)
		table.insert(report, {
			energy = if team ~= nil then round(team.energy, 0) else "no team",
			target_health_lost = round(damage_to(behind), 0),
			distance = round((behind.position - tower.position).Magnitude, 1),
			range = round(weapons[1].range, 1),
		})
		if damage_to(behind) <= 0 then
			all_fired = false
		end
		findings[def_name] = report
		clear_world()
	end

	findings.pass = all_fired
	return findings
end

-- The Starlight's tachyon beam fires only into the half ahead of it, and it blows up when it dies. On flat open ground,
-- a Starlight facing along z, left to itself, against a building it cannot kill 40 studs off at each of several
-- bearings off its nose, for `args.seconds` (8 by default) each: how much damage that took, which should be some ahead
-- and none behind. Then one told to attack a building right behind it, which it has to turn onto first, and should.
-- Then a Starlight killed beside an enemy building: its blast should hurt it.
local function starlight(args: Args): Findings
	local seconds = args.seconds or 8
	local ground = harness.find_spot(function(x: number, z: number): boolean
		local height = heightmap.height_at(x, z)
		for dx = -40, 40, 20 do
			for dz = -40, 40, 20 do
				if
					heightmap.water_depth(x + dx, z + dz) > 0
					or math.abs(heightmap.height_at(x + dx, z + dz) - height) > 4
				then
					return false
				end
			end
		end
		return true
	end)
	assert(ground ~= nil, "no flat open ground on this map")
	clear_world()

	local result: Findings = {}
	with_switch(NOCOST, true, function()
		-- damage done to a building at `bearing` degrees off a Starlight's nose, with or without an order to attack it
		local function duel(bearing: number, ordered: boolean): number
			local shooter = unkillable(spawn_resting("starlight", OWN, ground.X, ground.Z))
			local angle = math.rad(bearing)
			local target = unkillable(
				spawn_resting(
					"solar_collector",
					ENEMY,
					ground.X + math.sin(angle) * 40,
					ground.Z + math.cos(angle) * 40
				)
			)
			advance(tick_rate.TICK_DELTA)
			if ordered then
				orders.issue(shooter, { { kind = "attack", target_id = target.id } }, false, false)
			end
			advance(seconds)
			local dealt = round(damage_to(target), 0)
			clear_world()
			return dealt
		end

		local findings: Findings = {}
		local pass = true
		for _, bearing in STARLIGHT_AHEAD do
			findings[`idle_{bearing}`] = duel(bearing, false)
			pass = pass and findings[`idle_{bearing}`] > 0
		end
		for _, bearing in STARLIGHT_BEHIND do
			findings[`idle_{bearing}`] = duel(bearing, false)
			pass = pass and findings[`idle_{bearing}`] == 0
		end
		findings.ordered_180 = duel(180, true)

		local victim = unkillable(spawn_resting("solar_collector", ENEMY, ground.X + 12, ground.Z))
		local doomed = spawn_resting("starlight", OWN, ground.X, ground.Z)
		advance(tick_rate.TICK_DELTA)
		damage.apply(doomed, doomed.health + 1)
		advance(tick_rate.TICK_DELTA)
		findings.blast_damage_at_12 = round(damage_to(victim), 0)
		findings.pass = pass and findings.ordered_180 > 0 and findings.blast_damage_at_12 > 0
		result = findings
	end)
	return result
end

-- The Thor and the Behemoth (unit_defs/t3.luau). A Thor on an attack order against a target in a crowd: how much of its
-- lightning the target and the crowd took, how many of the crowd its sparks reached, and whether its own side's unit
-- beside the target was sparked too. Then its stockpiled EMP missile, launched at the target on a launch order (D,
-- `Order.launch`), which should stun it. Then its EMP lasers with an enemy off its right flank only: only the right one should fire. Then a Behemoth
-- firing its gauss cannon (with no energy, so its lasers hold fire) at the nearest of a column of units straight ahead:
-- what each took, and whether the ball was gone by the end.
local function t3_test(args: Args): Findings
	-- on the flattest dry ground there is, so that no hill between them gets in the way of a shot
	local spot: Vector3? = nil
	local flattest = math.huge
	local extent = math.min(heightmap.half_extents()) - 60
	for x = -extent, extent, 16 do
		harness.settle()
		for z = -extent, extent, 16 do
			local low, high = math.huge, -math.huge
			for dx = -15, 30, 5 do
				for dz = -15, 55, 5 do
					local y = heightmap.height_at(x + dx, z + dz)
					low, high = math.min(low, y), math.max(high, y)
				end
			end
			if low > ground_levels.WATER_LEVEL + 1 and high - low < flattest then
				spot = Vector3.new(x, 0, z)
				flattest = high - low
			end
		end
	end
	assert(spot ~= nil, "no dry ground on this map")
	local function put(def_name: string, team: TeamId, x: number, z: number): Entity
		return spawn_resting(def_name, team, spot.X + x, spot.Z + z)
	end
	local function sturdy(def_name: string, team: TeamId, x: number, z: number): Entity
		return unkillable(put(def_name, team, x, z))
	end

	local thor_findings: Findings = {}
	with_switch(NOCOST, true, function()
		local thor = put("thor", OWN, 0, 0)
		local target = sturdy("grunt", ENEMY, 0, 40)
		local crowd: { Entity } = {}
		for index = 1, 7 do
			local angle = index * 2 * math.pi / 7
			table.insert(crowd, sturdy("grunt", ENEMY, math.sin(angle) * 5, 40 + math.cos(angle) * 5))
		end
		local friend = sturdy("grunt", OWN, 0, 42.5)
		advance(tick_rate.TICK_DELTA)
		orders.issue(thor, { { kind = "attack", target_id = target.id } }, false, false)
		advance(args.seconds or 3)
		local crowd_lost, crowd_hit = 0, 0
		for _, other in crowd do
			local lost = damage_to(other)
			crowd_lost += lost
			if lost > 0 then
				crowd_hit += 1
			end
		end
		local lightning_findings = {
			bolts = shots_of(thor.id, 1),
			target_lost = round(damage_to(target), 1),
			crowd_lost = round(crowd_lost, 1),
			crowd_hit = crowd_hit,
			friend_lost = round(damage_to(friend), 1),
			thor_lost = round(thor.max_health - thor.health, 1),
		}

		-- EMP stuns only what it fills past its max health, so the target is made stunnable, and sturdy enough to
		-- outlast the lightning meanwhile
		target.max_health = 20000
		target.health = 20000
		thor.weapon_stockpiles[2].held = 1
		orders.issue(thor, { { kind = "attack", target_id = target.id, launch = true } }, false, false)
		advance(args.missile_seconds or 8)
		local missile_findings = {
			launched = thor.weapon_stockpiles[2].held < 1,
			target_stunned = emp.is_stunned(target),
			target_stun_left = round(stun_left(target) or 0, 2),
		}
		clear_world()

		-- facing 0 is +Z, so +X is along `fire_direction` +90 degrees, weapon 4's
		local flanked = put("thor", OWN, 0, 0)
		sturdy("grunt", ENEMY, 20, 0)
		advance(args.flank_seconds or 2)
		local flank_findings = { minus_90 = shots_of(flanked.id, 3), plus_90 = shots_of(flanked.id, 4) }
		clear_world()
		thor_findings = { lightning = lightning_findings, missile = missile_findings, flanks = flank_findings }
	end)
	local lightning, missile, flanks = thor_findings.lightning, thor_findings.missile, thor_findings.flanks

	local behemoth = put("behemoth", OWN, 0, 0)
	local column: { Entity } = {}
	for index = 0, 3 do
		table.insert(column, sturdy("grunt", ENEMY, 0, 25 + index * 3))
	end
	advance(tick_rate.TICK_DELTA)
	orders.issue(behemoth, { { kind = "attack", target_id = column[1].id } }, false, false)
	advance(args.gauss_seconds or 3)
	local taken = {}
	for _, other in column do
		table.insert(taken, round(damage_to(other), 1))
	end
	local gauss = {
		shots = shots_of(behemoth.id, 1),
		laser_shots = shots_of(behemoth.id, 2) + shots_of(behemoth.id, 3) + shots_of(behemoth.id, 4),
		column_taken = taken,
		in_flight = #in_flight(),
	}

	return {
		ground_spread = round(flattest, 2),
		lightning = lightning,
		missile = missile,
		flanks = flanks,
		gauss = gauss,
		pass = lightning.bolts > 0
			and lightning.target_lost > 0
			and lightning.crowd_hit > 0
			and missile.launched
			and missile.target_stunned
			and flanks.plus_90 > 0
			and flanks.minus_90 == 0
			and gauss.shots > 0
			and gauss.laser_shots == 0
			and taken[1] > 0,
	}
end

-- An anti-air launcher, `args.launcher` or a Thistle, and an enemy fighter flying straight past it, `args.pass` (50)
-- studs to one side, which is within its reach but further than `targeting.STEALTH_DETECTION_RANGE`: first a Nighthawk,
-- which is stealthy and should not be shot at, then a Valiant, which is not and should be.
local function stealth(args: Args): Findings
	local launcher_def = args.launcher or "thistle"
	local pass_by = args.pass or 50
	local function shots_at(plane_def: string): number
		clear_world()
		local launcher = unkillable(spawn(launcher_def, OWN, 0, 0))
		local plane = unkillable(spawn(plane_def, ENEMY, -160, pass_by))
		advance(tick_rate.TICK_DELTA)
		orders.issue(plane, { { kind = "move", position = heightmap.ground_position(160, pass_by) } }, false, false)
		harness.until_idle(plane, args.seconds or 25)
		local fired = 0
		local weapons = unit_defs.get(launcher_def).weapons
		if weapons ~= nil then
			for index in weapons do
				fired += shots_of(launcher.id, index)
			end
		end
		return fired
	end
	local at_nighthawk = shots_at "nighthawk"
	local at_valiant = shots_at "valiant"
	return {
		passed_at = pass_by,
		detection_range = targeting.STEALTH_DETECTION_RANGE,
		launcher_reach = round(unit_defs.attack_range(unit_defs.get(launcher_def)) :: number, 1),
		shots_at_nighthawk = at_nighthawk,
		shots_at_valiant = at_valiant,
		pass = at_nighthawk == 0 and at_valiant > 0,
	}
end

-- The nuclear silo is manual fire (`Weapon.manual_fire`): one with a missile ready and an enemy within reach holds
-- its fire, through a plain attack order too, until it is told to launch (D, `Order.launch`), and then launches,
-- building the next through the reload that follows. A
-- scavengers' silo is given its orders by them (`scavengers`), so it launches with nobody telling it to.
local function nuke_manual(args: Args): Findings
	local silo_def = args.silo or "apocalypse"
	local function ready_silo(team: TeamId, x: number): Entity
		local def = unit_defs.get(silo_def)
		local y = surface.height(def, x, 0) + unit_defs.collider_height(def) / 2
		local silo = unkillable(state.create_entity(silo_def, team, Vector3.new(x, y, 0), 0, "active"))
		silo.weapon_stockpiles[1].held = 1
		return silo
	end

	-- the next missile is paid for as it is built, and what it costs is beside the point
	local findings: Findings = {}
	with_switch(NOCOST, true, function()
		local silo = ready_silo(OWN, 0)
		local target = unkillable(spawn("grunt", ENEMY, 120, 0))
		advance(args.seconds or 5)
		local held = silo.weapon_stockpiles[1].held
		orders.issue(silo, { { kind = "attack", position = nil, target_id = target.id } }, false, false)
		advance(2)
		local held_on_attack = silo.weapon_stockpiles[1].held
		orders.issue(silo, { { kind = "attack", position = nil, target_id = target.id, launch = true } }, false, false)
		advance(2)
		local after_order = silo.weapon_stockpiles[1].held
		-- the next missile goes on being built through the reload that follows a launch
		local reloading = silo.weapon_reloads[1] > 0
		local progress_before = silo.weapon_stockpiles[1].progress
		advance(5)
		local progress_after = silo.weapon_stockpiles[1].progress
		findings = {
			held_fire_without_order = held == 1,
			held_fire_on_plain_attack = held_on_attack == 1,
			launched_when_ordered = after_order == 0,
			stockpile_grew_while_reloading = reloading and progress_after > progress_before,
			reloading_after_launch = reloading,
			stockpile_progress = { round(progress_before, 2), round(progress_after, 2) },
		}
	end)
	clear_world()

	local scavenger_silo = ready_silo(teams.SCAVENGER, 0)
	unkillable(spawn("grunt", OWN, 120, 0))
	advance(args.seconds or 5)
	findings.scavenger_silo_launched = scavenger_silo.weapon_stockpiles[1].held == 0
	findings.pass = findings.held_fire_without_order
		and findings.held_fire_on_plain_attack
		and findings.launched_when_ordered
		and findings.stockpile_grew_while_reloading
		and findings.scavenger_silo_launched
	return findings
end

-- An anti-nuke (`args.def`, the Prevailer by default) works as BAR's do: it stockpiles interceptors faster than a silo
-- builds nukes, launches one on its own at every enemy nuke aimed within its coverage and only one at each, and that
-- one kills it in the air, where it goes off harming nothing. A nuke aimed outside the coverage gets through.
local function anti_nuke(args: Args): Findings
	local findings: Findings = {}
	local anti_def = unit_defs.get(args.def or "prevailer")
	local silo_def = unit_defs.get "apocalypse"
	local interceptor = (anti_def.weapons :: { types.Weapon })[1]
	findings.interceptor_build_time = (interceptor.stockpile :: types.Stockpile).build_time
	findings.nuke_build_time = ((silo_def.weapons :: { types.Weapon })[1].stockpile :: types.Stockpile).build_time

	harness.ensure_team(ENEMY)
	-- somewhere on dry land `distance` out from `from`, trying a sixteenth of a turn at a time
	local function dry_land(from: Vector3, distance: number, turn: number): Vector3
		for step = 0, 15 do
			local angle = turn + step * math.pi / 8
			local x, z = from.X + math.cos(angle) * distance, from.Z + math.sin(angle) * distance
			if heightmap.in_bounds(x, z) and heightmap.height_at(x, z) > ground_levels.WATER_LEVEL + 2 then
				return Vector3.new(x, 0, z)
			end
		end
		error(`no dry land {distance} studs from {from}`)
	end
	-- set down where it could be built, or, for one that needs a vent (a Rampart), on the ground there anyway
	local function building(def_name: string, team: TeamId, at: Vector3): Entity
		local def = unit_defs.get(def_name)
		local center = placement.resolve_center(def_name, at.X, at.Z, 0, nil)
			or surface.position(def, at.X, at.Z) + Vector3.new(0, unit_defs.collider_height(def) / 2, 0)
		return unkillable(state.create_entity(def_name, team, center, 0, "active"))
	end

	local result: Findings = {}
	with_switch(NOCOST, true, function()
		local anti = building(anti_def.name, OWN, dry_land(Vector3.zero, 0, 0))
		local mark = unkillable(spawn("grunt", OWN, anti.position.X + 20, anti.position.Z))
		local silos = {}
		for n = 1, 2 do
			table.insert(silos, building("apocalypse", ENEMY, dry_land(anti.position, 250, n * math.pi / 2)))
		end
		advance(tick_rate.TICK_DELTA * 2)
		anti.weapon_stockpiles[1].held = 5
		anti.weapon_stockpiles[1].progress = 0

		-- every health on the map, to find anything the interceptions hurt
		local function healths(): { [number]: number }
			local out = {}
			for _, entity in state.all() do
				if entity.alive then
					out[entity.id] = entity.health
				end
			end
			return out
		end
		-- the nukes in flight and where each was last seen, to tell where they ended
		local last_seen: { [number]: Vector3 } = {}
		local ended: { Vector3 } = {}
		local function watch()
			local seen: { [number]: Vector3 } = {}
			for _, projectile in in_flight() do
				if projectile.nuke ~= nil and projectile.nuke.intercepted == false then
					seen[projectile.id] = projectile.flight.position
				end
			end
			for id, at in last_seen do
				if typeof(seen[id]) ~= "Vector3" then
					table.insert(ended, at)
				end
			end
			last_seen = seen
		end

		local before = healths()
		for _, silo in silos do
			silo.weapon_stockpiles[1].held = 1
			orders.issue(
				silo,
				{ { kind = "attack_ground", position = mark.position, target_id = nil, launch = true } },
				false,
				false
			)
		end
		local most_in_flight = 0
		-- the leg of its flight each nuke was on when an interceptor was first seen going after it: it should have
		-- climbed to its cruising height by then
		local nuke_phase_at_launch: { string } = {}
		local seen_interceptors: { [number]: boolean } = {}
		advance(args.seconds or 40, function()
			watch()
			local chasing = 0
			for _, flying in interceptors_in_flight() do
				chasing += 1
				if seen_interceptors[flying.id] == nil then
					seen_interceptors[flying.id] = true
					table.insert(nuke_phase_at_launch, flying.chased.flight.phase or "none")
				end
			end
			most_in_flight = math.max(most_in_flight, chasing)
		end)
		local after = healths()
		local hurt = 0
		for id, health in before do
			if after[id] ~= nil and after[id] < health then
				hurt += 1
			end
		end
		local heights = {}
		local all_in_the_air = true
		for _, at in ended do
			local height = math.round(at.Y - heightmap.height_at(at.X, at.Z))
			table.insert(heights, height)
			all_in_the_air = all_in_the_air and height > 10
		end
		findings.covered = {
			nukes_launched = silos[1].weapon_stockpiles[1].held == 0 and silos[2].weapon_stockpiles[1].held == 0,
			interceptors_used = 5 - anti.weapon_stockpiles[1].held,
			most_interceptors_in_flight = most_in_flight,
			nuke_phase_at_launch = nuke_phase_at_launch,
			nukes_ended = #ended,
			ended_above_ground = heights,
			things_hurt = hurt,
		}

		-- aimed well outside the coverage, a nuke is let through
		local far = dry_land(anti.position, interceptor.range * 2.2, 0)
		far = heightmap.ground_position(far.X, far.Z)
		local far_mark = unkillable(spawn("grunt", OWN, far.X, far.Z))
		local held = anti.weapon_stockpiles[1].held
		silos[1].weapon_stockpiles[1].held = 1
		orders.issue(
			silos[1],
			{ { kind = "attack_ground", position = far, target_id = nil, launch = true } },
			false,
			false
		)
		advance(args.seconds or 40)
		findings.uncovered = {
			interceptors_used = held - anti.weapon_stockpiles[1].held,
			landed = far_mark.health < UNKILLABLE,
		}
		findings.pass = findings.interceptor_build_time < findings.nuke_build_time
			and findings.covered.nukes_launched
			and findings.covered.interceptors_used == 2
			and #ended == 2
			and all_in_the_air
			and hurt == 0
			and findings.uncovered.interceptors_used == 0
			and findings.uncovered.landed
		result = findings
	end)
	return result
end

-- Self-destruct (server/self_destruct.luau): each of `args.defs` counts down as long as its def's countdown says, as
-- the Spring engine counts it (BAR's roughly 6 seconds for most, 1.6 for a wall and 11 for a Juggernaut), and then
-- goes, leaving a wreck only if it is a commander. Toggling it again or stopping calls it off.
local function self_destruct_test(args: Args): Findings
	local home = starts.default_spot(1)
	local names: { string } = args.defs or { "grunt", "wall", "juggernaut", "commander" }
	local findings: Findings = {}
	local pass = true
	for index, name in names do
		-- far enough apart that no death explosion reaches the next one
		local entity = spawn_resting(name, OWN, home.X + (index - 1) * 60, home.Y)
		advance(tick_rate.TICK_DELTA)
		self_destruct.toggle(entity)
		local countdown = countdown_left(entity.id) :: number
		local started = now()
		while entity.alive and now() - started < 20 do
			advance(tick_rate.TICK_DELTA)
		end
		local seconds = now() - started
		advance(tick_rate.TICK_DELTA)
		local wrecks = 0
		for _, other in state.all() do
			if other.alive and other.kind == "wreck" and other.def_name == name then
				wrecks += 1
			end
		end
		local wrecks_left = if unit_defs.is_commander(unit_defs.get(name)) then 1 else 0
		findings[name] = {
			seconds = round(seconds, 2),
			countdown = round(countdown, 2),
			gone = entity.alive == false,
			wrecks = wrecks,
		}
		pass = pass
			and entity.alive == false
			and math.abs(seconds - countdown) <= TIMING_SLACK
			and wrecks == wrecks_left
	end

	local toggled = spawn_resting("grunt", OWN, home.X, home.Y + 60)
	local stopped = spawn_resting("grunt", OWN, home.X + 60, home.Y + 60)
	advance(tick_rate.TICK_DELTA)
	self_destruct.toggle(toggled)
	self_destruct.toggle(stopped)
	advance(2)
	self_destruct.toggle(toggled)
	self_destruct.cancel(stopped)
	advance(10)
	findings.toggled_off_alive = toggled.alive
	findings.stopped_alive = stopped.alive
	findings.pass = pass and toggled.alive and stopped.alive
	return findings
end

-- An unkillable `args.veteran` (a Grunt by default) left to fight `args.count` (3) each of `args.victims` (Grunts and
-- Ticks) set round it in a ring: what it has to show for it after `args.seconds` (40), against what BAR's rules say it
-- should if it made every kill and dealt all the damage itself, 0.2 x the victim's power over its own per kill, which it
-- should, alone as it is. Then a friend's shot, which earns nothing.
local function experience(args: Args): Findings
	-- a start spot is open ground, where nothing stands between it and the ring (resting on it, not sunk into it, so
	-- the ground is not in the way of its shots)
	local home = starts.default_spot(1)
	local veteran = unkillable(spawn_resting(args.veteran or "grunt", OWN, home.X, home.Y))
	local victims: { Entity } = {}
	local names: { string } = args.victims or { "grunt", "tick" }
	local count = args.count or 3
	local own_power = unit_defs.power(unit_defs.get(veteran.def_name))
	local expected = 0
	for kind, name in names do
		for index = 1, count do
			local angle = ((kind - 1) * count + index) / (#names * count) * 2 * math.pi
			table.insert(
				victims,
				spawn_resting(name, ENEMY, home.X + 16 * math.cos(angle), home.Y + 16 * math.sin(angle))
			)
			expected += 0.2 * unit_defs.power(unit_defs.get(name)) / own_power
		end
	end
	advance(tick_rate.TICK_DELTA)
	orders.issue(veteran, { { kind = "fight", position = veteran.position } }, false, false)
	advance(args.seconds or 40)
	local dead = 0
	for _, victim in victims do
		if victim.alive == false then
			dead += 1
		end
	end

	local friend = spawn_resting("grunt", OWN, home.X, home.Y + 40)
	local before = veteran.experience
	damage.apply(friend, 10, veteran.id)
	local friendly_fire_earned = veteran.experience - before
	return {
		victims = #victims,
		dead = dead,
		kills = veteran.kills,
		damage_dealt = round(veteran.damage_dealt, 1),
		score_dealt = round(veteran.score_dealt, 1),
		experience = round(veteran.experience, 4),
		expected_if_all_its_own = round(expected, 4),
		friendly_fire_earned = friendly_fire_earned,
		pass = dead == #victims
			and veteran.kills == #victims
			and math.abs(before - expected) <= expected * 0.01
			and friendly_fire_earned == 0,
	}
end

-- Ally griefing (`alliances.may_harm`), off and then on: how much of a shot from OWN's commander an extractor of its
-- own, of an ally's and of an enemy's takes; how much an ally's takes from a shell of OWN's whose shooter is gone;
-- and which of a grunt of each a disintegrator sweeps through survives it. A team's own things and an enemy's are
-- always hurt; an ally's only with griefing on. What the disintegrator takes counts as it would shot down: the enemy's
-- grunt is a kill for the commander, and each grunt taken a loss for its side.
local function ally_griefing(_args: Args): Findings
	for _, team_id in { OWN, ENEMY, ALLY } do
		harness.ensure_team(team_id)
	end
	alliances.ally(OWN, ALLY)
	local home = starts.default_spot(1)

	local function run(enabled: boolean): Findings
		local result: Findings = {}
		with_switch(ALLY_GRIEFING, enabled, function()
			local commander = unkillable(spawn_resting("commander", OWN, home.X, home.Y))
			local mexes: { [string]: Entity } = {
				own = spawn_resting("metal_extractor", OWN, home.X - 20, home.Y + 20),
				ally = spawn_resting("metal_extractor", ALLY, home.X, home.Y + 20),
				enemy = spawn_resting("metal_extractor", ENEMY, home.X + 20, home.Y + 20),
			}
			local taken: { [string]: number } = {}
			for owner, mex in mexes do
				local before = mex.health
				damage.apply(mex, 100, commander.id)
				taken[owner] = before - mex.health
			end
			local before = mexes.ally.health
			damage.apply(mexes.ally, 100, -1, OWN)
			local orphan_shell = before - mexes.ally.health

			-- a row straight ahead of the commander, along -z, well inside the disintegrator's reach
			local row: { [string]: Entity } = {
				own = spawn_resting("grunt", OWN, home.X, home.Y - 8),
				ally = spawn_resting("grunt", ALLY, home.X, home.Y - 13),
				enemy = spawn_resting("grunt", ENEMY, home.X, home.Y - 18),
			}
			advance(tick_rate.TICK_DELTA)
			commander.manual_reload_remaining = 0
			local kills_before = commander.kills
			local lost_before = match_stats.tally_for(ENEMY).lost
			local dgun: any = nil
			with_switch(NOCOST, true, function()
				dgun = manual_weapons.fire(commander, Vector3.new(home.X, 0, home.Y - 30))
			end)
			advance(tick_rate.TICK_DELTA)
			local survived: { [string]: boolean } = {}
			for owner, grunt in row do
				survived[owner] = grunt.alive
			end
			local dgun_kills = commander.kills - kills_before
			local enemy_lost = match_stats.tally_for(ENEMY).lost - lost_before
			clear_world()
			result = {
				taken = taken,
				orphan_shell = orphan_shell,
				dgun = dgun,
				survived_dgun = survived,
				dgun_kills = dgun_kills,
				enemy_lost = enemy_lost,
			}
		end)
		return result
	end

	local off = run(false)
	local on = run(true)
	return {
		off = off,
		on = on,
		pass = off.taken.own > 0
			and off.taken.ally == 0
			and off.taken.enemy > 0
			and off.orphan_shell == 0
			and off.survived_dgun.own == false
			and off.survived_dgun.ally == true
			and off.survived_dgun.enemy == false
			and off.dgun_kills == 1
			and off.enemy_lost == 1
			and on.taken.own > 0
			and on.taken.ally > 0
			and on.taken.enemy > 0
			and on.orphan_shell > 0
			and on.survived_dgun.own == false
			and on.survived_dgun.ally == false
			and on.survived_dgun.enemy == false,
	}
end

-- Drones are a stockpile, as BAR's stockpiling carriers have them (`drones`): a Mantis, or `args.unit`, comes with its
-- first drone out, fills its stockpile while that one is out, replaces one that is shot down from the stockpile at
-- once, and, with the stockpile spent, has none out until the next is built, a build time later.
local function drone_stockpile(args: Args): Findings
	local result: Findings = {}
	with_switch(NOCOST, true, function()
		local carrier = unkillable(spawn(args.unit or "mantis", OWN, 0, 0))
		local spec = unit_defs.get(carrier.def_name).carrier :: types.Carrier
		local function drones_out(): { Entity }
			local out = {}
			for _, entity in state.all() do
				if entity.alive and entity.def_name == spec.drone and entity.team == OWN then
					table.insert(out, entity)
				end
			end
			return out
		end
		advance(tick_rate.TICK_DELTA * 2)
		local at_start = { out = #drones_out(), held = (carrier.drone_stockpile :: types.Stocked).held }

		advance(spec.stockpile.build_time + 0.5)
		local filled = (carrier.drone_stockpile :: types.Stocked).held

		deaths.destroy(drones_out()[1], "removed")
		advance(tick_rate.TICK_DELTA * 2)
		local replaced = { out = #drones_out(), held = (carrier.drone_stockpile :: types.Stocked).held }

		deaths.destroy(drones_out()[1], "removed")
		advance(tick_rate.TICK_DELTA * 2)
		local spent_out = #drones_out()
		local waited = 0
		while #drones_out() == 0 and waited < spec.stockpile.build_time * 2 do
			advance(tick_rate.TICK_DELTA)
			waited += tick_rate.TICK_DELTA
		end
		result = {
			starts_with = at_start,
			stockpile_after_build_time = filled,
			after_first_loss = replaced,
			out_after_second_loss = spent_out,
			seconds_until_next = round(waited, 2),
			build_time = spec.stockpile.build_time,
			pass = at_start.out == 1
				and filled > at_start.held
				and replaced.out == 1
				and replaced.held == filled - 1
				and spent_out == 0
				and math.abs(waited - spec.stockpile.build_time) <= 1,
		}
	end)
	return result
end

-- The Janus (armjanus) and the Pounder (corlevlr), or only `args.def`, each put through what a new unit has to do, on
-- dry, level ground of its own, on a map with room for it (prairie). Made: the Vehicle Lab, which makes both, makes
-- one, at no cost and so at once. Moves: told to go 40 studs, how fast it went at most against its max_speed, and
-- whether it got there. Fires: against an unkillable, unarmed Solar Collector (or `args.target`) at `args.distance` of
-- its range (0.8 by default) for `args.seconds` (four of its reloads and 3 more by default). A building, because the
-- ground under one does not give: a unit that stands still under fire sinks into the craters the blasts dig, where a
-- shot that does not go over what is in the way may no longer reach it. For the shots: how many each weapon let go and
-- when the first went, how many struck the target and the damage each did, which for a direct hit is the weapon's whole
-- damage (330 a rocket for the Janus, two rockets a volley, and 190 a shell for the Pounder), and the damage a second
-- that came out of it against what BAR's numbers give. The same at 0.95 of its range (`at_range`) on an unkillable
-- Grunt, low enough that a shell that arcs reaches it there (the Collector stands taller than the shooter's muzzle, and
-- a shell falls short of what is above it), where the Pounder's shell bursts on its fuse (`fuse_bursts`) before it
-- gets there, and only its blast reaches. Splash: five unkillable Grunts in a cross 2 studs apart at 0.8 of its range,
-- for two of its reloads and 3 seconds more: the damage each took, the middle one first, then the right, left, far and
-- near ones, and how many took any. Then, as both fire only at the ground, the same with an unkillable Whirlwind flying
-- to and fro over it instead, at which it must never fire (BAR's onlytargetcategory SURFACE). Last, the two against
-- each other at 25 studs, in reach of both, mortal, until one dies or 60 seconds pass: who won, when, what each had
-- left and how many shots each let go. The Pounder, a riot tank, should win.
local function janus_pounder(args: Args): Findings
	local findings: Findings = {}
	-- Each unit's part, and the duel, somewhere dry and level of its own, so that nothing reaches further or less far
	-- for being above or below what it fires at, and nothing stands in the craters an earlier part dug: the ground
	-- within FLAT_TOLERANCE of the same height over the whole of where the part puts things, and SPOT_APART from
	-- every spot used before.
	local FLAT_TOLERANCE = 0.25
	local SPOT_APART = 100
	local used: { Vector3 } = {}
	local ox, oz = 0, 0
	local function level_spot(): { number }
		local spot = harness.find_spot(function(x: number, z: number): boolean
			for _, before in used do
				if math.abs(x - before.X) < SPOT_APART and math.abs(z - before.Z) < SPOT_APART then
					return false
				end
			end
			local height = heightmap.height_at(x, z)
			for dx = -24, 24, 4 do
				for dz = -18, 36, 3 do
					if
						math.abs(heightmap.height_at(x + dx, z + dz) - height) > FLAT_TOLERANCE
						or heightmap.water_depth(x + dx, z + dz) > 0
					then
						return false
					end
				end
			end
			return true
		end)
		assert(spot ~= nil, "there is no level ground big enough for the test on this map")
		table.insert(used, spot)
		ox, oz = spot.X, spot.Z
		return { ox, oz }
	end
	local function put(def_name: string, team: TeamId, x: number, z: number): Entity
		return spawn_resting(def_name, team, ox + x, oz + z)
	end
	-- shots let go by `shooter`, per weapon, counted off each weapon's reload jumping up
	local function shot_counter(shooter: Entity): (() -> (), { number }, { number })
		local shots: { number } = {}
		local first: { number } = {}
		local last: { number } = {}
		local started = now()
		return function()
			for index in shooter.weapon_reloads do
				local reload = shooter.weapon_reloads[index] or 0
				if reload > (last[index] or 0) + 1e-6 then
					shots[index] = (shots[index] or 0) + 1
					if first[index] == nil then
						first[index] = round(now() - started, 2)
					end
				end
				last[index] = reload
			end
		end,
			shots,
			first
	end

	local def_names: { string } = if typeof(args.def) == "string"
		then { args.def :: string }
		else { "janus", "pounder" }
	local pass = true
	for _, def_name in def_names do
		local def = unit_defs.get(def_name)
		local weapons = def.weapons :: { types.Weapon }
		local report: Findings = { at = level_spot() }

		-- made by its lab
		local lab_name = "vehicle_lab"
		local lab_def = unit_defs.get(lab_name)
		local lab_options = if lab_def.builder ~= nil then lab_def.builder.options else nil
		report.in_lab_options = lab_options ~= nil and table.find(lab_options, def_name) ~= nil
		local made: Entity? = nil
		local began = now()
		with_switch(NOCOST, true, function()
			local lab_y = surface.height(lab_def, ox, oz) + unit_defs.collider_height(lab_def) / 2
			local lab = unkillable(state.create_entity(lab_name, OWN, Vector3.new(ox, lab_y, oz), 0, "active"))
			production.enqueue(lab, def_name)
			while made == nil and now() < began + 60 do
				advance(tick_rate.TICK_DELTA)
				for _, entity in state.all() do
					if entity.alive and entity.def_name == def_name and entity.state ~= "blueprint" then
						made = entity
					end
				end
			end
		end)
		report.made = made ~= nil
		report.made_seconds = if made ~= nil then round(now() - began, 2) else "never"
		clear_world()

		-- moves
		local mover = put(def_name, OWN, -20, 0)
		orders.issue(mover, { { kind = "move", position = heightmap.ground_position(ox + 20, oz) } }, false, false)
		local top_speed = 0
		local arrived = harness.until_idle(mover, 30, function()
			top_speed = math.max(top_speed, Vector3.new(mover.velocity.X, 0, mover.velocity.Z).Magnitude)
		end)
		report.arrived = arrived
		report.top_speed = round(top_speed, 2)
		report.max_speed = round(def.max_speed :: number, 2)
		clear_world()

		-- fires, at `fraction` of its range
		local range = weapons[1].range
		local expected_dps = 0
		for _, weapon in weapons do
			expected_dps += weapon.damage / weapon.reload
		end
		local function fire_at(fraction: number, seconds: number, target_def: string): Findings
			local distance = range * fraction
			local shooter = unkillable(put(def_name, OWN, 0, 0))
			local target = unkillable(put(target_def, ENEMY, 0, distance))
			local count, shots, first = shot_counter(shooter)
			local hits: { number } = {}
			local last = target.health
			-- a shell of the shooter's seen at or past its fuse's time, as it bursts
			local fused: { [number]: boolean } = {}
			local fuse_bursts = 0
			advance(seconds, function()
				count()
				local took = last - target.health
				last = target.health
				if took > 1e-6 then
					table.insert(hits, round(took, 1))
				end
				for _, flying in in_flight() do
					local fuse = flying.delivery.projectile.fuse
					if
						flying.owner_id == shooter.id
						and fuse ~= nil
						and flying.flight.age + tick_rate.TICK_DELTA >= fuse
						and fused[flying.id] == nil
					then
						fused[flying.id] = true
						fuse_bursts += 1
					end
				end
			end)
			clear_world()
			return {
				distance = round(distance, 1),
				shots = shots,
				first_shot = first,
				hits = hits,
				fuse_bursts = fuse_bursts,
				damage = round(damage_to(target), 0),
				damage_per_second = round(damage_to(target) / seconds, 1),
			}
		end
		report.range = round(range, 1)
		report.expected_damage_per_second = round(expected_dps, 1)
		report.fires =
			fire_at(args.distance or 0.8, args.seconds or weapons[1].reload * 4 + 3, args.target or "solar_collector")
		report.at_range = fire_at(0.95, weapons[1].reload * 2 + 3, "grunt")

		-- splash, on a cross of Grunts
		local shooter = unkillable(put(def_name, OWN, 0, 0))
		local middle = range * 0.8
		local crowd: { Entity } = {}
		for _, offset in { Vector2.zero, Vector2.new(2, 0), Vector2.new(-2, 0), Vector2.new(0, 2), Vector2.new(0, -2) } do
			table.insert(crowd, unkillable(put("grunt", ENEMY, offset.X, middle + offset.Y)))
		end
		local count_splash, splash_shots = shot_counter(shooter)
		advance(weapons[1].reload * 2 + 3, count_splash)
		local taken: { number } = {}
		local touched = 0
		for _, grunt in crowd do
			local took = round(damage_to(grunt), 0)
			table.insert(taken, took)
			if took > 0 then
				touched += 1
			end
		end
		report.splash = { shots = splash_shots, damage_each = taken, grunts_hurt = touched }
		clear_world()

		-- never at aircraft, for what fires only at the ground
		local ground_only = true
		for _, weapon in weapons do
			ground_only = ground_only and weapon.target_layer == "ground"
		end
		if ground_only then
			local lone = unkillable(put(def_name, OWN, 0, 0))
			-- a bomber flying to and fro over it, never left to settle on the ground
			local plane = unkillable(spawn("whirlwind", ENEMY, ox - 40, oz + range * 0.5))
			local legs: { types.Order } = {}
			for leg = 1, 8 do
				local x = if leg % 2 == 1 then 40 else -40
				table.insert(legs, { kind = "move", position = heightmap.ground_position(ox + x, oz + range * 0.5) })
			end
			orders.issue(plane, legs, false, false)
			local count_air, air_shots = shot_counter(lone)
			advance(weapons[1].reload + 3, count_air)
			report.shots_at_aircraft = air_shots[1] or 0
			report.aircraft_damage = round(damage_to(plane), 0)
			clear_world()
		end

		-- no hit does more than a whole volley's damage
		local most_hit = 0
		for _, hit in report.fires.hits do
			most_hit = math.max(most_hit, hit)
		end
		pass = pass
			and report.in_lab_options
			and report.made
			and report.arrived
			and report.top_speed <= report.max_speed * 1.01
			and (report.fires.shots[1] or 0) > 0
			and report.fires.damage > 0
			and most_hit <= weapons[1].damage * #weapons + 1e-3
			and report.at_range.damage > 0
			and touched > 1
			and (ground_only == false or (report.shots_at_aircraft == 0 and report.aircraft_damage == 0))
		findings[def_name] = report
	end

	-- the two against each other, mortal
	if args.def == nil then
		local at = level_spot()
		local janus = put("janus", OWN, 0, -12.5)
		local pounder = put("pounder", ENEMY, 0, 12.5)
		local count_janus, janus_shots = shot_counter(janus)
		local count_pounder, pounder_shots = shot_counter(pounder)
		local began = now()
		while janus.alive and pounder.alive and now() < began + 60 do
			advance(tick_rate.TICK_DELTA, function()
				count_janus()
				count_pounder()
			end)
		end
		findings.duel = {
			at = at,
			winner = if janus.alive and not pounder.alive
				then "janus"
				elseif pounder.alive and not janus.alive then "pounder"
				else "neither",
			seconds = round(now() - began, 2),
			janus_health = round(math.max(0, janus.health), 0),
			pounder_health = round(math.max(0, pounder.health), 0),
			janus_shots = janus_shots,
			pounder_shots = pounder_shots,
		}
		pass = pass and findings.duel.winner == "pounder"
		clear_world()
	end
	findings.pass = pass
	return findings
end

-- Units on a fight order walking up to something that is outranged by them: `args.count` (1) of `args.shooter` (an
-- Aggravator) in a block, `args.columns` (3) across and 3 studs apart, starting 10 studs past their reach from an
-- unkillable `args.target` (a Thug), told to fight to it, or to `args.beyond` studs past it. For `args.seconds` (25):
-- how near each came to it, how far off it was when each first had it in reach, and what each lost to it. They should
-- all stand off outside its reach, as a unit on a fight order waits behind a friend for a clear shot rather than
-- pushing on into the enemy's reach (targeting.has_target's `past_friends`), losing nothing and hitting it.
local function fight_standoff(args: Args): Findings
	harness.ensure_team(OWN)
	harness.ensure_team(ENEMY)
	clear_world()
	local shooter_name = args.shooter or "aggravator"
	local target_name = args.target or "thug"
	local count = args.count or 1
	local columns = args.columns or 3
	local reach = (unit_defs.get(shooter_name).weapons :: { types.Weapon })[1].range
	local their_reach = (unit_defs.get(target_name).weapons :: { types.Weapon })[1].range
	local home = starts.default_spot(1)
	local target = unkillable(spawn_resting(target_name, ENEMY, home.X, home.Y))
	local shooters: { Entity } = {}
	for index = 1, count do
		local row = (index - 1) // columns
		local column = (index - 1) % columns - (math.min(count, columns) - 1) / 2
		local x = home.X - reach - 10 - row * 3
		table.insert(shooters, unkillable(spawn_resting(shooter_name, OWN, x, home.Y + column * 3)))
	end
	advance(tick_rate.TICK_DELTA)
	local goal = target.position + Vector3.new(args.beyond or 0, 0, 0)
	for _, shooter in shooters do
		orders.issue(shooter, { { kind = "fight", position = goal, target_id = nil } }, false, false)
	end
	local closest: { number } = {}
	local first_in_reach: { number } = {}
	for index in shooters do
		closest[index] = math.huge
	end
	advance(args.seconds or 25, function()
		for index, shooter in shooters do
			local distance = geometry.distance_2d(shooter.position, target.position)
			closest[index] = math.min(closest[index], distance)
			if first_in_reach[index] == nil and targeting.has_target(shooter) then
				first_in_reach[index] = distance
			end
		end
	end)
	local units = {}
	local inside = 0
	local lost = 0
	for index, shooter in shooters do
		local health_lost = damage_to(shooter)
		lost += health_lost
		if closest[index] <= their_reach then
			inside += 1
		end
		table.insert(units, {
			closest = round(closest[index], 2),
			first_in_reach = if first_in_reach[index] ~= nil then round(first_in_reach[index], 2) else nil,
			lost = round(health_lost, 1),
		})
	end
	local target_lost = damage_to(target)
	return {
		reach = round(reach, 2),
		their_reach = round(their_reach, 2),
		target_lost = round(target_lost, 1),
		came_inside_their_reach = inside,
		health_lost = round(lost, 1),
		units = units,
		pass = inside == 0 and lost == 0 and target_lost > 0,
	}
end

-- Where every def's weapons fire from (server/muzzles.luau): a weapon on a turret piece of its model fires from its
-- def's turret mount (unit_defs/turret_mounts), and every turret piece of a def's art has one, turning where the piece
-- does; and no def has more weapons than there are attribute names for (`entity_attrs.MAX_WEAPONS`). Lists every
-- turret piece with no mount, every mount with no turret piece, every one whose pivot is not the piece's, and every def
-- with too many weapons.
local function weapon_mounts(_args: Args): Findings
	local unmounted: { string } = {}
	local pieceless: { string } = {}
	local elsewhere: { string } = {}
	local too_many: { string } = {}
	local turrets = 0
	for name, def in unit_defs.defs do
		local weapons: { types.Weapon } = def.weapons or {}
		if #weapons > entity_attrs.MAX_WEAPONS then
			table.insert(too_many, name)
		end
		local pieces: { [number]: art.Group } = {}
		local data = if art.has(name) then art.get(name) else nil
		if data ~= nil then
			for _, group in data.groups do
				if group.kind == "turret" and group.weapon ~= nil then
					pieces[group.weapon] = group
				end
			end
		end
		for index in weapons do
			local mount = muzzles.mount_of(def, index)
			local piece = pieces[index]
			if mount.kind == "turret" then
				turrets += 1
				local turns_at = if piece ~= nil
					then Vector3.new(piece.pivot[1], piece.pivot[2], piece.pivot[3])
					else nil
				if turns_at == nil then
					table.insert(pieceless, `{name} {index}`)
				elseif (mount.pivot.Position - turns_at).Magnitude > 0.01 then
					table.insert(elsewhere, `{name} {index}`)
				end
			elseif piece ~= nil then
				table.insert(unmounted, `{name} {index}`)
			end
		end
	end
	table.sort(unmounted)
	table.sort(pieceless)
	table.sort(elsewhere)
	table.sort(too_many)
	return {
		turret_mounts = turrets,
		turret_pieces_without_a_mount = unmounted,
		mounts_without_a_turret_piece = pieceless,
		mounts_not_where_their_piece_turns = elsewhere,
		too_many_weapons = too_many,
		pass = #unmounted == 0 and #pieceless == 0 and #elsewhere == 0 and #too_many == 0 and turrets > 0,
	}
end

local TESTS: { [string]: Test } = {
	weapon_mounts = { run = weapon_mounts },
	fight_standoff = { run = fight_standoff },
	bombing = { run = bombing },
	emp = { run = emp_test },
	aa_missiles = { run = aa_missiles },
	beam = { run = beam },
	turret = { run = turret },
	starlight = { run = starlight },
	t3 = { run = t3_test },
	stealth = { run = stealth },
	nuke_manual = { run = nuke_manual },
	anti_nuke = { run = anti_nuke },
	self_destruct = { run = self_destruct_test },
	experience = { run = experience },
	ally_griefing = { run = ally_griefing },
	drone_stockpile = { run = drone_stockpile },
	janus_pounder = { run = janus_pounder, defaults = { preset = "prairie" } },
}

return table.freeze(TESTS)
