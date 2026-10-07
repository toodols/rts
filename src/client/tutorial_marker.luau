-- The tutorial's marker on the field: where the move step asks the commander to be sent, or what a step points at. A
-- ring on the ground as wide as a right click may miss it by, laid over the hills the way order paths are, a pulsing pad
-- in the middle, and a beam of light standing up from it so it can be found from across the screen. In the colour of a
-- move order.

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

-- Shows the marker at `where()`, in world (x, z), with its ring `radius` out, moving it along whenever that moves and
-- leaving it out while it is nil. Returns a function that takes it away.
local function mark(where: () -> Vector2?, radius: number): () -> ()
	local model = Instance.new "Model"
	model.Name = "TutorialMarker"

	-- the pad lies flat, and the beam, a cylinder too, stands up (a lying cylinder's length is its size's X)
	local pad = make_part("Pad", model)
	pad.Shape = Enum.PartType.Cylinder
	pad.Size = Vector3.new(PAD_HEIGHT, PAD_DIAMETER, PAD_DIAMETER)

	local beam = make_part("Beam", model)
	beam.Shape = Enum.PartType.Cylinder
	beam.Size = Vector3.new(BEAM_HEIGHT, BEAM_DIAMETER, BEAM_DIAMETER)
	beam.Transparency = BEAM_TRANSPARENCY

	-- the ring's dashes are laid again over the ground wherever it goes, the ones it already has reused
	local ring: { Part } = {}
	local placed: Vector2? = nil
	local function place(at: Vector2)
		placed = at
		local ground = heightmap.ground_position(at.X, at.Y)
		local points = world_fx.arc_points(ground, function(_: Vector3): number
			return radius
		end, 0, math.pi * 2, RING_SEGMENTS, "surface")
		local used = 0
		world_fx.lay_line(points, RING_STYLE, function(): Part
			used += 1
			local dash = ring[used]
			if dash == nil then
				dash = make_part("Ring", model)
				dash.Transparency = RING_TRANSPARENCY
				ring[used] = dash
			end
			return dash
		end)
		for index = #ring, used + 1, -1 do
			ring[index]:Destroy()
			ring[index] = nil
		end
		pad.CFrame = world_fx.lying_flat(ground + Vector3.new(0, RING_STYLE.lift, 0))
		beam.CFrame = world_fx.lying_flat(ground + Vector3.new(0, BEAM_HEIGHT / 2, 0))
	end

	-- Moves it to `where()`, or leaves it out; whether it is out on the field.
	local function keep_up(): boolean
		local at = where()
		if at ~= nil and at ~= placed then
			place(at)
		end
		local parent = if at ~= nil then world_fx.folder() else nil
		if model.Parent ~= parent then
			model.Parent = parent
		end
		return at ~= nil
	end

	keep_up()

	local began = os.clock()
	local connection = RunService.RenderStepped:Connect(function()
		if keep_up() == false then
			return
		end
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

-- Shows the marker at `at`, in world (x, z), with its ring `radius` out. Returns a function that takes it away.
local function show(at: Vector2, radius: number): () -> ()
	return mark(function(): Vector2?
		return at
	end, radius)
end

-- Shows the marker round `entity`, an entity model, with its ring `radius` out, going wherever it goes and out of sight
-- while it is off the field. Returns a function that takes it away.
local function follow(entity: Model, radius: number): () -> ()
	return mark(function(): Vector2?
		if entity.Parent == nil then
			return nil
		end
		local position = entity:GetPivot().Position
		return Vector2.new(position.X, position.Z)
	end, radius)
end

return table.freeze({
	show = show,
	follow = follow,
})
