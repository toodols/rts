-- The world behind the lobby's menus: a stretch of battlefield at dusk, with a commander on its pad in front, its army
-- and factories behind it, another army on the far ridge, and a camera drifting slowly around it all. None of it is
-- simulated; it is the game's own art, set out and moved just enough to look alive.
--
-- Everything here is client-side: the lobby place has no world of its own and nobody else sees this one. Units are
-- built from Shared.art the way src/client/art.luau dresses a match's entities, from the same uploaded meshes, and
-- painted the same way (Shared.appearance), but posed by this module rather than by replicated attributes.

local AssetService = game:GetService "AssetService"
local Lighting = game:GetService "Lighting"
local ReplicatedStorage = game:GetService "ReplicatedStorage"
local RunService = game:GetService "RunService"
local Workspace = game:GetService "Workspace"

local art = require(ReplicatedStorage.Shared.art)
local appearance = require(ReplicatedStorage.Shared.appearance)

local TAU = 2 * math.pi

-- Where the scene is built: well above anything the place file itself has in it (a template's baseplate at the
-- origin), so the two never meet. The terrain is filled up to TERRAIN_TOP, but its surface does not land exactly
-- there - it comes out half a voxel higher - so everything is stood on `origin`, the surface as it is found once the
-- terrain is in.
local TERRAIN_TOP = Vector3.new(0, 300, 0)
local origin = CFrame.new(TERRAIN_TOP)
-- Blue is the player's side, nearest the camera; red holds the far ridge.
local BLUE = appearance.team_color(1)
local RED = appearance.team_color(2)
-- See src/client/art.luau: an uploaded mesh comes in half a turn about its own vertical axis.
local UPLOADED_TURN = CFrame.Angles(0, math.pi, 0)
local MATERIAL = Enum.Material.SmoothPlastic
-- A turret sweeping on its own: how far either way, in radians, and how long a sweep takes, in seconds.
local SWEEP = math.rad(35)
local SWEEP_PERIOD = 9
-- How fast the patrol walks, in studs a second, and a leg's swing where its art does not say.
local PATROL_SPEED = 5
local DEFAULT_SWING = math.rad(25)
local DEFAULT_STRIDE = 3
-- How long the camera takes to glide from one framing to the next, in seconds, and how far it drifts, in radians,
-- either way about its framing's centre, once every DRIFT_PERIOD seconds.
local FRAMING_TIME = 1.6
local DRIFT = math.rad(7)
local DRIFT_PERIOD = 40
-- The distant guns: how often one fires, in seconds, at the most and the least.
local FLASH_EVERY = { 0.6, 2.2 }

-- Where each unit stands, relative to origin, in studs on the ground, and which way it faces, in degrees about the
-- vertical (0 faces +Z, toward the camera).
type Placement = {
	def: string,
	team: Color3,
	at: Vector2,
	facing: number,
	-- lifted off the ground, as the commander is onto its pad
	height: number?,
}

-- How tall the commander's pad is, and how wide.
local PAD_HEIGHT = 1
local PAD_WIDTH = 15

