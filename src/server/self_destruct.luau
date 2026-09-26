-- Self-destruct, as in BAR: told to, a thing counts down and then destroys itself, which leaves no wreck unless it is
-- a commander, whose wreck is always left. Telling it again while it counts stops the countdown, and so does telling it
-- to stop (BAR has a gadget for that). It goes on doing whatever it was doing meanwhile.
--
-- The countdown is the Spring engine's: a def's `self_destruct_countdown` (BAR's selfdestructcountdown, 5 unless the
-- unit file says otherwise) is counted in half steps, one for every slow update of 16 frames at 30 a second, with one
-- more on top, so 5 takes about 6 seconds and 1 about 1.6.

local ReplicatedStorage = game:GetService "ReplicatedStorage"

local types = require(ReplicatedStorage.Shared.types)
local entity_attrs = require(ReplicatedStorage.Shared.entity_attrs)

local state = require(script.Parent.state)
local deaths = require(script.Parent.deaths)
local snapshot = require(script.Parent.snapshot)

type Entity = types.Entity
type EntityId = types.EntityId

local DEFAULT_COUNTDOWN = 5
local SLOW_UPDATE_SECONDS = 16 / 30

-- Seconds left, by entity, for everything counting down.
local counting: { [EntityId]: number } = {}

local function countdown_seconds(entity: Entity): number
	local countdown = entity.def.self_destruct_countdown or DEFAULT_COUNTDOWN
	return (countdown * 2 + 1) * SLOW_UPDATE_SECONDS
end

-- Starts `entity` counting down, or stops it if it already is.
local function toggle(entity: Entity)
	if counting[entity.id] ~= nil then
		counting[entity.id] = nil
	else
		counting[entity.id] = countdown_seconds(entity)
	end
end

local function cancel(entity: Entity)
	counting[entity.id] = nil
end

-- Seconds until `id` destroys itself, or nil if it is not counting down.
local function seconds_left(id: EntityId): number?
	return counting[id]
end

-- Counts every countdown down a step, and destroys what reaches the end of its own.
local function tick(delta: number)
	for id, left in counting do
		local entity = state.get(id)
		-- one that has been taken aboard a transport, or has died some other way, is not counting any more
		if entity == nil then
			counting[id] = nil
			continue
		end
		left -= delta
		if left > 0 then
			counting[id] = left
			continue
		end
		counting[id] = nil
		deaths.destroy(entity, "self_destructed")
	end
end

local function forget(id: EntityId)
	counting[id] = nil
end

-- Publishes whole seconds until `entity` destroys itself, rounded up (`self_destruct`); nil unless it is counting down.
local function publish(entity: Entity, _def: types.EntityDef, write: entity_attrs.Publish)
	local left = counting[entity.id]
	write("self_destruct", if left ~= nil then math.ceil(left) else nil)
end

snapshot.keep("self_destruct", function()
	return { counting = counting }
end, function(saved)
	counting = saved.counting
end)

return table.freeze({
	seconds_left = seconds_left,
	forget = forget,
	toggle = toggle,
	cancel = cancel,
	tick = tick,
	publish = publish,
})
