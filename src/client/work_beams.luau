--!strict
-- A pulsing beam from every builder, reclaimer, repairer or raiser to what it is working on, visible to everyone, in
-- the colour of the order its work is (`work_kind`), redrawn every frame from a pool (world_fx).

local ReplicatedStorage = game:GetService "ReplicatedStorage"
local RunService = game:GetService "RunService"

local unit_defs = require(ReplicatedStorage.Shared.unit_defs)
local entity_attrs = require(ReplicatedStorage.Shared.entity_attrs)

local world = require(ReplicatedStorage.Client.world)
local world_fx = require(ReplicatedStorage.Client.world_fx)
local order_colors = require(ReplicatedStorage.Client.order_colors)

local BEAM_THICKNESS = 0.35
local BEAM_BASE_TRANSPARENCY = 0.3
local BEAM_PULSE = 0.2
local BEAM_PULSE_RATE = 14

local beam_pool = world_fx.pool(function(): Part
	return world_fx.part "WorkBeam"
end)

local function update()
	local pulse = BEAM_BASE_TRANSPARENCY + BEAM_PULSE * math.sin(os.clock() * BEAM_PULSE_RATE)
	for _, model in world.all() do
		local target_id = entity_attrs.number(model, "work_target")
		local target = if target_id ~= nil then world.get(target_id) else nil
		if target == nil then
			continue
		end

		-- from the top of the worker, so the beam clears its own body
		local from = world.position_of(model)
		local def = world.def_of(model)
		if def ~= nil then
			from += Vector3.new(0, unit_defs.collider_height(def) / 2, 0)
		end
		local to = world.position_of(target)
		local length = (to - from).Magnitude
		if length < 1e-3 then
			continue
		end

		local beam = world_fx.acquire(beam_pool)
		beam.Size = Vector3.new(BEAM_THICKNESS, BEAM_THICKNESS, length)
		beam.CFrame = CFrame.lookAt((from + to) / 2, to)
		beam.Color = order_colors.of(entity_attrs.text(model, "work_kind"))
		beam.Transparency = pulse
	end
	world_fx.release_rest(beam_pool)
end

local function init()
	RunService.RenderStepped:Connect(update)
end

return table.freeze({
	init = init,
})
