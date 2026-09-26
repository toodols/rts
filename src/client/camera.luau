-- A fixed-pitch RTS camera. It looks at a focus point on the ground, pans with the arrow keys or by
-- dragging with the middle mouse button, turns around the focus by dragging with the middle mouse
-- button while alt is held, and zooms by raising and lowering itself rather than changing angle. The
-- letter keys are left free for commands. Panning is told as it happens (Client.events).

local ReplicatedStorage = game:GetService "ReplicatedStorage"
local RunService = game:GetService "RunService"
local UserInputService = game:GetService "UserInputService"
local Workspace = game:GetService "Workspace"

local heightmap = require(ReplicatedStorage.Shared.heightmap)

local events = require(ReplicatedStorage.Client.events)
local modifiers = require(ReplicatedStorage.Client.modifiers)
local input_router = require(ReplicatedStorage.Client.input_router)

local RENDER_STEP = "rts_camera"
-- How long a glide (`glide_to`) takes, in seconds.
local GLIDE_SECONDS = 0.8
-- Units are only a few studs across, so the default altitude is low enough to actually read them.
local CAMERA_HEIGHT = 65
local CAMERA_PITCH = -55
local CAMERA_PAN_SPEED = 120
local CAMERA_MIN_HEIGHT = 22
local CAMERA_MAX_HEIGHT = 420
local CAMERA_ZOOM_STEP = 14
-- Radians the view turns per pixel of cursor movement while rotating with alt and the middle button.
local CAMERA_ROTATE_SPEED = 0.008

local focus = Vector3.zero
local height = CAMERA_HEIGHT
-- How far the view has turned about the vertical, in radians. At zero the camera sits south of the
-- focus looking north.
local yaw = 0

local KEY_DIRECTIONS: { [Enum.KeyCode]: Vector2 } = {
	[Enum.KeyCode.Up] = Vector2.new(0, -1),
	[Enum.KeyCode.Down] = Vector2.new(0, 1),
	[Enum.KeyCode.Left] = Vector2.new(-1, 0),
	[Enum.KeyCode.Right] = Vector2.new(1, 0),
}

local held: { [Enum.KeyCode]: boolean } = {}

-- Set while something else has the camera, which the input router tells as its layer is covered (piloting a unit,
-- client/pilot.luau): this neither moves it nor zooms.
local suspended = false

-- A move of the view that eases there rather than jumping (`glide_to`): from where and to where, in (x, z), when it
-- began and how long it takes. The player panning or zooming, or a jump (`look_at`), ends it where it is.
type Glide = { from: Vector2, to: Vector2, began: number, seconds: number }
local glide: Glide? = nil

-- Where the cursor was last frame while the middle mouse button has been held, if it has: the drag
-- pans or turns by how far it has moved since. The button is polled every frame rather than followed
-- through input events, which the interface can swallow.
local last_drag_location: Vector2? = nil

local function keyboard_pan(): Vector2
	local total = Vector2.zero
	for key, direction in KEY_DIRECTIONS do
		if held[key] then
			total += direction
		end
	end
	return total
end

-- Turns a movement given in screen terms, x to the right and y down, into one across the ground in the
-- direction the view faces.
local function screen_to_ground(offset: Vector2): Vector3
	local c, s = math.cos(yaw), math.sin(yaw)
	return Vector3.new(offset.X * c + offset.Y * s, 0, -offset.X * s + offset.Y * c)
end

-- The camera looking at `at_focus` from `at_height`, behind and above it along the pitch angle and
-- turned by the current yaw.
local function view_at(at_focus: Vector3, at_height: number): CFrame
	local back = at_height / math.tan(-math.rad(CAMERA_PITCH))
	return CFrame.new(at_focus + screen_to_ground(Vector2.new(0, back)) + Vector3.new(0, at_height, 0), at_focus)
end

-- Moves the focus by `delta` pixels of cursor movement. The camera looks down at a fixed
-- pitch, so a pixel is the same distance everywhere across the screen on the ground sideways, and a
-- pixel up or down covers more ground the flatter the view, by one over the sine of that pitch.
local function pan_by_pixels(delta: Vector2)
	local camera = Workspace.CurrentCamera
	if camera == nil or camera.ViewportSize.Y <= 0 then
		return
	end
	local elevation = math.rad(-CAMERA_PITCH)
	local distance = height / math.sin(elevation)
	local per_pixel = 2 * distance * math.tan(math.rad(camera.FieldOfView) / 2) / camera.ViewportSize.Y
	-- the camera goes where the cursor goes: moving the mouse up pans it the way the view faces
	focus += screen_to_ground(Vector2.new(delta.X * per_pixel, delta.Y * per_pixel / math.sin(elevation)))
end

