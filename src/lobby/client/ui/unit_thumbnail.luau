-- A def's own art in a ViewportFrame, for the encyclopedia: a still picture on each card and a large one, turning
-- slowly, on an open entry. The meshes are the uploaded ones in Shared.art, fetched the way the lobby's scene fetches
-- its units (scene.luau), with their team parts in the player's own blue.
--
-- Each def's model is built once, the first time any picture of it is asked for, and every picture is a copy. A mesh
-- that will not fetch is left out rather than losing the whole picture, as the scene does, and one not uploaded yet
-- (which would need EditableMesh) is left out too. A def with no art, or none that fetched, shows a flat icon for what
-- it does instead (Shared.ui_art, as the HUD's weapon rows have), and `fallback` as text while that icon is missing.

local AssetService = game:GetService "AssetService"
local ReplicatedStorage = game:GetService "ReplicatedStorage"
local RunService = game:GetService "RunService"

local React = require(ReplicatedStorage.Packages.react)

local appearance = require(ReplicatedStorage.Shared.appearance)
local art = require(ReplicatedStorage.Shared.art)
local unit_defs = require(ReplicatedStorage.Shared.unit_defs)
local unit_facts = require(ReplicatedStorage.Shared.unit_facts)

local art_icon = require(ReplicatedStorage.Client.ui.art_icon)

local ArtIcon = art_icon.ArtIcon

-- The player's side, as the scene paints it.
local TEAM = appearance.team_color(1)
-- How much of the def's own colour its team parts keep. A match leans them only partway to the team
-- (appearance.team_tint), which on a pale def like the commander reads as grey; here they are the player's blue with
-- a touch of the def's colour, so every picture reads as one of theirs.
local TEAM_KEEPS_DEF = 0.2
-- See src/client/art.luau: an uploaded mesh comes in half a turn about its own vertical axis.
local UPLOADED_TURN = CFrame.Angles(0, math.pi, 0)
local MATERIAL = Enum.Material.SmoothPlastic
-- From ahead and to the right, a little from above, through a narrow lens so it is not distorted, as the build menu's
-- pictures are (Client.ui.unit_icon). What fills the frame is FIT of it, leaving a margin.
local FOV = 30
local YAW = math.rad(35)
local PITCH = math.rad(24)
local FIT = 0.9

type Status = "building" | "ready" | "none"

local templates: { [string]: Model } = {}
local status: { [string]: Status } = {}
local waiting: { [string]: { () -> () } } = {}

local function vector(values: { number }): Vector3
	return Vector3.new(values[1], values[2], values[3])
end

local function finish(def_name: string, model: Model?)
	if model ~= nil then
		templates[def_name] = model
		status[def_name] = "ready"
	else
		status[def_name] = "none"
	end
	local callbacks = waiting[def_name]
	waiting[def_name] = nil
	for _, callback in callbacks or {} do
		task.spawn(callback)
	end
end

-- Starts building `def_name`'s model, once; its meshes are fetched all at once.
local function build(def_name: string)
	if status[def_name] ~= nil then
		return
	end
	local data = art.get(def_name)
	if data == nil then
		status[def_name] = "none"
		return
	end
	status[def_name] = "building"
	task.spawn(function()
		local model = Instance.new "Model"
		model.Name = def_name
		local def_color = unit_defs.get(def_name).color
		local fetched = 0
		local remaining = #data.parts
		local thread = coroutine.running()
		for _, part in data.parts do
			task.spawn(function()
				local uri = part.mesh
				if uri ~= nil then
					local ok, mesh = pcall(function()
						return AssetService:CreateMeshPartAsync(
							Content.fromUri(uri),
							{ CollisionFidelity = Enum.CollisionFidelity.Box }
						)
					end)
					if ok then
						local group = data.groups[part.group]
						local pivot = if group ~= nil then CFrame.new(vector(group.pivot)) else CFrame.identity
						mesh.Name = part.group
						mesh.Anchored = true
						mesh.CanCollide = false
						mesh.CanTouch = false
						mesh.CanQuery = false
						mesh.Size = vector(part.size)
						mesh.Material = if part.neon == true then Enum.Material.Neon else MATERIAL
						local color = Color3.new(part.color[1], part.color[2], part.color[3])
						mesh.Color = if part.team == true then TEAM:Lerp(def_color, TEAM_KEEPS_DEF) else color
						mesh.CFrame = pivot * CFrame.new(vector(part.offset)) * UPLOADED_TURN
						mesh.Parent = model
						fetched += 1
					end
				end
				remaining -= 1
				if remaining == 0 and coroutine.status(thread) == "suspended" then
					task.spawn(thread)
				end
			end)
		end
		if remaining > 0 then
			coroutine.yield()
		end
		model.WorldPivot = CFrame.identity
		if fetched == 0 then
			model:Destroy()
			finish(def_name, nil)
		else
			finish(def_name, model)
		end
	end)
end

-- Where the camera goes to see all of `model` from `direction` in a frame `aspect` wide for its height: as close as it
-- can be with every corner of the model's box inside the frame.
local function framing(model: Model, direction: Vector3, aspect: number): CFrame
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
				-- a camera looks down its -Z, so how far the corner stands toward it is +Z
				local needed = math.max(math.abs(seen.X) / tan_horizontal, math.abs(seen.Y) / tan_vertical) + seen.Z
				distance = math.max(distance, needed)
			end
		end
	end
	return CFrame.lookAt(center + direction * distance, center)
end

local function direction_at(yaw: number): Vector3
	return Vector3.new(math.sin(yaw) * math.cos(PITCH), math.sin(PITCH), math.cos(yaw) * math.cos(PITCH))
end

-- The icon for a def with no picture: its first weapon's, a builder's repair icon, or else the guard icon, for what
-- only stands in the way.
local function icon_of(def_name: string): string
	local def = unit_defs.get(def_name)
	local weapons = def.weapons
	if weapons ~= nil and #weapons > 0 then
		local _name, _slot, icon = unit_facts.weapon_kind(weapons[1])
		return icon
	elseif def.buildpower ~= nil then
		return "icon_repair"
	end
	return "icon_guard"
end

-- `spin` is radians a second the camera circles the model at; nil or 0 for a still picture.
local function UnitThumbnail(props: {
	def_name: string,
	tag: string,
	spin: number?,
	fallback: string?,
	LayoutOrder: number?,
})
	local frame_ref = React.useRef(nil :: ViewportFrame?)
	local _built, set_built = React.useState(0)
	build(props.def_name)
	local state = status[props.def_name]

	React.useEffect(function(): (() -> ())?
		if state ~= "building" then
			return nil
		end
		local function built()
			set_built(function(count: number)
				return count + 1
			end)
		end
		-- it may have finished between the render and now
		if status[props.def_name] ~= "building" then
			built()
			return nil
		end
		local callbacks = waiting[props.def_name] or {}
		waiting[props.def_name] = callbacks
		table.insert(callbacks, built)
		return function()
			local index = table.find(callbacks, built)
			if index ~= nil then
				table.remove(callbacks, index)
			end
		end
	end, { props.def_name, state })

	React.useEffect(function(): (() -> ())?
		local viewport = frame_ref.current
		local template = templates[props.def_name]
		if viewport == nil or template == nil then
			return nil
		end
		local model = template:Clone()
		local camera = Instance.new "Camera"
		camera.FieldOfView = FOV
		local yaw = YAW
		local function aim()
			local size = viewport.AbsoluteSize
			local aspect = if size.X > 0 and size.Y > 0 then size.X / size.Y else 1
			camera.CFrame = framing(model, direction_at(yaw), aspect)
		end
		aim()
		camera.Parent = viewport
		viewport.CurrentCamera = camera
		model.Parent = viewport
		-- the frame's size is only known once it is laid out
		local resized = viewport:GetPropertyChangedSignal("AbsoluteSize"):Connect(aim)
		local spinning: RBXScriptConnection? = nil
		local spin = props.spin
		if spin ~= nil and spin ~= 0 then
			spinning = RunService.RenderStepped:Connect(function(dt: number)
				yaw += spin * dt
				aim()
			end)
		end
		return function()
			resized:Disconnect()
			if spinning ~= nil then
				spinning:Disconnect()
			end
			model:Destroy()
			camera:Destroy()
		end
	end, { props.def_name, state, props.spin or 0 } :: { any })

	if state == "none" then
		return React.createElement("Frame", {
			[React.Tag] = `{props.tag} icon-fallback`,
			LayoutOrder = props.LayoutOrder,
		}, {
			Icon = React.createElement(ArtIcon, {
				name = icon_of(props.def_name),
				view = "front",
				flat = true,
				fallback = props.fallback,
				tag = "thumbnail-icon",
			}),
		})
	end
	return React.createElement("ViewportFrame", {
		[React.Tag] = props.tag,
		LayoutOrder = props.LayoutOrder,
		ref = frame_ref,
		-- lit from ahead and above, the same side it is seen from, with enough ambient that the far side reads
		Ambient = Color3.fromRGB(150, 150, 160),
		LightColor = Color3.fromRGB(255, 250, 240),
		LightDirection = Vector3.new(-0.5, -1, -0.7),
	})
end

return table.freeze({
	UnitThumbnail = UnitThumbnail,
})
