--!strict
-- Where the client's time goes each frame, the client's side of server/profiler.luau: every system that runs every
-- frame is bound through `wrap`, which adds up the time it takes under its name. It always runs, since two os.clock()
-- calls a system a frame are nothing next to what a system does, so it is there the moment a frame is slow.
--
-- It is read through the BindableFunction `FrameProfile` it hangs under this module (from Studio, in a playtest's Client
-- datamodel: `ReplicatedStorage.Client.frame_profile.FrameProfile:Invoke()`), which returns the frames since it was last
-- read and each system's average milliseconds a frame, and starts counting afresh.

local RunService = game:GetService "RunService"

local totals: { [string]: number } = {}
local frames = 0
local began = os.clock()

-- `run`, timed under `label` every time it is called.
local function wrap<A...>(label: string, run: (A...) -> ()): (A...) -> ()
	return function(...: A...)
		local start = os.clock()
		run(...)
		totals[label] = (totals[label] or 0) + os.clock() - start
	end
end

local function read(): { frames: number, seconds: number, ms_per_frame: { [string]: number } }
	local per_frame: { [string]: number } = {}
	for label, total in totals do
		per_frame[label] = if frames > 0 then total * 1000 / frames else 0
	end
	local report = { frames = frames, seconds = os.clock() - began, ms_per_frame = per_frame }
	table.clear(totals)
	frames = 0
	began = os.clock()
	return report
end

local function init()
	RunService.PreRender:Connect(function()
		frames += 1
	end)
	local reader = Instance.new "BindableFunction"
	reader.Name = "FrameProfile"
	reader.OnInvoke = read
	reader.Parent = script
end

return table.freeze({
	init = init,
	wrap = wrap,
})
