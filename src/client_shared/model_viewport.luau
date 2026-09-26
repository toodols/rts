--!strict
-- A picture of some art (art_models: a def's, or one of the HUD's own) in a ViewportFrame with a camera of its own,
-- framed to fit it: every picture of a model in both clients is one of these (unit_picture, art_icon). Art still being
-- built shows once it is; art that is missing, or failed, shows `fallback` instead.
--
-- The camera looks along the view's direction at the middle of the model's box and stands as close as it can with
-- every corner of the box in the frame, less a margin, so a tall bot fits as well as a flat building; `foot` of the
-- frame's height at the bottom is left clear for text over it. A `round` view keeps the sphere round the box in the
-- frame instead, which frames it the same whichever way it faces. With `spin` (radians a second) the camera circles
-- the model, so it turns slowly on the spot. A ViewportFrame only redraws when what it holds changes, so a still
-- picture costs nothing once it is up.
--
-- `paint` is given each part of the copy with how it was built, to recolour it (lit keys, a locked picture's greys),
-- and is run again whenever `paint_key` changes. `shake` makes the picture swing side to side and flash red, each time
-- it is bumped.

local ReplicatedStorage = game:GetService "ReplicatedStorage"
local RunService = game:GetService "RunService"

local React = require(ReplicatedStorage.Packages.react)

local art_models = require(ReplicatedStorage.ClientShared.art_models)

export type View = {
	-- the way the camera looks at the model from, toward its middle, before any spin
	direction: Vector3,
	-- how much of the frame the model fills
	fit: number,
	-- framed by the sphere round its box rather than by the box itself
	round: boolean?,
}

-- A part of a picture's model as it was built.
export type Original = { color: Color3, material: Enum.Material, cframe: CFrame }

export type Props = {
	name: string,
	-- for a def's art: its team parts in this side's colour
	team: Color3?,
	view: View,
	spin: number?,
	foot: number?,
	-- unlit: each part shows exactly its own colour (the flat "vector" icons)
	flat: boolean?,
	paint: ((parts: { [BasePart]: Original }) -> ())?,
	paint_key: string?,
	shake: number?,
	fallback: any?,
	tag: string,
	LayoutOrder: number?,
	Position: any?,
	AnchorPoint: Vector2?,
	-- what the picture is multiplied by, to darken it
	ImageColor3: Color3?,
	children: any?,
}

-- A narrow lens, so nothing is distorted.
local FOV = 30
-- Lit from ahead and above, the side it is seen from, with enough ambient that the far side reads.
local AMBIENT = Color3.fromRGB(150, 150, 160)
local LIGHT_COLOR = Color3.fromRGB(255, 250, 240)
local LIGHT_DIRECTION = Vector3.new(-0.5, -1, -0.7)
-- A shake: how long, how far the camera swings side to side (of the model's size), how many swings a second, and the
-- red the picture flashes.
local SHAKE_SECONDS = 0.45
local SHAKE_AMOUNT = 0.08
local SHAKE_RATE = 14
local FLASH_COLOR = Color3.fromRGB(255, 70, 60)
local WHITE = Color3.new(1, 1, 1)

-- Where the camera goes to see all of `model` from `direction` in a frame `aspect` wide for its height, `fit` of it
-- filled, with the bottom `foot` of it left clear, and how big the model is. The camera looks along `direction` at the
-- model's centre, then drops so the centre sits in the middle of what is left; a corner `y` up and `z` toward the camera
-- from the centre is then seen `(y + c*z*t) / ((d - z) * t)` off that middle, `t` the lens's half-height at unit depth
-- and `c` how far the middle is lifted, which gives the least distance `d` each corner allows. A `round` framing
-- keeps the sphere round the box inside the frame instead.
local function framing(
	model: Model,
	direction: Vector3,
	aspect: number,
	fit: number,
	foot: number,
	round: boolean
): (CFrame, number)
	local box, size = model:GetBoundingBox()
	local center = box.Position
	local look = CFrame.lookAt(center + direction, center)
	-- the picture's middle and half-height, as fractions of the frame's half-height
	local middle = foot
	local half = (1 - foot) * fit
	local tan_vertical = math.tan(math.rad(FOV) / 2)
	local tan_horizontal = tan_vertical * aspect
	local distance = 0
	if round then
		local reach = math.min(tan_vertical * half, tan_horizontal * fit)
		distance = (size.Magnitude / 2) / math.sin(math.atan(reach))
	else
		for _, x in { -1, 1 } do
			for _, y in { -1, 1 } do
				for _, z in { -1, 1 } do
					local corner = box:PointToWorldSpace(Vector3.new(x, y, z) * size / 2)
					local seen = look:VectorToObjectSpace(corner - center)
					-- a camera looks down its -Z, so how far the corner stands toward it is +Z
					local across = math.abs(seen.X) / (tan_horizontal * fit)
					local up = math.abs(seen.Y + middle * seen.Z * tan_vertical) / (tan_vertical * half)
					distance = math.max(distance, seen.Z + math.max(across, up))
				end
			end
		end
	end
	-- moving the camera down in its own frame moves the model up in the picture
	local frame = CFrame.lookAt(center + direction.Unit * distance, center)
		* CFrame.new(0, -middle * distance * tan_vertical, 0)
	return frame, size.Magnitude
end

local function ModelViewport(props: Props)
	local frame_ref = React.useRef(nil :: ViewportFrame?)
	local camera_ref = React.useRef(nil :: Camera?)
	-- where the camera rests, and how big the model is, for a shake to swing about
	local rest_ref = React.useRef(nil :: CFrame?)
	local scale_ref = React.useRef(1)
	local parts_ref = React.useRef({} :: { [BasePart]: Original })
	local built, set_built = React.useState(0)
	local status = art_models.status(props.name)
	local foot = props.foot or 0
	local spin = props.spin or 0
	local view = props.view

	local function paint()
		if props.paint ~= nil then
			props.paint(parts_ref.current)
		end
	end

	React.useEffect(function(): (() -> ())?
		local viewport = frame_ref.current
		if viewport == nil then
			return nil
		end
		local model = art_models.copy(props.name, props.team)
		if model == nil then
			if art_models.status(props.name) == "building" then
				return art_models.when_built(props.name, function()
					set_built(function(count: number): number
						return count + 1
					end)
				end)
			end
			-- it went missing or failed between the render and now
			if status == "building" then
				set_built(function(count: number): number
					return count + 1
				end)
			end
			return nil
		end

		local parts: { [BasePart]: Original } = {}
		for _, part in model:GetDescendants() do
			if part:IsA "BasePart" then
				parts[part] = { color = part.Color, material = part.Material, cframe = part.CFrame }
			end
		end
		parts_ref.current = parts

		local camera = Instance.new "Camera"
		camera.FieldOfView = FOV
		local yaw = 0
		local function frame()
			local size = viewport.AbsoluteSize
			local aspect = if size.X > 0 and size.Y > 0 then size.X / size.Y else 1
			local direction = CFrame.Angles(0, yaw, 0):VectorToWorldSpace(view.direction)
			local rest, scale = framing(model, direction, aspect, view.fit, foot, view.round == true)
			camera.CFrame = rest
			rest_ref.current = rest
			scale_ref.current = scale
		end
		frame()
		camera.Parent = viewport
		viewport.CurrentCamera = camera
		camera_ref.current = camera
		model.Parent = viewport
		paint()
		-- the frame's size is only known once it is laid out, and changes with the screen
		local resized = viewport:GetPropertyChangedSignal("AbsoluteSize"):Connect(frame)
		local spinning: RBXScriptConnection? = nil
		if spin ~= 0 then
			spinning = RunService.RenderStepped:Connect(function(dt: number)
				yaw += spin * dt
				frame()
			end)
		end

		return function()
			resized:Disconnect()
			if spinning ~= nil then
				spinning:Disconnect()
			end
			parts_ref.current = {}
			camera_ref.current = nil
			rest_ref.current = nil
			model:Destroy()
			camera:Destroy()
		end
	end, { props.name, props.team, view, spin, foot, built, status } :: { any })

	React.useEffect(paint, { props.paint_key, built } :: { any })

	React.useEffect(function(): (() -> ())?
		local viewport = frame_ref.current
		if props.shake == nil or props.shake == 0 or viewport == nil then
			return nil
		end
		local function settle()
			viewport.ImageColor3 = props.ImageColor3 or WHITE
			local camera = camera_ref.current
			local rest = rest_ref.current
			if camera ~= nil and rest ~= nil then
				camera.CFrame = rest
			end
		end
		local began = os.clock()
		local connection: RBXScriptConnection
		connection = RunService.RenderStepped:Connect(function()
			local elapsed = os.clock() - began
			if elapsed >= SHAKE_SECONDS then
				connection:Disconnect()
				settle()
				return
			end
			local fade = 1 - elapsed / SHAKE_SECONDS
			local camera = camera_ref.current
			local rest = rest_ref.current
			if camera ~= nil and rest ~= nil then
				local swing = math.sin(elapsed * SHAKE_RATE * math.pi * 2) * SHAKE_AMOUNT * scale_ref.current * fade
				camera.CFrame = rest * CFrame.new(swing, 0, 0)
			end
			viewport.ImageColor3 = FLASH_COLOR:Lerp(WHITE, 1 - fade)
		end)
		return function()
			if connection.Connected then
				connection:Disconnect()
				settle()
			end
		end
	end, { props.shake })

	if (status == "missing" or status == "failed") and props.fallback ~= nil then
		return props.fallback
	end

	return React.createElement("ViewportFrame", {
		[React.Tag] = props.tag,
		LayoutOrder = props.LayoutOrder,
		Position = props.Position,
		AnchorPoint = props.AnchorPoint,
		ImageColor3 = props.ImageColor3,
		ref = frame_ref,
		-- a flat picture has only ambient light, at full, so no face is shaded
		Ambient = if props.flat == true then WHITE else AMBIENT,
		LightColor = if props.flat == true then Color3.new(0, 0, 0) else LIGHT_COLOR,
		LightDirection = LIGHT_DIRECTION,
	}, props.children)
end

return table.freeze({
	ModelViewport = ModelViewport,
})
