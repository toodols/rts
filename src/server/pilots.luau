-- Who is piloting what (see shared/piloting.luau), and what each pilot is doing: which way they steer, which way they
-- look, what they aim at, whether they are firing, and what they have asked for on the next step. It keeps no more than
-- that, so that movement, weapons and orders can each read it without depending on one another; possession.luau takes
-- the pilots' word for it and writes it here.

local ReplicatedStorage = game:GetService "ReplicatedStorage"

local types = require(ReplicatedStorage.Shared.types)
local entity_attrs = require(ReplicatedStorage.Shared.entity_attrs)
local piloting = require(ReplicatedStorage.Shared.piloting)

local state = require(script.Parent.state)
local snapshot = require(script.Parent.snapshot)

type EntityId = types.EntityId
type Entity = types.Entity

-- What a pilot has asked their unit to do with a transport's hold, done on the next step: for a transport, "load" (pick
-- up what its hook can reach) or "unload" (set down what it carries); for something that can be carried, "call" (have
-- the nearest transport of its team that can lift it come and pick it up).
export type CargoRequest = "load" | "unload" | "call"

export type Pilot = {
	player: Player,
	-- which way to walk across the ground, as long as its top speed at the most; zero to stand still
	steer: Vector3,
	-- which way the unit faces, as `Entity.facing` has it
	facing: number,
	-- where the pilot aims, and the enemy they aim at, if the aim is on one
	aim: Vector3?,
	target_id: EntityId?,
	firing: boolean,
	-- which of its weapons the trigger fires, by index; nil for something with none it can
	weapon: number?,
	-- where the pilot has asked the manual weapon to be fired, and what they have asked of a hold, each done once on the
	-- next step (possession.tick)
	ability: Vector3?,
	cargo: CargoRequest?,
	-- for an aircraft that hovers: which way the pilot is taking it, 1 up, -1 down, 0 neither, and how high over the
	-- ground they have it, in studs; nil until they first change it, when it flies at its usual height
	lift: number,
	height: number?,
	-- for a transport: the nearest thing its hook can reach to pick up, and whether it is low enough to set what it
	-- carries down, as of the last step (possession.tick)
	loadable: EntityId?,
	can_unload: boolean,
	-- for something that can be carried: the transport that would come for it if it called one, as of the last step
	transporter: EntityId?,
	-- the transport it has called, while that is on its way, and when, by the game's clock (`state.now`), the last one it
	-- called was lost on the way
	called: EntityId?,
	call_lost_at: number?,
	-- for a transport its pilot came to by being picked up in something else they piloted: that, which they go back
	-- to piloting when the transport sets it down
	rider: EntityId?,
	-- when the pilot was last heard from, by the game's clock (`state.now`)
	heard_at: number,
}

local pilots: { [EntityId]: Pilot } = {}

-- A pilot of `entity` for `player`, as they take it over: standing still, facing the way it faces, its primary weapon
-- on the trigger, last heard from at `heard_at`.
local function new(player: Player, entity: Entity, heard_at: number): Pilot
	return {
		player = player,
		steer = Vector3.zero,
		facing = entity.facing,
		aim = nil,
		target_id = nil,
		firing = false,
		weapon = piloting.primary_weapon(entity.def),
		ability = nil,
		cargo = nil,
		lift = 0,
		height = nil,
		loadable = nil,
		can_unload = false,
		transporter = nil,
		rider = nil,
		called = nil,
		call_lost_at = nil,
		heard_at = heard_at,
	}
end

local function get(entity_id: EntityId): Pilot?
	return pilots[entity_id]
end

local function set(entity_id: EntityId, pilot: Pilot)
	pilots[entity_id] = pilot
end

local function clear(entity_id: EntityId)
	pilots[entity_id] = nil
end

-- The unit `player` pilots, if they pilot one.
local function piloted_by(player: Player): EntityId?
	for entity_id, pilot in pilots do
		if pilot.player == player then
			return entity_id
		end
	end
	return nil
end

-- Every pilot, by the entity they pilot, as they are now: the list is a copy, which pilots coming and going after do not
-- change.
local function all(): { [EntityId]: Pilot }
	return table.clone(pilots)
end

-- Publishes who pilots `entity` (`piloting.MODEL_ATTRIBUTE`, their user id), and for them what its pilot's HUD shows:
-- how long its manual weapon has left to reload, to a tenth of a second; for a transport, whether its pilot can pick
-- something up or set what it carries down right now; for something that can be carried, whether its pilot can call a
-- transport over to pick it up, and whether one it called is on its way ("coming") or was lost on the way a moment ago
-- ("lost"); and how far each of its weapons is through its reload, to a hundredth. All nil while nobody pilots it.
local function publish(entity: Entity, def: types.EntityDef, write: entity_attrs.Publish)
	local pilot = pilots[entity.id]
	write(piloting.MODEL_ATTRIBUTE, if pilot ~= nil then pilot.player.UserId else nil)
	write(
		piloting.COOLDOWN_ATTRIBUTE,
		if pilot ~= nil and def.manual_weapon ~= nil then math.ceil(entity.manual_reload_remaining * 10) / 10 else nil
	)
	local piloted_transport = pilot ~= nil and def.transport ~= nil
	write(piloting.LOAD_ATTRIBUTE, if piloted_transport and pilot ~= nil then pilot.loadable ~= nil else nil)
	write(piloting.UNLOAD_ATTRIBUTE, if piloted_transport and pilot ~= nil then pilot.can_unload else nil)
	write(
		piloting.CALL_ATTRIBUTE,
		if pilot ~= nil and def.transport == nil and def.weight_class ~= nil then pilot.transporter ~= nil else nil
	)
	local call_state: string? = nil
	if pilot ~= nil and pilot.called ~= nil then
		call_state = "coming"
	elseif
		pilot ~= nil
		and pilot.call_lost_at ~= nil
		and state.now() - pilot.call_lost_at < piloting.CALL_LOST_SECONDS
	then
		call_state = "lost"
	end
	write(piloting.CALL_STATE_ATTRIBUTE, call_state)
	if def.weapons ~= nil then
		for index, weapon in def.weapons do
			local charge: number? = nil
			if pilot ~= nil then
				local remaining = entity.weapon_reloads[index] or 0
				charge = if weapon.reload > 0
					then math.floor(math.clamp(1 - remaining / weapon.reload, 0, 1) * 100) / 100
					else 1
			end
			write(entity_attrs.charge_name(index), charge)
		end
	end
end

snapshot.keep("pilots", function()
	return { pilots = pilots }
end, function(saved)
	pilots = saved.pilots
end)

return table.freeze({
	new = new,
	get = get,
	set = set,
	clear = clear,
	piloted_by = piloted_by,
	all = all,
	publish = publish,
})
