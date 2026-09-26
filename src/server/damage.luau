--!strict
-- Harm done to what is on the map. Damage (`apply`) takes health, is credited to whoever dealt it, and kills what it
-- takes the last of (`deaths`). EMP (`stun`) is a different kind of harm, not a kind of damage: it fills what it reaches
-- with paralysis instead (server/emp.luau), earns nobody anything, and never kills. A weapon deals one or the other,
-- as its def says (`Weapon.paralyze_time`), and whatever delivers its harm, a beam, a projectile or a spark, lands it
-- through `hit`, which is all of what a weapon's harm does to what it reaches.
--
-- What a weapon's shot strikes is its delivery's business, and differs as the physics does: a beam strikes the first
-- solid thing on its line, a friend included (server/beams.luau); a projectile flies through its own side's and its
-- allies' things and strikes the first other thing it touches, though its blast spares nobody but its shooter
-- (server/projectiles.luau); a lightning gun's sparks jump to friend and foe alike. Whether what is struck is harmed is
-- decided here, the same for all of them.
--
-- What is immune (`EntityDef.damage_immunity`: a reclaimable, or what only a disintegrator can harm) takes nothing from
-- either. Without ally griefing, an ally's weapon does nothing (`alliances.may_harm`).

local ReplicatedStorage = game:GetService "ReplicatedStorage"

local types = require(ReplicatedStorage.Shared.types)
local unit_defs = require(ReplicatedStorage.Shared.unit_defs)
local signal = require(ReplicatedStorage.Shared.signal)

local state = require(script.Parent.state)
local movement = require(script.Parent.movement)
local deaths = require(script.Parent.deaths)
local credit = require(script.Parent.credit)
local alliances = require(script.Parent.alliances)
local emp = require(script.Parent.emp)
local deformation = require(script.Parent.deformation)
local spatial = require(script.Parent.spatial)
local shot_feed = require(script.Parent.shot_feed)

type Entity = types.Entity
type EntityId = types.EntityId
type TeamId = types.TeamId
type Weapon = types.Weapon

-- How long something that moves answers slower, its acceleration gone, after a weapon strikes it
-- (`movement.set_impulse`), so that no rush of heavy units shrugs off being shot at.
local HIT_SLOW_SECONDS = 0.5

-- Told of everything that takes damage, as it does, with how much and whose it was, if anyone's.
local hurt = signal.new() :: signal.Signal<Entity, number, TeamId?>

-- Whether `target` can be harmed at all by what `team`'s, if anyone's, deals it; and who dealt it, if they are still
-- here to be credited.
local function harmable(target: Entity, attacker_id: EntityId?, attacker_team: TeamId?): (boolean, Entity?, TeamId?)
	if target.alive == false or unit_defs.harmed_by_weapons(target.def) == false then
		return false, nil, nil
	end
	local attacker = if attacker_id ~= nil then state.get(attacker_id) else nil
	local team = attacker_team or (if attacker ~= nil then attacker.team else nil)
	if team ~= nil and alliances.may_harm(team, target.team) == false then
		return false, nil, nil
	end
	return true, attacker, team
end

