--!strict
-- Firing weapons, every tick: each weapon's reload, its bursts and its stockpile of missiles, turning its turret onto
-- what it means to shoot, and taking the shot, which a projectile (server/projectiles.luau), an interceptor
-- (server/interceptors.luau) or a beam (server/beams.luau) then carries. What each weapon shoots at is targeting's, and
-- the harm a shot does is `damage`'s.
--
-- Each of an entity's weapons has its own reload, its own choice of target and its own origin for the shot
-- (server/muzzles.luau), except that weapons sharing a `weapon_group` share one reload between them (`group_leader`)
-- and so only ever fire one at a time. A weapon that is reloading is left alone, and one that finds nothing in range
-- simply waits, without holding up the others. Later weapons prefer a target none of this entity's other weapons
-- already claimed this tick, but take one that is claimed over none at all. A weapon on a turret decides what it means
-- to shoot every tick, reloading or not, and turns toward it (`turrets.turn`); once reloaded it fires only when it faces
-- it, and otherwise waits ready.

local ReplicatedStorage = game:GetService "ReplicatedStorage"

local types = require(ReplicatedStorage.Shared.types)
local unit_defs = require(ReplicatedStorage.Shared.unit_defs)
local art = require(ReplicatedStorage.Shared.art)
local entity_attrs = require(ReplicatedStorage.Shared.entity_attrs)

local state = require(script.Parent.state)
local economy = require(script.Parent.economy)
local stockpiles = require(script.Parent.stockpiles)
local projectiles = require(script.Parent.projectiles)
local interceptors = require(script.Parent.interceptors)
local beams = require(script.Parent.beams)
local air = require(script.Parent.air)
local turrets = require(script.Parent.turrets)
local pilots = require(script.Parent.pilots)
local control = require(script.Parent.control)
local muzzles = require(script.Parent.muzzles)
local shot_rules = require(script.Parent.shot_rules)
local targeting = require(script.Parent.targeting)
local attack_orders = require(script.Parent.attack_orders)
local manual_weapons = require(script.Parent.manual_weapons)
local sight = require(script.Parent.sight)

type Entity = types.Entity
type EntityId = types.EntityId
type Weapon = types.Weapon
type Choice = targeting.Choice
type Aim = sight.Aim

-- The most shots one weapon takes in a tick, when its reload is shorter than a tick.
local MAX_SHOTS_PER_TICK = 16
-- How long after a shooter last had a target and could not pay for the shot it says so.
local STARVED_SHOWN_FOR = 0.4
-- A weapon that takes longer than this many seconds to reload shows a bar over its owner for how far along it is.
local RELOAD_BAR_MIN_SECONDS = 5

-- What a bomber let the first bomb of its current burst go at, by weapon: the target, if it was one, and where it was.
-- The rest of the burst goes at the same: at the target while it lives, and at where it was once it is gone.
local burst_aims: { [EntityId]: { [Weapon]: { target: Entity?, point: Vector3 } } } = {}
-- When each shooter last had a target and could not pay for the shot, so that it can say so.
local starved_at: { [EntityId]: number } = {}
-- Shots fired so far, by entity and weapon (see shots_of).
local shots: { [EntityId]: { [number]: number } } = {}

local function count_shot(entity_id: EntityId, index: number)
	local by_weapon = shots[entity_id]
	if by_weapon == nil then
		by_weapon = {}
		shots[entity_id] = by_weapon
	end
	by_weapon[index] = (by_weapon[index] or 0) + 1
end

-- How many shots weapon `index` of `entity_id` has fired.
local function shots_of(entity_id: EntityId, index: number): number
	local by_weapon = shots[entity_id]
	return if by_weapon ~= nil then by_weapon[index] or 0 else 0
end

-- Pays the energy a shot costs, and says whether it could be paid. A burst is paid for once, as it starts, the way
-- Spring charges a whole salvo when it begins (CWeapon::Update), so a `mid_burst` shot is free.
local function pay_for_shot(attacker: Entity, weapon: Weapon, mid_burst: boolean): boolean
	if mid_burst then
		return true
	end
	if weapon.energy_per_shot > 0 and economy.spend(attacker.team, 0, weapon.energy_per_shot, attacker.id) == false then
		starved_at[attacker.id] = state.now()
		return false
	end
	return true
end

