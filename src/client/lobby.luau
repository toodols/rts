-- The starts to choose among while the game is waiting to begin (see shared/game_phase.luau): a ring on the ground at
-- each of the map's starts, lit in the local player's colour on the one they chose, red on one someone else has, and
-- pale on one that is free, with the name of whoever has it over it. Clicking on or near a free one asks the server
-- for it. They are gone once the game is playing.

local Players = game:GetService "Players"
local ReplicatedStorage = game:GetService "ReplicatedStorage"
local UserInputService = game:GetService "UserInputService"
local Workspace = game:GetService "Workspace"

local game_phase = require(ReplicatedStorage.Shared.game_phase)
local heightmap = require(ReplicatedStorage.Shared.heightmap)
local starts = require(ReplicatedStorage.Shared.starts)

local choose_start: RemoteEvent = ReplicatedStorage.Shared.ChooseStart

local local_player = Players.LocalPlayer

-- How wide a start's ring is drawn, and how near it a click has to land to choose it, in studs.
local RING_RADIUS = 14
local CHOOSE_RADIUS = 40
local RING_HEIGHT = 0.4

local FREE_COLOR = Color3.fromRGB(236, 244, 252)
local MINE_COLOR = Color3.fromRGB(96, 210, 242)
local TAKEN_COLOR = Color3.fromRGB(238, 88, 74)

type Marker = {
	ring: Part,
	label: TextLabel,
}

local markers: { Marker } = {}
local folder: Folder? = nil

local function holder_of(slot: number): Player?
	for _, player in Players:GetPlayers() do
		if game_phase.start_of(player) == slot then
			return player
		end
	end
	return nil
end

local function make_marker(slot: number, parent: Instance): Marker
	local center = starts.center(slot)
	local ground = heightmap.ground_position(center.X, center.Y)

	local ring = Instance.new "Part"
	ring.Name = `Start{slot}`
	ring.Anchored = true
	ring.CanCollide = false
	ring.CanQuery = false
	ring.CanTouch = false
	ring.CastShadow = false
	ring.Material = Enum.Material.Neon
	ring.Transparency = 0.35
	ring.Shape = Enum.PartType.Cylinder
	ring.Size = Vector3.new(RING_HEIGHT, RING_RADIUS * 2, RING_RADIUS * 2)
	-- a Cylinder part's flat faces point along X, so it is rolled to lie flat on the ground
	ring.CFrame = CFrame.new(ground + Vector3.new(0, RING_HEIGHT, 0)) * CFrame.Angles(0, 0, math.pi / 2)
	ring.Parent = parent

	local billboard = Instance.new "BillboardGui"
	billboard.Size = UDim2.fromOffset(160, 28)
	billboard.StudsOffsetWorldSpace = Vector3.new(0, 8, 0)
	billboard.AlwaysOnTop = true
	billboard.Adornee = ring
	billboard.Parent = ring
	local label = Instance.new "TextLabel"
	label.Size = UDim2.fromScale(1, 1)
	label.BackgroundTransparency = 1
	label.Font = Enum.Font.RobotoMono
	label.TextSize = 16
	label.TextStrokeTransparency = 0.4
	label.Parent = billboard

	return { ring = ring, label = label }
end

-- Colours and names every marker for who has its start now, and shows them only while there is a start to choose.
local function refresh()
	local visible = game_phase.is_playing() == false
	for slot, marker in markers do
		local holder = holder_of(slot)
		local color = if holder == nil then FREE_COLOR elseif holder == local_player then MINE_COLOR else TAKEN_COLOR
		marker.ring.Color = color
		marker.label.TextColor3 = color
		marker.label.Text = if holder ~= nil then holder.DisplayName else `Start {slot}`
		marker.ring.Transparency = if visible then 0.35 else 1
		marker.label.Visible = visible
	end
end

-- Draws a marker for every start on the map now, replacing any from a map before it.
local function rebuild()
	if folder ~= nil then
		folder:Destroy()
	end
	local made = Instance.new "Folder"
	made.Name = "StartMarkers"
	made.Parent = Workspace
	folder = made
	table.clear(markers)
	for slot = 1, starts.count() do
		markers[slot] = make_marker(slot, made)
	end
	refresh()
end

-- The start nearest where the cursor points on the ground, if one is near enough to mean it.
local function start_under_cursor(): number?
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
	if hit == nil then
		return nil
	end
	local best: number? = nil
	local best_distance = CHOOSE_RADIUS
	for slot = 1, starts.count() do
		local center = starts.center(slot)
		local distance = Vector2.new(hit.Position.X - center.X, hit.Position.Z - center.Y).Magnitude
		if distance <= best_distance then
			best = slot
			best_distance = distance
		end
	end
	return best
end

local function watch_player(player: Player)
	player:GetAttributeChangedSignal(game_phase.START_ATTRIBUTE):Connect(refresh)
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
		if game_phase.is_playing() then
			return
		end
		local slot = start_under_cursor()
		if slot == nil then
			return
		end
		local holder = holder_of(slot)
		if holder == nil or holder == local_player then
			choose_start:FireServer(slot)
		end
	end)
end

return table.freeze({
	init = init,
	rebuild = rebuild,
})
