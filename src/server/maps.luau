--!strict
-- Loading a map: the first a session plays, and every one that replaces it while the game runs, all the same way.
--
-- The server builds its half of a map - the heightmap and all that is worked out from it (shared/ground.luau), its
-- conditions and look, the rocks and trees lying about it (see scenery.luau), then the terrain - and publishes it for
-- the clients, who build the same from it (see shared/map_state.luau). A map may be played with a campaign mission on
-- it (server/missions), which is always played on its own map, whatever else is asked.
--
-- A load (`load`) is one pipeline, in order:
--
-- 1. the world is cleared: nothing that stood on the old ground is carried over to the new;
-- 2. every stage's `cleared` is told what the map is loaded with (the mission it is played with begins);
-- 3. the map is built;
-- 4. every team's stockpile goes back to how it started;
-- 5. every stage's `built` starts its part over on the new map (each player gets a new starting force at their start
--    on it, and so on).
--
-- The stages are handed in once, in the order they run in, by whoever starts the server (bootstrap.luau), so that what
-- runs when is read off one list. A map that fails to build leaves the world cleared under the stages that were told of
-- it, so the map there was before is loaded again the same way, and the game goes on from the start on it.

local ReplicatedStorage = game:GetService "ReplicatedStorage"

local teams = require(ReplicatedStorage.Shared.teams)
local map_presets = require(ReplicatedStorage.Shared.map_presets)
local map_state = require(ReplicatedStorage.Shared.map_state)
local ground = require(ReplicatedStorage.Shared.ground)
local environment = require(ReplicatedStorage.Shared.environment)
local atmosphere = require(ReplicatedStorage.Shared.atmosphere)
local campaign = require(ReplicatedStorage.Shared.campaign)

local state = require(script.Parent.state)
local deaths = require(script.Parent.deaths)
local terrain = require(script.Parent.terrain)
local lighting = require(script.Parent.lighting)
local deformation = require(script.Parent.deformation)
local wind = require(script.Parent.wind)
local scenery = require(script.Parent.scenery)

-- What map to play, and what on it.
export type Request = {
	-- a name from map_presets; a mission's own map is played instead, whatever this says
	preset: string?,
	-- what a procedural map is built from; nil for the seed the map has now
	seed: number?,
	-- a campaign mission to play on it, or nil for none, and whether in its hard mode
	mission: string?,
	hard: boolean?,
}

-- What has to start over on a new map, and when: `cleared` once the old world is gone, with what the new map is loaded
-- with, before it is built; `built` once it has been and every team's stockpile is back to how it started.
export type Stage = {
	cleared: ((Request) -> ())?,
	built: (() -> ())?,
}

local stages: { Stage }? = nil
local loading = false
-- What the map there is now was loaded with, from its seed, once one has been.
local loaded: Request? = nil

-- The map `request` asks for, or nil and why for one there is not: a mission's own map, or else the preset asked for.
local function preset_for(request: Request): (string?, string?)
	if request.mission ~= nil then
		local mission = campaign.get(request.mission)
		if mission == nil then
			return nil, `there is no mission "{request.mission}"`
		end
		if request.hard == true and mission.hard_mode == false then
			return nil, `{mission.label} has no hard mode`
		end
		return mission.preset, nil
	end
	local preset = request.preset
	if preset == nil or map_presets.presets[preset] == nil then
		return nil, `there is no map "{preset}"`
	end
	return preset, nil
end

-- Builds the map `request` asks for from `seed` and tells the clients to. Yields while it draws the terrain.
local function build(request: Request, seed: number)
	local preset = assert(preset_for(request))
	local built = table.freeze({ generation = map_state.generation() + 1, seed = seed, preset = preset })
	-- everything the simulation reads is in place before anything can yield, so no step ever sees half a map
	ground.rebuild(built)
	-- the map's own wind and tide, or the defaults for one that does not say
	local ok, reason = environment.apply(map_presets.presets[preset].conditions or {})
	if ok == false then
		warn(`map "{preset}" has conditions that cannot be: {reason}; keeping the defaults`)
		environment.apply({})
	end
	wind.refit()
	-- and how it looks, which each client lights its own view by
	atmosphere.apply(map_presets.presets[preset].atmosphere)
	deformation.discard_pending()
	map_state.publish(built)
	lighting.fit_fog()
	scenery.scatter()
	terrain.render()
end

-- Clears the world, and loads the map `request` asks for from `seed` through every stage. Returns whether it built,
-- and why not.
local function replace(request: Request, seed: number): (boolean, string?)
	local every = stages :: { Stage }
	for _, entity in state.all() do
		deaths.destroy(entity, "removed")
	end
	state.reap()
	for _, stage in every do
		if stage.cleared ~= nil then
			stage.cleared(request)
		end
	end
	local ok: boolean, err: any = pcall(build, request, seed)
	if ok == false then
		return false, tostring(err)
	end
	-- while the world was empty its stores were gone and the stockpiles were cut down to what the teams could hold
	-- without them
	for id in state.all_teams() do
		if teams.is_playable(id) then
			state.reset_team(id)
		end
	end
	for _, stage in every do
		if stage.built ~= nil then
			stage.built()
		end
	end
	loaded = { preset = request.preset, seed = seed, mission = request.mission, hard = request.hard }
	return true, nil
end

-- Loads the map `request` asks for, clearing the world and starting everything over on it. Yields while it draws the
-- terrain; a second load while one is under way is refused. Returns whether it loaded, and why not; one that failed
-- to build has the map there was loaded again in its place.
local function load(request: Request): (boolean, string?)
	assert(stages ~= nil, "the map stages are handed in (maps.init) before a map is loaded")
	local _, problem = preset_for(request)
	if problem ~= nil then
		return false, problem
	end
	if loading then
		return false, "a map is already loading"
	end
	loading = true
	local current = map_state.get()
	local seed = if request.seed ~= nil then request.seed elseif current ~= nil then current.seed else 0
	local previous = loaded
	local ok, err = replace(request, seed)
	if ok == false then
		warn(`the map could not be built: {err}`)
		-- the first map has nothing to go back to: the session cannot start without it
		assert(previous ~= nil, err)
		local restored, restore_err = replace(previous, previous.seed :: number)
		assert(restored, `the map there was could not be built again either: {restore_err}`)
	end
	loading = false
	return ok, err
end

-- Hands in the stages every map is loaded through, in the order they run in. Once, before the first map.
local function init(given: { Stage })
	assert(stages == nil, "the map stages are handed in once")
	stages = given
end

return table.freeze({
	init = init,
	load = load,
})
