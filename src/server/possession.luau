-- The remotes a pilot drives their unit through (see shared/piloting.luau). Everything arriving is untrusted: only a
-- developer may pilot, only a unit of their own team that can be piloted, and only one nobody else is piloting. What
-- the pilot does is written to `pilots`, where movement, combat and orders read it; the manual weapon is fired from
-- `tick`, within the step, as an order would fire it.

local Players = game:GetService "Players"
local ReplicatedStorage = game:GetService "ReplicatedStorage"

local types = require(ReplicatedStorage.Shared.types)
local unit_defs = require(ReplicatedStorage.Shared.unit_defs)
local developers = require(ReplicatedStorage.Shared.developers)
local piloting = require(ReplicatedStorage.Shared.piloting)
local geometry = require(ReplicatedStorage.Shared.geometry)

local state = require(script.Parent.state)
local players = require(script.Parent.players)
local combat = require(script.Parent.combat)
local pilots = require(script.Parent.pilots)
local transport = require(script.Parent.transport)
local orders = require(script.Parent.orders)

type Entity = types.Entity
type EntityId = types.EntityId

local possess: RemoteEvent = ReplicatedStorage.Shared.Possess
local pilot_input: UnreliableRemoteEvent = ReplicatedStorage.Shared.PilotInput
local pilot_ability: RemoteEvent = ReplicatedStorage.Shared.PilotAbility
local pilot_say: RemoteEvent = ReplicatedStorage.Shared.PilotSay
local pilot_cargo: RemoteEvent = ReplicatedStorage.Shared.PilotCargo

-- What each piloted transport's pilot has asked it to do with its hold, "load" or "unload", done on the next step.
-- or, for something that can be carried, "call": have the nearest transport of its team that can lift it come and pick
-- it up.
export type CargoRequest = "load" | "unload" | "call"
local cargo_requests: { [EntityId]: CargoRequest } = {}

-- A pilot says no more than one thing in this many seconds.
local SAY_INTERVAL = 0.5
local said_at: { [Player]: number } = {}

-- The manual weapon each pilot has asked to fire, and where at, fired on the next step.
local abilities: { [EntityId]: Vector3 } = {}

local function finite(value: unknown): boolean
	return typeof(value) == "number" and value == value and math.abs(value) < math.huge
end

local function finite_vector(value: unknown): boolean
	if typeof(value) ~= "Vector3" then
		return false
	end
	return finite(value.X) and finite(value.Y) and finite(value.Z)
end

local function release(entity_id: EntityId)
	local pilot = pilots.get(entity_id)
	if pilot == nil then
		return
	end
	pilots.clear(entity_id)
	abilities[entity_id] = nil
	if pilot.player:GetAttribute(piloting.PLAYER_ATTRIBUTE) == entity_id then
		pilot.player:SetAttribute(piloting.PLAYER_ATTRIBUTE, nil)
	end
end

local function release_player(player: Player)
	local entity_id = pilots.piloted_by(player)
	if entity_id ~= nil then
		release(entity_id)
	end
end

-- `payload` is the id of the unit to take, or nil to let go of the one held.
local function on_possess(player: Player, payload: unknown)
	release_player(player)
	if typeof(payload) ~= "number" or developers.is_developer(player) == false then
		return
	end
	local entity = state.get(payload)
	local team = players.team_of(player)
	if entity == nil or team == nil or entity.team ~= team or entity.alive == false or entity.state ~= "active" then
		return
	end
	if piloting.can_pilot(unit_defs.of(entity)) == false or pilots.get(entity.id) ~= nil then
		return
	end
	-- whatever it was ordered to shoot at, it shoots at what it is aimed at now
	combat.set_forced_target(entity, nil)
	pilots.set(entity.id, {
		player = player,
		steer = Vector3.zero,
		facing = entity.facing,
		aim = nil,
		target_id = nil,
		firing = false,
		weapon = piloting.primary_weapon(unit_defs.of(entity)),
		lift = 0,
		height = nil,
		loadable = nil,
		can_unload = false,
		transporter = nil,
		rider = nil,
		called = nil,
		call_lost_at = nil,
		heard_at = os.clock(),
	})
	player:SetAttribute(piloting.PLAYER_ATTRIBUTE, entity.id)
end