-- Fires weapon `index` of `attacker`'s, `weapon`, from `origin` at `aim`, and returns whether it went off: its beam, or
-- whatever its delivery launches, `late` seconds into its flight already, for the part of this tick since the weapon
-- was ready. An anti-nuke's interceptor goes after `nuke`, the one its aim is on.
local function fire(
	attacker: Entity,
	weapon: Weapon,
	index: number,
	origin: Vector3,
	aim: Aim,
	nuke: projectiles.Projectile?,
	late: number,
	mid_burst: boolean
): boolean
	if pay_for_shot(attacker, weapon, mid_burst) == false then
		return false
	end
	local delivery = weapon.delivery
	if delivery.kind == "beam" then
		beams.fire(attacker, weapon, index, delivery, origin, aim)
	elseif nuke ~= nil then
		interceptors.launch(attacker, weapon, index, origin, nuke, late)
	else
		projectiles.launch(
			attacker,
			weapon,
			index,
			origin,
			aim,
			shot_rules.chosen_arc(attacker, weapon, origin, aim),
			late
		)
	end
	return true
end

-- A bomber's burst is one shot: the first bomb is let go when the target is in the drop window, and the rest follow it
-- at what the first was let go at, whatever they will come down on, short of it and then past it. Notes what the first
-- is let go at.
local function remember_drop(attacker: Entity, weapon: Weapon, aim: Aim)
	local by_weapon = burst_aims[attacker.id]
	if by_weapon == nil then
		by_weapon = {}
		burst_aims[attacker.id] = by_weapon
	end
	by_weapon[weapon] = { target = sight.target_of(aim), point = sight.position_of(aim) }
end

-- What the rest of a bomber's burst goes at: what the first bomb was let go at while it lives, or where it was.
local function drop_aim(attacker: Entity, weapon: Weapon): Aim?
	local by_weapon = burst_aims[attacker.id]
	local dropped = if by_weapon ~= nil then by_weapon[weapon] else nil
	if dropped == nil then
		return nil
	end
	local target = dropped.target
	if target ~= nil and target.alive then
		return target
	end
	return dropped.point
end

-- Takes a shot with weapon `index` of `attacker`'s, `weapon`, from `origin`: at what `choose` picks, or at `chosen`
-- when that has already been made (for a turret, which fires at what it has turned to face, or a piloted weapon).
-- Returns whether the shot went off, and the entity it was at, if it was at one. `mid_burst` says the weapon has
-- already fired the first shot of a burst, and `late` is how long ago in this tick it was ready to fire (see `fire`).
local function shoot(
	attacker: Entity,
	weapon: Weapon,
	index: number,
	origin: Vector3,
	claimed: { EntityId },
	mid_burst: boolean,
	late: number,
	chosen: Choice?
): (boolean, EntityId?)
	local dropped = weapon.delivery.kind == "bomb"
	-- a bomb is only let go from the air: a bomber sitting on the ground holds on to it, as a fighter does its missiles
	if (dropped or weapon.airborne_only == true) and air.is_airborne(attacker) == false then
		return false, nil
	end
	local following = if dropped and mid_burst then drop_aim(attacker, weapon) else nil
	if following ~= nil then
		local followed = sight.target_of(following)
		return fire(attacker, weapon, index, origin, following, nil, late, mid_burst),
			if followed ~= nil then followed.id else nil
	end

	local choice = chosen or targeting.choose(attacker, weapon, origin, claimed)
	local aim = choice.aim
	local target = if aim ~= nil then sight.target_of(aim) else nil
	-- a turret's target can die to an earlier shot this same tick, and the nuke it turned toward can be caught, or have
	-- another interceptor sent after it
	if
		aim == nil
		or (target ~= nil and target.alive == false)
		or (choice.nuke ~= nil and projectiles.is_free_nuke(choice.nuke) == false)
	then
		return false, nil
	end
	if dropped then
		remember_drop(attacker, weapon, aim)
	end
	return fire(attacker, weapon, index, origin, aim, choice.nuke, late, mid_burst),
		if target ~= nil then target.id else nil
end

-- What follows a shot of `weapon` when `fired` shots of its burst were out before it: how long until it may fire
-- again, the short gap within a burst or the full reload once the burst is out, and how many of the burst are then
-- out, which is back to none once it is over.
local function after_shot(weapon: Weapon, fired: number): (number, number)
	local burst = weapon.burst_count
	if burst == nil or burst <= 1 or fired + 1 >= burst then
		return weapon.reload, 0
	end
	return unit_defs.burst_interval(weapon), fired + 1
end

-- The damage a second `weapon` does firing as fast as it can: a whole burst, its shots the gap `after_shot` gives
-- apart, and then its reload; a weapon that fires from a stockpile no faster than it builds its missiles. What the AI's
-- fight predictor (server/ai/combat_sim.luau) takes a weapon's sustained fire to be.
local function damage_per_second(weapon: Weapon): number
	local burst = weapon.burst_count or 1
	local cycle = weapon.reload
	if burst > 1 then
		cycle += (burst - 1) * unit_defs.burst_interval(weapon)
	end
	if weapon.stockpile ~= nil then
		cycle = math.max(cycle, weapon.stockpile.build_time)
	end
	return weapon.damage * burst / math.max(cycle, 1 / 30)
end

