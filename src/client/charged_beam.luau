-- The dressing of a heavy beam weapon (`charged_beam` on its def's weapon): the Sharpshooter's, the Starlight's and
-- the Pulsar's. It is only drawn.
--
-- Its muzzle glows as the weapon charges up between shots (the `reload_progress` the server replicates): a core that
-- swells and brightens, and rings round the barrel behind it that light one after another as the charge builds. Full,
-- it breathes, and a ripple runs down its rings to the muzzle. Firing spends the charge in a flash and it goes dark.
--
-- Its shot (`draw`) is more than a line: a white-hot core in the beam, a sheath of glow round it that throbs for as
-- long as the beam burns, rings rippling out from it down its length, and a flash at each end, and it narrows away to
-- nothing rather than just fading.

local Debris = game:GetService "Debris"
local ReplicatedStorage = game:GetService "ReplicatedStorage"
local RunService = game:GetService "RunService"
local Workspace = game:GetService "Workspace"

local config = require(ReplicatedStorage.Shared.config)
local types = require(ReplicatedStorage.Shared.types)

local TAU = 2 * math.pi
local WHITE = Color3.new(1, 1, 1)

-- A laser's colour when its weapon does not say: its team's.
local TEAM_BEAM_COLORS: { [number]: Color3 } = {
	[1] = Color3.fromRGB(140, 200, 255),
	[2] = Color3.fromRGB(255, 150, 130),
	[config.SCAVENGER_TEAM] = Color3.fromRGB(206, 130, 255),
}

-- The muzzle: its core's width against the beam's, and the least it is; how many rings sit round the barrel behind
-- it, how far apart in muzzle widths, and how wide against the core; how fast a full charge breathes, in breaths a
-- second, and by how much; how long the flash of firing lasts, in seconds, and how big it gets against the core.
local MUZZLE_WIDTH = 1.8
local MUZZLE_LEAST = 0.45
local MUZZLE_RINGS = 3
local MUZZLE_RING_SPACING = 0.45
local MUZZLE_RING_WIDTH = 0.8
local BREATH_RATE = 1.2
local BREATH_DEPTH = 0.18
local FLASH_TIME = 0.3
local FLASH_SIZE = 2.6
-- A drop in the charge this big is a shot rather than an update landing out of step.
local FIRED_DROP = 0.4
-- How quickly the glow follows the charge, which only arrives with each update, in seconds.
local CHARGE_SMOOTHING = 0.08

-- The shot: its core's width against the beam's, and its sheath's; how many times a second the sheath throbs; the
-- share of the beam's time spent narrowing away at the end; rings along it, how far apart in beam widths, within
-- bounds on how many, how long each takes to ripple out, and how wide it gets, against the beam; how long the ripple
-- takes to run from the muzzle to the far end; the flashes at the muzzle and the far end, how long they last and how
-- big against the beam; the least time the dressing lasts, however short the beam, and the least width the sheath,
-- rings and flashes are drawn for, however thin the beam (the Sharpshooter's is a hairline), so that they are seen.
local SHOT_CORE = 0.45
local SHOT_SHEATH = 2.4
local SHOT_THROB_RATE = 7
local SHOT_NARROW_SHARE = 0.4
local SHOT_RING_SPACING = 7
local SHOT_RINGS_LEAST = 3
local SHOT_RINGS_MOST = 14
local SHOT_RING_TIME = 0.4
local SHOT_RING_WIDTH = 4.5
local SHOT_RIPPLE_TIME = 0.12
local SHOT_FLASH_TIME = 0.35
local SHOT_MUZZLE_FLASH = 4
local SHOT_IMPACT_FLASH = 5
local SHOT_LEAST_TIME = 0.45
local SHOT_LEAST_GLOW = 0.5

-- The colour a laser of a weapon that says `color`, fired by `team`, is drawn in.
local function color_of(color: Color3?, team: number?): Color3
	if color ~= nil then
		return color
	end
	local by_team = if team ~= nil then TEAM_BEAM_COLORS[team] else nil
	return by_team or WHITE
end

local function effects_folder(): Instance
	return Workspace:FindFirstChild "Effects" or Workspace
end

local function glowing_part(name: string, shape: Enum.PartType, color: Color3): Part
	local part = Instance.new "Part"
	part.Name = name
	part.Shape = shape
	part.Anchored = true
	part.CanCollide = false
	part.CanQuery = false
	part.CanTouch = false
	part.CastShadow = false
	part.Material = Enum.Material.Neon
	part.Color = color
	return part
end

-- A flat ring round `adornee`'s Z axis, `at` along it; its size is set by whoever animates it.
local function ring(adornee: BasePart, at: CFrame, color: Color3): CylinderHandleAdornment
	local handle = Instance.new "CylinderHandleAdornment"
	handle.Name = "Ring"
	handle.Adornee = adornee
	handle.CFrame = at
	handle.Color3 = color
	handle.Height = 0.05
	handle.Radius = 0.1
	handle.InnerRadius = 0.05
	handle.AlwaysOnTop = false
	handle.ZIndex = 1
	handle.Transparency = 1
	handle.Parent = adornee
	return handle
end

-- Sets a ring `width` across, its band and its depth each a quarter of its radius.
local function size_ring(handle: CylinderHandleAdornment, width: number)
	local radius = math.max(width / 2, 0.02)
	handle.Radius = radius
	handle.InnerRadius = radius * 0.75
	handle.Height = radius * 0.25
end

----------------------------------------------------------------------------------------------------------------------
-- The muzzle

type Muzzle = {
	folder: Folder,
	core: Part,
	light: PointLight,
	rings: { CylinderHandleAdornment },
	-- how wide the core is at full charge
	width: number,
	color: Color3,
	-- the charge drawn now, which follows the replicated one smoothly, and the last replicated one seen
	shown: number,
	seen: number?,
	-- when the last shot's flash started (os.clock()), if it is still going
	flashed_at: number?,
}

local muzzles: { [Model]: Muzzle } = {}

local function make_muzzle(parent: Instance, weapon: types.Weapon, team: number?): Muzzle
	local color = color_of(weapon.beam_color, team)
	local width = math.max((weapon.beam_thickness or 0.25) * MUZZLE_WIDTH, MUZZLE_LEAST)
	local folder = Instance.new "Folder"
	folder.Name = "ChargeGlow"
	local core = glowing_part("Charge", Enum.PartType.Ball, color:Lerp(WHITE, 0.2))
	core.Size = Vector3.one * width
	core.Transparency = 1
	core.Parent = folder
	local light = Instance.new "PointLight"
	light.Color = color
	light.Brightness = 0
	light.Range = width * 6
	light.Shadows = false
	light.Parent = core
	local rings: { CylinderHandleAdornment } = {}
	for index = 1, MUZZLE_RINGS do
		-- behind the muzzle, down the barrel: the core faces along it, so that is its +Z
		local at = CFrame.new(0, 0, index * width * MUZZLE_RING_SPACING)
		table.insert(rings, ring(core, at, color))
	end
	folder.Parent = parent
	return {
		folder = folder,
		core = core,
		light = light,
		rings = rings,
		width = width,
		color = color,
		shown = 1,
		seen = nil,
		flashed_at = nil,
	}
end

local function forget(model: Model)
	local muzzle = muzzles[model]
	if muzzle ~= nil then
		muzzles[model] = nil
		muzzle.folder:Destroy()
	end
end

-- Draws the muzzle of `model`'s charged beam `weapon` at `at`, a frame facing along the barrel, for this frame;
-- `showing` is false while it is not a finished, working thing (a blueprint, a wreck), which hides it. The glow is
-- kept under `parent`, the model's art.
local function step_muzzle(
	model: Model,
	weapon: types.Weapon,
	at: CFrame,
	showing: boolean,
	parent: Instance,
	dt: number
)
	local muzzle = muzzles[model]
	if muzzle == nil then
		local team = model:GetAttribute "team"
		muzzle = make_muzzle(parent, weapon, if typeof(team) == "number" then team else nil)
		muzzles[model] = muzzle
	end
	local now = os.clock()
	local progress = model:GetAttribute "reload_progress"
	local charge = if showing and typeof(progress) == "number" then progress elseif showing then 1 else 0
	if muzzle.seen ~= nil and charge < muzzle.seen - FIRED_DROP then
		muzzle.flashed_at = now
		muzzle.shown = charge
	end
	muzzle.seen = charge
	muzzle.shown += (charge - muzzle.shown) * (1 - math.exp(-dt / CHARGE_SMOOTHING))
	local shown = muzzle.shown

	-- charging, the core grows with the square of the charge, so it hangs back and then swells as it nears full
	local scale = 0.25 + 0.75 * shown * shown
	local brightness = shown
	local full = charge >= 0.99
	local phase = now * BREATH_RATE * TAU
	if full then
		scale *= 1 + BREATH_DEPTH * math.sin(phase)
	end
	-- the flash of the shot, a burst of white that shrinks back to nothing
	local flash = 0
	if muzzle.flashed_at ~= nil then
		local age = (now - muzzle.flashed_at) / FLASH_TIME
		if age >= 1 then
			muzzle.flashed_at = nil
		else
			flash = 1 - age
		end
	end
	local core = muzzle.core
	if showing == false or (shown < 0.02 and flash == 0) then
		core.Transparency = 1
		muzzle.light.Brightness = 0
		for _, handle in muzzle.rings do
			handle.Transparency = 1
		end
		core.CFrame = at
		return
	end
	local size = muzzle.width * math.max(scale, flash * FLASH_SIZE)
	core.Size = Vector3.one * size
	core.CFrame = at
	core.Color = muzzle.color:Lerp(WHITE, 0.2 + 0.7 * flash)
	core.Transparency = 1 - math.max(0.15 + 0.75 * brightness, flash)
	muzzle.light.Brightness = 3 * math.max(brightness, flash * 2)

	-- ring `index` lights as the charge passes its share, the one nearest the muzzle last; full, a ripple runs down
	-- them toward the muzzle
	for index, handle in muzzle.rings do
		local from_muzzle = MUZZLE_RINGS - index + 1
		local lit = math.clamp((shown - (index - 1) / MUZZLE_RINGS) * MUZZLE_RINGS, 0, 1)
		local width = muzzle.width * MUZZLE_RING_WIDTH
		if full then
			width *= 1 + 0.2 * math.max(0, math.sin(phase * 2 + from_muzzle * 1.3))
		end
		size_ring(handle, width)
		handle.Transparency = 1 - 0.85 * lit
	end
end

----------------------------------------------------------------------------------------------------------------------
-- The shot

-- Draws a charged beam's shot from `from` to `to`, `thickness` across, burning for `lifetime` seconds.
local function draw(from: Vector3, to: Vector3, color: Color3, thickness: number, lifetime: number)
	local offset = to - from
	local length = offset.Magnitude
	if length < 1e-3 then
		return
	end
	local total = math.max(lifetime, SHOT_LEAST_TIME)
	local glow = math.max(thickness, SHOT_LEAST_GLOW)
	local folder = Instance.new "Folder"
	folder.Name = "ChargedBeam"
	-- a cylinder's axis is its X, turned here onto the line
	local along = CFrame.lookAt(from + offset / 2, to)
	local lying = along * CFrame.Angles(0, math.pi / 2, 0)
	local hot = color:Lerp(WHITE, 0.75)

	local core = glowing_part("Core", Enum.PartType.Cylinder, hot)
	core.CFrame = lying
	core.Parent = folder
	local body = glowing_part("Beam", Enum.PartType.Cylinder, color)
	body.CFrame = lying
	body.Parent = folder
	local sheath = glowing_part("Sheath", Enum.PartType.Cylinder, color)
	sheath.CFrame = lying
	sheath.Parent = folder
	-- rings hang off a part that faces down the line, whose Z is the line
	local spine = glowing_part("Spine", Enum.PartType.Block, color)
	spine.Size = Vector3.one * 0.05
	spine.Transparency = 1
	spine.CFrame = along
	spine.Parent = folder

	local count = math.clamp(math.round(length / (glow * SHOT_RING_SPACING + 4)), SHOT_RINGS_LEAST, SHOT_RINGS_MOST)
	local rings: { { handle: CylinderHandleAdornment, delay: number } } = {}
	for index = 1, count do
		local share = (index - 0.5) / count
		-- the line runs from the spine's middle toward -Z
		local at = CFrame.new(0, 0, length * (0.5 - share))
		table.insert(rings, { handle = ring(spine, at, hot), delay = share * SHOT_RIPPLE_TIME })
	end

	local muzzle_flash = glowing_part("MuzzleFlash", Enum.PartType.Ball, hot)
	muzzle_flash.CFrame = CFrame.new(from)
	muzzle_flash.Parent = folder
	local impact = glowing_part("Impact", Enum.PartType.Ball, hot)
	impact.CFrame = CFrame.new(to)
	impact.Parent = folder
	local light = Instance.new "PointLight"
	light.Color = color
	light.Range = glow * 10 + 8
	light.Shadows = false
	light.Parent = impact

	folder.Parent = effects_folder()
	Debris:AddItem(folder, total + 0.1)

	local started = os.clock()
	local connection: RBXScriptConnection
	local function frame()
		local age = os.clock() - started
		if age >= total or folder.Parent == nil then
			connection:Disconnect()
			folder:Destroy()
			return
		end
		-- the beam's width against its own: it overshoots as it fires, throbs while it burns, then narrows away
		local scale = 0
		if age < lifetime then
			local progress = age / lifetime
			local swell = 1 + 0.4 * math.exp(-age * 25)
			local narrowing = math.clamp((1 - progress) / SHOT_NARROW_SHARE, 0, 1)
			scale = swell * narrowing
		end
		local throb = 1 + 0.3 * math.sin(age * SHOT_THROB_RATE * TAU)
		local core_width, sheath_width = thickness * scale * SHOT_CORE, glow * scale * SHOT_SHEATH * throb
		core.Size = Vector3.new(length, core_width, core_width)
		body.Size = Vector3.new(length, thickness * scale, thickness * scale)
		sheath.Size = Vector3.new(length, sheath_width, sheath_width)
		local hidden = scale <= 1e-3
		core.Transparency = if hidden then 1 else 0
		body.Transparency = if hidden then 1 else 0.15
		sheath.Transparency = if hidden then 1 else 0.82 - 0.08 * throb

		for _, entry in rings do
			local ring_age = (age - entry.delay) / SHOT_RING_TIME
			if ring_age < 0 or ring_age >= 1 then
				entry.handle.Transparency = 1
			else
				size_ring(entry.handle, glow * (1 + (SHOT_RING_WIDTH - 1) * math.sqrt(ring_age)))
				entry.handle.Transparency = 0.2 + 0.8 * ring_age
			end
		end

		local flash_age = math.clamp(age / SHOT_FLASH_TIME, 0, 1)
		local fade = 1 - flash_age
		muzzle_flash.Size = Vector3.one * glow * SHOT_MUZZLE_FLASH * (0.5 + flash_age)
		muzzle_flash.Transparency = 1 - fade * 0.9
		impact.Size = Vector3.one * glow * SHOT_IMPACT_FLASH * (0.4 + 0.6 * flash_age)
		impact.Transparency = 1 - fade * 0.9
		light.Brightness = 4 * math.max(fade, if hidden then 0 else 0.5)
	end
	connection = RunService.Heartbeat:Connect(frame)
	frame()
end

return table.freeze({
	color_of = color_of,
	step_muzzle = step_muzzle,
	forget = forget,
	draw = draw,
})
