-- Building the map, at the start and whenever it is replaced while the game runs.
--
-- The server builds its half of a map - the heightmap and all that is worked out from it, the rocks and trees lying
-- about it (see scenery.luau), then the terrain - and
-- publishes it for the clients, who build the same from it (see shared/map_state.luau). Replacing the map clears the
-- world first: nothing that stood on the old ground is carried over to the new, every team's stockpile goes back to
-- how it started, and each player is given a new starting force at their start on the new map.

local Players = game:GetService "Players"
local ReplicatedStorage = game:GetService "ReplicatedStorage"

local config = require(ReplicatedStorage.Shared.config)
local map_presets = require(ReplicatedStorage.Shared.map_presets)
local map_state = require(ReplicatedStorage.Shared.map_state)
local passability = require(ReplicatedStorage.Shared.passability)
local pathfinder = require(ReplicatedStorage.Shared.pathfinder)
local environment = require(ReplicatedStorage.Shared.environment)

local state = require(script.Parent.state)
local terrain = require(script.Parent.terrain)
local lighting = require(script.Parent.lighting)
local deformation = require(script.Parent.deformation)
local projectiles = require(script.Parent.projectiles)
local reaper = require(script.Parent.reaper)
local players = require(script.Parent.players)
local spawning = require(script.Parent.spawning)
local wind = require(script.Parent.wind)
local scenery = require(script.Parent.scenery)

local loading = false

-- Builds the map `preset` from `seed` and tells the clients to. Yields while it draws the terrain.
local function build(seed: number, preset: string)
	assert(map_presets.presets[preset] ~= nil, `there is no map preset "{preset}"`)
	local built = table.freeze({ generation = map_state.generation() + 1, seed = seed, preset = preset })
	-- everything the simulation reads is in place before anything can yield, so no step ever sees half a map
	map_state.apply(built)
	-- the map's own wind and tide, or the defaults for one that does not say
	local ok, reason = environment.apply(map_presets.presets[preset].conditions or {})
	if ok == false then
		warn(`map "{preset}" has conditions that cannot be: {reason}; keeping the defaults`)
		environment.apply({})
	end
	wind.refit()
	passability.initialize()
	pathfinder.reset()
	deformation.discard_pending()
	map_state.publish(built)
	lighting.fit_fog()
	scenery.scatter()
	terrain.render()
end

-- Replaces the map with `preset`, from `seed` or the seed the map has now, clearing the world and starting every
-- player over on it. Yields while it draws the terrain; a second load while one is under way is refused.
local function load(preset: string, seed: number?): (boolean, string?)
	if map_presets.presets[preset] == nil then
		return false, `there is no map "{preset}"`
	end
	if loading then
		return false, "a map is already loading"
	end
	loading = true

	state.flush()
	for _, entity in state.all() do
		state.mark_dead(entity)
	end
	reaper.reap()
	projectiles.clear()

	local current = map_state.get()
	local ok, err = pcall(build, if seed ~= nil then seed elseif current ~= nil then current.seed else 0, preset)
	if ok then
		for _, player in Players:GetPlayers() do
			local team_id = players.team_of(player)
			if team_id ~= nil then
				spawning.give_starting_force(team_id)
			end
		end
	end
	-- only now that the new commanders stand, since while the world was empty its stores were gone and the stockpile
	-- was cut down to what the teams could hold without them
	for id in state.all_teams() do
		if id ~= config.SCAVENGER_TEAM then
			state.reset_team(id)
		end
	end
	loading = false
	return ok, if ok then nil else tostring(err)
end

return table.freeze({
	build = build,
	load = load,
})
