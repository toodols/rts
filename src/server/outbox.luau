--!strict
-- What a step tells the world outside the simulation: the clients, and the voxels that draw the ground. The phases of
-- a step only say what happened (`shattered`, `ground_edited`), as it happens; it is all delivered in one go once the
-- step is over (`deliver`, which simulation.step calls last), so that nothing in the simulation touches a remote or an
-- instance, and a barrage of shells in a step is one rewrite of the ground and one message. Shots, which the clients
-- fly themselves, go out as they are fired, through their own gateway (server/shot_feed.luau).

local ReplicatedStorage = game:GetService "ReplicatedStorage"

local map_state = require(ReplicatedStorage.Shared.map_state)

local terrain = require(script.Parent.terrain)

-- Something finished that went without leaving a wreck, for the clients to fling its pieces apart (client/debris.luau),
-- harder the more violent its death.
export type Shattered = {
	id: number,
	severity: number,
	velocity: Vector3,
}

local unit_shattered: RemoteEvent = ReplicatedStorage.Shared.UnitShattered
local terrain_deformed: RemoteEvent = ReplicatedStorage.Shared.TerrainDeformed

local shattered_list: { Shattered } = {}
-- The ground edited this step, as heightmap keeps edits (`{ index, height, ... }`), and the cells whose surface they
-- moved, first to last each way.
local ground_changes: { number } = {}
local first_x, first_z, last_x, last_z = math.huge, math.huge, -math.huge, -math.huge

local function shattered(event: Shattered)
	table.insert(shattered_list, event)
end

-- The ground has been edited: `changes` over the cells from (from_x, from_z) to (to_x, to_z).
local function ground_edited(changes: { number }, from_x: number, from_z: number, to_x: number, to_z: number)
	table.move(changes, 1, #changes, #ground_changes + 1, ground_changes)
	first_x, first_z = math.min(first_x, from_x), math.min(first_z, from_z)
	last_x, last_z = math.max(last_x, to_x), math.max(last_z, to_z)
end

-- Delivers everything the step said: the pieces of what shattered, and the edited ground, drawn and sent labelled with
-- the map it was made to (shared/map_state.luau), so that a client that has since built another drops it.
local function deliver()
	if #shattered_list > 0 then
		for _, event in shattered_list do
			unit_shattered:FireAllClients(event)
		end
		table.clear(shattered_list)
	end
	if #ground_changes > 0 then
		terrain.rewrite(first_x, first_z, last_x, last_z)
		terrain_deformed:FireAllClients(map_state.generation(), ground_changes)
		ground_changes = {}
		first_x, first_z, last_x, last_z = math.huge, math.huge, -math.huge, -math.huge
	end
end

return table.freeze({
	shattered = shattered,
	ground_edited = ground_edited,
	deliver = deliver,
})
