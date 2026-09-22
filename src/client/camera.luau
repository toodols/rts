-- A fixed-pitch RTS camera. It looks at a focus point on the ground, pans with the arrow keys or by
-- dragging with the middle mouse button, and zooms by raising and lowering itself rather than changing
-- angle. The letter keys are left free for commands.

local ContextActionService = game:GetService "ContextActionService"
local ReplicatedStorage = game:GetService "ReplicatedStorage"
local RunService = game:GetService "RunService"
local UserInputService = game:GetService "UserInputService"
local Workspace = game:GetService "Workspace"

local config = require(ReplicatedStorage.Shared.config)
local heightmap = require(ReplicatedStorage.Shared.heightmap)

local PAN_ACTION = "rts_camera_pan"
local RENDER_STEP = "rts_camera"

local focus = Vector3.zero
local height = config.CAMERA_HEIGHT

local KEY_DIRECTIONS: { [Enum.KeyCode]: Vector2 } = {
	[Enum.KeyCode.Up] = Vector2.new(0, -1),
	[Enum.KeyCode.Down] = Vector2.new(0, 1),
	[Enum.KeyCode.Left] = Vector2.new(-1, 0),
	[Enum.KeyCode.Right] = Vector2.new(1, 0),
}

local held: { [Enum.KeyCode]: boolean } = {}

-- Where the cursor was last frame while the middle mouse button has been held, if it has: the drag
-- pans by how far it has moved since. The button is polled every frame rather than followed through
-- input events, which the interface can swallow.
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

-- Moves the focus by `delta` pixels of cursor movement. The camera looks down at a fixed
-- pitch, so a pixel is the same distance everywhere across the screen on the ground sideways, and a
-- pixel up or down covers more ground the flatter the view, by one over the sine of that pitch.
local function pan_by_pixels(delta: Vector2)
	local camera = Workspace.CurrentCamera
	if camera == nil or camera.ViewportSize.Y <= 0 then
		return
	end
	local elevation = math.rad(-config.CAMERA_PITCH)
	local distance = height / math.sin(elevation)
	local per_pixel = 2 * distance * math.tan(math.rad(camera.FieldOfView) / 2) / camera.ViewportSize.Y
	-- the camera goes where the cursor goes: moving the mouse up pans it north, the way the view faces
	focus += Vector3.new(delta.X * per_pixel, 0, delta.Y * per_pixel / math.sin(elevation))
end

local function apply(delta: number)
	local camera = Workspace.CurrentCamera
	if camera == nil then
		return
	end

	if UserInputService:IsMouseButtonPressed(Enum.UserInputType.MouseButton3) then
		local location = UserInputService:GetMouseLocation()
		if last_drag_location ~= nil then
			pan_by_pixels(location - last_drag_location)
		end
		last_drag_location = location
	else
		last_drag_location = nil
	end

	local direction = keyboard_pan()
	if direction.Magnitude > 0 then
		local unit = direction.Unit
		-- pan speed scales with altitude so a zoomed-out camera crosses the map at the same
		-- apparent rate as a zoomed-in one
		local speed = config.CAMERA_PAN_SPEED * (height / config.CAMERA_HEIGHT)
		focus += Vector3.new(unit.X, 0, unit.Y) * speed * delta
	end

	focus = Vector3.new(focus.X, heightmap.height_at(focus.X, focus.Z), focus.Z)

	local pitch = math.rad(config.CAMERA_PITCH)
	-- place the camera behind and above the focus along the pitch angle
	local back = height / math.tan(-pitch)
	local position = focus + Vector3.new(0, height, back)
	camera.CFrame = CFrame.new(position, focus)
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

	local pitch = math.rad(config.CAMERA_PITCH)
	local back = at_height / math.tan(-pitch)
	local view = CFrame.new(at_focus + Vector3.new(0, at_height, back), at_focus)

	local tan_half = math.tan(math.rad(camera.FieldOfView) / 2)
	local x = (2 * cursor.X / size.X - 1) * tan_half * (size.X / size.Y)
	local y = -(2 * cursor.Y / size.Y - 1) * tan_half
	local direction = view:VectorToWorldSpace(Vector3.new(x, y, -1))
	if direction.Y > -1e-4 then
		return nil
	end
	return view.Position + direction * ((at_focus.Y - view.Position.Y) / direction.Y)
end

local function on_zoom(_, input_state: Enum.UserInputState, input: InputObject): Enum.ContextActionResult
	if input.UserInputType ~= Enum.UserInputType.MouseWheel then
		return Enum.ContextActionResult.Pass
	end
	-- Zoom toward the cursor: whatever is under it stays under it. The focus moves by however far the
	-- point under the cursor would otherwise have slid across the ground.
	local cursor = UserInputService:GetMouseLocation()
	local before = ground_under_cursor(cursor, focus, height)
	height = math.clamp(
		height - input.Position.Z * config.CAMERA_ZOOM_STEP,
		config.CAMERA_MIN_HEIGHT,
		config.CAMERA_MAX_HEIGHT
	)
	local after = ground_under_cursor(cursor, focus, height)
	if before ~= nil and after ~= nil then
		focus += Vector3.new(before.X - after.X, 0, before.Z - after.Z)
	end
	return Enum.ContextActionResult.Sink
end

local function look_at(position: Vector3)
	focus = Vector3.new(position.X, 0, position.Z)
end

local function get_focus(): Vector3
	return focus
end

local function init()
	local camera = Workspace.CurrentCamera
	if camera ~= nil then
		camera.CameraType = Enum.CameraType.Scriptable
	end

	UserInputService.InputBegan:Connect(function(input: InputObject, processed: boolean)
		if processed then
			return
		end
		if KEY_DIRECTIONS[input.KeyCode] ~= nil then
			held[input.KeyCode] = true
		end
	end)
	UserInputService.InputEnded:Connect(function(input: InputObject)
		if KEY_DIRECTIONS[input.KeyCode] ~= nil then
			held[input.KeyCode] = nil
		end
	end)

	ContextActionService:BindAction(PAN_ACTION, on_zoom, false, Enum.UserInputType.MouseWheel)

	-- Bound at the camera's own priority so that everything that projects through the camera, which
	-- binds just after it, sees this frame's position and not last frame's.
	RunService:BindToRenderStep(RENDER_STEP, Enum.RenderPriority.Camera.Value, apply)
end

return table.freeze({
	init = init,
	look_at = look_at,
	get_focus = get_focus,
})
