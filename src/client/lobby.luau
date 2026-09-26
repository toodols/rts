-- Choosing where to start while the game is waiting to begin (see shared/game_phase.luau). Every team's start box is
-- drawn on the ground, laid along it so it climbs the hills: the local player's own lit in their colour, and the rest in
-- red. Where each player has chosen to start is a ring with their name over it. Clicking anywhere in the player's own
-- box asks the server to start there, or on the nearest ground there a team can start on. It is all gone once the game
-- is playing, and never there in a campaign mission, whose player starts where it says (Shared.campaign).

local Players = game:GetService "Players"
local ReplicatedStorage = game:GetService "ReplicatedStorage"

local game_phase = require(ReplicatedStorage.Shared.game_phase)
local heightmap = require(ReplicatedStorage.Shared.heightmap)
local mission_state = require(ReplicatedStorage.Shared.mission_state)
local starts = require(ReplicatedStorage.Shared.starts)

local cursor = require(ReplicatedStorage.Client.cursor)
local map_events = require(ReplicatedStorage.Client.map_events)
local input_router = require(ReplicatedStorage.Client.input_router)
local world_fx = require(ReplicatedStorage.Client.world_fx)

local palette = require(ReplicatedStorage.ClientShared.palette)

local choose_start: RemoteEvent = ReplicatedStorage.Shared.ChooseStart

local local_player = Players.LocalPlayer

-- A box's edge is laid in pieces this long, so it follows the ground, this thick and this far up off it.
local EDGE_STEP = 4
local EDGE_STYLE: world_fx.LineStyle = table.freeze({ lift = 0.5, thickness = 0.6, closed_corners = true })
-- The ring where a player has chosen to start.
local RING_RADIUS = 6
local RING_HEIGHT = 0.4

local MINE_COLOR = palette.accent
local OTHER_COLOR = palette.danger
local LABEL_COLOR = palette.text

type Box = {
	edges: { Part },
	label: BillboardGui,
}

type Marker = {
	ring: Part,
	label: TextLabel,
}

-- A left click in the player's own start box asks the server to start there; the server moves it to the nearest ground
-- there a team can start on.
local function choose(input: InputObject, processed: boolean): boolean
	if processed or input.UserInputType ~= Enum.UserInputType.MouseButton1 then
		return false
	end
	local own = game_phase.box_of(local_player)
	local at = cursor.ground_point()
	if own ~= nil and at ~= nil and starts.in_box(own, at.X, at.Z) then
		choose_start:FireServer(heightmap.ground_position(at.X, at.Z))
	end
	return true
end

-- The start boxes' input layer, up while there is a start to choose.
local LAYER: input_router.Layer = table.freeze({
	began = choose,
	ended = function(_: InputObject) end,
	exclusive = false,
})
local pop_layer: (() -> ())? = nil

local folder: Instance? = nil
local boxes: { Box } = {}
local markers: { [Player]: Marker } = {}

local function effect_part(name: string, parent: Instance): Part
	local part = world_fx.part(name)
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
	local points = world_fx.ground_points(
		heightmap.ground_position(from.X, from.Y),
		heightmap.ground_position(to.X, to.Y),
		EDGE_STEP
	)
	world_fx.lay_line(points, EDGE_STYLE, function(): Part
		local piece = effect_part("StartBoxEdge", parent)
		table.insert(edges, piece)
		return piece
	end)
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

-- Colours the boxes for whose they are, and shows them and the chosen starts only while there is a start to choose,
-- when a left click chooses one and does nothing else.
local function refresh()
	local visible = game_phase.has_begun() == false and mission_state.mission() == nil
	if visible and pop_layer == nil then
		pop_layer = input_router.push(LAYER)
	elseif visible == false and pop_layer ~= nil then
		pop_layer()
		pop_layer = nil
	end
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
		shown.ring.CFrame = world_fx.lying_flat(chosen + Vector3.new(0, RING_HEIGHT, 0))
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
	local made = world_fx.folder "StartBoxes"
	made:ClearAllChildren()
	table.clear(markers)
	table.clear(boxes)
	folder = made
	for index = 1, starts.box_count() do
		boxes[index] = make_box(index, made)
	end
	refresh()
end

local function watch_player(player: Player)
	game_phase.start_changed(player, refresh)
	game_phase.box_changed(player, refresh)
end

local function init()
	rebuild()
	map_events.on_rebuilt(rebuild)
	game_phase.changed(refresh)
	mission_state.subscribe_mission(refresh)
	for _, player in Players:GetPlayers() do
		watch_player(player)
	end
	Players.PlayerAdded:Connect(watch_player)
	Players.PlayerRemoving:Connect(function()
		task.defer(refresh)
	end)
end

return table.freeze({
	init = init,
})
