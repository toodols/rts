-- Smooths every entity model's motion between replicated updates, instead of the camera just
-- snapping to wherever the server put it. The server calls :PivotTo on each model itself, once a
-- server tick, and lets Roblox replicate the change for free (see instances.luau); at 30 Hz, or in
-- bursts when the server catches up several ticks in one frame under load, that reads as a jump on
-- the client rather than motion, so this renders the gap between the last two observed pivots
-- instead of the raw replicated one.
--
-- No server changes and no per-model signal wiring: each frame this reads back whatever pivot the
-- model is actually showing right now. If that differs from what was rendered last frame by more
-- than replication's own floating-point noise, a fresh server update just landed, so it becomes the
-- new target and interpolation restarts from wherever rendering had gotten to - never from the old
-- target, so a fast update never leaves a visible snap back before smoothing resumes. The pace to
-- interpolate at comes from how long the last gap between updates actually was, so this keeps up
-- whether the server is ticking steadily or catching up in bursts.

local ReplicatedStorage = game:GetService "ReplicatedStorage"
local RunService = game:GetService "RunService"

local world = require(ReplicatedStorage.Client.world)

type State = {
	from: CFrame,
	to: CFrame,
	rendered: CFrame,
	started_at: number,
	duration: number,
}

local states: { [Instance]: State } = {}

-- Below this, two pivots count as the same one: far smaller than any real movement, but comfortably
-- above the rounding noise replication's own compression introduces.
local SAME_EPSILON = 1e-3
-- However long the render is stretched over, it is clamped to this range: short bursts of very fast
-- updates would otherwise flicker, and a stall (or the game being paused) would otherwise freeze
-- interpolation forever waiting on a duration that never arrives.
local MIN_DURATION = 1 / 60
local MAX_DURATION = 0.5

local function close_enough(a: CFrame, b: CFrame): boolean
	return (a.Position - b.Position).Magnitude < SAME_EPSILON and (a.LookVector - b.LookVector).Magnitude < SAME_EPSILON
end

local function forget(child: Instance)
	states[child] = nil
end

local function step()
	local now = os.clock()
	for _, model in world.all() do
		local actual = model:GetPivot()
		local state = states[model]
		if state == nil then
			states[model] = { from = actual, to = actual, rendered = actual, started_at = now, duration = MIN_DURATION }
			continue
		end

		if close_enough(actual, state.rendered) == false then
			-- a fresh server update landed: interpolate the gap since the last one, at whatever pace
			-- the last gap between updates took, so this adapts to the server's real update rate
			-- rather than assuming a fixed one
			local gap = math.clamp(now - state.started_at, MIN_DURATION, MAX_DURATION)
			state.from = state.rendered
			state.to = actual
			state.started_at = now
			state.duration = gap
		end

		local alpha = math.clamp((now - state.started_at) / state.duration, 0, 1)
		local rendered = state.from:Lerp(state.to, alpha)
		if rendered ~= state.rendered then
			model:PivotTo(rendered)
		end
		state.rendered = rendered
	end
end

local function init()
	world.container().ChildRemoved:Connect(forget)
	RunService.Heartbeat:Connect(step)
end

return table.freeze({
	init = init,
})
