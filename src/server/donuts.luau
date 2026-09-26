-- The pool skin's donuts (shared/skins/pool.luau), as the server keeps them, so that every player sees the same:
-- whether each unit that wears one has it on, how hard it is shaking, and when it popped or flew off. Only a look,
-- which nothing in the sim reads; client/donuts.luau draws it from the attributes published from here (`publish`).
--
--   - a hit (anything that deals it damage, server/damage.luau) pops it;
--   - on an aircraft going faster than `shake_speed` of its top speed it shakes, harder the longer it keeps it up, and
--     after `fly_off_seconds` of that it flies off;
--   - on something that has been under the water deeper than `submerge_depth` for `submerge_seconds` (an amphibious
--     unit wading out, a submarine that has dived) it floats off, up to the surface;
--   - once it is gone, `regen_seconds` of nothing that would knock one off (no hit, no speed, not under the water)
--     puts a new one on.
--
-- A unit that has just started wearing one (it was just finished, or its team just equipped the skin) has it on.

local ReplicatedStorage = game:GetService "ReplicatedStorage"

local ground_levels = require(ReplicatedStorage.Shared.ground_levels)
local skins = require(ReplicatedStorage.Shared.skins)
local types = require(ReplicatedStorage.Shared.types)
local entity_attrs = require(ReplicatedStorage.Shared.entity_attrs)
local unit_defs = require(ReplicatedStorage.Shared.unit_defs)

local state = require(script.Parent.state)
local damage = require(script.Parent.damage)

type DonutSettings = skins.DonutSettings
type Entity = types.Entity
type EntityId = types.EntityId

-- How it last came off: popped by a hit, flown off a fast aircraft, or floated off something under the water.
export type Event = "pop" | "fly" | "float"

type Donut = {
	on: boolean,
	-- seconds since anything last knocked a donut off it, while its donut is off
	quiet: number,
	-- seconds it has been shaking at speed; it winds back down when the speed drops
	shaking: number,
	-- seconds it has been under the water deeper than `submerge_depth`; 0 once it is not
	submerged: number,
	-- how many times it has come off, and how it last did
	events: number,
	last_event: Event?,
}

local donuts: { [EntityId]: Donut } = {}
-- What has been hit since the last step looked.
local hits: { [EntityId]: true } = {}
-- Whether each skin puts a donut on anything, by skin name, worked out once.
local skin_gives_donuts: { [string]: boolean } = {}

-- The donut `entity` wears, if its skin gives something of its kind one and it is finished.
local function settings_of(entity: Entity): DonutSettings?
	if entity.skin == nil or entity.state ~= "active" then
		return nil
	end
	local donut = skins.get(entity.skin).donut
	return if donut ~= nil and table.find(donut.kinds, entity.kind) ~= nil then donut else nil
end

-- Whether `entity`, of `def`, is under the water deeper than `settings` lets a donut stay on: its middle, about where
-- the donut is worn, that far below the surface. Nothing that rides on the water is: a ship, a hovercraft, an
-- aircraft. A submarine is once it has dived.
local function drowned(entity: Entity, def: types.EntityDef, settings: DonutSettings): boolean
	if
		def.air ~= nil
		or def.footing.water == "hover"
		or (unit_defs.floats(def) and unit_defs.is_submarine(def) == false)
	then
		return false
	end
	return ground_levels.WATER_LEVEL - entity.position.Y > settings.submerge_depth
end

local function knock_off(donut: Donut, event: Event)
	donut.on = false
	donut.quiet = 0
	donut.shaking = 0
	donut.submerged = 0
	donut.events += 1
	donut.last_event = event
end

-- Whether any team wears a skin that gives donuts. While none does, which is almost always, a step costs nothing here.
local function anyone_wears(): boolean
	for _, team in state.all_teams() do
		local gives = skin_gives_donuts[team.skin]
		if gives == nil then
			gives = skins.get(team.skin).donut ~= nil
			skin_gives_donuts[team.skin] = gives
		end
		if gives then
			return true
		end
	end
	return false
end

