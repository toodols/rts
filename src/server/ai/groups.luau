--!strict
-- Groups apart from the army, as CircuitAI's military manager runs attack, raid and defence tasks side by side, each
-- with its own group:
--
-- - raids (the profile's raid_size, raid_groups and raid_interval): a few of its fastest units after the enemy's
--   extractors and constructors that stand where they are well able for them (targets.luau's `choose_raid_target`, or
--   with the profile's raid_rule "sim", predictions.luau's), one after another. A new one is sent every raid_interval
--   seconds, while fewer than raid_groups are out, of the raid_size fastest units waiting at home, if there is
--   something for them to go after; by the "danger" rule only while the army is at home.
-- - hunts (the profile's hunt_groups): for each of the enemy's armed units that comes into its territory
--   (targets.luau's `intruders`) that nothing hunts yet, the nearest home first, the fewest of what waits at home, the
--   quickest to get to it first, that are predicted to beat it and what is round it by the profile's hunt_margin (or,
--   with neither its attack_rule nor its defend_rule "sim", that are worth the danger round it); one that nothing at
--   home is enough for is left to the army's defence. What a hunt is after, and whatever of the enemy is within
--   HUNT_CLUSTER of it, is left to it by the army (`hunted`).
-- - strikes (the profile's strike_groups, with its attack_rule "sim"): no more often than STRIKE_INTERVAL, while fewer
--   than strike_groups are out, the target of the enemy's away from where it already fights that what waits at home
--   beats most cheaply, and the fewest of those, the nearest it first, predicted to beat it by sim_attack_margin, if
--   they are no more than the profile's strike_share of what waits at home. A strike is STRIKE_LEAST units at the least
--   and goes only at buildings. The army sends one too, of what a wave setting out does not need (`split_wave`).
--
-- Each goes after its target, and once that is gone, the next: a raid as it chose the first, a hunt the nearest
-- intruder nothing hunts, a strike the next target it beats away from where it already fights. It comes home once where
-- it stands is too dangerous for it: by the danger field for a raid by the "danger" rule; for a hunt, a strike and a
-- raid by the "sim" rule, by the fight predictor, every CHECK_INTERVAL seconds, against what of the enemy is really
-- round it, a raid first slipping away to another target on the far side of it from the threat, no more than
-- RAID_SLIPS times. Or it has nothing left to go after. It is let go back into the army once it is home.
--
-- The groups out are the brain's `groups` record, in the order they were sent; which units are in each is their
-- assignments' to say.

local ReplicatedStorage = game:GetService "ReplicatedStorage"
local ServerScriptService = game:GetService "ServerScriptService"

local types = require(ReplicatedStorage.Shared.types)
local unit_defs = require(ReplicatedStorage.Shared.unit_defs)
local geometry = require(ReplicatedStorage.Shared.geometry)

local state = require(ServerScriptService.Server.state)

local danger_field = require(script.Parent.danger_field)
local brains = require(script.Parent.brains)
local assignments = require(script.Parent.assignments)
local catalog = require(script.Parent.catalog)
local censuses = require(script.Parent.census)
local squads = require(script.Parent.squads)
local targets = require(script.Parent.targets)
local predictions = require(script.Parent.predictions)
local sorties = require(script.Parent.sorties)

type Entity = types.Entity
type EntityId = types.EntityId
type Brain = brains.Brain
type Group = brains.Group
type GroupKind = brains.GroupKind
type Sortie = brains.Sortie
type Census = censuses.Census

-- A group on its way home is let go back into the army this near the rally point.
local HOME_SLACK = 40
-- The fight a hunt, a strike or a raid by the "sim" rule is in is predicted again every this many seconds.
local CHECK_INTERVAL = 3
local RAID_SLIPS = 1
local HUNT_CLUSTER = 40
local STRIKE_INTERVAL = 8
local STRIKE_LEAST = 2
-- A wave that sets out keeps the fewest that beat its target by SPLIT_BUFFER over the profile's sim_attack_margin.
local SPLIT_BUFFER = 0.25

-- How many of `brain`'s groups out are of `kind`.
local function out_of(brain: Brain, kind: GroupKind): number
	local count = 0
	for _, group in brain.groups.out do
		if group.kind == kind then
			count += 1
		end
	end
	return count
end

-- How many raids `brain` has out.
local function raids_out(brain: Brain): number
	return out_of(brain, "raid")
end

-- How many units go on each of its raids, if it wants another out: its profile raids, and it has fewer out than its
-- raid_groups.
local function raid_wanted(brain: Brain): number?
	local profile = brain.profile
	if profile.raid_size == nil or raids_out(brain) >= profile.raid_groups then
		return nil
	end
	return profile.raid_size
end

-- What of the army waits at home, free to be sent somewhere, and able to fight on the ground.
local function free_units(brain: Brain, census: Census): { Entity }
	local free: { Entity } = {}
	for _, unit in census.army do
		if
			assignments.is_free(brain, unit)
			and unit_defs.is_air(unit.def) == false
			and catalog.role_of(unit.def_name).hits_ground
		then
			table.insert(free, unit)
		end
	end
	return free
end

-- The units of each group out still standing, by group.
local function members_by_group(brain: Brain): { [Group]: { Entity } }
	local members: { [Group]: { Entity } } = {}
	for _, group in brain.groups.out do
		members[group] = {}
	end
	for _, unit_id in assignments.each(brain, "group") do
		local assignment = assignments.get(brain, unit_id)
		local unit = state.get(unit_id)
		if assignment ~= nil and assignment.job == "group" and unit ~= nil and unit.alive then
			table.insert(members[assignment.group], unit)
		end
	end
	return members
end

-- Lets `group` go, its units back into the army.
local function disband(brain: Brain, group: Group)
	for _, unit_id in assignments.each(brain, "group") do
		local assignment = assignments.get(brain, unit_id)
		if assignment ~= nil and assignment.job == "group" and assignment.group == group then
			assignments.release(brain, unit_id)
		end
	end
	table.remove(brain.groups.out, table.find(brain.groups.out, group) :: number)
end

-- Sends `members` out as a group of `kind` at `target`, and tells whoever is watching.
local function launch(brain: Brain, kind: GroupKind, members: { Entity }, target: Entity): Group
	local now = brains.now()
	local sortie: Sortie = {
		at = now - brain.started,
		units = #members,
		worth = squads.worth_of(members),
		needed = nil,
		target = target.def_name,
		ended = nil,
		kills = 0,
		slipped = nil,
	}
	local group: Group = { kind = kind, target = target.id, returning = false, next_check = now, sortie = sortie }
	table.insert(brain.groups.out, group)
	for _, unit in members do
		assignments.assign(brain, unit.id, { job = "group", group = group })
	end
	sorties.sent(brain, kind, sortie)
	return group
end

-- Where it is attacking now, but for `except`: the wave's target, and each raid's and strike's.
local function fronts(brain: Brain, except: Group?): { Vector3 }
	local positions: { Vector3 } = {}
	local wave = brain.army.wave
	local wave_target = if wave ~= nil and wave.target ~= nil then state.get(wave.target) else nil
	if wave_target ~= nil then
		table.insert(positions, wave_target.position)
	end
	for _, group in brain.groups.out do
		local target = if group.target ~= nil then state.get(group.target) else nil
		if group ~= except and group.kind ~= "hunt" and group.returning == false and target ~= nil then
			table.insert(positions, target.position)
		end
	end
	return positions
end

-- Marks `prey`, and whatever of the enemy is within HUNT_CLUSTER of it, as hunted, which the army leaves to the hunt
-- (targets.luau's `nearest_intruder`).
local function mark_hunted(brain: Brain, census: Census, prey: Entity)
	local hunted = brain.groups.hunted
	hunted[prey.id] = true
	for _, enemy in census.enemy_units do
		if geometry.distance_2d(enemy.position, prey.position) <= HUNT_CLUSTER then
			hunted[enemy.id] = true
		end
	end
end

-- Whether the profile judges a hunt's fight by the fight predictor: its attack_rule or its defend_rule is "sim".
local function hunts_by_sim(brain: Brain): boolean
	return brain.profile.attack_rule == "sim" or brain.profile.defend_rule == "sim"
end

-- Hunters (see the top of this file), for `intruders`.
local function start_hunts(brain: Brain, census: Census, intruders: { Entity })
	local profile = brain.profile
	local most = profile.hunt_groups or 0
	local out = out_of(brain, "hunt")
	if out >= most or #intruders == 0 then
		return
	end
	local pool = free_units(brain, census)
	local by_home = table.clone(intruders)
	table.sort(by_home, function(a, b): boolean
		return geometry.distance_2d(a.position, brain.home) < geometry.distance_2d(b.position, brain.home)
	end)
	for _, prey in by_home do
		if out >= most or #pool == 0 then
			break
		end
		if brain.groups.hunted[prey.id] then
			continue
		end
		local times: { [Entity]: number } = {}
		for _, unit in pool do
			times[unit] = geometry.distance_2d(unit.position, prey.position) / math.max(1, unit.def.max_speed or 1)
		end
		table.sort(pool, function(a, b): boolean
			return times[a] < times[b]
		end)
		local count: number? = nil
		if hunts_by_sim(brain) then
			local theirs = predictions.enemies_near(census, prey.position)
			count = predictions.fewest_that_win(brain, pool, theirs, profile.hunt_margin, 1)
		else
			local needed = danger_field.peak_near(brain.field, prey.position, profile.target_danger_radius)
				* math.max(1, profile.defend_share or 0)
			local worth = 0
			for index, unit in pool do
				worth += unit_defs.power(unit.def)
				if worth >= needed then
					count = index
					break
				end
			end
		end
		if count == nil then
			continue
		end
		local members = table.move(pool, 1, count, 1, {})
		pool = table.move(pool, count + 1, #pool, 1, {})
		launch(brain, "hunt", members, prey)
		mark_hunted(brain, census, prey)
		out += 1
	end
end

-- Strikes (see the top of this file).
local function start_strikes(brain: Brain, census: Census)
	local profile = brain.profile
	local most = profile.strike_groups
	local record = brain.groups
	-- none while the whole army is seeing off an enemy at home
	if
		most == nil
		or profile.attack_rule ~= "sim"
		or brains.now() < record.next_strike_at
		or brain.army.defending ~= nil
	then
		return
	end
	if out_of(brain, "strike") >= most then
		return
	end
	record.next_strike_at = brains.now() + STRIKE_INTERVAL
	local pool = free_units(brain, census)
	if #pool == 0 then
		return
	end
	local from = squads.centroid(pool)
	local target = predictions.choose_target(brain, census, pool, from, fronts(brain, nil), true)
	if target == nil then
		return
	end
	local goal = target.position
	table.sort(pool, function(a, b): boolean
		return geometry.distance_2d(a.position, goal) < geometry.distance_2d(b.position, goal)
	end)
	local count = predictions.fewest_that_win(
		brain,
		pool,
		predictions.enemies_near(census, goal),
		profile.sim_attack_margin,
		STRIKE_LEAST,
		{ from = from, to = goal }
	)
	if count == nil then
		return
	end
	local members = table.move(pool, 1, count, 1, {})
	if squads.worth_of(members) > squads.worth_of(pool) * profile.strike_share then
		return
	end
	launch(brain, "strike", members, target)
end

-- A wave about to set out from `home`, at `target` from `from`, with the profile's strike_groups and its attack_rule
-- "sim": it keeps only the fewest that beat its target by SPLIT_BUFFER over sim_attack_margin, the nearest it first,
-- and what it does not need goes as a strike at another target it beats, if there is one. Returns what goes with the
-- wave: `home` as it was when nothing splits off.
local function split_wave(brain: Brain, census: Census, home: { Entity }, target: Entity, from: Vector3): { Entity }
	local profile = brain.profile
	local most = profile.strike_groups
	if most == nil or profile.attack_rule ~= "sim" or out_of(brain, "strike") >= most then
		return home
	end
	local goal = target.position
	local line = table.clone(home)
	table.sort(line, function(a, b): boolean
		return geometry.distance_2d(a.position, goal) < geometry.distance_2d(b.position, goal)
	end)
	local count = predictions.fewest_that_win(
		brain,
		line,
		predictions.enemies_near(census, goal),
		profile.sim_attack_margin + SPLIT_BUFFER,
		1,
		{ from = from, to = goal }
	)
	if count == nil or #line - count < STRIKE_LEAST then
		return home
	end
	local rest = table.move(line, count + 1, #line, 1, {})
	local elsewhere = predictions.choose_target(brain, census, rest, squads.centroid(rest), { goal }, true)
	if elsewhere == nil then
		return home
	end
	launch(brain, "strike", rest, elsewhere)
	return table.move(line, 1, count, 1, {})
end

-- Whether `group`, `members` with its middle at `middle`, worth `worth`, is outmatched where it stands, and if it is,
-- whether a raid slips away to another target instead (which it is then sent at).
local function outmatched(
	brain: Brain,
	census: Census,
	group: Group,
	members: { Entity },
	middle: Vector3,
	worth: number
): boolean
	local profile = brain.profile
	if group.kind == "raid" and profile.raid_rule == "danger" then
		return danger_field.at(brain.field, middle) > worth * profile.raid_retreat_ratio
	end
	local now = brains.now()
	if now < group.next_check then
		return false
	end
	group.next_check = now + CHECK_INTERVAL
	local theirs =
		predictions.enemies_near(census, middle, if group.kind == "raid" then predictions.RAID_RADIUS else nil)
	local armed: { Entity } = {}
	for _, enemy in theirs do
		if catalog.role_of(enemy.def_name).reach > 0 then
			table.insert(armed, enemy)
		end
	end
	if #armed == 0 or predictions.predict(brain, members, theirs).margin >= profile.sim_retreat_margin then
		return false
	end
	-- a raid that commits slips away to another target on the far side of it from the threat, if it has one it beats,
	-- rather than going home, as BARb's RaidTask turns to another target
	local sortie = group.sortie
	if group.kind == "raid" and (sortie.slipped or 0) < RAID_SLIPS then
		local slipped =
			predictions.choose_raid_target(brain, census, members, middle, fronts(brain, group), squads.centroid(armed))
		if slipped ~= nil then
			group.target = slipped.id
			sortie.slipped = (sortie.slipped or 0) + 1
			return false
		end
	end
	return true
end

-- The next target of `group`, `members` with its middle at `middle`, worth `worth`, once the one it was after is gone.
local function next_target(
	brain: Brain,
	census: Census,
	group: Group,
	members: { Entity },
	middle: Vector3,
	worth: number,
	intruders: { Entity }
): Entity?
	if group.kind == "hunt" then
		local best: Entity? = nil
		local best_distance = math.huge
		for _, intruder in intruders do
			local distance = geometry.distance_2d(intruder.position, middle)
			if brain.groups.hunted[intruder.id] ~= true and distance < best_distance then
				best = intruder
				best_distance = distance
			end
		end
		return best
	elseif group.kind == "strike" then
		return predictions.choose_target(brain, census, members, middle, fronts(brain, group), true)
	elseif brain.profile.raid_rule == "sim" then
		return predictions.choose_raid_target(brain, census, members, middle, fronts(brain, group), nil)
	end
	return targets.choose_raid_target(brain, census, middle, worth)
end

-- Sends a new raid, if one is wanted and there is something for it to go after (see the top of this file).
local function start_raid(brain: Brain, census: Census)
	local profile = brain.profile
	local record = brain.groups
	local size = raid_wanted(brain)
	-- only what is waiting at home is sent, and by the "danger" rule not while the army is out
	if
		size == nil
		or brains.now() < record.next_raid_at
		or (brain.army.wave ~= nil and profile.raid_rule == "danger")
		or brain.army.defending ~= nil
	then
		return
	end
	local home = squads.rally_point(brain)
	local waiting = free_units(brain, census)
	local fastest = 0
	for _, unit in waiting do
		fastest = math.max(fastest, unit.def.max_speed or 0)
	end
	local chosen: { Entity } = {}
	for _, unit in waiting do
		if (unit.def.max_speed or 0) >= fastest * profile.raider_speed_share then
			table.insert(chosen, unit)
		end
	end
	if #chosen < size then
		return
	end
	-- the fastest, then the nearest home
	table.sort(chosen, function(a, b): boolean
		local a_speed = a.def.max_speed or 0
		local b_speed = b.def.max_speed or 0
		if a_speed ~= b_speed then
			return a_speed > b_speed
		end
		return geometry.distance_2d(a.position, home) < geometry.distance_2d(b.position, home)
	end)
	local members = table.move(chosen, 1, size, 1, {})
	local target = if profile.raid_rule == "sim"
		then predictions.choose_raid_target(brain, census, members, squads.centroid(members), fronts(brain, nil), nil)
		else targets.choose_raid_target(brain, census, squads.centroid(members), squads.worth_of(members))
	if target == nil then
		return
	end
	launch(brain, "raid", members, target)
	record.next_raid_at = brains.now() + profile.raid_interval
end

local function run_groups(brain: Brain, census: Census)
	local profile = brain.profile
	local home = squads.rally_point(brain)
	local intruders: { Entity } = if profile.hunt_groups ~= nil then targets.intruders(brain, census) else {}
	local inside: { [EntityId]: boolean } = {}
	for _, intruder in intruders do
		inside[intruder.id] = true
	end
	table.clear(brain.groups.hunted)
	local members_of = members_by_group(brain)
	for _, group in table.clone(brain.groups.out) do
		local members = members_of[group]
		local sortie = group.sortie
		if #members == 0 then
			sortie.ended = sortie.ended or "lost"
			disband(brain, group)
			continue
		end
		local middle = squads.centroid(members)
		local worth = squads.worth_of(members)
		if group.returning == false and outmatched(brain, census, group, members, middle, worth) then
			group.returning = true
			sortie.ended = "outmatched"
		end
		if group.returning == false then
			local target = if group.target ~= nil then state.get(group.target) else nil
			local killed = group.target ~= nil and (target == nil or target.alive == false)
			local gone = killed or target == nil or (target :: Entity).team == brain.team
			if group.kind == "hunt" and target ~= nil and inside[target.id] ~= true then
				gone = true
			end
			if gone then
				if killed then
					sortie.kills = (sortie.kills or 0) + 1
				end
				target = next_target(brain, census, group, members, middle, worth, intruders)
				group.target = if target ~= nil then target.id else nil
			end
			if target ~= nil then
				if group.kind == "hunt" then
					mark_hunted(brain, census, target)
				end
				squads.send_all(brain, members, target.position, "fight", 0)
				continue
			end
			group.returning = true
			sortie.ended = "won"
		end
		if geometry.distance_2d(middle, home) <= HOME_SLACK then
			disband(brain, group)
			continue
		end
		squads.send_all(brain, members, home, "move", squads.RALLY_SLACK)
	end

	if profile.hunt_groups ~= nil then
		start_hunts(brain, census, intruders)
	end
	start_strikes(brain, census)
	start_raid(brain, census)
end

return table.freeze({
	raids_out = raids_out,
	raid_wanted = raid_wanted,
	fronts = fronts,
	split_wave = split_wave,
	run_groups = run_groups,
})