local PLACEMENTS: { Placement } = {
	{ def = "commander", team = BLUE, at = Vector2.new(0, 0), facing = 20, height = PAD_HEIGHT },

	{ def = "bot_lab", team = BLUE, at = Vector2.new(-34, -34), facing = 160 },
	{ def = "vehicle_lab", team = BLUE, at = Vector2.new(48, -48), facing = 200 },
	{ def = "guard", team = BLUE, at = Vector2.new(16, -8), facing = 180 },
	{ def = "guard", team = BLUE, at = Vector2.new(-20, -16), facing = 190 },
	{ def = "tiger", team = BLUE, at = Vector2.new(-11, -8), facing = 175 },
	{ def = "tiger", team = BLUE, at = Vector2.new(-5, -15), facing = 185 },
	{ def = "brute", team = BLUE, at = Vector2.new(7, -14), facing = 170 },
	{ def = "mammoth", team = BLUE, at = Vector2.new(22, -22), facing = 195 },
	{ def = "sumo", team = BLUE, at = Vector2.new(-24, -26), facing = 165 },
	-- off to the side, so the commander stands out against open ground rather than against it
	{ def = "juggernaut", team = BLUE, at = Vector2.new(32, -66), facing = 200 },
	{ def = "wind_turbine", team = BLUE, at = Vector2.new(44, -18), facing = 0 },
	{ def = "wind_turbine", team = BLUE, at = Vector2.new(52, -32), facing = 0 },
	{ def = "solar_collector", team = BLUE, at = Vector2.new(40, -4), facing = 30 },
	{ def = "metal_extractor", team = BLUE, at = Vector2.new(-42, -8), facing = 0 },

	{ def = "juggernaut", team = RED, at = Vector2.new(-14, -150), facing = 10 },
	{ def = "shiva", team = RED, at = Vector2.new(22, -160), facing = -10 },
	{ def = "tiger", team = RED, at = Vector2.new(-34, -138), facing = 0 },
	{ def = "tiger", team = RED, at = Vector2.new(4, -134), facing = 5 },
	{ def = "tiger", team = RED, at = Vector2.new(38, -140), facing = -5 },
	{ def = "guard", team = RED, at = Vector2.new(-54, -150), facing = 15 },
	{ def = "guard", team = RED, at = Vector2.new(58, -156), facing = -15 },
	{ def = "advanced_bot_lab", team = RED, at = Vector2.new(0, -184), facing = 0 },
}

-- The patrol: bots walking back and forth across the base behind the commander, between these two points.
local PATROL = {
	def = "grunt",
	from = Vector2.new(-38, -22),
	to = Vector2.new(34, -28),
	-- how far apart along the line they walk, in studs
	spacing = 5,
	count = 4,
}

-- Aircraft circling over the base: around this point, this far out and this high, a turn every `period` seconds.
-- Every circle stays well in front of the camera, which a wing passing overhead would otherwise fill.
local ORBITS = {
	{ def = "valiant", centre = Vector2.new(0, -70), radius = 50, height = 34, period = 26, phase = 0 },
	{ def = "valiant", centre = Vector2.new(0, -70), radius = 50, height = 36, period = 26, phase = 0.06 },
	{
		def = "construction_aircraft",
		centre = Vector2.new(-20, -50),
		radius = 22,
		height = 22,
		period = 18,
		phase = 0.5,
	},
}

-- Where the camera looks from and at, relative to origin, for each screen. In the browser the commander stands on
-- the right, clear of the list on the left; in a lobby the panels cover the middle, so the camera pulls up and back
-- over the whole field and the scene is only a setting.
type Framing = { eye: Vector3, focus: Vector3, fov: number }

local FRAMINGS: { [string]: Framing } = {
	browser = { eye = Vector3.new(-4, 5.5, 20), focus = Vector3.new(-8, 4.5, -2), fov = 50 },
	room = { eye = Vector3.new(30, 42, 70), focus = Vector3.new(0, 0, -50), fov = 55 },
}

-- One piece of a unit's art that moves, and the meshes on it.
type Group = {
	def: art.Group,
	pivot: CFrame,
	parts: { { part: MeshPart, offset: CFrame } },
	angle: number,
	-- a turret's sweep, offset per unit so they do not all swing together
	phase: number,
}

type Unit = {
	model: Model,
	groups: { Group },
	origin: CFrame,
	-- how far it has walked, in studs, which its legs keep pace with
	walked: number,
}

local units: { Unit } = {}
local patrol: { Unit } = {}
local aircraft: { { unit: Unit, orbit: typeof(ORBITS[1]) } } = {}
local folder: Folder? = nil
local view = "browser"
local framing_from: CFrame? = nil
local framing_changed = 0
local next_flash = 0

local function vector(values: { number }): Vector3
	return Vector3.new(values[1], values[2], values[3])
