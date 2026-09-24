-- The tutorial's marker on the field: where the move step asks the commander to be sent. A ring on the ground as wide
-- as a right click may miss it by, laid over the hills the way order paths are, a pulsing pad in the middle, and a
-- beam of light standing up from it so it can be found from across the screen. In the colour of a move order.

local ReplicatedStorage = game:GetService "ReplicatedStorage"
local RunService = game:GetService "RunService"
local Workspace = game:GetService "Workspace"

local heightmap = require(ReplicatedStorage.Shared.heightmap)

local COLOR = Color3.fromRGB(126, 240, 154)
local RING_SEGMENTS = 40
local RING_THICKNESS = 0.35
local RING_LIFT = 0.4
local PAD_DIAMETER = 5
local PAD_HEIGHT = 0.2
local BEAM_HEIGHT = 40
local BEAM_DIAMETER = 1.2
-- how often it pulses, a second, and how far the pad swells and the ring fades over one
local PULSE_RATE = 1.2
local PAD_SWELL = 0.35
local RING_TRANSPARENCY = 0.25
local RING_FADE = 0.35
local BEAM_TRANSPARENCY = 0.55
local BEAM_FADE = 0.25

local function effects_folder(): Instance
	local folder = Workspace:FindFirstChild "Effects"
	if folder ~= nil then
		return folder
	end
	return Workspace
end

local function make_part(name: string, parent: Instance): Part
	local part = Instance.new "Part"
	part.Name = name
	part.Anchored = true
	part.CanCollide = false
	part.CanQuery = false
	part.CanTouch = false
	part.CastShadow = false
	part.Material = Enum.Material.Neon
	part.Color = COLOR
	part.Parent = parent
	return part
end

-- Shows the marker at `at`, in world (x, z), with its ring `radius` out. Returns a function that takes it away.
local function show(at: Vector2, radius: number): () -> ()
	local model = Instance.new "Model"
	model.Name = "TutorialMarker"
	local ground = heightmap.ground_position(at.X, at.Y)

	local ring: { Part } = {}
	local previous: Vector3? = nil
	for step = 0, RING_SEGMENTS do
		local angle = step / RING_SEGMENTS * math.pi * 2
		local point = heightmap.ground_position(at.X + math.cos(angle) * radius, at.Y + math.sin(angle) * radius)
			+ Vector3.new(0, RING_LIFT, 0)
		if previous ~= nil then
			local dash = make_part("Ring", model)
			local length = (point - previous).Magnitude
			dash.Size = Vector3.new(RING_THICKNESS, RING_THICKNESS, length + RING_THICKNESS)
			dash.CFrame = CFrame.lookAt((previous + point) / 2, point)
			dash.Transparency = RING_TRANSPARENCY
			table.insert(ring, dash)
		end
		previous = point
	end

	-- a Cylinder part's flat faces point along X, so the pad is rolled to lie flat and the beam to stand up
	local pad = make_part("Pad", model)
	pad.Shape = Enum.PartType.Cylinder
	pad.Size = Vector3.new(PAD_HEIGHT, PAD_DIAMETER, PAD_DIAMETER)
	pad.CFrame = CFrame.new(ground + Vector3.new(0, RING_LIFT, 0)) * CFrame.Angles(0, 0, math.pi / 2)

	local beam = make_part("Beam", model)
	beam.Shape = Enum.PartType.Cylinder
	beam.Size = Vector3.new(BEAM_HEIGHT, BEAM_DIAMETER, BEAM_DIAMETER)
	beam.CFrame = CFrame.new(ground + Vector3.new(0, BEAM_HEIGHT / 2, 0)) * CFrame.Angles(0, 0, math.pi / 2)
	beam.Transparency = BEAM_TRANSPARENCY

	model.Parent = effects_folder()

	local began = os.clock()
	local connection = RunService.RenderStepped:Connect(function()
		-- 0 to 1 and back, once a pulse
		local wave = (1 - math.cos((os.clock() - began) * PULSE_RATE * math.pi * 2)) / 2
		local diameter = PAD_DIAMETER * (1 + PAD_SWELL * wave)
		pad.Size = Vector3.new(PAD_HEIGHT, diameter, diameter)
		pad.Transparency = 0.2 + 0.4 * wave
		for _, dash in ring do
			dash.Transparency = RING_TRANSPARENCY + RING_FADE * wave
		end
		beam.Transparency = BEAM_TRANSPARENCY + BEAM_FADE * wave
	end)

	return function()
		connection:Disconnect()
		model:Destroy()
	end
end

return table.freeze({
	show = show,
})
