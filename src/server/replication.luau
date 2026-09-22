-- Makes sure the client is actually sent the world.
--
-- Instance streaming needs somewhere to stream around, and this game has no characters: players
-- command units from a free camera, so `Players.CharacterAutoLoads` is false and nothing ever
-- gives a player a position in the world. With no character and no `ReplicationFocus` the client's
-- streaming region is empty, so entity models arrive as empty shells, terrain never arrives at
-- all, and nothing errors - the server looks perfectly healthy while the client renders nothing.
--
-- The project file turns streaming off, because the map is 256 studs across and there is nothing
-- here worth streaming. A place that still has it on - one built before that setting, or one
-- somebody else opened this project in - gets a focus part at the centre of the map instead, which
-- the default streaming radius covers several times over.

local ReplicatedStorage = game:GetService "ReplicatedStorage"
local Workspace = game:GetService "Workspace"

local config = require(ReplicatedStorage.Shared.config)
local heightmap = require(ReplicatedStorage.Shared.heightmap)

local FOCUS_NAME = "ReplicationFocus"

local focus_part: BasePart? = nil

local function map_center(): Vector3
	local x = heightmap.ORIGIN_X + config.MAP_CELLS_X * config.CELL_STUDS / 2
	local z = heightmap.ORIGIN_Z + config.MAP_CELLS_Z * config.CELL_STUDS / 2
	return heightmap.ground_position(x, z)
end

local function get_focus(): BasePart
	if focus_part ~= nil then
		return focus_part
	end

	local part = Instance.new "Part"
	part.Name = FOCUS_NAME
	part.Size = Vector3.new(1, 1, 1)
	part.Transparency = 1
	part.Anchored = true
	part.Locked = true
	part.CanCollide = false
	part.CanQuery = false
	part.CanTouch = false
	part.CastShadow = false
	part.Position = map_center()
	part.Parent = Workspace

	focus_part = part
	return part
end

-- Called as each player joins, before anything is built for them.
local function attach(player: Player)
	if Workspace.StreamingEnabled == false then
		return
	end
	if focus_part == nil then
		warn(
			"Workspace.StreamingEnabled is on and this game has no characters, so players have "
				.. "nothing to stream around; focusing replication on the centre of the map. Turn "
				.. "streaming off in Workspace (the project file sets it) to be rid of this."
		)
	end
	player.ReplicationFocus = get_focus()
end

return table.freeze({
	attach = attach,
})
