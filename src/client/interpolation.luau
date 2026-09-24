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
-- interpolate at comes from how long the gaps between updates have been lately, so this keeps up
-- whether the server is ticking steadily or catching up in bursts. Lately, not the last gap alone:
-- updates land on whole frames, so a server ticking every 50ms reaches the client 33ms and then 66ms
-- apart, and pacing each by the one before would rush through a step and then stand still waiting,
-- a stutter that walking legs make plain.
--
-- It runs at render time, ahead of anything that draws on where a model is (art.luau), so nothing
-- reads a raw replicated pivot in the frame it lands.

local ReplicatedStorage = game:GetService "ReplicatedStorage"
local RunService = game:GetService "RunService"

local world = require(ReplicatedStorage.Client.world)

type State = {
	from: CFrame,
	to: CFrame,
	rendered: CFrame,
	started_at: number,
	duration: number,
	-- the gap between updates lately, a running average
	gap: number,
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
-- The gap a model is assumed to update at before it has shown one; how much of each new gap goes into
-- the running average; and the longest gap that counts toward it at all, beyond which the model was
-- standing still rather than being updated slowly.
local FIRST_GAP = 1 / 20
local GAP_SMOOTHING = 0.25
local MAX_GAP = 0.25
-- Each step is played a little slower than the gaps have been, so that one landing a frame late
-- finds the model still moving toward the last, not stopped on it.
local SLACK = 1.15

-- When the last frame was drawn. A step that lands is played from then, not from now: it has been
-- on its way for that frame already, and starting it from nothing would hold the model still for the
-- frame it lands in, one frame in every update.
local last_frame_at: number? = nil

local function close_enough(a: CFrame, b: CFrame): boolean
	return (a.Position - b.Position).Magnitude < SAME_EPSILON and (a.LookVector - b.LookVector).Magnitude < SAME_EPSILON
end

local function forget(child: Instance)
	states[child] = nil
end

local function step(_dt: number)
	local now = os.clock()
	local previous = last_frame_at or now
	last_frame_at = now
	for _, model in world.all() do
		local actual = model:GetPivot()
		local state = states[model]
		if state == nil then
			states[model] = {
				from = actual,
				to = actual,
				rendered = actual,
				started_at = now,
				duration = MIN_DURATION,
				gap = FIRST_GAP,
			}
			continue
		end

		if close_enough(actual, state.rendered) == false then
			-- a fresh server update landed: play it over as long as updates have lately been apart, so
			-- this adapts to the server's real update rate rather than assuming a fixed one
			local gap = previous - state.started_at
			if gap <= MAX_GAP then
				state.gap += (gap - state.gap) * GAP_SMOOTHING
			end
			state.from = state.rendered
			state.to = actual
			state.started_at = previous
			state.duration = math.clamp(state.gap * SLACK, MIN_DURATION, MAX_DURATION)
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
	-- first of everything bound to render, see art.luau
	RunService:BindToRenderStep("interpolation", Enum.RenderPriority.First.Value, step)
end

return table.freeze({
	init = init,
})