local function apply(delta: number)
	local camera = Workspace.CurrentCamera
	if camera == nil or suspended then
		last_drag_location = nil
		return
	end

	if UserInputService:IsMouseButtonPressed(Enum.UserInputType.MouseButton3) then
		local location = UserInputService:GetMouseLocation()
		if last_drag_location ~= nil then
			local moved = location - last_drag_location
			if modifiers.alt_held() then
				-- the ground turns the way the cursor drags it
				yaw -= moved.X * CAMERA_ROTATE_SPEED
			elseif moved.Magnitude > 0 then
				glide = nil
				pan_by_pixels(moved)
				events.panned.fire "drag"
			end
		end
		last_drag_location = location
	else
		last_drag_location = nil
	end

	local direction = keyboard_pan()
	if direction.Magnitude > 0 then
		-- pan speed scales with altitude so a zoomed-out camera crosses the map at the same
		-- apparent rate as a zoomed-in one
		local speed = CAMERA_PAN_SPEED * (height / CAMERA_HEIGHT)
		glide = nil
		focus += screen_to_ground(direction.Unit) * speed * delta
		events.panned.fire "keys"
	end

	local gliding = glide
	if gliding ~= nil then
		local t = math.clamp((os.clock() - gliding.began) / gliding.seconds, 0, 1)
		-- quick to start and gentle to arrive
		local eased = 1 - (1 - t) ^ 3
		local at = gliding.from:Lerp(gliding.to, eased)
		focus = Vector3.new(at.X, focus.Y, at.Y)
		if t >= 1 then
			glide = nil
		end
	end

	focus = Vector3.new(focus.X, heightmap.height_at(focus.X, focus.Z), focus.Z)

	camera.CFrame = view_at(focus, height)
end

-- Where on the flat ground at the focus's height the cursor would point if the camera were looking at
-- `at_focus` from `at_height`. Worked out by hand rather than asked of the camera, because zooming has
-- to compare where the cursor points before and after a change the camera has not made yet.
local function ground_under_cursor(cursor: Vector2, at_focus: Vector3, at_height: number): Vector3?
	local camera = Workspace.CurrentCamera
	if camera == nil or camera.ViewportSize.Y <= 0 then
		return nil
	end
	local size = camera.ViewportSize

	local view = view_at(at_focus, at_height)

	local tan_half = math.tan(math.rad(camera.FieldOfView) / 2)
	local x = (2 * cursor.X / size.X - 1) * tan_half * (size.X / size.Y)
	local y = -(2 * cursor.Y / size.Y - 1) * tan_half
	local direction = view:VectorToWorldSpace(Vector3.new(x, y, -1))
	if direction.Y > -1e-4 then
		return nil
	end
	return view.Position + direction * ((at_focus.Y - view.Position.Y) / direction.Y)
end

-- Zooms by `delta` notches of the wheel toward the cursor: whatever is under it stays under it. The focus moves by
-- however far the point under the cursor would otherwise have slid across the ground.
local function zoom(delta: number): boolean
	glide = nil
	local cursor = UserInputService:GetMouseLocation()
	local before = ground_under_cursor(cursor, focus, height)
	height = math.clamp(height - delta * CAMERA_ZOOM_STEP, CAMERA_MIN_HEIGHT, CAMERA_MAX_HEIGHT)
	local after = ground_under_cursor(cursor, focus, height)
	if before ~= nil and after ~= nil then
		focus += Vector3.new(before.X - after.X, 0, before.Z - after.Z)
	end
	return true
end

local function look_at(position: Vector3)
	glide = nil
	focus = Vector3.new(position.X, 0, position.Z)
end

-- Moves the view to look at `position`, easing there over GLIDE_SECONDS rather than jumping.
local function glide_to(position: Vector3)
	glide = {
		from = Vector2.new(focus.X, focus.Z),
		to = Vector2.new(position.X, position.Z),
		began = os.clock(),
		seconds = GLIDE_SECONDS,
	}
end

-- Where the view looks now.
local function get_focus(): Vector3
	return focus
end

-- Hands the camera over to something else (`true`) or takes it back, looking where it did before.
local function set_suspended(value: boolean)
	suspended = value
	table.clear(held)
end

local function init()
	local camera = Workspace.CurrentCamera
	if camera ~= nil then
		camera.CameraType = Enum.CameraType.Scriptable
	end

	-- the arrow keys, held down, and the wheel, through the input router, which covers the layer while something else
	-- has the camera
	input_router.push({
		began = function(input: InputObject, processed: boolean): boolean
			if processed or KEY_DIRECTIONS[input.KeyCode] == nil then
				return false
			end
			held[input.KeyCode] = true
			return true
		end,
		ended = function(input: InputObject)
			held[input.KeyCode] = nil
		end,
		wheel = zoom,
		exclusive = false,
		covered = set_suspended,
	})

	-- Bound at the camera's own priority so that everything that projects through the camera, which
	-- binds just after it, sees this frame's position and not last frame's.
	RunService:BindToRenderStep(RENDER_STEP, Enum.RenderPriority.Camera.Value, apply)
end

return table.freeze({
	CAMERA_HEIGHT = CAMERA_HEIGHT,
	CAMERA_PITCH = CAMERA_PITCH,
	init = init,
	look_at = look_at,
	glide_to = glide_to,
	get_focus = get_focus,
})
