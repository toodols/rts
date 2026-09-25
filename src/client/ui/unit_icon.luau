-- A still picture of `def_name`'s own art, in `team`'s colours, drawn in a ViewportFrame from the meshes the client
-- already built for it (Client.art): the build menu's options and a factory's queue. A ViewportFrame only redraws when
-- what it holds changes, and nothing in it moves, so these cost nothing once they are up. Art still being built shows
-- once it is. A `locked` one is grey.
--
-- The camera stands as close as it can with every corner of the model's box in the frame, so a tall bot fits as well
-- as a flat building. `foot` is how much of the frame's height, at the bottom, is left clear for text over it.

local ReplicatedStorage = game:GetService "ReplicatedStorage"

local React = require(ReplicatedStorage.Packages.react)

local art = require(ReplicatedStorage.Client.art)

-- From ahead and to the right, a little from above, through a narrow lens so it is not distorted. What fills the
-- frame is `FIT` of it, leaving a margin.
local FOV = 30
local YAW = math.rad(35)
local PITCH = math.rad(28)
local FIT = 0.92
local DIRECTION = Vector3.new(math.sin(YAW) * math.cos(PITCH), math.sin(PITCH), math.cos(YAW) * math.cos(PITCH))
-- A locked picture: its colours drained to grey and darkened by this much.
local LOCKED_SHADE = 0.55

-- `color` as a grey of the same brightness, darkened.
local function drained(color: Color3): Color3
	local luminance = (0.299 * color.R + 0.587 * color.G + 0.114 * color.B) * LOCKED_SHADE
	return Color3.new(luminance, luminance, luminance)
end

-- Where the camera goes to see all of `model` in a frame `aspect` wide for its height, with the bottom `foot` of it
-- left clear. The camera looks along DIRECTION at the model's centre, then drops so the centre sits in the middle of
-- what is left; a corner `y` up and `z` toward the camera from the centre is then seen `(y + c*z*t) / ((d - z) * t)`
-- off that middle, `t` the lens's half-height at unit depth and `c` how far the middle is lifted, which gives the
-- least distance `d` each corner allows.
local function framing(model: Model, aspect: number, foot: number): CFrame
	local box, size = model:GetBoundingBox()
	local center = box.Position
	local look = CFrame.lookAt(center + DIRECTION, center)
	-- the picture's middle and half-height, as fractions of the frame's half-height
	local middle = foot
	local half = (1 - foot) * FIT
	local tan_vertical = math.tan(math.rad(FOV) / 2)
	local tan_horizontal = tan_vertical * aspect
	local distance = 0
	for _, x in { -1, 1 } do
		for _, y in { -1, 1 } do
			for _, z in { -1, 1 } do
				local corner = box:PointToWorldSpace(Vector3.new(x, y, z) * size / 2)
				local seen = look:VectorToObjectSpace(corner - center)
				-- a camera looks down its -Z, so how far the corner stands toward it is +Z
				local across = math.abs(seen.X) / (tan_horizontal * FIT)
				local up = math.abs(seen.Y + middle * seen.Z * tan_vertical) / (tan_vertical * half)
				distance = math.max(distance, seen.Z + math.max(across, up))
			end
		end
	end
	-- moving the camera down in its own frame moves the model up in the picture
	return CFrame.lookAt(center + DIRECTION * distance, center) * CFrame.new(0, -middle * distance * tan_vertical, 0)
end

local function UnitIcon(props: {
	def_name: string,
	team: Color3?,
	locked: boolean?,
	foot: number?,
	tag: string,
	LayoutOrder: number?,
})
	local frame_ref = React.useRef(nil :: ViewportFrame?)
	local built, set_built = React.useState(0)
	local foot = props.foot or 0

	React.useEffect(function(): (() -> ())?
		local viewport = frame_ref.current
		if viewport == nil then
			return nil
		end
		local model = art.ghost(props.def_name, props.team)
		if model == nil then
			if art.pending(props.def_name) then
				return art.when_built(props.def_name, function()
					set_built(function(count: number)
						return count + 1
					end)
				end)
			end
			return nil
		end
		if props.locked == true then
			for _, part in model:GetDescendants() do
				if part:IsA "BasePart" then
					part.Color = drained(part.Color)
					part.Material = Enum.Material.SmoothPlastic
				end
			end
		end

		local camera = Instance.new "Camera"
		camera.FieldOfView = FOV
		local function frame()
			local size = viewport.AbsoluteSize
			local aspect = if size.X > 0 and size.Y > 0 then size.X / size.Y else 1
			camera.CFrame = framing(model, aspect, foot)
		end
		frame()
		camera.Parent = viewport
		viewport.CurrentCamera = camera
		model.Parent = viewport
		-- the frame's size is only known once it is laid out
		local resized = viewport:GetPropertyChangedSignal("AbsoluteSize"):Connect(frame)

		return function()
			resized:Disconnect()
			model:Destroy()
			camera:Destroy()
		end
	end, { props.def_name, props.team, props.locked, foot, built } :: { any })

	return React.createElement("ViewportFrame", {
		[React.Tag] = if props.locked == true then `{props.tag} locked-icon` else props.tag,
		LayoutOrder = props.LayoutOrder,
		ref = frame_ref,
		-- lit from ahead and above, the same side it is seen from, with enough ambient that the far side reads
		Ambient = Color3.fromRGB(150, 150, 160),
		LightColor = Color3.fromRGB(255, 250, 240),
		LightDirection = Vector3.new(-0.5, -1, -0.7),
	})
end

return table.freeze({
	UnitIcon = UnitIcon,
})
