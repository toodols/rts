--!strict
-- The fight predictor: a quick forward simulation of a fight between two sets of things, and nothing but the fight,
-- for the AI (init.luau) to ask before it commits to one. It is in the spirit of SparCraft, the combat simulator
-- UAlbertaBot (David Churchill's StarCraft bot) runs before every attack: rather than weigh one side's worth against
-- the other's, it plays the fight out, so that what each side's weapons can shoot at, how far they reach, how hard and
-- how quickly they hit, what splashes and what is standing where all count. A wave of bots that would walk into a
-- warden's reach, or an army with nothing that shoots upward under bombers, is told it loses, however much it is
-- worth.
--
-- It is coarse on purpose, cheap enough to ask several times a second of a few hundred things:
--
-- - Things are put together in groups, one for each side, def and patch of ground (GROUP_CELL studs across), and
--   each group fights as one: it stands at the middle of its members, moves at their speed and shoots with all their
--   weapons at once. Its health is the sum of theirs, and it has as many members left as that health fills whole ones
--   (the fire is taken as focused: the game's targeting shoots first at what is nearest to dying, see targeting.luau's
--   pick_target, so what is hurt is finished off before the next is started).
-- - The clock goes in STEP seconds, for no longer than a horizon (HORIZON seconds unless told), and it stops early once
--   one side has nothing armed left, or nothing on either side can hurt anything on the other.
-- - Every number about a thing is its def's (shared/unit_defs, which has them from BAR's unit files): its health, its
--   speed, and for each weapon its damage, reload, burst, range, splash, and what it can be turned on. What a weapon
--   does to an aircraft if it is not made for shooting them is what unit_defs.damage_against says. The few numbers of
--   this file's own (how the groups are cut, how spread out they stand, how often a lobbed shell or a burst lands on
--   something that moves) are only how the fight is approximated, and were set by holding its predictions up against
--   the real game in the AI arena (tools/ai_arena/fight_check.py).
-- - Each weapon of a group shoots, every step, at the enemy group in its reach it would rather hit, as the game's
--   targeting chooses: the most worth (`unit_defs.power`) for the health it takes to kill, times the share of the
--   weapon's damage it takes; on a tie, the nearest. Weapons that share a reload (`weapon_group`) fire one at a time.
--   A shot does no more than the health of what it hits (the rest of it is wasted, as it is in the game when a
--   heavy gun kills a cheap bot), and one that splashes hits as many more of the group as its blast covers of the
--   ground they stand on.
-- - Anything that moves walks at its top speed toward the nearest enemy group it can shoot at, and stands to shoot
--   once anything is in the reach of one of its weapons, as a unit on a fight order does (orders.luau's run_fight).
--   What does not move, or has nothing left that it can hurt, stands where it is.
--
-- Things with no weapons (builders, the enemy's labs and extractors) can be put in as well: they are shot at like
-- anything else, and so draw fire away from what fights, but they neither fight nor count in what either side is said
-- to have left.
--
-- `simulate` answers with who won, what each side has left of what was armed (as worth: each thing's power for the
-- share of its health it has left), and how long the fight took; `margin` is the first side's share of its worth left
-- less the second's, from -1 (the first lost everything and did nothing) to 1.

local ReplicatedStorage = game:GetService "ReplicatedStorage"
local ServerScriptService = game:GetService "ServerScriptService"

local types = require(ReplicatedStorage.Shared.types)
local unit_defs = require(ReplicatedStorage.Shared.unit_defs)
local order_kinds = require(ReplicatedStorage.Shared.order_kinds)

local targeting = require(ServerScriptService.Server.targeting)
local damage = require(ServerScriptService.Server.damage)
local weapons = require(ServerScriptService.Server.weapons)

type EntityDef = types.EntityDef
type Weapon = types.Weapon
type Layer = unit_defs.Layer

-- What one of the things put into a fight has to say about itself: an Entity will do, and so will a table made up
-- for a test, with the def's full health when `health` is left out.
export type Fighter = {
	def_name: string,
	skin: string?,
	position: Vector3,
	health: number?,
}

export type Options = {
	-- how many seconds the fight is played for at most, and how long a step is
	horizon: number?,
	step: number?,
	-- where the first side is coming from and what it is going at, for a fight it has not yet walked into: its groups
	-- are moved up the way from `from` to `to`, keeping their places among themselves, to stand just out of the reach
	-- of the second side's nearest weapon on that way. Without it, everything fights from where it stands.
	approach: { from: Vector3, to: Vector3 }?,
}

export type Outcome = {
	-- 1 or 2 for the side that won, and 0 when neither did: both lost everything, or neither could hurt the other
	winner: number,
	-- what each side's armed things were worth when it began, and are worth at the end, as their power for the share
	-- of their health they have (unit_defs.power)
	start_worth: { number },
	worth: { number },
	-- the first side's share of its worth left, less the second's
	margin: number,
	-- how long the fight took, in seconds: until one side had nothing armed left, or the horizon
	seconds: number,
}

-- How the fight is played.
local STEP = 0.5
local HORIZON = 45
-- The things of one side and def within a square this many studs across go in one group.
local GROUP_CELL = 40
-- How much ground each member of a group stands on, as a square this many times its collider's width across: what a
-- splash covers of a group is its blast's area over the group's.
local SPACING = 1.6
-- A thing stops short of its reach by order_kinds.RANGE_MARGIN, as orders.luau has it, and the groups' distances are
-- measured between the middles of the two groups, less each one's spread.
-- How much longer a lobbed shell is in the air than one fired flat, by its arc: its way over the ground goes at its
-- speed times the cosine of the angle it is thrown at, taken as 45 degrees for a medium arc and 60 for a high one (and
-- a missile, which climbs before it dives).
local ARC_FLIGHT: { [string]: number } = { medium = 1 / math.cos(math.rad(45)), high = 2, auto = 2 }

-- A weapon as the fight uses it.
type Gun = {
	-- damage a second, and the damage of one shot
	dps: number,
	shot: number,
	range: number,
	-- the weapon itself, for what it can be turned on (unit_defs.reaches_layer)
	weapon: Weapon,
	-- a weapon made for shooting aircraft does its full damage to them
	anti_air: boolean,
	-- the radius of its blast, and what is left of the damage at its edge; 0 for none
	splash: number,
	edge: number,
	-- how long a shot is in the air for each stud it goes, for a lobbed shell that neither homes nor leads its target
	-- and so comes down where the target was when it was fired; 0 for one that hits what it is aimed at (a laser, a
	-- homing missile, a shell fired ahead of its target) or flies at it flat, into the way of what walks at it
	flight: number,
	-- half the angle of the cone its shots stray within (a def's `inaccuracy`), in radians
	scatter: number,
	-- the reload it shares with others, if it does
	group: string?,
}

-- What a def is, as the fight sees it, worked out once for each def.
type Kind = {
	def: EntityDef,
	guns: { Gun },
	power: number,
	health: number,
	speed: number,
	autoheal: number,
	-- the width of its collider
	width: number,
	-- the longest reach of any of its weapons, and whether it has any it can use
	reach: number,
	armed: boolean,
}

type Group = {
	side: number,
	kind: Kind,
	layer: Layer,
	x: number,
	z: number,
	-- health left, all members together, and how many members that still is
	health: number,
	alive: number,
	-- how far out the group stands, from its middle
	spread: number,
	mobile: boolean,
	-- whether it walked in the last step, when a shell that does not lead it lands where it was, and in this one
	moving: boolean,
	walked: boolean,
}

local kinds: { [EntityDef]: Kind } = {}

-- A weapon as the fight uses it: its sustained fire (weapons.damage_per_second), its blast and its edge as the game's
-- blasts have them (damage.edge_of), how late a lobbed shell lands and how far a shot strays; nil for what fights
-- nothing here.
local function gun_of(weapon: Weapon): Gun?
	-- what fires only when told to (a nuke), what only shoots nukes down, and what only stuns, fight nothing here
	if weapon.manual_fire == true or unit_defs.is_anti_nuke(weapon) or weapon.paralyze_time ~= nil then
		return nil
	end
	if weapon.damage <= 0 then
		return nil
	end
	local delivery = weapon.delivery
	local splash, edge, flight, scatter = 0, 0, 0, 0
	if delivery.kind == "beam" then
		local lightning = delivery.lightning
		if lightning ~= nil then
			-- a lightning gun's sparks are a splash of their own: up to `forks` more things within its range, at
			-- `fork_damage` of the bolt; taken here as a blast that covers them at that much
			splash, edge = lightning.range, lightning.fork_damage
		end
	else
		local params = delivery.projectile
		splash, edge = params.aoe_radius, damage.edge_of(params.edge_effectiveness)
		-- a shell thrown along an arc, or a missile that climbs before it dives, neither homes nor leads
		local arc = if delivery.kind == "missile"
			then ARC_FLIGHT.high
			elseif delivery.kind == "lobbed" then ARC_FLIGHT[delivery.arc]
			else nil
		if arc ~= nil and params.speed > 0 then
			flight = arc / params.speed
		end
		local homes = (delivery.kind == "straight" or delivery.kind == "torpedo") and delivery.guidance == "homes"
		if homes == false then
			scatter = params.inaccuracy or 0
		end
	end
	return {
		dps = weapons.damage_per_second(weapon),
		shot = weapon.damage,
		range = weapon.range,
		weapon = weapon,
		anti_air = unit_defs.is_anti_air(weapon),
		splash = splash,
		edge = edge,
		flight = flight,
		scatter = scatter,
		group = weapon.weapon_group,
	}
end

local function kind_of(def: EntityDef): Kind
	local found = kinds[def]
	if found ~= nil then
		return found
	end
	local guns: { Gun } = {}
	local reach = 0
	if def.weapons ~= nil then
		for _, weapon in def.weapons do
			local gun = gun_of(weapon)
			if gun ~= nil then
				table.insert(guns, gun)
				reach = math.max(reach, gun.range)
			end
		end
	end
	local kind: Kind = {
		def = def,
		guns = guns,
		power = unit_defs.power(def),
		health = math.max(unit_defs.max_health(def), 1),
		speed = if def.kind == "unit" then def.max_speed or 0 else 0,
		autoheal = def.autoheal or 0,
		width = unit_defs.collider_radius(def) * 2,
		reach = reach,
		armed = #guns > 0,
	}
	kinds[def] = kind
	return kind
end

-- How far out a group of `count` things `width` studs across stands from its middle, packed SPACING widths apart.
local function spread_of(count: number, width: number): number
	return math.max(width / 2, math.sqrt(count / math.pi) * width * SPACING)
end

-- Puts `fighters` into groups for side `side`, adding them to `groups`, and returns what the armed ones are worth.
local function gather(fighters: { Fighter }, side: number, groups: { Group }): number
	local by_key: { [string]: Group } = {}
	local sums: { [Group]: { x: number, z: number, count: number } } = {}
	local worth = 0
	for _, fighter in fighters do
		local def = unit_defs.skinned(fighter.def_name, fighter.skin)
		local kind = kind_of(def)
		local position = fighter.position
		local layer: Layer = unit_defs.layer_of(def, position)
		local key = `{def.name}|{layer}|{math.floor(position.X / GROUP_CELL)}|{math.floor(position.Z / GROUP_CELL)}`
		local group = by_key[key]
		local health = math.clamp(fighter.health or kind.health, 0, kind.health)
		if health <= 0 then
			continue
		end
		if group == nil then
			local made: Group = {
				side = side,
				kind = kind,
				layer = layer,
				x = 0,
				z = 0,
				health = 0,
				alive = 0,
				spread = 0,
				mobile = kind.speed > 0,
				moving = false,
				walked = false,
			}
			group = made
			by_key[key] = made
			sums[made] = { x = 0, z = 0, count = 0 }
			table.insert(groups, made)
		end
		local g = group :: Group
		local sum = sums[g]
		sum.x += position.X
		sum.z += position.Z
		sum.count += 1
		g.health += health
		if kind.armed then
			worth += kind.power * health / kind.health
		end
	end
	for group, sum in sums do
		group.x = sum.x / sum.count
		group.z = sum.z / sum.count
		group.alive = sum.count
		group.spread = spread_of(sum.count, group.kind.width)
	end
	return worth
end

-- Moves the first side up the way from `from` to `to` (Options.approach), to just out of the second side's reach.
local function stage(groups: { Group }, from: Vector3, to: Vector3)
	local dx, dz = to.X - from.X, to.Z - from.Z
	local length = math.sqrt(dx * dx + dz * dz)
	if length < 1e-3 then
		return
	end
	dx, dz = dx / length, dz / length
	-- how far back from `to` the second side's reach comes along the way, at the most
	local back = 0
	for _, group in groups do
		if group.side == 2 and group.kind.armed then
			local behind = -((group.x - to.X) * dx + (group.z - to.Z) * dz)
			back = math.max(back, behind + group.kind.reach + group.spread)
		end
	end
	-- the first side's middle, and how far its front reaches ahead of it
	local cx, cz, count, front = 0, 0, 0, 0
	for _, group in groups do
		if group.side == 1 then
			cx += group.x * group.alive
			cz += group.z * group.alive
			count += group.alive
		end
	end
	if count == 0 then
		return
	end
	cx, cz = cx / count, cz / count
	for _, group in groups do
		if group.side == 1 then
			front = math.max(front, (group.x - cx) * dx + (group.z - cz) * dz + group.spread)
		end
	end
	-- where its middle goes: `back` before `to`, and its front a little short of that, but never past where it is if
	-- it is already nearer than that
	local along = (to.X - cx) * dx + (to.Z - cz) * dz
	local wanted = back + front + 2
	if along <= wanted then
		return
	end
	local shift = along - wanted
	for _, group in groups do
		if group.side == 1 then
			group.x += dx * shift
			group.z += dz * shift
		end
	end
end

local function gap_between(a: Group, b: Group): number
	local dx, dz = a.x - b.x, a.z - b.z
	return math.max(0, math.sqrt(dx * dx + dz * dz) - a.spread - b.spread)
end

-- What `gun` would rather shoot, as the game's targeting reckons it (targeting.reward): worth for the health it takes
-- to kill, a member at a time.
local function reward(gun: Gun, target: Group): number
	return targeting.reward(gun.anti_air, target.kind.def, target.kind.health)
end

-- `died` of `source` have gone up in their death explosions (unit_defs' death_explosion), `radius` studs round and
-- `strength` at the middle: everything on the ground in reach, friend or foe, takes it in the next step, falling off to
-- its edge as a blast does (damage.falloff), each thing no more than its health. Of a group, as many are caught as the
-- blast covers of the ground it stands on.
local function explode(
	groups: { Group },
	blasts: { number },
	source: Group,
	died: number,
	radius: number,
	strength: number
)
	for index, other in groups do
		if other.alive <= 0 or other.layer == "air" then
			continue
		end
		local dx, dz = other.x - source.x, other.z - source.z
		local distance = math.max(0, math.sqrt(dx * dx + dz * dz) - source.spread)
		if distance > radius + other.spread then
			continue
		end
		local falloff = damage.falloff(math.clamp(distance / radius, 0, 1))
		local caught = math.max(1, other.alive * math.min(1, (radius / other.spread) ^ 2))
		blasts[index] += died * caught * math.min(strength * falloff, other.kind.health)
	end
end

-- Plays out the fight between `ones` and `twos`.
local function simulate(ones: { Fighter }, twos: { Fighter }, options: Options?): Outcome
	local horizon = if options ~= nil and options.horizon ~= nil then options.horizon else HORIZON
	local step = if options ~= nil and options.step ~= nil then options.step else STEP
	local groups: { Group } = {}
	local start_worth = { gather(ones, 1, groups), gather(twos, 2, groups) }
	if options ~= nil and options.approach ~= nil then
		stage(groups, options.approach.from, options.approach.to)
	end

	local count = #groups
	local taken = table.create(count, 0)
	-- what the blasts of what died in a step do, which lands in the next
	local blasts = table.create(count, 0)
	local elapsed = 0
	while elapsed < horizon do
		-- whether each side still has something armed, and whether anything was in anything's reach
		local armed = { false, false }
		for _, group in groups do
			if group.alive > 0 and group.kind.armed then
				armed[group.side] = true
			end
		end
		if armed[1] == false or armed[2] == false then
			break
		end
		elapsed += step

		local acted = false
		for index, group in groups do
			taken[index] = blasts[index]
			blasts[index] = 0
			group.moving = group.walked
			group.walked = false
		end
		-- where each side's things stand, on the whole: what has nothing it can shoot at makes for the other side's
		local middles = { { x = 0, z = 0, count = 0 }, { x = 0, z = 0, count = 0 } }
		for _, group in groups do
			if group.alive > 0 then
				local middle = middles[group.side]
				middle.x += group.x * group.alive
				middle.z += group.z * group.alive
				middle.count += group.alive
			end
		end
		for _, group in groups do
			if group.alive <= 0 or group.kind.armed == false then
				continue
			end
			-- the most of it that has something in its reach, by any of its weapons
			local engaged = 0
			local nearest: Group? = nil
			local nearest_gap = math.huge
			-- how far the weapons that can be turned on it reach
			local nearest_reach = 0
			local fired: { [string]: boolean }? = nil
			for _, gun in group.kind.guns do
				if gun.group ~= nil and fired ~= nil and fired[gun.group] then
					continue
				end
				local best: number? = nil
				local best_reward, best_gap = -1, math.huge
				for index, other in groups do
					if
						other.side == group.side
						or other.alive <= 0
						or unit_defs.reaches_layer(gun.weapon, other.layer) == false
					then
						continue
					end
					local gap = gap_between(group, other)
					if gap < nearest_gap then
						nearest, nearest_gap, nearest_reach = other, gap, gun.range
					elseif other == nearest then
						nearest_reach = math.max(nearest_reach, gun.range)
					end
					if gap > gun.range then
						continue
					end
					local value = reward(gun, other)
					if value > best_reward or (value == best_reward and gap < best_gap) then
						best, best_reward, best_gap = index, value, gap
					end
				end
				if best == nil then
					continue
				end
				if gun.group ~= nil then
					fired = fired or {}
					(fired :: { [string]: boolean })[gun.group] = true
				end
				local target = groups[best]
				local kind = target.kind
				-- of a group spread out, those at its back may not reach yet: as many shoot as stand within reach, the
				-- group's depth taken as its width
				local within = if group.alive > 1
					then math.clamp((gun.range - best_gap) / (2 * group.spread), 1 / group.alive, 1)
					else 1
				engaged = math.max(engaged, within)
				-- a shot does no more than the health of what it hits, and splashes onto as many more as its blast
				-- covers of the ground the group stands on, at the blast's damage over that ground on the whole (it
				-- falls off from the middle to `edge` at the rim, so over a disc it comes to a third of the way)
				local per_shot = gun.shot
				local landed = math.min(unit_defs.damage_against(gun.anti_air, kind.def, per_shot), kind.health)
					/ per_shot
				local covered = 1
				if gun.splash > 0 and target.alive > 1 then
					local area = math.min(1, (gun.splash / target.spread) ^ 2)
					covered += (target.alive - 1) * area * (1 + 2 * gun.edge) / 3
				end
				-- a lobbed shell that does not lead what it is thrown at comes down where that was when it was fired,
				-- which what is walking has left by its speed for the shell's time in the air, and a shell that strays
				-- lands anywhere in its cone: either way it hits as often as the target's size and the blast cover of
				-- where it might land
				local accuracy = 1
				local distance = best_gap + target.spread + group.spread
				local reach = kind.width / 2 + gun.splash
				if target.moving and gun.flight > 0 then
					local missed_by = kind.speed * gun.flight * distance
					accuracy = math.min(1, reach / math.max(missed_by, 1e-3))
				end
				if gun.scatter > 0 then
					local strays_by = distance * math.tan(gun.scatter)
					accuracy *= math.min(1, (reach / math.max(strays_by, 1e-3)) ^ 2)
				end
				taken[best] += gun.dps * group.alive * within * step * landed * covered * accuracy
			end
			if engaged > 0 then
				acted = true
			end
			if group.mobile == false or engaged >= 1 then
				continue
			end
			-- what is not in reach yet walks toward the nearest thing it can shoot, to a little inside its reach, its
			-- back as well as its front; with nothing it can shoot at, it makes for where the other side stands, as a
			-- unit on a fight order goes on to where it was sent
			local tx, tz, stop
			if nearest ~= nil then
				local target = nearest :: Group
				tx, tz = target.x, target.z
				stop = nearest_gap + 2 * group.spread - nearest_reach * order_kinds.RANGE_MARGIN
			else
				local middle = middles[3 - group.side]
				if middle.count == 0 then
					continue
				end
				tx, tz = middle.x / middle.count, middle.z / middle.count
				stop = math.huge
			end
			local dx, dz = tx - group.x, tz - group.z
			local distance = math.sqrt(dx * dx + dz * dz)
			local go = math.min(group.kind.speed * step, stop, distance)
			if go > 0 and distance > 1e-3 then
				group.x += dx / distance * go
				group.z += dz / distance * go
				group.walked = true
				acted = true
			end
		end
		if acted == false then
			break
		end
		for index, group in groups do
			if group.alive <= 0 then
				continue
			end
			local kind = group.kind
			local health = group.health - taken[index]
			if health > 0 and kind.autoheal > 0 then
				health = math.min(health + kind.autoheal * group.alive * step, kind.health * group.alive)
			end
			group.health = math.max(0, health)
			local alive = math.ceil(group.health / kind.health - 1e-6)
			local died = group.alive - alive
			group.alive = alive
			group.spread = spread_of(math.max(group.alive, 1), kind.width)
			local blast = kind.def.death_explosion
			if died > 0 and blast ~= nil then
				explode(groups, blasts, group, died, blast.radius, blast.damage)
			end
		end
	end

	local worth = { 0, 0 }
	for _, group in groups do
		if group.kind.armed and group.alive > 0 then
			worth[group.side] += group.kind.power * group.health / group.kind.health
		end
	end
	local shares = {
		if start_worth[1] > 0 then worth[1] / start_worth[1] else 0,
		if start_worth[2] > 0 then worth[2] / start_worth[2] else 0,
	}
	local margin = shares[1] - shares[2]
	local winner = if margin > 0 then 1 elseif margin < 0 then 2 else 0
	return {
		winner = winner,
		start_worth = start_worth,
		worth = worth,
		margin = margin,
		seconds = elapsed,
	}
end

-- What the armed ones of `fighters` are worth, as `simulate` counts it: each one's power for the share of its health
-- it has.
local function worth_of(fighters: { Fighter }): number
	local worth = 0
	for _, fighter in fighters do
		local kind = kind_of(unit_defs.skinned(fighter.def_name, fighter.skin))
		if kind.armed then
			worth += kind.power * math.clamp((fighter.health or kind.health) / kind.health, 0, 1)
		end
	end
	return worth
end

return table.freeze({
	simulate = simulate,
	worth_of = worth_of,
	HORIZON = HORIZON,
})
