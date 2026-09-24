-- Choosing where to start while the game is waiting to begin (see shared/game_phase.luau). Every team's start box is
-- drawn on the ground, laid along it so it climbs the hills: the local player's own lit in their colour, and the rest in
-- red. Where each player has chosen to start is a ring with their name over it. Clicking anywhere in the player's own
-- box that a team can start on asks the server to start there. It is all gone once the game is playing.

local Players = game:GetService "Players"
local ReplicatedStorage = game:GetService "ReplicatedStorage"
local UserInputService = game:GetService "UserInputService"
local Workspace = game:GetService "Workspace"

local game_phase = require(ReplicatedStorage.Shared.game_phase)
local heightmap = require(ReplicatedStorage.Shared.heightmap)
local starts = require(ReplicatedStorage.Shared.starts)

local choose_start: RemoteEvent = ReplicatedStorage.Shared.ChooseStart

local local_player = Players.LocalPlayer

-- A box's edge is laid in pieces this long, so it follows the ground, this thick and this far up off it.
local EDGE_STEP = 4
local EDGE_THICKNESS = 0.6
local EDGE_LIFT = 0.5
-- The ring where a player has chosen to start.
local RING_RADIUS = 6
local RING_HEIGHT = 0.4

local MINE_COLOR = Color3.fromRGB(96, 210, 242)
local OTHER_COLOR = Color3.fromRGB(238, 88, 74)
local LABEL_COLOR = Color3.fromRGB(236, 244, 252)

type Box = {
	edges: { Part },
	label: BillboardGui,
}

type Marker = {
	ring: Part,
	label: TextLabel,
}

local folder: Folder? = nil
local boxes: { Box } = {}
local markers: { [Player]: Marker } = {}

local function effect_part(name: string, parent: Instance): Part
	local part = Instance.new "Part"
	part.Name = name
	part.Anchored = true
	part.CanCollide = false
	part.CanQuery = false
	part.CanTouch = false
	part.CastShadow = false
	part.Material = Enum.Material.Neon
	part.Parent = parent
	return part
end

local function label_for(parent: Instance, offset: number, size: number): (BillboardGui, TextLabel)
	local billboard = Instance.new "BillboardGui"
	billboard.Size = UDim2.fromOffset(220, 28)
	billboard.StudsOffsetWorldSpace = Vector3.new(0, offset, 0)
	billboard.AlwaysOnTop = true
	billboard.Parent = parent
	local label = Instance.new "TextLabel"
	label.Size = UDim2.fromScale(1, 1)
	label.BackgroundTransparency = 1
	label.Font = Enum.Font.RobotoMono
	label.TextSize = size
	label.TextColor3 = LABEL_COLOR
	label.TextStrokeTransparency = 0.4
	label.Parent = billboard
	return billboard, label
end

-- The edge of a box from `from` to `to`, in (x, z), laid along the ground in short pieces.
local function lay_edge(edges: { Part }, from: Vector2, to: Vector2, parent: Instance)
	local steps = math.max(1, math.ceil((to - from).Magnitude / EDGE_STEP))
	local previous = heightmap.ground_position(from.X, from.Y) + Vector3.new(0, EDGE_LIFT, 0)
	for step = 1, steps do
		local at = from:Lerp(to, step / steps)
		local point = heightmap.ground_position(at.X, at.Y) + Vector3.new(0, EDGE_LIFT, 0)
		local piece = effect_part("StartBoxEdge", parent)
		piece.Size = Vector3.new(EDGE_THICKNESS, EDGE_THICKNESS, (point - previous).Magnitude + EDGE_THICKNESS)
		piece.CFrame = CFrame.lookAt((previous + point) / 2, point)
		table.insert(edges, piece)
		previous = point
	end
end

local function make_box(index: number, parent: Instance): Box
	local box = starts.box(index)
	local corners = {
		box.min,
		Vector2.new(box.max.X, box.min.Y),
		box.max,
		Vector2.new(box.min.X, box.max.Y),
	}
	local edges: { Part } = {}
	for corner = 1, 4 do
		lay_edge(edges, corners[corner], corners[corner % 4 + 1], parent)
	end
	-- the name of the box floats over its middle
	local middle = (box.min + box.max) / 2
	local anchor = effect_part("StartBoxLabel", parent)
	anchor.Transparency = 1
	anchor.Size = Vector3.one
	anchor.Position = heightmap.ground_position(middle.X, middle.Y)
	local billboard, label = label_for(anchor, 12, 18)
	label.Text = `START AREA {index}`
	return { edges = edges, label = billboard }