end

-- A unit of `def_name` in `team`'s colours, standing at `at`, or nil if it has no art or none of it could be
-- fetched. It yields while its meshes are fetched, all at once.
local function build_unit(def_name: string, team: Color3, at: CFrame, parent: Instance): Unit?
	local data = art.get(def_name)
	if data == nil then
		return nil
	end
	local model = Instance.new "Model"
	model.Name = def_name

	local by_name: { [string]: Group } = {}
	local groups: { Group } = {}
	for name, group_def in data.groups do
		local group: Group = {
			def = group_def,
			pivot = CFrame.new(vector(group_def.pivot)),
			parts = {},
			angle = 0,
			phase = math.random() * TAU,
		}
		by_name[name] = group
		table.insert(groups, group)
	end

	local remaining = #data.parts
	local waiting = coroutine.running()
	for _, part in data.parts do
		task.spawn(function()
			-- a mesh not uploaded yet would need EditableMesh, which the lobby does without: it is left out
			if part.mesh ~= nil then
				local ok, mesh = pcall(function()
					return AssetService:CreateMeshPartAsync(
						Content.fromUri(part.mesh :: string),
						{ CollisionFidelity = Enum.CollisionFidelity.Box }
					)
				end)
				if ok then
					local color = Color3.new(part.color[1], part.color[2], part.color[3])
					mesh.Anchored = true
					mesh.CanCollide = false
					mesh.CanTouch = false
					mesh.CanQuery = false
					mesh.CastShadow = true
					mesh.Size = vector(part.size)
					mesh.Material = if part.neon == true then Enum.Material.Neon else MATERIAL
					mesh.Color = if part.team == true then appearance.team_tint(color, team) else color
					mesh.Parent = model
					table.insert(by_name[part.group].parts, {
						part = mesh,
						offset = CFrame.new(vector(part.offset)) * UPLOADED_TURN,
					})
				end
			end
			remaining -= 1
			if remaining == 0 and coroutine.status(waiting) == "suspended" then
				task.spawn(waiting)
			end
		end)
	end
	if remaining > 0 then
		coroutine.yield()
	end

	local unit: Unit = { model = model, groups = groups, origin = at, walked = 0 }
	model.Parent = parent
	return unit
end

-- Puts every piece of `unit` where its group's pivot and angle say (as src/client/art.luau's `place` does).
local function place(unit: Unit)
	for _, group in unit.groups do
		local kind = group.def.kind
		local turn: CFrame
		if kind == "spin" then
			turn = CFrame.fromAxisAngle(vector(group.def.axis or { 0, 1, 0 }), group.angle)
		elseif kind == "turret" or kind == "work" then
			turn = CFrame.Angles(0, group.angle, 0)
		elseif kind == "leg" or kind == "wheel" or kind == "hatch" then
			turn = CFrame.fromAxisAngle(vector(group.def.axis or { 1, 0, 0 }), group.angle)
		else
			turn = CFrame.identity
		end
		local frame = unit.origin * group.pivot * turn
		for _, piece in group.parts do
			piece.part.CFrame = frame * piece.offset
		end
	end
end

-- Moves each piece that moves on its own: turrets sweep, a commander looks about, rotors and turbines spin, and legs
-- keep pace with however far the unit has walked.
local function animate(unit: Unit, now: number, dt: number)
	for _, group in unit.groups do
		local kind = group.def.kind
		if kind == "turret" or kind == "work" then
			group.angle = SWEEP * math.sin(TAU * now / SWEEP_PERIOD + group.phase)
		elseif kind == "spin" then
			group.angle = (group.angle + (group.def.speed or 0) * dt) % TAU
		elseif kind == "leg" then
			local stride = group.def.stride or DEFAULT_STRIDE
			group.angle = (group.def.swing or DEFAULT_SWING)
				* math.sin(TAU * (unit.walked / stride + (group.def.phase or 0)))
		elseif kind == "wheel" then
			group.angle = (unit.walked / (group.def.radius or 0.5)) % TAU
		end
	end