-- Counts `remaining`, a reload, down by `delta`, unless it had already run out, and returns what is left. Nothing
-- is lost to the tick: a reload that runs out partway through one is left below zero by as much, which is how long
-- ago the weapon was ready, and the shot it then takes is that much into its flight already and makes the next
-- reload start that much sooner. A 0.267 second gap is 0.267 seconds on average, not a whole number of ticks.
local function count_down(remaining: number, delta: number): number
	if remaining > 0 then
		return remaining - delta
	end
	return remaining
end

-- The index, within `weapons`, of the first one sharing weapon `index`'s `weapon_group`, or `index`
-- itself if it has none. Weapons in the same group reload as one: only their group's leader counts its
-- reload down, and every member reads and writes that one slot, so only whichever of them fires first
-- each cycle gets to.
local function group_leader(weapons: { Weapon }, index: number): number
	local group = weapons[index].weapon_group
	if group == nil then
		return index
	end
	for candidate, other in weapons do
		if other.weapon_group == group then
			return candidate
		end
	end
	return index
end

-- Fires weapon `index` of `entity`'s, `weapon`, as often as its reload lets it this tick, `ready_since` seconds after
-- it was ready (a reload counted down below zero), at `chosen` or at what it chooses, and returns what is left of its
-- reload: more than nothing once it has fired, or nothing when it has nothing to fire at, or no missile to fire, and
-- waits ready without saving up the shots it could have taken.
local function fire_volley(
	entity: Entity,
	weapon: Weapon,
	index: number,
	origin: Vector3,
	claimed: { EntityId },
	chosen: Choice?,
	remaining: number
): number
	for _ = 1, MAX_SHOTS_PER_TICK do
		local stocked = entity.weapon_stockpiles[index]
		if stocked ~= nil and stocked.held < 1 then
			return 0
		end
		local fired, at =
			shoot(entity, weapon, index, origin, claimed, entity.weapon_burst_remaining[index] > 0, -remaining, chosen)
		if fired == false then
			return 0
		end
		count_shot(entity.id, index)
		local wait: number
		wait, entity.weapon_burst_remaining[index] = after_shot(weapon, entity.weapon_burst_remaining[index])
		remaining += wait
		if stocked ~= nil then
			stocked.held -= 1
			attack_orders.note_launch(entity.id)
		end
		if at ~= nil then
			table.insert(claimed, at)
		end
		if remaining > 0 then
			break
		end
	end
	return remaining
end

-- Weapon `index` of a piloted `entity`, `weapon`, which its pilot has not chosen: it holds its fire, its reload runs
-- on, and its turret turns back to rest.
local function hold(entity: Entity, weapons: { Weapon }, index: number, frame: CFrame, delta: number)
	local turret = weapons[index].turret
	if turret ~= nil then
		turrets.turn(entity, index, turret, muzzles.origin_of(entity, frame, index), nil, delta)
	end
	if group_leader(weapons, index) == index then
		entity.weapon_reloads[index] = math.max(0, count_down(entity.weapon_reloads[index], delta))
	end
end

-- One tick of weapon `index` of `entity`'s: its stockpile grows, it chooses what to shoot at (its pilot's aim, if it
-- is piloted), turns its turret toward that, reloads, and fires once it is ready and facing it (`fire_volley`).
local function tick_weapon(
	entity: Entity,
	weapons: { Weapon },
	index: number,
	frame: CFrame,
	claimed: { EntityId },
	pilot: pilots.Pilot?,
	delta: number
)
	local weapon = weapons[index]
	-- missiles go on being built whatever the weapon is doing, reloading after a launch included
	local stockpile = weapon.stockpile
	local stocked = entity.weapon_stockpiles[index]
	if stockpile ~= nil and stocked ~= nil then
		stockpiles.grow(entity, stockpile, stocked, delta)
	end
	-- a piloted unit fires nothing its pilot does not
	if pilot ~= nil and pilot.weapon ~= index then
		hold(entity, weapons, index, frame, delta)
		return
	end

	local origin: Vector3? = nil
	local chosen: Choice? = nil
	local aligned = true
	local turret = weapon.turret
	if turret ~= nil then
		local from = muzzles.origin_of(entity, frame, index)
		origin = from
		chosen = if pilot ~= nil
			then targeting.pilot_choice(entity, weapon, from, pilot)
			else targeting.choose(entity, weapon, from, claimed)
		local aim = (chosen :: Choice).aim
		aligned = turrets.turn(entity, index, turret, from, if aim ~= nil then sight.position_of(aim) else nil, delta)
	end

	local leader = group_leader(weapons, index)
	-- a grouped weapon has no reload of its own: it reads its group leader's, which the leader's own turn through this
	-- tick already counted down, earlier this tick
	local remaining = if leader ~= index
		then entity.weapon_reloads[leader]
		else count_down(entity.weapon_reloads[index], delta)
	if remaining > 0 then
		if leader == index then
			entity.weapon_reloads[index] = remaining
		end
		return
	end
	-- reloaded, but still turning to face its target, or with its pilot not on the trigger: it waits ready, as with
	-- nothing to shoot, and does not save up the shots it could have taken
	if aligned == false or (pilot ~= nil and pilot.firing == false) then
		entity.weapon_reloads[leader] = 0
		return
	end
	local from = if origin ~= nil then origin else muzzles.origin_of(entity, frame, index)
	if pilot ~= nil and chosen == nil then
		chosen = targeting.pilot_choice(entity, weapon, from, pilot)
	end
	-- whichever of a group actually fired (or found nothing to) sets the reload the rest of the
	-- group will read on their own turn through this loop, this tick or the next
	entity.weapon_reloads[leader] = fire_volley(entity, weapon, index, from, claimed, chosen, remaining)
