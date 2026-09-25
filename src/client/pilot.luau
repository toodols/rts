-- Piloting a unit (see shared/piloting.luau), for a developer. P takes the first selected unit that can be piloted, and
-- P or Escape lets it go. While it is held:
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
-- The server says what is piloted: the camera is handed over when the player's attribute names a unit and taken back
-- when it no longer does, however that came about (the unit died, or another client told it to let go).

local ContextActionService = game:GetService "ContextActionService"
local Players = game:GetService "Players"
local ReplicatedStorage = game:GetService "ReplicatedStorage"
local RunService = game:GetService "RunService"
local UserInputService = game:GetService "UserInputService"
local Workspace = game:GetService "Workspace"

local types = require(ReplicatedStorage.Shared.types)
local unit_defs = require(ReplicatedStorage.Shared.unit_defs)
local heightmap = require(ReplicatedStorage.Shared.heightmap)
local geometry = require(ReplicatedStorage.Shared.geometry)
local piloting = require(ReplicatedStorage.Shared.piloting)
local developers = require(ReplicatedStorage.Shared.developers)
local projectile = require(ReplicatedStorage.Shared.projectile)

local world = require(ReplicatedStorage.Client.world)
local camera_mod = require(ReplicatedStorage.Client.camera)
local selection = require(ReplicatedStorage.Client.selection)
local routes = require(ReplicatedStorage.Client.routes)
local markers = require(ReplicatedStorage.Client.markers)

type EntityId = types.EntityId
type EntityDef = types.EntityDef

local possess: RemoteEvent = ReplicatedStorage.Shared.Possess
local pilot_input: UnreliableRemoteEvent = ReplicatedStorage.Shared.PilotInput
local pilot_ability: RemoteEvent = ReplicatedStorage.Shared.PilotAbility
local issue_order: RemoteEvent = ReplicatedStorage.Shared.IssueOrder
local pilot_say: RemoteEvent = ReplicatedStorage.Shared.PilotSay
local pilot_cargo: RemoteEvent = ReplicatedStorage.Shared.PilotCargo
local team_updated: RemoteEvent = ReplicatedStorage.Shared.TeamUpdated

local local_player = Players.LocalPlayer

local RENDER_STEP = "rts_pilot"
local ZOOM_ACTION = "rts_pilot_zoom"
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
-- How far apart the units of a hold stand, beyond their own widths, in studs, and how far behind the pilot the first
-- row stands.
local FORMATION_GAP = 3
local FORMATION_BEHIND = 4
-- How long the dots a hold or a follow puts down stay up.
local COMMAND_MARKER_SECONDS = 1.5
-- How far round the crosshair the army attacks everything, in studs.
local ATTACK_RADIUS = 40
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
local piloted: EntityId? = nil
-- Which way the view looks: `facing` as `Entity.facing` has it, and `pitch` up from level.
local facing = 0
local pitch = 0
-- How far the view has backed out, in the unit's widths: 0 is its eyes.
local zoom = 0
local firing = false
local sent_at = 0
-- What the crosshair is on, worked out every frame.
local aim_point: Vector3? = nil
local aim_target: EntityId? = nil
-- Whether `aim_target` is something the chosen weapon can hit from here, for the crosshair to show it.
local on_target = false
-- Which of its weapons the trigger fires, by index, chosen with the number keys.
local weapon: number? = nil
-- The last order given the army, hold or follow, and when (`os.clock()`), for the HUD to show it.
export type Command = { kind: "hold" | "follow" | "attack", at: number }
local command: Command? = nil

-- When each key that has a tile on the HUD was last pressed (`os.clock()`), by what the tile shows: "1" for the first
-- weapon, "Q", "X", "C"; firing presses the chosen weapon's.
local presses: { [string]: number } = {}
-- What each piloted unit, anyone's, last said (a name from `piloting.PHRASES`) and when, while it is still shown.
export type Callout = { phrase: string, at: number }
local callouts: { [EntityId]: Callout } = {}

local listeners: { () -> () } = {}

local function active(): EntityId?
	return piloted
end

local function chosen_weapon(): number?
	return weapon
end

local function is_on_target(): boolean
	return on_target
end

local function last_command(): Command?
	return command
end

local function pressed_at(key: string): number?
	return presses[key]
end

local function notify()
	for _, listener in table.clone(listeners) do
		listener()
	end
end

local function press(key: string)
	presses[key] = os.clock()
	notify()
end

-- A key pressed for something that cannot be done yet: it is not sent, and its tile flashes red with why.
export type Failure = { key: string, reason: string, at: number }
local failure: Failure? = nil