end

local function ground(at: Vector2, facing: number, height: number?): CFrame
	return origin * CFrame.new(at.X, height or 0, at.Y) * CFrame.Angles(0, math.rad(facing), 0)
end

-- The ground: a plain of terrain with ridges around it, and the commander's pad on it. Sets `origin` to where the
-- terrain's surface really is, so it has to run before anything is stood on it.
local function build_ground(parent: Instance)
	local terrain = Workspace.Terrain
	local base = TERRAIN_TOP
	terrain:SetMaterialColor(Enum.Material.Ground, Color3.fromRGB(104, 92, 78))
	terrain:SetMaterialColor(Enum.Material.Rock, Color3.fromRGB(112, 104, 98))
	terrain:SetMaterialColor(Enum.Material.Basalt, Color3.fromRGB(70, 66, 68))
	terrain:FillBlock(CFrame.new(base - Vector3.new(0, 6, 60)), Vector3.new(720, 12, 720), Enum.Material.Ground)
	local only_terrain = RaycastParams.new()
	only_terrain.FilterType = Enum.RaycastFilterType.Include
	only_terrain.FilterDescendantsInstances = { terrain }
	local surface = Workspace:Raycast(base + Vector3.new(0, 20, 0), Vector3.new(0, -40, 0), only_terrain)
	if surface ~= nil then
		origin = CFrame.new(surface.Position)
	end
	-- a scatter of rock and ridges, the same every time
	local random = Random.new(7)
	for _ = 1, 38 do
		-- round the sides and the far side only: on the camera's side a ridge would stand between it and the base
		local angle = random:NextNumber(0.9 * math.pi, 2.1 * math.pi)
		-- and beyond the far army, which stands within about 115 of the middle of the ring
		local distance = random:NextNumber(130, 280)
		local centre = base + Vector3.new(math.cos(angle) * distance, -8, math.sin(angle) * distance - 70)
		terrain:FillBall(centre, random:NextNumber(16, 38), Enum.Material.Rock)
	end
	for _ = 1, 24 do
		local centre = base + Vector3.new(random:NextNumber(-70, 70), -1.5, random:NextNumber(-120, 40))
		-- keep clear of the pad and the ground the units stand on
		if Vector2.new(centre.X - base.X, centre.Z - base.Z).Magnitude > 14 then
			terrain:FillBall(centre, random:NextNumber(1.2, 2.6), Enum.Material.Basalt)
		end
	end

	local pad = Instance.new "Part"
	pad.Name = "Pad"
	pad.Shape = Enum.PartType.Cylinder
	pad.Anchored = true
	pad.CanCollide = false
	pad.Material = Enum.Material.DiamondPlate
	pad.Color = Color3.fromRGB(70, 80, 92)
	pad.Size = Vector3.new(PAD_HEIGHT, PAD_WIDTH, PAD_WIDTH)
	pad.CFrame = origin * CFrame.new(0, PAD_HEIGHT / 2, 0) * CFrame.Angles(0, 0, math.pi / 2)
	pad.Parent = parent

	-- a lit band around the pad's side, a little wider than it, so it shows as an edge
	local ring = Instance.new "Part"
	ring.Name = "PadRing"
	ring.Shape = Enum.PartType.Cylinder
	ring.Anchored = true
	ring.CanCollide = false
	ring.Material = Enum.Material.Neon
	ring.Color = Color3.fromRGB(96, 210, 242)
	ring.Size = Vector3.new(0.3, PAD_WIDTH + 0.5, PAD_WIDTH + 0.5)
	ring.CFrame = origin * CFrame.new(0, PAD_HEIGHT * 0.6, 0) * CFrame.Angles(0, 0, math.pi / 2)
	ring.Parent = parent

	local glow = Instance.new "PointLight"
	glow.Color = ring.Color
	glow.Range = 16
	glow.Brightness = 1.2
	glow.Parent = ring