local function on_input(player: Player, payload: unknown)
	local entity_id = pilots.piloted_by(player)
	if entity_id == nil or typeof(payload) ~= "table" then
		return
	end
	local pilot = pilots.get(entity_id) :: pilots.Pilot
	local data = payload :: any
	if finite_vector(data.steer) then
		local steer = geometry.flatten(data.steer)
		pilot.steer = if steer.Magnitude > 1 then steer.Unit else steer
	end
	if finite(data.facing) then
		pilot.facing = data.facing
	end
	pilot.aim = if finite_vector(data.aim) then data.aim else nil
	pilot.target_id = if typeof(data.target_id) == "number" then data.target_id else nil
	pilot.firing = data.firing == true
	pilot.lift = if finite(data.lift) then math.clamp(math.round(data.lift), -1, 1) else 0
	-- the weapon the trigger fires, which the pilot chooses among those it can
	local entity = state.get(entity_id)
	if entity ~= nil and finite(data.weapon) and piloting.can_select(unit_defs.of(entity), data.weapon) then
		pilot.weapon = data.weapon
	end
	pilot.heard_at = os.clock()
end

-- Asks for the manual weapon of `entity_id`, which is piloted, to be fired at `aim` on the next step.
local function request_ability(entity_id: EntityId, aim: Vector3)
	if pilots.get(entity_id) ~= nil then
		abilities[entity_id] = aim
	end
end

-- `payload` names one of `piloting.PHRASES`, which every client is told the pilot's unit says.
local function on_say(player: Player, payload: unknown)
	local entity_id = pilots.piloted_by(player)
	if entity_id == nil or typeof(payload) ~= "string" or piloting.PHRASES[payload] == nil then
		return
	end
	local now = os.clock()
	local last = said_at[player]
	if last ~= nil and now - last < SAY_INTERVAL then
		return
	end
	said_at[player] = now
	pilot_say:FireAllClients(entity_id, payload)
end

local function on_ability(player: Player, payload: unknown)
	local entity_id = pilots.piloted_by(player)
	if entity_id == nil or finite_vector(payload) == false then
		return
	end
	request_ability(entity_id, payload :: Vector3)
end

-- Asks for the transport `entity_id`, which is piloted, to pick up what its hook can reach, or set down what it
-- carries, on the next step.
local function request_cargo(entity_id: EntityId, request: CargoRequest)
	if pilots.get(entity_id) ~= nil then
		cargo_requests[entity_id] = request
	end
end

local function on_cargo(player: Player, payload: unknown)
	local entity_id = pilots.piloted_by(player)
	if entity_id == nil or (payload ~= "load" and payload ~= "unload" and payload ~= "call") then
		return
	end
	request_cargo(entity_id, payload :: CargoRequest)
end

-- The nearest thing a piloted `carrier` could pick up this moment: one it can carry, within its hook's reach. A pilot
-- need not hold still over it, as a transport given a load order has to (`transport.in_grasp`).
local function nearest_loadable(carrier: Entity): Entity?
	local best: Entity? = nil
	local best_distance = math.huge
	for _, other in state.all() do
		if transport.in_reach(carrier, other) == false or transport.can_load(carrier, other) == false then
			continue
		end
		local distance = (other.position - carrier.position).Magnitude
		if distance < best_distance then
			best = other
			best_distance = distance
		end
	end
	return best
end

-- The nearest transport of `cargo`'s own team anywhere on the map, finished and not piloted, that could take it aboard.
local function nearest_transporter(cargo: Entity): Entity?
	local best: Entity? = nil
	local best_distance = math.huge
	for _, other in state.all() do
		if other.team ~= cargo.team or unit_defs.of(other).transport == nil or pilots.get(other.id) ~= nil then
			continue
		end
		local distance = geometry.distance_2d(other.position, cargo.position)
		if distance < best_distance and transport.can_load(other, cargo) then
			best = other
			best_distance = distance
		end
	end
	return best
end