end

local function tick(delta: number)
	-- the beams already up burn on before anything fires this tick, so a beam fired now is not burned twice in it
	beams.tick()
	for _, entity in state.all() do
		-- something stunned neither fires nor reloads, nor does anything inert or parked on its carrier (`control`)
		if control.can_act(entity) == false then
			continue
		end
		manual_weapons.reload(entity, delta)
		local weapons = entity.def.weapons
		if weapons ~= nil then
			local claimed: { EntityId } = {}
			local frame = muzzles.frame_of(entity)
			-- the weapon a piloted unit's pilot has chosen is theirs to fire, and the rest hold theirs
			local pilot = control.pilot_of(entity)
			for index in weapons do
				tick_weapon(entity, weapons, index, frame, claimed, pilot, delta)
			end
		end
	end
end

-- How far along a slow weapon is to its next shot, from 0 to 1, rounded to a hundredth so that it is not
-- rewritten every step; nil for something with no weapon that takes longer than `RELOAD_BAR_MIN_SECONDS`
-- to reload. A unit with several weapons shows its first slow one.
local function reload_progress(entity: Entity, weapons: { Weapon }): number?
	for index, weapon in weapons do
		if weapon.reload > RELOAD_BAR_MIN_SECONDS then
			local remaining = entity.weapon_reloads[index] or 0
			return math.floor(math.clamp(1 - remaining / weapon.reload, 0, 1) * 100) / 100
		end
	end
	return nil
end

-- The weapons of a def whose art plays something when they fire (a "hatch" piece naming them), worked out once.
local fired_by_def: { [string]: { number } } = {}
local function fired_weapons(def_name: string): { number }
	local found = fired_by_def[def_name]
	if found ~= nil then
		return found
	end
	found = {}
	local data = if art.has(def_name) then art.get(def_name) else nil
	if data ~= nil then
		for _, group in data.groups do
			if group.kind == "hatch" and group.weapon ~= nil and table.find(found, group.weapon) == nil then
				table.insert(found, group.weapon)
			end
		end
	end
	fired_by_def[def_name] = found
	return found
end

-- Publishes what the client shows of `entity`'s weapons: whether one with an energy cost has just had no energy to
-- fire with (`need_energy`, true for a moment after the last failed shot, and it keeps trying while it is short),
-- whether its manual weapon is ready (`manual_ready`), how far along a slow weapon is to its next shot
-- (`reload_progress`), where each turret points, in radians from the way the entity faces, to a hundredth so that one
-- holding still is not rewritten every step (`aim_1`...), and how many shots each weapon whose art plays something when
-- it fires (a silo's hatch) has taken, to the nearest thousand, which is plenty to see a new one by (`fired_1`...).
local function publish(entity: Entity, def: types.EntityDef, write: entity_attrs.Publish)
	local starved = starved_at[entity.id]
	write("need_energy", starved ~= nil and state.now() - starved < STARVED_SHOWN_FOR)
	if def.manual_weapon ~= nil then
		write("manual_ready", entity.manual_reload_remaining <= 0)
	end
	local weapons = def.weapons
	write("reload_progress", if weapons ~= nil then reload_progress(entity, weapons) else nil)
	if weapons ~= nil then
		for index, weapon in weapons do
			if weapon.turret ~= nil then
				write(entity_attrs.aim_name(index), math.round((entity.weapon_aims[index] or 0) * 100) / 100)
			end
		end
	end
	for _, index in fired_weapons(entity.def_name) do
		write(entity_attrs.fired_name(index), shots_of(entity.id, index) % 1000)
	end
end

local function forget(entity_id: EntityId)
	burst_aims[entity_id] = nil
	starved_at[entity_id] = nil
	shots[entity_id] = nil
end

return table.freeze({
	damage_per_second = damage_per_second,
	shots_of = shots_of,
	forget = forget,
	tick = tick,
	publish = publish,
})
