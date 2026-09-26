-- The tutorial's marker on the field: where the move step asks the commander to be sent. A ring on the ground as wide
-- as a right click may miss it by, laid over the hills the way order paths are, a pulsing pad in the middle, and a
-- beam of light standing up from it so it can be found from across the screen. In the colour of a move order.

local ReplicatedStorage = game:GetService "ReplicatedStorage"
local RunService = game:GetService "RunService"

local heightmap = require(ReplicatedStorage.Shared.heightmap)

local world_fx = require(ReplicatedStorage.Client.world_fx)

local palette = require(ReplicatedStorage.ClientShared.palette)

local COLOR = palette.buildpower
local RING_SEGMENTS = 40
local RING_STYLE: world_fx.LineStyle = table.freeze({ lift = 0.4, thickness = 0.35, closed_corners = true })
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

local function make_part(name: string, parent: Instance): Part
	local part = world_fx.part(name)
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
	local points = world_fx.arc_points(ground, function(_: Vector3): number
		return radius
	end, 0, math.pi * 2, RING_SEGMENTS)
	world_fx.lay_line(points, RING_STYLE, function(): Part
		local dash = make_part("Ring", model)
		dash.Transparency = RING_TRANSPARENCY
		table.insert(ring, dash)
		return dash
	end)

	-- the pad lies flat, and the beam, a cylinder too, stands up (a lying cylinder's length is its size's X)
	local pad = make_part("Pad", model)
	pad.Shape = Enum.PartType.Cylinder
	pad.Size = Vector3.new(PAD_HEIGHT, PAD_DIAMETER, PAD_DIAMETER)
	pad.CFrame = world_fx.lying_flat(ground + Vector3.new(0, RING_STYLE.lift, 0))

	local beam = make_part("Beam", model)
	beam.Shape = Enum.PartType.Cylinder
	beam.Size = Vector3.new(BEAM_HEIGHT, BEAM_DIAMETER, BEAM_DIAMETER)
	beam.CFrame = world_fx.lying_flat(ground + Vector3.new(0, BEAM_HEIGHT / 2, 0))
	beam.Transparency = BEAM_TRANSPARENCY

	model.Parent = world_fx.folder()

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