end

-- Colours the boxes for whose they are, and shows them and the chosen starts only while there is a start to choose.
local function refresh()
	local visible = game_phase.has_begun() == false
	local own = game_phase.box_of(local_player)
	for index, box in boxes do
		local color = if index == own then MINE_COLOR else OTHER_COLOR
		for _, edge in box.edges do
			edge.Color = color
			edge.Transparency = if visible then (if index == own then 0.1 else 0.45) else 1
		end
		box.label.Enabled = visible
		local text = box.label:FindFirstChildOfClass "TextLabel"
		if text ~= nil then
			text.Text = if index == own then "YOUR START AREA" else `START AREA {index}`
			text.TextColor3 = color
		end
	end

	local parent = folder
	for _, player in Players:GetPlayers() do
		local chosen = game_phase.start_of(player)
		local marker = markers[player]
		if chosen == nil or visible == false or parent == nil then
			if marker ~= nil then
				marker.ring:Destroy()
				markers[player] = nil
			end
			continue
		end
		if marker == nil then
			local ring = effect_part("ChosenStart", parent)
			ring.Shape = Enum.PartType.Cylinder
			ring.Size = Vector3.new(RING_HEIGHT, RING_RADIUS * 2, RING_RADIUS * 2)
			ring.Transparency = 0.2
			local _, label = label_for(ring, 6, 16)
			marker = { ring = ring, label = label }
			markers[player] = marker
		end
		local shown = marker :: Marker
		-- a Cylinder part's flat faces point along X, so it is rolled to lie flat on the ground
		shown.ring.CFrame = CFrame.new(chosen + Vector3.new(0, RING_HEIGHT, 0)) * CFrame.Angles(0, 0, math.pi / 2)
		local color = if player == local_player then MINE_COLOR else OTHER_COLOR
		shown.ring.Color = color
		shown.label.Text = player.DisplayName
		shown.label.TextColor3 = color
	end
	for player, marker in markers do
		if player.Parent == nil then
			marker.ring:Destroy()
			markers[player] = nil
		end
	end
end

-- Draws the boxes of the map there is now, replacing any from a map before it.
local function rebuild()
	if folder ~= nil then
		folder:Destroy()
	end
	table.clear(markers)
	table.clear(boxes)
	local made = Instance.new "Folder"
	made.Name = "StartBoxes"
	made.Parent = Workspace
	folder = made
	for index = 1, starts.box_count() do
		boxes[index] = make_box(index, made)
	end
	refresh()
end

-- Where on the ground the cursor points, as (x, z), or nil off the map.
local function ground_under_cursor(): Vector2?
	local camera = Workspace.CurrentCamera
	if camera == nil then
		return nil
	end
	local cursor = UserInputService:GetMouseLocation()
	local ray = camera:ViewportPointToRay(cursor.X, cursor.Y)
	local params = RaycastParams.new()
	params.FilterType = Enum.RaycastFilterType.Include
	params.FilterDescendantsInstances = { Workspace.Terrain }
	params.IgnoreWater = true
	local hit = Workspace:Raycast(ray.Origin, ray.Direction * 5000, params)
	return if hit ~= nil then Vector2.new(hit.Position.X, hit.Position.Z) else nil
end

local function watch_player(player: Player)
	player:GetAttributeChangedSignal(game_phase.START_ATTRIBUTE):Connect(refresh)
	player:GetAttributeChangedSignal(game_phase.BOX_ATTRIBUTE):Connect(refresh)
end

local function init()
	rebuild()
	game_phase.changed(refresh)
	for _, player in Players:GetPlayers() do
		watch_player(player)
	end
	Players.PlayerAdded:Connect(watch_player)
	Players.PlayerRemoving:Connect(function()
		task.defer(refresh)
	end)

	UserInputService.InputBegan:Connect(function(input: InputObject, processed: boolean)
		if processed or input.UserInputType ~= Enum.UserInputType.MouseButton1 then
			return
		end
		if game_phase.has_begun() then
			return
		end
		local own = game_phase.box_of(local_player)
		local at = ground_under_cursor()
		if own == nil or at == nil then
			return
		end
		-- the server checks the same, and ignores anything else
		if starts.in_box(own, at.X, at.Y) and starts.can_start_at(at.X, at.Y) then
			choose_start:FireServer(heightmap.ground_position(at.X, at.Y))
		end
	end)
end

return table.freeze({
	init = init,
	rebuild = rebuild,
})