local function tick(delta: number)
	if next(donuts) == nil and anyone_wears() == false then
		table.clear(hits)
		return
	end
	for id, entity in state.all() do
		local settings = settings_of(entity)
		if settings == nil then
			-- one that has stopped wearing one, for its team's skin changing, is forgotten
			donuts[id] = nil
			continue
		end
		local donut = donuts[id]
		if donut == nil then
			donuts[id] = {
				on = true,
				quiet = 0,
				shaking = 0,
				submerged = 0,
				events = 0,
				last_event = nil,
			}
			continue
		end

		local hit = hits[id] == true
		local def = entity.def
		local max_speed = def.max_speed
		local fast = unit_defs.is_air(def)
			and max_speed ~= nil
			and max_speed > 0
			and entity.velocity.Magnitude > settings.shake_speed * max_speed

		local under = drowned(entity, def, settings)
		donut.submerged = if under then donut.submerged + delta else 0

		if donut.on then
			if donut.submerged >= settings.submerge_seconds then
				knock_off(donut, "float")
			elseif hit then
				knock_off(donut, "pop")
			elseif fast then
				donut.shaking += delta
				if donut.shaking >= settings.fly_off_seconds then
					knock_off(donut, "fly")
				end
			else
				donut.shaking = math.max(0, donut.shaking - delta * 2)
			end
		elseif hit or fast or under then
			donut.quiet = 0
		else
			donut.quiet += delta
			if donut.quiet >= settings.regen_seconds then
				donut.on = true
				donut.shaking = 0
			end
		end
	end
	table.clear(hits)
end

-- Publishes `entity`'s donut, which every client draws alike: on or off (`donut`), how close it is to flying off, from 0
-- to 1 to a tenth (`donut_shake`, nil for none), and how it last came off, "<count>:<pop|fly|float>", which changes each
-- time it does (`donut_event`, nil until it first has). All nil for one that wears none.
local function publish(entity: Entity, _def: types.EntityDef, write: entity_attrs.Publish)
	local donut = donuts[entity.id]
	if donut == nil then
		write("donut", nil)
		write("donut_shake", nil)
		write("donut_event", nil)
		return
	end
	local settings = settings_of(entity)
	local shake = if settings ~= nil and donut.on
		then math.round(math.clamp(donut.shaking / settings.fly_off_seconds, 0, 1) * 10) / 10
		else 0
	write("donut", donut.on)
	write("donut_shake", if shake > 0 then shake else nil)
	write("donut_event", if donut.last_event ~= nil then `{donut.events % 1000}:{donut.last_event}` else nil)
end

-- For debugging (pow's donut commands): knocks `entity`'s donut off as `event` would, if it has one on. Returns whether
-- it did.
local function force_off(entity: Entity, event: Event): boolean
	local donut = donuts[entity.id]
	if donut == nil or donut.on == false then
		return false
	end
	knock_off(donut, event)
	return true
end

-- For debugging: puts a new donut on `entity` now, if it wears one and has lost it. Returns whether it did.
local function force_on(entity: Entity): boolean
	local donut = donuts[entity.id]
	if donut == nil or donut.on then
		return false
	end
	donut.on = true
	donut.shaking = 0
	donut.submerged = 0
	return true
end

-- For debugging: how many of `team_id`'s units (every team's if nil) wear a donut, have it on, have it off, and are
-- shaking it loose.
local function census(team_id: types.TeamId?): { wearing: number, on: number, off: number, shaking: number }
	local counts = { wearing = 0, on = 0, off = 0, shaking = 0 }
	for id, donut in donuts do
		local entity = state.get(id)
		if entity == nil or (team_id ~= nil and entity.team ~= team_id) then
			continue
		end
		counts.wearing += 1
		if donut.on then
			counts.on += 1
			if donut.shaking > 0 then
				counts.shaking += 1
			end
		else
			counts.off += 1
		end
	end
	return counts
end

-- Something is gone, and its donut with it.
local function forget(id: EntityId)
	donuts[id] = nil
	hits[id] = nil
end

-- Counts every hit from now on.
local function init()
	damage.on_hurt(function(entity: Entity)
		hits[entity.id] = true
	end)
end

return table.freeze({
	init = init,
	tick = tick,
	forget = forget,
	publish = publish,
	force_off = force_off,
	force_on = force_on,
	census = census,
})
