-- The remotes a pilot drives their unit through (see shared/piloting.luau). Everything arriving is untrusted: only a
-- developer may pilot, only a unit of their own team that can be piloted, and only one nobody else is piloting. What
-- the pilot does is written to their record in `pilots`, where movement, weapons and orders read it; what they ask for
-- on the next step, the manual weapon fired or a transport's hold loaded, unloaded or called for, is done from `tick`,
-- within the step, as an order would do it.

local ReplicatedStorage = game:GetService "ReplicatedStorage"
local ServerScriptService = game:GetService "ServerScriptService"

local types = require(ReplicatedStorage.Shared.types)
local developers = require(ReplicatedStorage.Shared.developers)
local piloting = require(ReplicatedStorage.Shared.piloting)
local geometry = require(ReplicatedStorage.Shared.geometry)
local decode = require(ReplicatedStorage.Shared.decode)

local remotes = require(ServerScriptService.ServerShared.remotes)

local state = require(script.Parent.state)
local players = require(script.Parent.players)
local attack_orders = require(script.Parent.attack_orders)
local manual_weapons = require(script.Parent.manual_weapons)
local pilots = require(script.Parent.pilots)
local transport = require(script.Parent.transport)
local orders = require(script.Parent.orders)

type Entity = types.Entity
type EntityId = types.EntityId
type Pilot = pilots.Pilot

local possess: RemoteEvent = ReplicatedStorage.Shared.Possess
local pilot_input: UnreliableRemoteEvent = ReplicatedStorage.Shared.PilotInput
local pilot_ability: RemoteEvent = ReplicatedStorage.Shared.PilotAbility
local pilot_say: RemoteEvent = ReplicatedStorage.Shared.PilotSay
local pilot_cargo: RemoteEvent = ReplicatedStorage.Shared.PilotCargo

-- What a pilot's client sends of what they are doing, piloting.INPUT_RATE times a second: which way they steer, which
-- way they look, where and at what they aim, whether they are firing, which way they lift an aircraft and which weapon
-- the trigger fires.
type Input = {
	steer: Vector3?,
	facing: number?,
	aim: Vector3?,
	target_id: EntityId?,
	firing: boolean,
	lift: number?,
	weapon: number?,
}

local INPUT = decode.record({
	steer = decode.optional(decode.vector),
	facing = decode.optional(decode.number),
	aim = decode.optional(decode.vector),
	target_id = decode.optional(decode.number),
	firing = decode.flag,
	lift = decode.optional(decode.number),
	weapon = decode.optional(decode.number),
})
local PHRASE = decode.key_of(piloting.PHRASES)
local CARGO = decode.one_of({ "load", "unload", "call" } :: { pilots.CargoRequest })
-- Input comes piloting.INPUT_RATE times a second, and a little more after a hitch; the rest as a player clicks.
local INPUT_RATE: remotes.Rate = { per_second = piloting.INPUT_RATE * 2, burst = piloting.INPUT_RATE }
local CLICK_RATE: remotes.Rate = { per_second = 10, burst = 10 }
-- A pilot says no more than one thing in this many seconds.
local SAY_RATE: remotes.Rate = { per_second = 2, burst = 1 }

local function release(entity_id: EntityId)
	local pilot = pilots.get(entity_id)
	if pilot == nil then
		return
	end
	pilots.clear(entity_id)
	if piloting.piloted_by(pilot.player) == entity_id then
		piloting.publish_piloted(pilot.player, nil)
	end
end

local function release_player(player: Player)
	local entity_id = pilots.piloted_by(player)
	if entity_id ~= nil then
		release(entity_id)
	end
end

-- Hands `pilot`'s player over to piloting `to`: what `to` has just taken aboard, which is `rider`, or what `to` itself
-- has just been set down from.
local function hand_over(from: EntityId, pilot: Pilot, to: Entity, rider: EntityId?)
	pilots.clear(from)
	attack_orders.set(to, nil)
	local handed = pilots.new(pilot.player, to, pilot.heard_at)
	handed.rider = rider
	pilots.set(to.id, handed)
	piloting.publish_piloted(pilot.player, to.id)