local function fail(key: string, reason: string)
	failure = { key = key, reason = reason, at = os.clock() }
	notify()
end

-- The last key pressed for something that could not be done, and why.
local function last_failure(): Failure?
	return failure
end

-- The team's energy, as the server last said, for whether the manual weapon can be paid for.
local energy = 0
team_updated.OnClientEvent:Connect(function(team: { energy: number })
	energy = team.energy
end)

-- What the piloted units are saying now, by unit.
local function current_callouts(): { [EntityId]: Callout }
	return callouts
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

-- Calls `listener` whenever which unit is piloted, its chosen weapon, whether the crosshair is on something it reaches or
-- the last order given the army changes; the getters above say what they are now.
local function subscribe(listener: () -> ()): () -> ()
	table.insert(listeners, listener)
	return function()
		local index = table.find(listeners, listener)
		if index ~= nil then
			table.remove(listeners, index)
		end
	end
end

local function def_of(model: Model): EntityDef?
	local def_name = model:GetAttribute "def_name"
	return if typeof(def_name) == "string" then unit_defs.defs[def_name] else nil
end

local function look_vector(): Vector3
	return Vector3.new(math.sin(facing) * math.cos(pitch), math.sin(pitch), math.cos(facing) * math.cos(pitch))
end

-- The way the view faces across the ground, and to its right.
local function flat_axes(): (Vector3, Vector3)
	local forward = Vector3.new(math.sin(facing), 0, math.cos(facing))
	return forward, Vector3.new(-forward.Z, 0, forward.X)
end

-- Every armed unit of this player's that can walk, other than the one piloted: what X and C send, and what the HUD
-- counts. Builders are left to their work.
local function army(): { { id: EntityId, model: Model, def: EntityDef } }
	local result = {}
	for _, model in world.all() do
		local id = world.id_of(model)
		local def = def_of(model)
		if
			id == nil
			or id == piloted
			or def == nil
			or world.is_mine(model) == false
			or model:GetAttribute "kind" ~= "unit"
			or model:GetAttribute "state" ~= "active"
			or model:GetAttribute "carried" == true
		then
			continue
		end
		if piloting.can_pilot(def) and def.weapons ~= nil and def.buildpower == nil then
			table.insert(result, { id = id, model = model, def = def })
		end
	end
	return result
end

