--!strict
-- What a shooter has been ordered to shoot at: something on the map, which an attack order names, or a point on the
-- ground, which an attack-ground order does (`sight.Aim`). Either may be a launch (`Order.launch`), which is for the
-- shooter's manual-fire weapons alone: the rest go on picking their own targets, and without a launch the manual-fire
-- weapons shoot at nothing. `orders` sets it as it carries the orders out, and `targeting` reads it. An attack that
-- launches a stockpiled missile is done once it has (`note_launch`, `take_launch`).

local ReplicatedStorage = game:GetService "ReplicatedStorage"

local types = require(ReplicatedStorage.Shared.types)
local unit_defs = require(ReplicatedStorage.Shared.unit_defs)

local state = require(script.Parent.state)
local sight = require(script.Parent.sight)
local snapshot = require(script.Parent.snapshot)

type Entity = types.Entity
type EntityId = types.EntityId
type Aim = sight.Aim

-- What one shooter was ordered to shoot at: the target by its id, so that one that is gone is not kept, or the point.
type Ordered = {
	target_id: EntityId?,
	point: Vector3?,
	launch: boolean,
}

local ordered: { [EntityId]: Ordered } = {}
-- Shooters that have launched a stockpiled missile since their orders last looked.
local launched: { [EntityId]: boolean } = {}

-- `attacker` is ordered to shoot at `aim`, as a launch if `launch` says so, in place of whatever it was ordered to
-- shoot at before; nil, which every order but an attack sets, orders it to shoot at nothing in particular.
local function set(attacker: Entity, aim: Aim?, launch: boolean?)
	if aim == nil then
		ordered[attacker.id] = nil
		return
	end
	local target = sight.target_of(aim)
	ordered[attacker.id] = {
		target_id = if target ~= nil then target.id else nil,
		point = if target == nil then sight.position_of(aim) else nil,
		launch = launch == true,
	}
end

-- What `attacker` was ordered to shoot at, if anything, and it is still there to be shot at: a target that is gone is
-- nothing. Something hanging from a transport is still there.
local function aim_of(attacker: Entity): Aim?
	local order = ordered[attacker.id]
	if order == nil then
		return nil
	end
	if order.target_id ~= nil then
		return state.get(order.target_id, true)
	end
	return order.point
end

-- Whether `weapon` fires at what `attacker` was ordered to shoot at, if anything: a launch is for its manual-fire
-- weapons alone, and any other attack for the rest (`unit_defs.fired_by_order`).
local function answered_by(attacker: Entity, weapon: types.Weapon): boolean
	local order = ordered[attacker.id]
	return unit_defs.fired_by_order(weapon, order ~= nil and order.launch)
end

-- Notes that `entity_id` has launched a stockpiled missile.
local function note_launch(entity_id: EntityId)
	launched[entity_id] = true
end

-- Whether `entity_id` has launched a stockpiled missile since this was last asked. An attack order that
-- launches one is done, and asks so that it can end.
local function take_launch(entity_id: EntityId): boolean
	local was = launched[entity_id] == true
	launched[entity_id] = nil
	return was
end

local function forget(entity_id: EntityId)
	ordered[entity_id] = nil
	launched[entity_id] = nil
end

snapshot.keep("attack_orders", function()
	return { ordered = ordered, launched = launched }
end, function(saved)
	ordered = saved.ordered
	launched = saved.launched
end)

return table.freeze({
	forget = forget,
	set = set,
	aim_of = aim_of,
	answered_by = answered_by,
	note_launch = note_launch,
	take_launch = take_launch,
})
