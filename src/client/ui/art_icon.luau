-- One of the HUD's 3D pictures (Client.ui_art) in a ViewportFrame with a camera of its own, framed to fit it.
--
-- Parts of it can be lit by their art group (`lit`: a key held down, a mouse button clicked), pushed down by their
-- group (`pressed`, by `press_depth` studs: a key held down sinks the way a real one does), the whole of it greyed
-- (`muted`: a tick not done yet) or made to glow (`glow`: a tick once it is), and it can be made to shake and flash
-- red (`shake`: bumped each time it should, when what was pressed does not work). Only the bright parts of a piece
-- light or glow: a key's dark glyph stays dark on its lit cap, so it can still be read. Nothing in it moves but for a
-- shake, so it costs nothing once up.
-- While its art is missing it shows `fallback` as text instead.

local ReplicatedStorage = game:GetService "ReplicatedStorage"
local RunService = game:GetService "RunService"

local React = require(ReplicatedStorage.Packages.react)

local ui_art = require(ReplicatedStorage.Client.ui_art)

export type View = "above" | "front"

-- A narrow lens, so the keys are not distorted; what fills the frame is this much of it.
local FOV = 30
local FIT = 0.9
-- "above" looks at keys lying flat from ahead of them (+Z) and above, down this far; "front" looks straight at
-- something standing up and facing +Z.
local ABOVE_PITCH = math.rad(50)
local LIT_COLOR = Color3.fromRGB(96, 210, 242)
-- A part at least this bright is a face that lights; anything darker is a glyph or a rim, and keeps its colour.
local BRIGHT = 0.3
-- A muted picture's greys, as bright as the colours they replace by this much.
local MUTED_SHADE = 0.9
-- A shake: how long, how far the camera swings side to side (of the model's size), how many swings a second, and
-- the red the picture flashes.
local SHAKE_SECONDS = 0.45
local SHAKE_AMOUNT = 0.08
local SHAKE_RATE = 14
local FLASH_COLOR = Color3.fromRGB(255, 70, 60)
-- How far a pressed group sinks, in studs of the model, unless the picture says: most of a keycap's height.
local PRESS_DEPTH = 0.35

local function direction_of(view: View): Vector3
	if view == "front" then
		return Vector3.new(0, 0, 1)
	end
	return Vector3.new(0, math.sin(ABOVE_PITCH), math.cos(ABOVE_PITCH))
end

-- Where the camera goes to see all of `model` from `direction`, with a frame `aspect` wide for its height: as close as
-- it can be with every corner of the model's box inside the frame.
local function framing(model: Model, direction: Vector3, aspect: number): (CFrame, number)
	local box, size = model:GetBoundingBox()
	local center = box.Position
	local look = CFrame.lookAt(center + direction, center)
	local tan_vertical = math.tan(math.rad(FOV) / 2) * FIT
	local tan_horizontal = tan_vertical * aspect
	local distance = 0
	for _, x in { -1, 1 } do
		for _, y in { -1, 1 } do
			for _, z in { -1, 1 } do
				local corner = box:PointToWorldSpace(Vector3.new(x, y, z) * size / 2)
				local seen = look:VectorToObjectSpace(corner - center)
				-- depth in front of the camera is its distance less how far the corner stands toward it
				local needed = math.max(math.abs(seen.X) / tan_horizontal, math.abs(seen.Y) / tan_vertical) + seen.Z
				distance = math.max(distance, needed)
			end
		end
	end
	return CFrame.lookAt(center + direction.Unit * distance, center), size.Magnitude
end

-- A stable key for a set of lit groups, for an effect to depend on.
local function lit_key(lit: { [string]: boolean }?): string
	if lit == nil then
		return ""
	end
	local names = {}
	for name, on in lit do
		if on then
			table.insert(names, name)
		end
	end
	table.sort(names)
	return table.concat(names, ",")
end

type Original = { color: Color3, material: Enum.Material, bright: boolean, grey: Color3, cframe: CFrame }

local function luminance(color: Color3): number
	return 0.299 * color.R + 0.587 * color.G + 0.114 * color.B
end

local function ArtIcon(props: {
	name: string,
	view: View?,
	lit: { [string]: boolean }?,
	lit_color: Color3?,
	pressed: { [string]: boolean }?,
	press_depth: number?,
	muted: boolean?,
	glow: boolean?,
	shake: number?,
	fallback: string?,
	tag: string,
	LayoutOrder: number?,
	children: any?,
})
	local frame_ref = React.useRef(nil :: ViewportFrame?)
	local camera_ref = React.useRef(nil :: Camera?)
	-- where the camera rests, and how big the model is, for a shake to swing about
	local rest_ref = React.useRef(nil :: CFrame?)
	local scale_ref = React.useRef(1)
	local parts_ref = React.useRef({} :: { [BasePart]: Original })
	local built, set_built = React.useState(0)
	local missing, set_missing = React.useState(false)
	local view: View = props.view or "above"

	local key = lit_key(props.lit)
	local pressed_key = lit_key(props.pressed)
	local function paint()
		local lit = props.lit or {}
		local pressed = props.pressed or {}
		local depth = props.press_depth or PRESS_DEPTH
		for part, original in parts_ref.current do
			part.CFrame = if pressed[part.Name] == true
				then original.cframe - Vector3.new(0, depth, 0)
				else original.cframe
			if lit[part.Name] == true and original.bright then
				part.Color = props.lit_color or LIT_COLOR
				part.Material = Enum.Material.Neon
			elseif props.muted == true then
				part.Color = original.grey
				part.Material = original.material
			else
				part.Color = original.color
				part.Material = if props.glow == true and original.bright then Enum.Material.Neon else original.material
			end
		end
	end

	React.useEffect(function(): (() -> ())?
		local viewport = frame_ref.current
		if viewport == nil then
			return nil
		end
		local model = ui_art.copy(props.name)
		if model == nil then
			local status = ui_art.status(props.name)
			set_missing(status == "missing" or status == "failed")
			if status == "building" then
				return ui_art.when_built(props.name, function()
					set_built(function(count: number)
						return count + 1
					end)
				end)
			end
			return nil
		end
		set_missing(false)

		local parts: { [BasePart]: Original } = {}
		for _, part in model:GetDescendants() do
			if part:IsA "BasePart" then
				local bright = luminance(part.Color)
				local grey = math.clamp(bright * MUTED_SHADE, 0, 1)
				parts[part] = {
					color = part.Color,
					material = part.Material,
					bright = bright >= BRIGHT,
					grey = Color3.new(grey, grey, grey),
					cframe = part.CFrame,
				}
			end
		end
		parts_ref.current = parts

		local camera = Instance.new "Camera"
		camera.FieldOfView = FOV
		local function frame()
			local size = viewport.AbsoluteSize
			local aspect = if size.X > 0 and size.Y > 0 then size.X / size.Y else 1
			local rest, scale = framing(model, direction_of(view), aspect)
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

		return function()
			resized:Disconnect()
			parts_ref.current = {}
			camera_ref.current = nil
			rest_ref.current = nil
			model:Destroy()
			camera:Destroy()
		end
	end, { props.name, view, built } :: { any })

	React.useEffect(paint, { key, pressed_key, props.lit_color, props.muted, props.glow, built } :: { any })

	React.useEffect(function(): (() -> ())?
		local viewport = frame_ref.current
		if props.shake == nil or props.shake == 0 or viewport == nil then
			return nil
		end
		local function settle()
			viewport.ImageColor3 = Color3.new(1, 1, 1)
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
			viewport.ImageColor3 = FLASH_COLOR:Lerp(Color3.new(1, 1, 1), 1 - fade)
		end)
		return function()
			if connection.Connected then
				connection:Disconnect()
				settle()
			end
		end
	end, { props.shake })

	if missing then
		return React.createElement("TextLabel", {
			[React.Tag] = `{props.tag} art-fallback`,
			LayoutOrder = props.LayoutOrder,
			Text = props.fallback or "",
		}, props.children)
	end

	return React.createElement("ViewportFrame", {
		[React.Tag] = props.tag,
		LayoutOrder = props.LayoutOrder,
		ref = frame_ref,
		-- lit from ahead and above, the side it is seen from, with enough ambient that the keys' sides read
		Ambient = Color3.fromRGB(150, 150, 160),
		LightColor = Color3.fromRGB(255, 250, 240),
		LightDirection = Vector3.new(-0.3, -1, -0.6),
	}, props.children)
end

return table.freeze({
	ArtIcon = ArtIcon,
})
