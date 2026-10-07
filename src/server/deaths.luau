--!strict
-- Everything that leaves the map goes through `destroy`, and why it went (`DeathCause`) decides what else happens: who
-- is credited with it, whether it counts as lost, whether it leaves a wreck or flies to pieces, whether its death
-- explosion goes off, and what becomes of whatever it was carrying.
--
-- What a violent death leaves behind depends on how hard the unit was hit, as in BAR: its unit scripts read the
-- severity of the death, the damage taken lately as a percentage of the unit's health, and leave a whole wreck up to
-- 25 and nothing past that; this game has no heaps. Spring keeps the damage taken lately by adding each hit to a running
-- total that is multiplied by 0.9 every frame, at 30 frames a second, so it is the killing blow and whatever landed with
-- it. The blow counts in full, not only the part that was needed to kill. `damage` reports every hit here (`wound`).

local ReplicatedStorage = game:GetService "ReplicatedStorage"

local types = require(ReplicatedStorage.Shared.types)
local unit_defs = require(ReplicatedStorage.Shared.unit_defs)
local surface = require(ReplicatedStorage.Shared.surface)
local signal = require(ReplicatedStorage.Shared.signal)

local state = require(script.Parent.state)
local outbox = require(script.Parent.outbox)
local air = require(script.Parent.air)
local match_stats = require(script.Parent.match_stats)
local credit = require(script.Parent.credit)
local snapshot = require(script.Parent.snapshot)

type Entity = types.Entity
type EntityId = types.EntityId