-- A new pilot of `carrier` for the player of `pilot`, who was piloting what it has just taken aboard.
-- A new pilot of `to` for the player of `pilot`, who was piloting something else: what `to` has just taken aboard, which
-- is `rider`, or what `to` itself has just been set down from.
local function handed_to(pilot: pilots.Pilot, to: Entity, rider: EntityId?): pilots.Pilot
	return {
		player = pilot.player,
		steer = Vector3.zero,
		facing = to.facing,
		aim = nil,
		target_id = nil,
		firing = false,
		weapon = piloting.primary_weapon(unit_defs.of(to)),
		lift = 0,
		height = nil,
		loadable = nil,
		can_unload = false,
		transporter = nil,
		rider = rider,
		called = nil,
		call_lost_at = nil,
		heard_at = pilot.heard_at,
	}
end

-- Lets go of every unit that is gone; stops the units of pilots not heard from lately; fires the manual weapons asked
-- for since the last step, each once, if it is ready; and for a transport, works out what it could pick up or whether it
-- could set down what it carries, and does whichever was asked for if it can. A pilot who leaves lets go as they do
-- (`init`).
local function tick()
	local now = os.clock()
	-- pilots moving to the transport that has just taken their unit aboard, done once nothing is iterating them
	-- and pilots going back to what they rode in on, once their transport has set it down
	local handovers: { { from: EntityId, to: Entity, rider: EntityId? } } = {}
	for entity_id, pilot in pilots.all() do
		local entity = state.get(entity_id)
		if entity == nil or entity.alive == false then
			-- taken aboard a transport of its own side that nobody pilots: its pilot takes that over
			local carrier_id = state.carrier_of(entity_id)
			local carrier = if carrier_id ~= nil then state.get(carrier_id) else nil
			local carried = state.find(entity_id)
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
		local aim = abilities[entity_id]
		if aim ~= nil then
			abilities[entity_id] = nil
			combat.manual_fire(entity, aim)
		end

		local request = cargo_requests[entity_id]
		cargo_requests[entity_id] = nil
		if unit_defs.of(entity).transport == nil then
			-- something that can be carried may call the nearest transport over to pick it up
			local transporter = if unit_defs.of(entity).weight_class ~= nil then nearest_transporter(entity) else nil
			if request == "call" and transporter ~= nil then
				orders.issue(transporter, { { kind = "load", target_id = entity.id } }, false, false)
				pilot.called = transporter.id
				pilot.call_lost_at = nil
			end
			-- the transport called, on its way: lost if it is destroyed, and forgotten if it is given something else to do
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
			continue
		end
		local carrying = #state.cargo_of(entity_id) > 0
		local loadable = if carrying then nil else nearest_loadable(entity)
		if request == "load" and loadable ~= nil then
			transport.load(entity, loadable)
			loadable = nil
			carrying = true
		elseif request == "unload" and carrying and transport.low_enough(entity) then
			local at = entity.position
			transport.unload(entity, Vector3.new(at.X, 0, at.Z))
			carrying = #state.cargo_of(entity_id) > 0
			-- what its pilot rode in on, set down, is theirs to pilot again
			local rider = if pilot.rider ~= nil then state.get(pilot.rider) else nil
			if rider ~= nil then
				table.insert(handovers, { from = entity_id, to = rider, rider = nil })
			end
		end
		pilot.loadable = if loadable ~= nil then loadable.id else nil
		pilot.can_unload = carrying and transport.low_enough(entity)
	end

	for _, handover in handovers do
		local pilot = pilots.get(handover.from)
		local to = handover.to
		if pilot == nil or pilots.get(to.id) ~= nil then
			continue
		end
		pilots.clear(handover.from)
		abilities[handover.from] = nil
		cargo_requests[handover.from] = nil
		combat.set_forced_target(to, nil)
		pilots.set(to.id, handed_to(pilot, to, handover.rider))
		pilot.player:SetAttribute(piloting.PLAYER_ATTRIBUTE, to.id)
	end
end

local function init()
	possess.OnServerEvent:Connect(on_possess)
	pilot_input.OnServerEvent:Connect(on_input)
	pilot_ability.OnServerEvent:Connect(on_ability)
	pilot_say.OnServerEvent:Connect(on_say)
	pilot_cargo.OnServerEvent:Connect(on_cargo)
	Players.PlayerRemoving:Connect(function(player: Player)
		release_player(player)
		said_at[player] = nil
	end)
end

return table.freeze({
	init = init,
	tick = tick,
	release = release,
	release_player = release_player,
	request_ability = request_ability,
	request_cargo = request_cargo,
})