end

-- `entity_id` is the unit to take, or nil to let go of the one held.
local function on_possess(player: Player, entity_id: EntityId?)
	release_player(player)
	if entity_id == nil or developers.is_developer(player) == false then
		return
	end
	local entity = state.get(entity_id)
	local team = players.team_of(player)
	if entity == nil or team == nil or entity.team ~= team or entity.alive == false or entity.state ~= "active" then
		return
	end
	if piloting.can_pilot(entity.def) == false or pilots.get(entity.id) ~= nil then
		return
	end
	-- whatever it was ordered to shoot at, it shoots at what it is aimed at now
	attack_orders.set(entity, nil)
	pilots.set(entity.id, pilots.new(player, entity, state.now()))
	piloting.publish_piloted(player, entity.id)
end

-- The pilot record of what `player` pilots, if they pilot anything.
local function pilot_of(player: Player): (EntityId?, Pilot?)
	local entity_id = pilots.piloted_by(player)
	if entity_id == nil then
		return nil, nil
	end
	return entity_id, pilots.get(entity_id)
end

local function on_input(player: Player, input: Input)
	local entity_id, pilot = pilot_of(player)
	if entity_id == nil or pilot == nil then
		return
	end
	local steer = input.steer
	if steer ~= nil then
		local flat = geometry.flatten(steer)
		pilot.steer = if flat.Magnitude > 1 then flat.Unit else flat
	end
	if input.facing ~= nil then
		pilot.facing = input.facing
	end
	pilot.aim = input.aim
	pilot.target_id = input.target_id
	pilot.firing = input.firing
	pilot.lift = if input.lift ~= nil then math.clamp(math.round(input.lift), -1, 1) else 0
	-- the weapon the trigger fires, which the pilot chooses among those it can
	local entity = state.get(entity_id)
	local weapon = input.weapon
	if entity ~= nil and weapon ~= nil and piloting.can_select(entity.def, weapon) then
		pilot.weapon = weapon
	end
	pilot.heard_at = state.now()
end

-- `phrase` names one of `piloting.PHRASES`, which every client is told the pilot's unit says.
local function on_say(player: Player, phrase: string)
	local entity_id = pilots.piloted_by(player)
	if entity_id ~= nil then
		pilot_say:FireAllClients(entity_id, phrase)
	end
end

-- `aim` is where to fire the manual weapon, on the next step.
local function on_ability(player: Player, aim: Vector3)
	local _, pilot = pilot_of(player)
	if pilot ~= nil then
		pilot.ability = aim
	end
end

-- `request` is done on the next step.
local function on_cargo(player: Player, request: pilots.CargoRequest)
	local _, pilot = pilot_of(player)
	if pilot ~= nil then
		pilot.cargo = request
	end
end

-- For something piloted that can be carried: calls the nearest transport that could lift it over if its pilot asked,
-- and keeps track of the one called on its way, lost if it is destroyed and forgotten if it is given something else.
local function airlift(entity: Entity, pilot: Pilot, request: pilots.CargoRequest?, now: number)
	local transporter = if entity.def.weight_class ~= nil
		then transport.nearest_transporter(entity, function(other: Entity): boolean
			return pilots.get(other.id) == nil
		end)
		else nil
	if request == "call" and transporter ~= nil then
		orders.issue(transporter, { { kind = "load", target_id = entity.id } }, false, false)
		pilot.called = transporter.id
		pilot.call_lost_at = nil
	end
	local called_id = pilot.called
	if called_id ~= nil then
		local called = state.get(called_id)
		local order = if called ~= nil then called.orders[1] else nil
		if called == nil or called.alive == false then
			pilot.called = nil
			pilot.call_lost_at = now
		elseif order == nil or order.kind ~= "load" or order.target_id ~= entity.id then
			pilot.called = nil
		end
	end
	pilot.transporter = if transporter ~= nil then transporter.id else nil
