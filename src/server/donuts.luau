-- The pool skin's donuts (shared/skins/pool.luau), as the server keeps them, so that every player sees the same:
-- whether each unit that wears one has it on, how hard it is shaking, and when it popped or flew off. Only a look,
-- which nothing in the sim reads; client/donuts.luau draws it from the attributes `instances` publishes from here.
--
--   - a hit (its health dropped, and not because its skin changed its most) pops it;
--   - on an aircraft going faster than `shake_speed` of its top speed it shakes, harder the longer it keeps it up, and
--     after `fly_off_seconds` of that it flies off;
--   - on something under the water deeper than `submerge_depth` (an amphibious unit wading out, a submarine that has
--     dived) it floats off, up to the surface;
--   - once it is gone, `regen_seconds` of nothing that would knock one off (no hit, no speed, not under the water)
--     puts a new one on.
--
-- A unit that has just started wearing one (it was just finished, or its team just equipped the skin) has it on.

local ReplicatedStorage = game:GetService "ReplicatedStorage"
local ServerScriptService = game:GetService "ServerScriptService"

local config = require(ReplicatedStorage.Shared.config)
local skins = require(ReplicatedStorage.Shared.skins)
local types = require(ReplicatedStorage.Shared.types)
local unit_defs = require(ReplicatedStorage.Shared.unit_defs)

local state = require(ServerScriptService.Server.state)

type DonutSettings = types.DonutSettings
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
	-- its health and most health as of the last step, to see a hit by
	health: number,
	max_health: number,
	-- how many times it has come off, and how it last did
	events: number,
	last_event: Event?,
}

-- What `instances` publishes about a unit's donut.
export type Published = {
	on: boolean,
	-- 0 to 1, how close it is to flying off, to a tenth
	shake: number,
	-- "<count>:<pop|fly|float>", which changes each time it comes off; nil until it first has
	event: string?,
}

local donuts: { [EntityId]: Donut } = {}

-- The donut `entity` wears, if its skin gives something of its kind one and it is finished.
local function settings_of(entity: Entity): DonutSettings?
	if entity.skin == nil or entity.state ~= "active" then
		return nil
	end
	for _, attachment in skins.get(entity.skin).attachments do
		if attachment.kind == "donut" and table.find(attachment.kinds, entity.kind) ~= nil then
			return attachment.donut
		end
	end
	return nil
end

-- Whether `entity`, of `def`, is under the water deeper than `settings` lets a donut stay on: its middle, about where
-- the donut is worn, that far below the surface. Nothing that rides on the water is: a ship, a hovercraft, an
-- aircraft. A submarine is once it has dived.
local function drowned(entity: Entity, def: types.EntityDef, settings: DonutSettings): boolean
	if def.air ~= nil or def.hover == true or (unit_defs.floats(def) and def.waterline == nil) then
		return false
	end
	return config.WATER_LEVEL - entity.position.Y > settings.submerge_depth
end

local function knock_off(donut: Donut, event: Event)
	donut.on = false
	donut.quiet = 0
	donut.shaking = 0
	donut.events += 1
	donut.last_event = event
end

local function tick(delta: number)
	local seen: { [EntityId]: boolean } = {}
	for id, entity in state.all() do
		local settings = settings_of(entity)
		if settings == nil then
			continue
		end
		seen[id] = true
		local donut = donuts[id]
		if donut == nil then
			donuts[id] = {
				on = true,
				quiet = 0,
				shaking = 0,
				health = entity.health,
				max_health = entity.max_health,
				events = 0,
				last_event = nil,
			}
			continue
		end

		local hit = entity.health < donut.health and entity.max_health == donut.max_health
		donut.health = entity.health
		donut.max_health = entity.max_health
		local def = unit_defs.of(entity)
		local max_speed = def.max_speed
		local fast = unit_defs.is_air(def)
			and max_speed ~= nil
			and max_speed > 0
			and entity.velocity.Magnitude > settings.shake_speed * max_speed

		local under = drowned(entity, def, settings)

		if donut.on then
			if under then
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
	-- what has died, or stopped wearing one, is forgotten
	for id in donuts do
		if seen[id] == nil then
			donuts[id] = nil
		end
	end
end

-- What to publish about `entity`'s donut, or nil if it wears none.
local function published(entity: Entity): Published?
	local donut = donuts[entity.id]
	if donut == nil then
		return nil
	end
	local settings = settings_of(entity)
	local shake = if settings ~= nil and donut.on
		then math.round(math.clamp(donut.shaking / settings.fly_off_seconds, 0, 1) * 10) / 10
		else 0
	return {
		on = donut.on,
		shake = shake,
		event = if donut.last_event ~= nil then `{donut.events % 1000}:{donut.last_event}` else nil,
	}
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

return table.freeze({
	tick = tick,
	published = published,
	force_off = force_off,
	force_on = force_on,
	census = census,
})
