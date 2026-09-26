--!strict
-- The wrecks of units come back as scavengers. While the gamemode is on every one within settings.REVIVE_RANGE of a
-- standing beacon is raised (server/resurrection.luau's `put_work`, the progress the purple bar over it shows and a
-- Graverobber works on), at the rate that raises it in settings.REVIVE_SECONDS, and once it is up the unit stands in
-- its place on the scavengers' team, with the health a raised unit has and their difficulty's toughness. It costs them
-- nothing. Of what can be raised only units come back, never a commander or their boss; a wreck further out lies as it
-- is, keeping what progress it had, until a beacon goes up near it. With the server's ceiling of scavenger units out
-- it waits, done, for room; and whatever takes the wreck apart first, by reclaiming it, wins.

local ReplicatedStorage = game:GetService "ReplicatedStorage"
local ServerScriptService = game:GetService "ServerScriptService"

local types = require(ReplicatedStorage.Shared.types)
local teams = require(ReplicatedStorage.Shared.teams)
local unit_defs = require(ReplicatedStorage.Shared.unit_defs)
local geometry = require(ReplicatedStorage.Shared.geometry)

local state = require(ServerScriptService.Server.state)
local resurrection = require(ServerScriptService.Server.resurrection)

local settings = require(script.Parent.settings)
local progress = require(script.Parent.progress)

type Entity = types.Entity

-- What of the scavengers' is out this step (init.luau's `Tally`), as far as this needs it.
type Tally = { units: number }

-- Whether the wreck of `source` may come back as a scavenger.
local function comes_back(source: types.EntityDef): boolean
	return source.kind == "unit"
		and unit_defs.is_commander(source) == false
		and unit_defs.is_boss(source) == false
		and source.buildpower_cost > 0
end

-- Raises the wrecks lying near the beacons `near` by `delta` seconds' worth, `tally` counting what it raises.
local function run(delta: number, near: { Entity }, tally: Tally)
	if #near == 0 then
		return
	end
	local wrecks: { Entity } = {}
	for _, other in state.all() do
		if other.alive and other.kind == "wreck" then
			table.insert(wrecks, other)
		end
	end
	for _, wreck_entity in wrecks do
		local wreck = wreck_entity.wreck
		if wreck == nil or resurrection.raisable(wreck) == false then
			continue
		end
		local source = unit_defs.get(wreck.source_def_name)
		if comes_back(source) == false then
			continue
		end
		local in_range = false
		for _, beacon in near do
			if geometry.distance_2d(beacon.position, wreck_entity.position) <= settings.REVIVE_RANGE then
				in_range = true
				break
			end
		end
		if in_range == false then
			continue
		end
		local done = resurrection.put_work(wreck, source.buildpower_cost * delta / settings.REVIVE_SECONDS)
		if done and tally.units < settings.UNIT_CEILING then
			progress.toughen(resurrection.raise(wreck_entity, wreck, teams.SCAVENGER))
			tally.units += 1
		end
	end
end

return table.freeze({
	run = run,
})