-- X: the army comes to stand in rows behind the piloted unit, as square a block as they make, each taking the nearest
-- place left, nearest of them first.
local function hold(pilot_model: Model)
	command = { kind = "hold", at = os.clock() }
	notify()
	local units = army()
	if #units == 0 then
		return
	end
	local center = world.position_of(pilot_model)
	local pilot_def = def_of(pilot_model)
	local forward, right = flat_axes()
	local spacing = 0
	for _, unit in units do
		spacing = math.max(spacing, 2 * unit_defs.collider_radius(unit.def))
	end
	spacing += FORMATION_GAP
	local columns = math.ceil(math.sqrt(#units))
	local behind = (if pilot_def ~= nil then unit_defs.collider_radius(pilot_def) else 0) + FORMATION_BEHIND
	local hx, hz = heightmap.half_extents()
	local slots: { Vector3 } = {}
	for index = 0, #units - 1 do
		local row = index // columns
		local in_row = math.min(columns, #units - row * columns)
		local column = index % columns
		local at = center - forward * (behind + spacing * (row + 0.5)) + right * ((column - (in_row - 1) / 2) * spacing)
		local x = math.clamp(at.X, -hx + 1, hx - 1)
		local z = math.clamp(at.Z, -hz + 1, hz - 1)
		table.insert(slots, heightmap.ground_position(x, z))
	end

	table.sort(units, function(a, b)
		return geometry.distance_2d(world.position_of(a.model), center)
			< geometry.distance_2d(world.position_of(b.model), center)
	end)
	local ids: { EntityId } = {}
	local positions: { Vector3 } = {}
	for _, unit in units do
		local from = world.position_of(unit.model)
		local best = 1
		for index = 2, #slots do
			if geometry.distance_2d(slots[index], from) < geometry.distance_2d(slots[best], from) then
				best = index
			end
		end
		table.insert(ids, unit.id)
		table.insert(positions, unit_defs.surface_position(unit.def, slots[best].X, slots[best].Z))
		table.remove(slots, best)
	end
	issue_order:FireServer({
		kind = "move",
		ids = ids,
		positions = positions,
		routes = routes.for_units(ids, "move", function(index: number): Vector3?
			return positions[index]
		end, nil, false, false),
		queue = false,
		front = false,
	})
	-- where each will stand, as a move's dots show it
	markers.flash_points(positions, COMMAND_MARKER_SECONDS, "move")
end

-- V: the army attacks everything of the enemy's within ATTACK_RADIUS of `center`, where the crosshair is, one thing at a
-- time, as an attack circle dragged out on the map has it do.
local function attack(center: Vector3)
	command = { kind = "attack", at = os.clock() }
	notify()
	local ids: { EntityId } = {}
	for _, unit in army() do
		table.insert(ids, unit.id)
	end
	if #ids == 0 then
		return
	end
	local ground = heightmap.ground_position(center.X, center.Z)
	issue_order:FireServer({
		kind = "area_attack",
		ids = ids,
		position = ground,
		radius = ATTACK_RADIUS,
		routes = routes.for_units(ids, "area_attack", function(_: number): Vector3?
			return ground
		end, ATTACK_RADIUS, false, false),
		queue = false,
		front = false,
	})
	-- the circle, for a moment
	markers.show_area(ground, ATTACK_RADIUS, "attack")
	local shown = command
	task.delay(COMMAND_MARKER_SECONDS, function()
		if command == shown then
			markers.hide_area()
		end
	end)
end

-- C: the army guards the piloted unit, following it wherever it goes.
local function follow(pilot_model: Model, pilot_id: EntityId)
	command = { kind = "follow", at = os.clock() }
	notify()
	local ids: { EntityId } = {}
	local under: { Vector3 } = {}
	for _, unit in army() do
		table.insert(ids, unit.id)
		local at = world.position_of(unit.model)
		table.insert(under, heightmap.ground_position(at.X, at.Z))
	end
	if #ids == 0 then
		return
	end
	-- a dot under each one that is coming, in the guard order's colour
	markers.flash_points(under, COMMAND_MARKER_SECONDS, "guard")
	local at = world.position_of(pilot_model)
	issue_order:FireServer({
		kind = "guard",
		ids = ids,
		target_id = pilot_id,
		routes = routes.for_units(ids, "guard", function(_: number): Vector3?
			return at
		end, nil, false, false),
		queue = false,
		front = false,
	})
end

-- Where the view is, for the unit in `model` of `def`: just ahead of its front at the top of it, or backed out behind
-- and above that by the zoom.
local function eye_of(model: Model, def: EntityDef): Vector3
	local radius = unit_defs.collider_radius(def)
	local forward = flat_axes()
	local top = world.position_of(model) + Vector3.new(0, unit_defs.collider_height(def) / 2 + 0.5, 0)
	if zoom <= 0 then
		return top + forward * radius
	end
	local distance = zoom * 2 * radius + radius
	local eye = top - look_vector() * distance + Vector3.new(0, distance * 0.25, 0)
	local ground = heightmap.height_at(eye.X, eye.Z)
	return Vector3.new(eye.X, math.max(eye.Y, ground + 1), eye.Z)
end

-- Works out what the crosshair, in the middle of the view, is on: the first thing along the line of sight other than
-- the unit itself, or the ground, whichever is nearer, and the enemy it is, if it is one.
local function update_aim(model: Model, origin: Vector3)
	local look = look_vector()
	local point = origin + look * AIM_RANGE
	local distance = AIM_RANGE
	aim_target = nil
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
		if
			hit ~= nil
			and hit:GetAttribute "team" ~= 0
			and hit:GetAttribute "ally_group" ~= model:GetAttribute "ally_group"
			and (hit:GetAttribute "kind" == "unit" or hit:GetAttribute "kind" == "building")
		then
			aim_target = world.id_of(hit)
		end
		break
	end
	aim_point = point
end

-- Whether the chosen weapon of the unit in `model` can hit what the crosshair is on: an enemy of the layer it shoots
-- at, no further across the ground than it reaches, as the server measures a piloted shot.
local function reaches_aim(model: Model, def: EntityDef): boolean
	local target = if aim_target ~= nil then world.get(aim_target) else nil
	local target_def = if target ~= nil then def_of(target) else nil
	local chosen = if weapon ~= nil and def.weapons ~= nil then def.weapons[weapon] else nil
	if target == nil or target_def == nil or chosen == nil or aim_point == nil then
		return false
	end
	local in_air = unit_defs.is_air(target_def)
	if (chosen.target_layer == "air" and in_air == false) or (chosen.target_layer == "ground" and in_air) then
		return false
	end
	local from = world.position_of(model)
	local reach = if chosen.projectile ~= nil
		then projectile.range_to(chosen.range, from, aim_point, chosen.projectile)
		else chosen.range
	return geometry.distance_2d(from, aim_point) <= reach
end

-- Which way an aircraft that hovers is taken: 1 up while Space is held, -1 down while Shift is.
local function lift(): number
	if UserInputService:GetFocusedTextBox() ~= nil then
		return 0
	end
	local up = if UserInputService:IsKeyDown(Enum.KeyCode.Space) then 1 else 0
	local down = if UserInputService:IsKeyDown(Enum.KeyCode.LeftShift) then 1 else 0
	return up - down
end

local function steer(): Vector3
	local forward, right = flat_axes()
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

local function send()
	pilot_input:FireServer({
		steer = steer(),
		facing = facing,
		aim = aim_point,
		target_id = aim_target,
		firing = firing,
		lift = lift(),
		weapon = weapon,
	})
	sent_at = os.clock()
end

local function on_render()
	local id = piloted
	local model = if id ~= nil then world.get(id) else nil
	local def = if model ~= nil then def_of(model) else nil
	local camera = Workspace.CurrentCamera
	if model == nil or def == nil or camera == nil then
		return
	end
	UserInputService.MouseBehavior = Enum.MouseBehavior.LockCenter
	UserInputService.MouseIconEnabled = false

	local moved = UserInputService:GetMouseDelta()
	facing -= moved.X * LOOK_SPEED
	pitch = math.clamp(pitch - moved.Y * LOOK_SPEED, -MAX_PITCH, MAX_PITCH)

	local eye = eye_of(model, def)
	camera.CFrame = CFrame.lookAt(eye, eye + look_vector())
	update_aim(model, eye)
	local reaches = reaches_aim(model, def)
	if reaches ~= on_target then
		on_target = reaches
		notify()
	end

	if os.clock() - sent_at >= 1 / piloting.INPUT_RATE then
		send()
	end
end

local function on_zoom(_, _: Enum.UserInputState, input: InputObject): Enum.ContextActionResult
	if input.UserInputType ~= Enum.UserInputType.MouseWheel then
		return Enum.ContextActionResult.Pass
	end
	zoom = math.clamp(zoom - input.Position.Z * ZOOM_STEP, 0, MAX_ZOOM)
	return Enum.ContextActionResult.Sink
end

-- Hands the camera to the unit the server says is piloted, or back to the RTS view over wherever it was left.
local function follow_attribute()
	local value = local_player:GetAttribute(piloting.PLAYER_ATTRIBUTE)
	local id: EntityId? = if typeof(value) == "number" then value else nil
	if id == piloted then
		return
	end
	local was = piloted
	piloted = id
	firing = false
	aim_point = nil
	aim_target = nil
	on_target = false
	command = nil
	table.clear(presses)
	failure = nil
	weapon = nil
	if id ~= nil then
		local model = world.get(id)
		local def = if model ~= nil then def_of(model) else nil
		weapon = if def ~= nil then piloting.primary_weapon(def) else nil
		if was == nil then
			selection.set({})
			camera_mod.set_suspended(true)
			ContextActionService:BindActionAtPriority(
				ZOOM_ACTION,
				on_zoom,
				false,
				Enum.ContextActionPriority.High.Value,
				Enum.UserInputType.MouseWheel
			)
			RunService:BindToRenderStep(RENDER_STEP, Enum.RenderPriority.Camera.Value, on_render)
		end
		-- taking a unit from the RTS view looks the way it faces, from its eyes; going from one piloted unit straight to
		-- another, as when a transport takes it aboard, keeps the view where it was, zoomed as it was
		if was == nil then
			if model ~= nil then
				local front = model:GetPivot().ZVector
				facing = math.atan2(front.X, front.Z)
			end
			pitch = 0
			zoom = 0
		end
	else
		RunService:UnbindFromRenderStep(RENDER_STEP)
		ContextActionService:UnbindAction(ZOOM_ACTION)
		UserInputService.MouseBehavior = Enum.MouseBehavior.Default
		UserInputService.MouseIconEnabled = true
		local model = if was ~= nil then world.get(was) else nil
		if model ~= nil then
			camera_mod.look_at(world.position_of(model))
			selection.set({ was :: EntityId })
		end
		camera_mod.set_suspended(false)
	end
	notify()
end

-- P with a unit selected that can be piloted takes the first such one.
local function take_selected()
	if developers.is_developer(local_player) == false then
		return
	end
	for _, id in selection.get() do
		local model = world.get(id)
		local def = if model ~= nil then def_of(model) else nil
		if
			model ~= nil
			and def ~= nil
			and world.is_mine(model)
			and model:GetAttribute "state" == "active"
			and model:GetAttribute "carried" ~= true
			and piloting.can_pilot(def)
		then
			possess:FireServer(id)
			return
		end
	end
end

local function on_input_began(input: InputObject, processed: boolean)
	local id = piloted
	if id == nil then
		if processed == false and input.KeyCode == Enum.KeyCode.P and UserInputService:GetFocusedTextBox() == nil then
			take_selected()
		end
		return
	end
	-- the crosshair is always over the middle of the screen, where whatever GUI is there would swallow the click
	if input.UserInputType == Enum.UserInputType.MouseButton1 then
		firing = true
		send()
		if weapon ~= nil then
			press(tostring(weapon))
		end
		return
	end
	if processed or UserInputService:GetFocusedTextBox() ~= nil then
		return
	end
	local model = world.get(id)
	if input.KeyCode == Enum.KeyCode.P or input.KeyCode == Enum.KeyCode.Escape then
		possess:FireServer(nil)
	elseif model == nil then
		return
	elseif input.KeyCode == Enum.KeyCode.Q then
		local def = def_of(model)
		local manual = if def ~= nil then def.manual_weapon else nil
		local cooldown = model:GetAttribute(piloting.COOLDOWN_ATTRIBUTE)
		if manual == nil or aim_point == nil then
			return
		elseif typeof(cooldown) == "number" and cooldown > 0 then
			fail("Q", "Reloading")
		elseif energy < manual.energy_per_shot then
			fail("Q", "Not enough energy")
		else
			pilot_ability:FireServer(aim_point)
			press "Q"
		end
	elseif input.KeyCode == Enum.KeyCode.X then
		hold(model)
		press "X"
		pilot_say:FireServer "hold"
	elseif input.KeyCode == Enum.KeyCode.C then
		follow(model, id)
		press "C"
		pilot_say:FireServer "follow"
	elseif input.KeyCode == Enum.KeyCode.V then
		if aim_point == nil then
			fail("V", "No target")
		else
			attack(aim_point)
			press "V"
			pilot_say:FireServer "attack"
		end
	elseif input.KeyCode == Enum.KeyCode.J or input.KeyCode == Enum.KeyCode.U then
		-- a transport's: J while its hold is empty, U once it is not, as its tiles show
		local def = def_of(model)
		local cargo_used = model:GetAttribute "cargo_used"
		local carrying = typeof(cargo_used) == "number" and cargo_used > 0
		local loading = input.KeyCode == Enum.KeyCode.J
		if def == nil or def.transport == nil or loading == carrying then
			return
		elseif loading and model:GetAttribute(piloting.LOAD_ATTRIBUTE) ~= true then
			fail("J", "Nothing in reach")
		elseif loading == false and model:GetAttribute(piloting.UNLOAD_ATTRIBUTE) ~= true then
			fail("U", "Too high to unload")
		else
			pilot_cargo:FireServer(if loading then "load" else "unload")
			press(if loading then "J" else "U")
		end
	elseif input.KeyCode == Enum.KeyCode.G then
		local def = def_of(model)
		if def == nil or def.transport ~= nil or def.weight_class == nil then
			return
		elseif model:GetAttribute(piloting.CALL_ATTRIBUTE) ~= true then
			fail("G", "No mount available")
		else
			pilot_cargo:FireServer "call"
			press "G"
		end
	elseif WEAPON_KEYS[input.KeyCode] ~= nil then
		local def = def_of(model)
		local index = WEAPON_KEYS[input.KeyCode]
		if def ~= nil and piloting.can_select(def, index) then
			if index ~= weapon then
				weapon = index
				send()
			end
			press(tostring(index))
		end
	end
end

local function on_input_ended(input: InputObject)
	if piloted ~= nil and input.UserInputType == Enum.UserInputType.MouseButton1 then
		firing = false
		send()
	end
end

local function init()
	UserInputService.InputBegan:Connect(on_input_began)
	UserInputService.InputEnded:Connect(on_input_ended)
	pilot_say.OnClientEvent:Connect(on_said)
	local_player:GetAttributeChangedSignal(piloting.PLAYER_ATTRIBUTE):Connect(follow_attribute)
	follow_attribute()
end

return table.freeze({
	init = init,
	active = active,
	subscribe = subscribe,
	chosen_weapon = chosen_weapon,
	is_on_target = is_on_target,
	last_command = last_command,
	pressed_at = pressed_at,
	last_failure = last_failure,
	army = army,
	current_callouts = current_callouts,
})