end

-- For a piloted transport: picks up or sets down what its pilot asked, if it can, and works out what it could pick up
-- and whether it could set down what it carries. Returns what it has set down, for its pilot to go back to piloting,
-- if it was what they rode in on.
local function work_hold(entity: Entity, pilot: Pilot, request: pilots.CargoRequest?): Entity?
	local carrying = #state.cargo_of(entity.id) > 0
	local loadable = if carrying then nil else transport.nearest_loadable(entity)
	local rider: Entity? = nil
	if request == "load" and loadable ~= nil then
		transport.load(entity, loadable)
		loadable = nil
		carrying = true
	elseif request == "unload" and carrying and transport.low_enough(entity) then
		local at = entity.position
		transport.unload(entity, Vector3.new(at.X, 0, at.Z))
		carrying = #state.cargo_of(entity.id) > 0
		rider = if pilot.rider ~= nil then state.get(pilot.rider) else nil
	end
	pilot.loadable = if loadable ~= nil then loadable.id else nil
	pilot.can_unload = carrying and transport.low_enough(entity)
	return rider
end

-- Lets go of every unit that is gone; stops the units of pilots not heard from lately; fires the manual weapons asked
-- for since the last step, each once, if it is ready; and does what each pilot asked of a hold. A pilot whose unit is
-- taken aboard a transport of its own side that nobody pilots takes that over, and goes back to what they rode in on
-- once the transport sets it down. A pilot who leaves lets go as they do (`player_removing`).
local function tick()
	local now = state.now()
	-- done once nothing is iterating the pilots
	local handovers: { { from: EntityId, to: Entity, rider: EntityId? } } = {}
	for entity_id, pilot in pilots.all() do
		local entity = state.get(entity_id)
		if entity == nil then
			local carrier_id = state.carrier_of(entity_id)
			local carrier = if carrier_id ~= nil then state.get(carrier_id) else nil
			local carried = state.get(entity_id, true)
			if carrier ~= nil and carried ~= nil and carrier.team == carried.team and pilots.get(carrier.id) == nil then
				table.insert(handovers, { from = entity_id, to = carrier, rider = entity_id })
			else
				release(entity_id)
			end
			continue
		end
		if now - pilot.heard_at > piloting.INPUT_TIMEOUT then
			pilot.steer = Vector3.zero
			pilot.firing = false
			pilot.lift = 0
		end
		local aim = pilot.ability
		pilot.ability = nil
		if aim ~= nil then
			manual_weapons.fire(entity, aim)
		end
		local request = pilot.cargo
		pilot.cargo = nil
		if entity.def.transport == nil then
			airlift(entity, pilot, request, now)
			continue
		end
		local rider = work_hold(entity, pilot, request)
		if rider ~= nil then
			table.insert(handovers, { from = entity_id, to = rider, rider = nil })
		end
	end

	for _, handover in handovers do
		local pilot = pilots.get(handover.from)
		if pilot ~= nil and pilots.get(handover.to.id) == nil then
			hand_over(handover.from, pilot, handover.to, handover.rider)
		end
	end
end

-- A player leaving lets go of what they pilot.
local function player_removing(player: Player)
	release_player(player)
end

local function init()
	remotes.listen(possess, { args = { decode.optional(decode.number) }, rate = CLICK_RATE }, on_possess)
	remotes.listen(pilot_input, { args = { INPUT }, rate = INPUT_RATE }, on_input)
	remotes.listen(pilot_ability, { args = { decode.vector }, rate = CLICK_RATE }, on_ability)
	remotes.listen(pilot_say, { args = { PHRASE }, rate = SAY_RATE }, on_say)
	remotes.listen(pilot_cargo, { args = { CARGO }, rate = CLICK_RATE }, on_cargo)
end

return table.freeze({
	init = init,
	tick = tick,
	release = release,
	release_player = release_player,
	player_removing = player_removing,
})
