--!strict
-- Escorts: every builder out beyond the base gets the profile's escorts_per_builder of the army waiting at home to
-- guard it, and lets them go once it is back or done. Only the profile's escorted_builders builders at once have any,
-- if it says, and none after its escort_seconds, if it says (BARb's behaviour.json "defence"."escort").

local ReplicatedStorage = game:GetService "ReplicatedStorage"
local ServerScriptService = game:GetService "ServerScriptService"

local types = require(ReplicatedStorage.Shared.types)
local unit_defs = require(ReplicatedStorage.Shared.unit_defs)
local geometry = require(ReplicatedStorage.Shared.geometry)

local state = require(ServerScriptService.Server.state)
local orders = require(ServerScriptService.Server.orders)

local brains = require(script.Parent.brains)
local assignments = require(script.Parent.assignments)
local censuses = require(script.Parent.census)

type Entity = types.Entity
type EntityId = types.EntityId
type Brain = brains.Brain
type Census = censuses.Census

local function run_escorts(brain: Brain, census: Census)
	local guarding: { [EntityId]: number } = {}
	for _, escort_id in assignments.each(brain, "escort") do
		local escort = state.get(escort_id)
		local assignment = assignments.get(brain, escort_id)
		local builder_id = if assignment ~= nil and assignment.job == "escort" then assignment.builder else nil
		if escort == nil then
			assignments.release(brain, escort_id)
			continue
		end
		if builder_id == nil or state.get(builder_id) == nil or assignments.job_of(brain, builder_id) ~= "expand" then
			assignments.release(brain, escort_id)
			orders.issue(escort, {}, false, false)
			continue
		end
		guarding[builder_id] = (guarding[builder_id] or 0) + 1
	end
	-- only what is waiting at home is taken; an army on its way somewhere keeps going
	if brain.army.wave ~= nil or brain.army.defending ~= nil then
		return
	end
	-- none after the profile's escort_seconds, and only its escorted_builders builders at once have any
	local profile = brain.profile
	local over_at = profile.escort_seconds
	local wanted = if over_at == nil or brains.now() - brain.started < over_at then profile.escorts_per_builder else 0
	local slots = profile.escorted_builders or math.huge
	for _ in guarding do
		slots -= 1
	end
	for _, builder_id in assignments.each(brain, "expand") do
		local builder = state.get(builder_id)
		if builder == nil then
			assignments.release(brain, builder_id)
			continue
		end
		local have = guarding[builder_id] or 0
		if have == 0 then
			if slots <= 0 then
				continue
			end
			slots -= 1
		end
		while have < wanted do
			local best: Entity? = nil
			local best_distance = math.huge
			for _, unit in census.army do
				if assignments.is_free(brain, unit) == false or unit_defs.is_air(unit.def) then
					continue
				end
				local distance = geometry.distance_2d(unit.position, builder.position)
				if distance < best_distance then
					best = unit
					best_distance = distance
				end
			end
			if best == nil then
				break
			end
			orders.issue(best, { { kind = "guard", position = nil, target_id = builder.id } }, false, false)
			assignments.assign(brain, best.id, { job = "escort", builder = builder.id })
			have += 1
		end
	end
end

return table.freeze({
	run_escorts = run_escorts,
})