-- Why something left the map:
--   killed          destroyed by damage;
--   self_destructed destroyed itself (server/self_destruct.luau, or a defeated side's things);
--   disintegrated   swept away by a manual weapon (`manual_weapons.fire`);
--   reclaimed       taken apart by a reclaimer;
--   upgraded        built over in place by what replaces it (`EntityDef.upgrades`);
--   cancelled       a lab's blueprint whose queue entry was cancelled;
--   decayed         an abandoned blueprint that came all the way apart;
--   removed         taken off the map by game logic (a mission, a wave cleared away, a map replaced, a wreck raised,
--                   a drone whose carrier is gone), with no wreck, no blast and no stats.
export type DeathCause =
	"killed"
	| "self_destructed"
	| "disintegrated"
	| "reclaimed"
	| "upgraded"
	| "cancelled"
	| "decayed"
	| "removed"

local WRECK_MAX_SEVERITY = 25
local RECENT_DAMAGE_DECAY = 0.9
local FRAMES_PER_SECOND = 30
-- How violent being disintegrated or destroying itself counts as: past WRECK_MAX_SEVERITY, so it leaves no wreck.
local DISINTEGRATION_SEVERITY = 100
local SELF_DESTRUCT_SEVERITY = 100

-- Damage taken lately, by entity, decayed a little every tick.
local recent_damage: { [EntityId]: number } = {}

-- Told of each finished thing whose death sets its death explosion off (`damage` subscribes, and sets it off).
local blasts = signal.new() :: signal.Signal<Entity>
-- Told of everything that leaves the map, and why, as it goes: whoever has to tell a thing destroyed from one only
-- cleared away ("removed") asks here, not the thing's health.
local destroyed = signal.new() :: signal.Signal<Entity, DeathCause>

-- `entity` has just taken `amount` of damage, which counts toward how violent its death is if it dies of it soon.
local function wound(entity: Entity, amount: number)
	recent_damage[entity.id] = (recent_damage[entity.id] or 0) + amount
end

-- Lets a step's worth of the damage taken lately fade.
local function tick(delta: number)
	local decay = RECENT_DAMAGE_DECAY ^ (delta * FRAMES_PER_SECOND)
	for id, damage in recent_damage do
		if damage * decay < 1e-3 then
			recent_damage[id] = nil
		else
			recent_damage[id] = damage * decay
		end
	end
end

-- Whether `entity` is something finished of its side's, a unit or a building, and not a blueprint or remains: what dies
-- of it counts as lost, leaves a wreck or flies to pieces, and sets its death explosion off.
local function standing(entity: Entity): boolean
	return entity.state == "active" and unit_defs.is_remains(entity.def) == false
end

-- `entity`, finished, has gone and left no wreck: its pieces fly apart, harder the more violent its death (`severity`),
-- or, if it was an aircraft shot down in the air, it falls out of the sky and breaks up where it hits the ground.
local function shatter(entity: Entity, severity: number)
	outbox.shattered({
		id = entity.id,
		severity = severity,
		velocity = entity.velocity,
		falls = air.is_airborne(entity),
	})
end

-- Takes `cargo` out of the hold it is in, if any, and puts it on the ground right under where it hung.
local function fall_from_hold(cargo: Entity)
	local transport_id = state.carrier_of(cargo.id)
	if transport_id == nil then
		return
	end
	local def = cargo.def
	local x = cargo.position.X
	local z = cargo.position.Z
	local y = surface.height(def, x, z) + unit_defs.collider_height(def) / 2
	state.unstow(transport_id, cargo, Vector3.new(x, y, z))
end

-- Defined below `die`, which it calls and which calls it.
local lose_cargo: (transport: Entity, severity: number) -> ()

-- `entity` is destroyed as violently as `severity` says: something shot down from under a transport comes down to the
-- ground to die, and what dies of something finished counts as lost to its side, leaves its wreck if the death was not
-- too violent and it leaves one at all, or else flies to pieces, and sets its death explosion off, which its own wreck
-- is left lying after; a blueprint or remains just disappear. What it carried dies with it.
local function die(entity: Entity, severity: number)
	fall_from_hold(entity)
	local def = entity.def
	local finished = standing(entity)
	local wrecked = finished and unit_defs.leaves_wreck(def) and severity <= WRECK_MAX_SEVERITY
	if finished then
		if unit_defs.counts_as_loss(def) then
			match_stats.lost(entity.team)
		end
		if wrecked == false then
			shatter(entity, severity)
		end
	end
	state.mark_dead(entity)
	if finished then
		blasts.fire(entity)
	end
	if wrecked then
		state.create_wreck(entity.def_name, entity.position, entity.facing)
	end
	lose_cargo(entity, severity)
end

-- What `transport` was carrying when it was lost is killed with it: each thing comes down to the ground where it hung
-- and dies there as violently as the transport did, except that what always leaves its wreck, a commander, does.
lose_cargo = function(transport: Entity, severity: number)
	for _, cargo in table.clone(state.cargo_of(transport.id)) do
		die(cargo, if unit_defs.always_leaves_wreck(cargo.def) then 0 else severity)
	end
end

-- How violent `entity`'s death by damage is: the damage it took lately, as a percentage of its health.
local function severity_of(entity: Entity): number
	local severity = (recent_damage[entity.id] or 0) / entity.max_health * 100
	recent_damage[entity.id] = nil
	return severity
end

-- `killer`, if anyone, is credited with killing `entity`, and with what `entity` was carrying, which dies with it.
-- `unhurt` says it went in one go, without being worn down first, so what health it had left is credited as damage.
local function credit_killer(killer: Entity?, entity: Entity, unhurt: boolean)
	if killer == nil then
		return
	end
	if credit.earns(killer, entity) then
		if unhurt and entity.health > 0 then
			credit.damage(killer, entity, entity.health)
		end
		credit.kill(killer, entity)
	end
	for _, cargo in state.cargo_of(entity.id) do
		if cargo.health > 0 and credit.earns(killer, cargo) then
			credit.damage(killer, cargo, cargo.health)
			credit.kill(killer, cargo)
		end
	end
end

-- Takes `entity` off the map for `cause`, by `killer`'s doing if anyone's. Something already gone is left alone.
local function destroy(entity: Entity, cause: DeathCause, killer: Entity?)
	if entity.alive == false then
		return
	end
	destroyed.fire(entity, cause)
	local def = entity.def
	if cause == "killed" then
		credit_killer(killer, entity, false)
		die(entity, severity_of(entity))
	elseif cause == "self_destructed" then
		-- it leaves no wreck, except that a commander always leaves its own, as in BAR
		recent_damage[entity.id] = nil
		die(entity, if unit_defs.always_leaves_wreck(def) then 0 else SELF_DESTRUCT_SEVERITY)
	elseif cause == "disintegrated" then
		-- what nothing but a disintegrator can harm is simply gone: no wreck, no pieces, no blast
		if unit_defs.harmed_only_by_manual_weapon(def) then
			state.mark_dead(entity)
			return
		end
		-- a kill for whoever disintegrated it, and a loss for its side, as any other death is; disintegrated, but not
		-- defused
		credit_killer(killer, entity, true)
		die(entity, DISINTEGRATION_SEVERITY)
	elseif cause == "reclaimed" then
		state.mark_dead(entity)
		-- a transport taken apart with something aboard drops it, and it is lost
		lose_cargo(entity, 0)
	else
		state.mark_dead(entity)
		for _, cargo in table.clone(state.cargo_of(entity.id)) do
			destroy(cargo, "removed")
		end
	end
end

local function forget(id: EntityId)
	recent_damage[id] = nil
end

snapshot.keep("deaths", function()
	return { recent_damage = recent_damage }
end, function(saved)
	recent_damage = saved.recent_damage
end)

return table.freeze({
	forget = forget,
	destroy = destroy,
	wound = wound,
	tick = tick,
	on_blast = blasts.subscribe,
	on_destroyed = destroyed.subscribe,
})