end

-- Late afternoon going on dusk: a low warm sun, a rose and violet sky, and haze that swallows the horizon. Any later
-- and the plain goes black, which the menus over it then have nothing to stand out from.
local function light()
	Lighting.ClockTime = 16.9
	Lighting.GeographicLatitude = 30
	Lighting.Brightness = 3
	Lighting.Ambient = Color3.fromRGB(70, 74, 88)
	Lighting.OutdoorAmbient = Color3.fromRGB(120, 118, 132)
	Lighting.EnvironmentDiffuseScale = 0.5
	Lighting.EnvironmentSpecularScale = 0.6
	Lighting.ExposureCompensation = 0.35
	Lighting.GlobalShadows = true

	local function effect(class: string): Instance
		local found = Lighting:FindFirstChildOfClass(class)
		if found == nil then
			found = Instance.new(class)
			found.Parent = Lighting
		end
		return found :: Instance
	end

	local atmosphere = effect "Atmosphere" :: Atmosphere
	atmosphere.Density = 0.38
	atmosphere.Offset = 0.1
	atmosphere.Haze = 2.2
	atmosphere.Glare = 0.6
	atmosphere.Color = Color3.fromRGB(196, 150, 120)
	atmosphere.Decay = Color3.fromRGB(92, 84, 110)

	local bloom = effect "BloomEffect" :: BloomEffect
	bloom.Intensity = 0.7
	bloom.Size = 28
	bloom.Threshold = 1.4

	local rays = effect "SunRaysEffect" :: SunRaysEffect
	rays.Intensity = 0.06
	rays.Spread = 0.6

	local grade = effect "ColorCorrectionEffect" :: ColorCorrectionEffect
	grade.Contrast = 0.12
	grade.Saturation = -0.05
	grade.TintColor = Color3.fromRGB(255, 244, 236)
end

-- A gun firing somewhere out on the field: a flash and a burst of light that fade in a moment.
local function flash(parent: Instance)
	local random = Random.new()
	local position = origin.Position
		+ Vector3.new(random:NextNumber(-90, 90), random:NextNumber(0.5, 3), random:NextNumber(-150, -70))
	local burst = Instance.new "Part"
	burst.Shape = Enum.PartType.Ball
	burst.Anchored = true
	burst.CanCollide = false
	burst.CanQuery = false
	burst.CastShadow = false
	burst.Material = Enum.Material.Neon
	burst.Color = if random:NextNumber() < 0.5 then Color3.fromRGB(255, 170, 80) else Color3.fromRGB(255, 220, 140)
	burst.Size = Vector3.one * random:NextNumber(2, 4.5)
	burst.Position = position
	local glow = Instance.new "PointLight"
	glow.Color = burst.Color
	glow.Range = 30
	glow.Brightness = 4
	glow.Parent = burst
	burst.Parent = parent

	local started = os.clock()
	local connection: RBXScriptConnection
	connection = RunService.RenderStepped:Connect(function()
		local t = (os.clock() - started) / 0.7
		if t >= 1 then
			connection:Disconnect()
			burst:Destroy()
			return
		end
		burst.Transparency = t
		burst.Size = Vector3.one * (burst.Size.X + 0.15)
		glow.Brightness = 4 * (1 - t)
	end)
end

-- The camera's framing for the current screen, drifting a little either way about its centre.
local function target_framing(now: number): CFrame
	local framing = FRAMINGS[view] or FRAMINGS.browser
	local focus = origin * framing.focus
	local eye = origin * framing.eye
	local drift = DRIFT * math.sin(TAU * now / DRIFT_PERIOD)
	local offset = CFrame.Angles(0, drift, 0) * (eye - focus)
	return CFrame.lookAt(focus + offset, focus)
end