-- `target` takes `amount` of damage, dealt by the entity `attacker_id` if anyone (a death explosion or drowning is
-- nobody's doing), which is credited for it. `attacker_team` is whose weapon it was, when the attacker may be gone by
-- now, as a shell's may; otherwise it is the attacker's own.
local function apply(target: Entity, amount: number, attacker_id: EntityId?, attacker_team: TeamId?)
	local ok, attacker, team = harmable(target, attacker_id, attacker_team)
	if ok == false then
		return
	end
	if attacker ~= nil and amount > 0 and target.health > 0 and credit.earns(attacker, target) then
		credit.damage(attacker, target, math.min(amount, target.health))
	end
	target.health -= amount
	deaths.wound(target, amount)
	if amount > 0 then
		hurt.fire(target, amount, team)
	end
	if target.health <= 0 then
		deaths.destroy(target, "killed", attacker)
	end
end

-- `target` takes `amount` of EMP from a weapon that stuns for at most `paralyze_time` seconds, fired by `attacker_id`
-- of `attacker_team` as `apply` has them.
local function stun(
	target: Entity,
	amount: number,
	paralyze_time: number,
	attacker_id: EntityId?,
	attacker_team: TeamId?
)
	if harmable(target, attacker_id, attacker_team) then
		emp.add(target, amount, paralyze_time)
	end
end

-- `amount` of `weapon`'s harm lands on `target`, from the shot of the entity `attacker_id` of `attacker_team` (its team
-- when it fired, since it may be gone by now, as a shell's shooter may). An aircraft takes only a fraction of it from a
-- weapon that is not dedicated anti-air (`unit_defs.damage_against`); an EMP weapon's is EMP (`stun`) and any other's
-- damage (`apply`). What a weapon strikes `direct`ly, not only its blast or its sparks, answers slower for a moment
-- after, if it moves.
local function hit(
	target: Entity,
	amount: number,
	weapon: Weapon,
	attacker_id: EntityId,
	attacker_team: TeamId,
	direct: boolean
)
	local dealt = unit_defs.damage_against(unit_defs.is_anti_air(weapon), target.def, amount)
	local paralyze_time = weapon.paralyze_time
	if paralyze_time ~= nil then
		stun(target, dealt, paralyze_time, attacker_id, attacker_team)
	else
		apply(target, dealt, attacker_id, attacker_team)
	end
	if direct and unit_defs.moves(target.def) then
		movement.set_impulse(target, HIT_SLOW_SECONDS)
	end
end

-- What is left of a blast at its very edge, as a fraction of what it deals at its centre, unless it says otherwise.
local EDGE_EFFECTIVENESS = 0.25

-- A blast of `radius` going off at `at`: everything it reaches is passed to `harm` with how much of the blast's full
-- force it takes. As in BAR, the blast is measured to the nearest point of each thing's collider, not its centre, in
-- three dimensions: anything the blast touches at all is hurt, something it lands right against takes it all, and
-- `edge` of it at the very edge. One on the ground does not reach an aircraft well up over it, since that is further
-- off than the blast reaches.
-- What is left of a blast's force at its very edge, for a blast that says `edge` or none.
local function edge_of(edge: number?): number
	return edge or EDGE_EFFECTIVENESS
end

-- How much of a blast's full force reaches what is `fraction` of the way out to its edge (0 at the middle, 1 at the
-- edge), where `edge` is left (EDGE_EFFECTIVENESS unless it says). What a blast here and a death explosion in the AI's
-- fight predictor (server/ai/combat_sim.luau) both go by.
local function falloff(fraction: number, edge: number?): number
	return 1 - (1 - edge_of(edge)) * fraction
end

local function blast(at: Vector3, radius: number, edge: number?, harm: (other: Entity, force: number) -> ())
	spatial.each_collider_near(at.X, at.Z, radius, function(other: Entity, reach: number, half_height: number)
		local position = other.position
		local sideways = math.max(0, Vector2.new(position.X - at.X, position.Z - at.Z).Magnitude - reach)
		local vertical = math.max(0, math.abs(position.Y - at.Y) - half_height)
		local distance = math.sqrt(sideways * sideways + vertical * vertical)
		if distance <= radius then
			harm(other, falloff(if radius > 0 then distance / radius else 1, edge))
		end
	end)
end

-- Something finished with a death explosion goes up when it dies (`deaths.on_blast`), a blast (`blast`) that is nobody's
-- doing: it hits friend and foe alike, and other things that die to it can explode in their turn. It goes off once the
-- source is already marked dead, so the source is not part of its own blast.
local function death_explosion(source: Entity)
	local explosion = source.def.death_explosion
	if explosion == nil then
		return
	end

	shot_feed.send({ kind = "blast", at = source.position, radius = explosion.radius })
	deformation.crater(source.position, explosion.radius, explosion.damage)
	blast(source.position, explosion.radius, nil, function(other: Entity, force: number)
		apply(other, explosion.damage * force)
	end)
end

-- Sets off every death explosion from now on.
local function init()
	deaths.on_blast(death_explosion)
end

return table.freeze({
	init = init,
	apply = apply,
	hit = hit,
	blast = blast,
	falloff = falloff,
	edge_of = edge_of,
	on_hurt = hurt.subscribe,
})
