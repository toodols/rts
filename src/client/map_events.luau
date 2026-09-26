--!strict
-- The map on this client, built from what the server publishes (shared/map_state.luau), and built again whenever the
-- server replaces it. Everything drawn from the map subscribes to `on_rebuilt` as it starts (spot markers, the enemy
-- zone, the start boxes, the tutorial, the buildings as walls, the view), and is drawn again from the new map when it
-- is; handlers run in the order they subscribed, which is the order client_init starts things in.
--
-- The ground is never sent: it is built here from the map published, the way the server built it (shared/ground.luau).
-- It catches up the same way when the client joins and whenever the map is replaced: it builds the map it sees and
-- then asks for every edit made to that map so far, and is sent each edit as it is made after that. Edits labelled
-- with any other map are dropped.

local ReplicatedStorage = game:GetService "ReplicatedStorage"

local map_state = require(ReplicatedStorage.Shared.map_state)
local ground = require(ReplicatedStorage.Shared.ground)
local signal = require(ReplicatedStorage.Shared.signal)

local terrain_deformed: RemoteEvent = ReplicatedStorage.Shared.TerrainDeformed

local rebuilt = signal.new() :: signal.Signal<()>

-- Builds the map the server has published, if it is not the one built here already, and asks for every edit made to
-- it so far. Returns whether it built one.
local function build_published(): boolean
	local published = map_state.published()
	if published == nil or published.generation == map_state.generation() then
		return false
	end
	ground.rebuild(published)
	terrain_deformed:FireServer(published.generation)
	return true
end

-- Builds the map the server has published if it is a new one, and tells everything drawn from the old one.
local function follow()
	if build_published() then
		rebuilt.fire()
	end
end

-- Runs `handler` every time the map is built again, until the returned function is called.
local function on_rebuilt(handler: () -> ()): () -> ()
	return rebuilt.subscribe(handler)
end

-- Follows the edits made to the map and every map that replaces it, and yields until the first is built here, since
-- nothing can be drawn before there is ground to draw it on.
local function init()
	terrain_deformed.OnClientEvent:Connect(function(generation: number, changes: { number })
		if generation == map_state.generation() then
			ground.apply_edits(changes)
		end
	end)
	map_state.changed(follow)
	if build_published() or map_state.get() ~= nil then
		return
	end
	local waiting = coroutine.running()
	local stop_waiting: () -> ()
	stop_waiting = on_rebuilt(function()
		stop_waiting()
		task.spawn(waiting)
	end)
	coroutine.yield()
end

return table.freeze({
	init = init,
	on_rebuilt = on_rebuilt,
})
