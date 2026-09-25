-- Who is piloting what (see shared/piloting.luau), and what each pilot is doing: which way they steer, which way they
-- look, what they aim at and whether they are firing. It keeps no more than that, so that movement, combat and orders
-- can each read it without depending on one another; possession.luau takes the pilots' word for it and writes it here.

local ReplicatedStorage = game:GetService "ReplicatedStorage"

local types = require(ReplicatedStorage.Shared.types)

type EntityId = types.EntityId

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
	-- the transport it has called, while that is on its way, and when (`os.clock()`) the last one it called was lost
	-- on the way
	called: EntityId?,
	call_lost_at: number?,
	-- for a transport its pilot came to by being picked up in something else they piloted: that, which they go back
	-- to piloting when the transport sets it down
	rider: EntityId?,
	-- `os.clock()` when the pilot was last heard from
	heard_at: number,
}

local pilots: { [EntityId]: Pilot } = {}

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

local function all(): { [EntityId]: Pilot }
	return pilots
end

return table.freeze({
	get = get,
	set = set,
	clear = clear,
	piloted_by = piloted_by,
	all = all,
})