local function step(dt: number)
	local now = os.clock()
	local camera = Workspace.CurrentCamera
	if camera ~= nil then
		camera.CameraType = Enum.CameraType.Scriptable
		local target = target_framing(now)
		local framing = FRAMINGS[view] or FRAMINGS.browser
		if framing_from ~= nil then
			local t = math.clamp((now - framing_changed) / FRAMING_TIME, 0, 1)
			-- eased out, so it settles rather than stops
			local eased = 1 - (1 - t) ^ 3
			camera.CFrame = (framing_from :: CFrame):Lerp(target, eased)
			camera.FieldOfView += (framing.fov - camera.FieldOfView) * eased
			if t >= 1 then
				framing_from = nil
			end
		else
			camera.CFrame = target
			camera.FieldOfView = framing.fov
		end
	end

	for _, unit in units do
		animate(unit, now, dt)
		place(unit)
	end

	-- the patrol walks from one end to the other and back, turning round at each end
	local span = (PATROL.to - PATROL.from).Magnitude
	for index, unit in patrol do
		local along = (now * PATROL_SPEED + index * PATROL.spacing) % (span * 2)
		local outward = along < span
		local distance = if outward then along else span * 2 - along
		local at = PATROL.from:Lerp(PATROL.to, distance / span)
		local heading = if outward then PATROL.to - PATROL.from else PATROL.from - PATROL.to
		unit.origin = origin * CFrame.new(at.X, 0, at.Y) * CFrame.Angles(0, math.atan2(heading.X, heading.Y), 0)
		unit.walked += PATROL_SPEED * dt
		animate(unit, now, dt)
		place(unit)
	end

	for _, flying in aircraft do
		local orbit = flying.orbit
		local angle = TAU * (now / orbit.period + orbit.phase)
		local at = orbit.centre + Vector2.new(math.cos(angle), math.sin(angle)) * orbit.radius
		-- facing along the circle, banked into the turn
		local heading = Vector2.new(-math.sin(angle), math.cos(angle))
		flying.unit.origin = origin
			* CFrame.new(at.X, orbit.height, at.Y)
			* CFrame.Angles(0, math.atan2(heading.X, heading.Y), 0)
			* CFrame.Angles(0, 0, math.rad(-18))
		animate(flying.unit, now, dt)
		place(flying.unit)
	end

	if now >= next_flash and folder ~= nil then
		next_flash = now + FLASH_EVERY[1] + math.random() * (FLASH_EVERY[2] - FLASH_EVERY[1])
		flash(folder :: Folder)
	end
end

-- Which screen the lobby is showing, "browser" or "room"; the camera glides to that screen's framing.
local function set_view(name: string)
	if name == view then
		return
	end
	view = name
	local camera = Workspace.CurrentCamera
	framing_from = if camera ~= nil then camera.CFrame else nil
	framing_changed = os.clock()
end

-- Sets the scene up and starts it moving. The camera is framed at once; the units appear as their meshes arrive.
local function init()
	local root = Instance.new "Folder"
	root.Name = "LobbyScene"
	root.Parent = Workspace
	folder = root

	light()
	build_ground(root)
	RunService:BindToRenderStep("LobbyScene", Enum.RenderPriority.Camera.Value + 1, step)

	for _, placement in PLACEMENTS do
		task.spawn(function()
			local unit = build_unit(
				placement.def,
				placement.team,
				ground(placement.at, placement.facing, placement.height),
				root
			)
			if unit ~= nil then
				place(unit)
				table.insert(units, unit)
			end
		end)
	end
	for _ = 1, PATROL.count do
		task.spawn(function()
			local unit = build_unit(PATROL.def, BLUE, origin, root)
			if unit ~= nil then
				table.insert(patrol, unit)
			end
		end)
	end
	for _, orbit in ORBITS do
		task.spawn(function()
			local unit = build_unit(orbit.def, BLUE, origin, root)
			if unit ~= nil then
				table.insert(aircraft, { unit = unit, orbit = orbit })
			end
		end)
	end
end

return table.freeze({
	init = init,
	set_view = set_view,
})
