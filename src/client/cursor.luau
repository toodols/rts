--!strict
-- What the mouse cursor points at: the ground, an entity, or one of the HUD's panels in front of them.

local CollectionService = game:GetService "CollectionService"
local GuiService = game:GetService "GuiService"
local Players = game:GetService "Players"
local ReplicatedStorage = game:GetService "ReplicatedStorage"
local UserInputService = game:GetService "UserInputService"
local Workspace = game:GetService "Workspace"

local ground_levels = require(ReplicatedStorage.Shared.ground_levels)
local heightmap = require(ReplicatedStorage.Shared.heightmap)

local world = require(ReplicatedStorage.Client.world)

-- How far along the cursor's ray the ground and entities are looked for, in studs.
local GROUND_RAY_LENGTH = 3000
local ENTITY_RAY_LENGTH = 5000

-- The ray from the camera through the cursor, or nil with no camera.
local function ray(): Ray?
	local camera = Workspace.CurrentCamera
	if camera == nil then
		return nil
	end
	local location = UserInputService:GetMouseLocation()
	return camera:ViewportPointToRay(location.X, location.Y)
end

-- Where the cursor meets the ground, or the water's surface over it, or nil off the map. It comes from the heightmap,
-- not from casting a ray at the world: placing a building, ordering a move, aiming a weapon, pinging or choosing a
-- start should not depend on what happens to be under the cursor, and whether an action succeeds is a matter of range
-- alone. Water stops it like the ground does, so a point out at sea is the one under the cursor, and not the one on the
-- sea floor further along it.
local function ground_point(): Vector3?
	local cast = ray()
	if cast == nil then
		return nil
	end
	local point = heightmap.ray_to_ground(cast.Origin, cast.Direction, GROUND_RAY_LENGTH)
	-- a ray that reached the sea floor came down through the surface on the way, unless it began underneath
	if point == nil or point.Y >= ground_levels.WATER_LEVEL or cast.Origin.Y <= ground_levels.WATER_LEVEL then
		return point
	end
	local on_water = cast.Origin + cast.Direction * ((ground_levels.WATER_LEVEL - cast.Origin.Y) / cast.Direction.Y)
	return Vector3.new(on_water.X, ground_levels.WATER_LEVEL, on_water.Z)
end

-- The entity whose model the cursor is over, if any.
local function entity(): Model?
	local cast = ray()
	if cast == nil then
		return nil
	end
	local params = RaycastParams.new()
	params.FilterType = Enum.RaycastFilterType.Include
	params.FilterDescendantsInstances = { world.container() }
	local result = Workspace:Raycast(cast.Origin, cast.Direction * ENTITY_RAY_LENGTH, params)
	if result == nil then
		return nil
	end
	return world.from_instance(result.Instance)
end

-- Whether the cursor is over one of the HUD's panels (the build menu, the selection panel...), looking at the panel
-- and not at the world behind it. GUI positions are one inset below the viewport's.
local function over_panel(): boolean
	local player_gui = Players.LocalPlayer:FindFirstChildOfClass "PlayerGui"
	if player_gui == nil then
		return false
	end
	local location = UserInputService:GetMouseLocation() - GuiService:GetGuiInset()
	for _, object in player_gui:GetGuiObjectsAtPosition(location.X, location.Y) do
		local at: Instance? = object
		while at ~= nil and at ~= player_gui do
			if CollectionService:HasTag(at, "panel") then
				return true
			end
			at = at.Parent
		end
	end
	return false
end

return table.freeze({
	ground_point = ground_point,
	entity = entity,
	over_panel = over_panel,
})
