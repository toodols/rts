--!strict
-- Piloting a unit (see shared/piloting.luau), for a developer. P, among the commands (command_input.luau), takes the
-- first selected unit that can be piloted (`take_selected`), and P or Escape lets it go. While it is held every key,
-- button and turn of the wheel is its own, an exclusive layer of the input router (which covers the RTS camera's), and
-- nothing is commanded:
--
--   mouse          looks about, and the unit turns to face where the view does
--   W A S D        walk, relative to the view, at the unit's own top speed
--   left button    fires its chosen weapon at where the crosshair is, for as long as it is held
--   1 2 3 ...      choose which of its weapons the left button fires, the first to start with
--   Q              fires its manual weapon, the commander's disintegrator, where the crosshair is
--   X              hold: every armed unit of the army comes to stand in formation behind it, and it says so
--   C              follow: every armed unit of the army guards it, and it says so
--   V              attack: every armed unit of the army attacks all it finds round where the crosshair is, and it says so
--   Space / Shift  for an aircraft that hovers, take it up or down
--   J              for a transport, pick up what its hook can reach
--   U              for a transport, set what it carries down, once it is low enough
--   G              for something that can be carried, call the nearest transport of its side to pick it up, and pilot
--                  the transport once it has; setting down what the pilot rode in on puts them back in it
--   mouse wheel    backs the view out from the unit's eyes to over its shoulder, and back in
--
-- The army and what X, C and V tell it are client/pilot_army.luau's. The server says what is piloted: the camera is
-- handed over when the player's attribute names a unit and taken back when it no longer does, however that came about
-- (the unit died, or another client told it to let go). Everything about piloting one unit is its session, made anew
-- each time.

local Players = game:GetService "Players"
local ReplicatedStorage = game:GetService "ReplicatedStorage"
local RunService = game:GetService "RunService"
local UserInputService = game:GetService "UserInputService"
local Workspace = game:GetService "Workspace"

local signal = require(ReplicatedStorage.Shared.signal)
local types = require(ReplicatedStorage.Shared.types)
local unit_defs = require(ReplicatedStorage.Shared.unit_defs)
local heightmap = require(ReplicatedStorage.Shared.heightmap)
local geometry = require(ReplicatedStorage.Shared.geometry)
local piloting = require(ReplicatedStorage.Shared.piloting)
local developers = require(ReplicatedStorage.Shared.developers)
local projectile = require(ReplicatedStorage.Shared.projectile)
local entity_attrs = require(ReplicatedStorage.Shared.entity_attrs)

local world = require(ReplicatedStorage.Client.world)
local camera_mod = require(ReplicatedStorage.Client.camera)
local selection = require(ReplicatedStorage.Client.selection)
local team_state = require(ReplicatedStorage.Client.team_state)
local modifiers = require(ReplicatedStorage.Client.modifiers)
local input_router = require(ReplicatedStorage.Client.input_router)
local pilot_army = require(ReplicatedStorage.Client.pilot_army)
local orders = require(ReplicatedStorage.Client.orders)

type EntityId = types.EntityId
type EntityDef = types.EntityDef

-- The last order given the army, and when (`os.clock()`), for the HUD to show it.
export type Command = { kind: "hold" | "follow" | "attack", at: number }
-- A key pressed for something that cannot be done yet: it is not sent, and its tile flashes red with why.
export type Failure = { key: string, reason: string, at: number }
-- What a piloted unit, anyone's, last said (a name from `piloting.PHRASES`) and when, while it is still shown.
export type Callout = { phrase: string, at: number }

-- Piloting one unit, from when the server says it is piloted to when it no longer is.
type Session = {
	id: EntityId,
	-- which way the view looks: `facing` as `Entity.facing` has it, and `pitch` up from level
	facing: number,
	pitch: number,
	-- how far the view has backed out, in the unit's widths: 0 is its eyes
	zoom: number,
	-- whether the trigger is held, and when what the controls say was last sent
	firing: boolean,
	sent_at: number,
	-- what the crosshair is on, worked out every frame, and whether that is something the chosen weapon can hit from
	-- here, for the crosshair to show it
	aim_point: Vector3?,
	aim_target: EntityId?,
	on_target: boolean,
	-- which of its weapons the trigger fires, by index, chosen with the number keys
	weapon: number?,
	command: Command?,
	-- when each key that has a tile on the HUD was last pressed (`os.clock()`), by what the tile shows: "1" for the
	-- first weapon, "Q", "X", "C"; firing presses the chosen weapon's
	presses: { [string]: number },
	failure: Failure?,
}

local possess: RemoteEvent = ReplicatedStorage.Shared.Possess
local pilot_input: UnreliableRemoteEvent = ReplicatedStorage.Shared.PilotInput
local pilot_ability: RemoteEvent = ReplicatedStorage.Shared.PilotAbility
local pilot_say: RemoteEvent = ReplicatedStorage.Shared.PilotSay
local pilot_cargo: RemoteEvent = ReplicatedStorage.Shared.PilotCargo

local local_player = Players.LocalPlayer

local RENDER_STEP = "rts_pilot"
-- How far the view turns for a pixel of mouse movement, in radians.
local LOOK_SPEED = 0.004
-- How far up or down the view may look, in radians from level.
local MAX_PITCH = math.rad(80)
-- How far the view backs out from the unit's eyes for each notch of the wheel, and the furthest it goes, as many of the
-- unit's own widths.
local ZOOM_STEP = 0.75
local MAX_ZOOM = 8
-- How far out the crosshair finds what it is on.
local AIM_RANGE = 3000
-- The number keys that choose a weapon, the first weapon's first.
local WEAPON_KEYS: { [Enum.KeyCode]: number } = {
	[Enum.KeyCode.One] = 1,
	[Enum.KeyCode.Two] = 2,
	[Enum.KeyCode.Three] = 3,
	[Enum.KeyCode.Four] = 4,
	[Enum.KeyCode.Five] = 5,
	[Enum.KeyCode.Six] = 6,
	[Enum.KeyCode.Seven] = 7,
	[Enum.KeyCode.Eight] = 8,
	[Enum.KeyCode.Nine] = 9,
}

-- The unit piloted, while one is.
local session: Session? = nil
-- Takes the input layer and the render step off again, while a unit is piloted.
local stop_piloting: (() -> ())? = nil
local callouts: { [EntityId]: Callout } = {}

-- Fires whenever which unit is piloted, its chosen weapon, whether the crosshair is on something it reaches, a key
-- pressed or the last order given the army changes; the getters below say what they are now.
local changed = signal.new()

local function active(): EntityId?
	return if session ~= nil then session.id else nil
end

local function chosen_weapon(): number?
	return if session ~= nil then session.weapon else nil
end

local function is_on_target(): boolean
	return session ~= nil and session.on_target
end

local function last_command(): Command?
	return if session ~= nil then session.command else nil
end

local function pressed_at(key: string): number?
	return if session ~= nil then session.presses[key] else nil
end

-- The last key pressed for something that could not be done, and why.
local function last_failure(): Failure?
	return if session ~= nil then session.failure else nil
end

-- What the piloted units are saying now, by unit.
local function current_callouts(): { [EntityId]: Callout }
	return callouts
end

-- The army of the unit piloted (`pilot_army.of`), for the HUD to count.
local function army(): { pilot_army.Unit }
	return pilot_army.of(active())
end

local function notify()
	changed.fire()
end

local function press(now: Session, key: string)
	now.presses[key] = os.clock()
	notify()
end

local function fail(now: Session, key: string, reason: string)
	now.failure = { key = key, reason = reason, at = os.clock() }
	notify()
end

-- The army was given `kind` of order, and the HUD shows it.
local function commanded(now: Session, kind: "hold" | "follow" | "attack", key: string)
	now.command = { kind = kind, at = os.clock() }
	press(now, key)
	pilot_say:FireServer(kind)
end

-- A piloted unit said something: it is shown for `piloting.SAY_SECONDS`, and then taken down.
local function on_said(entity_id: unknown, phrase: unknown)
	if typeof(entity_id) ~= "number" or typeof(phrase) ~= "string" or piloting.PHRASES[phrase] == nil then
		return
	end
	local callout = { phrase = phrase, at = os.clock() }
	callouts[entity_id] = callout
	notify()
	task.delay(piloting.SAY_SECONDS, function()
		if callouts[entity_id] == callout then
			callouts[entity_id] = nil
			notify()
		end
	end)
end

local function look_vector(now: Session): Vector3
	return Vector3.new(
		math.sin(now.facing) * math.cos(now.pitch),
		math.sin(now.pitch),
		math.cos(now.facing) * math.cos(now.pitch)
	)
end

-- The way the view faces across the ground, and to its right.
local function flat_axes(now: Session): (Vector3, Vector3)
	local forward = Vector3.new(math.sin(now.facing), 0, math.cos(now.facing))
	return forward, Vector3.new(-forward.Z, 0, forward.X)
end

-- Where the view is, for the unit in `model` of `def`: just ahead of its front at the top of it, or backed out behind
-- and above that by the zoom.
local function eye_of(now: Session, model: Model, def: EntityDef): Vector3
	local radius = unit_defs.collider_radius(def)
	local forward = flat_axes(now)
	local top = world.position_of(model) + Vector3.new(0, unit_defs.collider_height(def) / 2 + 0.5, 0)
	if now.zoom <= 0 then
		return top + forward * radius
	end
	local distance = now.zoom * 2 * radius + radius
	local eye = top - look_vector(now) * distance + Vector3.new(0, distance * 0.25, 0)
	local ground = heightmap.height_at(eye.X, eye.Z)
	return Vector3.new(eye.X, math.max(eye.Y, ground + 1), eye.Z)
end

-- Works out what the crosshair, in the middle of the view, is on: the first thing along the line of sight other than
-- the unit itself, or the ground, whichever is nearer, and the enemy it is, if it is one.
local function update_aim(now: Session, model: Model, origin: Vector3)
	local look = look_vector(now)
	local point = origin + look * AIM_RANGE
	local distance = AIM_RANGE
	now.aim_target = nil
	local ground = heightmap.ray_to_ground(origin, look, AIM_RANGE)
	if ground ~= nil then
		point = ground
		distance = (ground - origin).Magnitude
	end
	local params = RaycastParams.new()
	params.FilterType = Enum.RaycastFilterType.Include
	params.FilterDescendantsInstances = { world.container() }
	local from = origin
	-- whatever of its own it looks through, it looks on past
	for _ = 1, 4 do
		local left = distance - (from - origin).Magnitude
		if left <= 0 then
			break
		end
		local result = Workspace:Raycast(from, look * left, params)
		if result == nil then
			break
		end
		local hit = world.from_instance(result.Instance)
		if hit == model then
			from = result.Position + look * 0.05
			continue
		end
		point = result.Position
		if hit ~= nil and world.relation(hit, model) == "enemy" then
			now.aim_target = world.id_of(hit)
		end
		break
	end
	now.aim_point = point
end

-- Whether the chosen weapon of the unit in `model` can hit what the crosshair is on: an enemy of the layer it shoots
-- at, no further across the ground than it reaches, as the server measures a piloted shot.
local function reaches_aim(now: Session, model: Model, def: EntityDef): boolean
	local target = if now.aim_target ~= nil then world.get(now.aim_target) else nil
	local target_def = if target ~= nil then world.def_of(target) else nil
	local chosen = if now.weapon ~= nil and def.weapons ~= nil then def.weapons[now.weapon] else nil
	local aim_point = now.aim_point
	if target == nil or target_def == nil or chosen == nil or aim_point == nil then
		return false
	end
	if unit_defs.reaches_layer(chosen, unit_defs.layer_of(target_def, world.position_of(target))) == false then
		return false
	end
	local from = world.position_of(model)
	local reach = projectile.range_to(chosen.range, from, aim_point, chosen.delivery)
	return geometry.distance_2d(from, aim_point) <= reach
end

-- Which way an aircraft that hovers is taken: 1 up while Space is held, -1 down while Shift is.
local function lift(): number
	if UserInputService:GetFocusedTextBox() ~= nil then
		return 0
	end
	local up = if UserInputService:IsKeyDown(Enum.KeyCode.Space) then 1 else 0
	local down = if modifiers.shift_held() then 1 else 0
	return up - down
end

local function steer(now: Session): Vector3
	local forward, right = flat_axes(now)
	local way = Vector3.zero
	if UserInputService:GetFocusedTextBox() == nil then
		if UserInputService:IsKeyDown(Enum.KeyCode.W) then
			way += forward
		end
		if UserInputService:IsKeyDown(Enum.KeyCode.S) then
			way -= forward
		end
		if UserInputService:IsKeyDown(Enum.KeyCode.D) then
			way += right
		end
		if UserInputService:IsKeyDown(Enum.KeyCode.A) then
			way -= right
		end
	end
	return if way.Magnitude > 1e-3 then way.Unit else Vector3.zero
end

local function send(now: Session)
	pilot_input:FireServer({
		steer = steer(now),
		facing = now.facing,
		aim = now.aim_point,
		target_id = now.aim_target,
		firing = now.firing,
		lift = lift(),
		weapon = now.weapon,
	})
	now.sent_at = os.clock()
end

local function on_render()
	local now = session
	local model = if now ~= nil then world.get(now.id) else nil
	local def = if model ~= nil then world.def_of(model) else nil
	local camera = Workspace.CurrentCamera
	if now == nil or model == nil or def == nil or camera == nil then
		return
	end
	UserInputService.MouseBehavior = Enum.MouseBehavior.LockCenter
	UserInputService.MouseIconEnabled = false

	local moved = UserInputService:GetMouseDelta()
	now.facing -= moved.X * LOOK_SPEED
	now.pitch = math.clamp(now.pitch - moved.Y * LOOK_SPEED, -MAX_PITCH, MAX_PITCH)

	local eye = eye_of(now, model, def)
	camera.CFrame = CFrame.lookAt(eye, eye + look_vector(now))
	update_aim(now, model, eye)
	local reaches = reaches_aim(now, model, def)
	if reaches ~= now.on_target then
		now.on_target = reaches
		notify()
	end

	if os.clock() - now.sent_at >= 1 / piloting.INPUT_RATE then
		send(now)
	end
end

-- P with a unit selected that can be piloted takes the first such one.
local function take_selected()
	if developers.is_developer(local_player) == false then
		return
	end
	for _, id in selection.get() do
		local model = world.get(id)
		local def = if model ~= nil then world.def_of(model) else nil
		if
			model ~= nil
			and def ~= nil
			and world.is_mine(model)
			and entity_attrs.state(model) == "active"
			and entity_attrs.flag(model, "carried") ~= true
			and piloting.can_pilot(def)
		then
			possess:FireServer(id)
			return
		end
	end
end

-- Q: the manual weapon, at the crosshair.
local function fire_manual(now: Session, model: Model)
	local def = world.def_of(model)
	local manual = if def ~= nil then def.manual_weapon else nil
	local cooldown = entity_attrs.number(model, piloting.COOLDOWN_ATTRIBUTE)
	if manual == nil or now.aim_point == nil then
		return
	elseif cooldown ~= nil and cooldown > 0 then
		fail(now, "Q", "Reloading")
	elseif team_state.get().energy < manual.energy_per_shot then
		fail(now, "Q", "Not enough energy")
	else
		pilot_ability:FireServer(now.aim_point)
		press(now, "Q")
	end
end

-- J and U, a transport's: J picks up while its hold is empty, U sets down once it is not, as its tiles show.
local function cargo(now: Session, model: Model, loading: boolean)
	local def = world.def_of(model)
	local cargo_used = entity_attrs.number(model, "cargo_used")
	local carrying = cargo_used ~= nil and cargo_used > 0
	if def == nil or def.transport == nil or loading == carrying then
		return
	elseif loading and entity_attrs.flag(model, piloting.LOAD_ATTRIBUTE) ~= true then
		fail(now, "J", "Nothing in reach")
	elseif loading == false and entity_attrs.flag(model, piloting.UNLOAD_ATTRIBUTE) ~= true then
		fail(now, "U", "Too high to unload")
	else
		pilot_cargo:FireServer(if loading then "load" else "unload")
		press(now, if loading then "J" else "U")
	end
end

-- G, for something that can be carried: calls a transport over.
local function call_mount(now: Session, model: Model)
	local def = world.def_of(model)
	if def == nil or def.transport ~= nil or def.weight_class == nil then
		return
	elseif entity_attrs.flag(model, piloting.CALL_ATTRIBUTE) ~= true then
		fail(now, "G", "No mount available")
	else
		pilot_cargo:FireServer "call"
		press(now, "G")
	end
end

-- 1, 2, 3 ...: which weapon the trigger fires.
local function choose_weapon(now: Session, model: Model, index: number)
	local def = world.def_of(model)
	if def == nil or piloting.can_select(def, index) == false then
		return
	end
	if index ~= now.weapon then
		now.weapon = index
		send(now)
	end
	press(now, tostring(index))
end

local function on_key(now: Session, model: Model, key: Enum.KeyCode)
	if key == Enum.KeyCode.Q then
		fire_manual(now, model)
	elseif key == Enum.KeyCode.X then
		local forward, right = flat_axes(now)
		pilot_army.hold(model, now.id, forward, right)
		commanded(now, "hold", "X")
	elseif key == Enum.KeyCode.C then
		pilot_army.follow(now.id)
		commanded(now, "follow", "C")
	elseif key == Enum.KeyCode.V then
		local aim_point = now.aim_point
		if aim_point == nil then
			fail(now, "V", "No target")
		else
			pilot_army.attack(now.id, aim_point)
			commanded(now, "attack", "V")
		end
	elseif key == Enum.KeyCode.J or key == Enum.KeyCode.U then
		cargo(now, model, key == Enum.KeyCode.J)
	elseif key == Enum.KeyCode.G then
		call_mount(now, model)
	elseif key == Enum.KeyCode.K then
		orders.send("shield", { now.id }, { aim = "none" }, orders.NOW)
	elseif WEAPON_KEYS[key] ~= nil then
		choose_weapon(now, model, WEAPON_KEYS[key])
	end
end

-- While a unit is piloted every key and button is the pilot's (its input layer is exclusive), whether or not anything
-- here does something with it.
local function on_input_began(input: InputObject, processed: boolean): boolean
	local now = session
	if now == nil then
		return true
	end
	-- the crosshair is always over the middle of the screen, where whatever GUI is there would swallow the click
	if input.UserInputType == Enum.UserInputType.MouseButton1 then
		now.firing = true
		send(now)
		if now.weapon ~= nil then
			press(now, tostring(now.weapon))
		end
		return true
	end
	if processed or UserInputService:GetFocusedTextBox() ~= nil then
		return true
	end
	if input.KeyCode == Enum.KeyCode.P or input.KeyCode == Enum.KeyCode.Escape then
		possess:FireServer(nil)
		return true
	end
	local model = world.get(now.id)
	if model ~= nil then
		on_key(now, model, input.KeyCode)
	end
	return true
end

local function on_input_ended(input: InputObject)
	local now = session
	if now ~= nil and input.UserInputType == Enum.UserInputType.MouseButton1 and now.firing then
		now.firing = false
		send(now)
	end
end

-- The wheel backs the view out from the unit's eyes, and back in.
local function on_wheel(delta: number): boolean
	local now = session
	if now ~= nil then
		now.zoom = math.clamp(now.zoom - delta * ZOOM_STEP, 0, MAX_ZOOM)
	end
	return true
end

local LAYER: input_router.Layer = table.freeze({
	began = on_input_began,
	ended = on_input_ended,
	wheel = on_wheel,
	exclusive = true,
})

-- Takes the controls and the camera for piloting, until the returned function gives them back.
local function start_piloting(): () -> ()
	selection.set({})
	local pop_layer = input_router.push(LAYER)
	RunService:BindToRenderStep(RENDER_STEP, Enum.RenderPriority.Camera.Value, on_render)
	return function()
		pop_layer()
		RunService:UnbindFromRenderStep(RENDER_STEP)
		UserInputService.MouseBehavior = Enum.MouseBehavior.Default
		UserInputService.MouseIconEnabled = true
	end
end

-- Pilots the unit the server says is piloted, in a session of its own, or hands the controls back to the RTS view over
-- wherever the last one was left.
local function follow_attribute()
	local id: EntityId? = piloting.piloted_by(local_player)
	local was = session
	if id == active() then
		return
	end
	if id == nil then
		session = nil
		local stop = stop_piloting
		stop_piloting = nil
		if stop ~= nil then
			stop()
		end
		local model = if was ~= nil then world.get(was.id) else nil
		if was ~= nil and model ~= nil then
			camera_mod.look_at(world.position_of(model))
			selection.set({ was.id })
		end
		notify()
		return
	end

	local model = world.get(id)
	local def = if model ~= nil then world.def_of(model) else nil
	-- taking a unit from the RTS view looks the way it faces, from its eyes; going from one piloted unit straight to
	-- another, as when a transport takes it aboard, keeps the view where it was, zoomed as it was
	local facing = if was ~= nil then was.facing else 0
	if was == nil and model ~= nil then
		local front = model:GetPivot().ZVector
		facing = math.atan2(front.X, front.Z)
	end
	session = {
		id = id,
		facing = facing,
		pitch = if was ~= nil then was.pitch else 0,
		zoom = if was ~= nil then was.zoom else 0,
		firing = false,
		sent_at = 0,
		aim_point = nil,
		aim_target = nil,
		on_target = false,
		weapon = if def ~= nil then piloting.primary_weapon(def) else nil,
		command = nil,
		presses = {},
		failure = nil,
	}
	if stop_piloting == nil then
		stop_piloting = start_piloting()
	end
	notify()
end

local function init()
	pilot_say.OnClientEvent:Connect(on_said)
	piloting.piloted_changed(local_player, follow_attribute)
	follow_attribute()
end

return table.freeze({
	init = init,
	active = active,
	subscribe = changed.subscribe,
	chosen_weapon = chosen_weapon,
	is_on_target = is_on_target,
	last_command = last_command,
	pressed_at = pressed_at,
	last_failure = last_failure,
	army = army,
	take_selected = take_selected,
	current_callouts = current_callouts,
})
