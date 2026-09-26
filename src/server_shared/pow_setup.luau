--!strict
-- Starts pow, the command bar (press ; to open it), the same way in every place: for debugging and administration only,
-- so only a developer may use it (shared/developers.luau, developer_list.luau), the experience's owner and whoever is
-- playing in Studio above the rest. Who may use it follows the developers' list as it is read for each player and as
-- it changes, rather than a list of its own.
--
-- Each place hands in its extension modules: pow clones the `shared` ones into ReplicatedStorage and runs them on the
-- server and on every client (types, which the command bar needs on both sides), runs the `server` ones on the server
-- alone (commands), and the `client` ones on each client alone (the halves of commands that start there, such as those
-- that act on what is selected, linked to their server halves by name).

local ReplicatedStorage = game:GetService "ReplicatedStorage"

local developers = require(ReplicatedStorage.Shared.developers)

local developer_list = require(script.Parent.developer_list)
local pow_internals = require(script.Parent.pow_internals)

export type Extensions = {
	shared: { ModuleScript },
	server: { ModuleScript },
	client: { ModuleScript }?,
}

-- pow's highest rank, the owner's and Studio's, and the rank a listed developer has under it.
local OWNER_RANK = 5
local DEVELOPER_RANK = 4
-- the player playing in Studio, as pow knows them
local STUDIO_USER = "-1"
local PERMISSION = "owner"

-- The rank `player` has in pow, if any: the owner's (or Studio's), or a developer's.
local function rank_of(player: Player): number?
	if developer_list.is_owner(player.UserId) or player.UserId < 0 then
		return OWNER_RANK
	end
	return if developers.is_developer(player) then DEVELOPER_RANK else nil
end

-- Starts pow from `pow_module` (the package, as the place mounts it) with `extensions`.
local function start(pow_module: ModuleScript, extensions: Extensions)
	local pow = require(pow_module) :: any
	local owners: { [string]: number? } = { [STUDIO_USER] = OWNER_RANK }
	if game.CreatorType == Enum.CreatorType.User then
		owners[tostring(game.CreatorId)] = OWNER_RANK
	end
	local config: { [string]: any } = {
		permissions = { [PERMISSION] = owners },
		disable_data_store = true,
		extras_shared = extensions.shared,
		extras_server = extensions.server,
		extras_client = extensions.client,
	}
	pow.init(config)
	local internals = pow_internals.open(pow_module, ReplicatedStorage:WaitForChild "Pow" :: RemoteFunction)

	-- a player's rank follows whether they are a developer, and their command bar is told when it changes
	developer_list.on_published(function(player: Player)
		local key = tostring(player.UserId)
		local rank = rank_of(player)
		if owners[key] == rank then
			return
		end
		owners[key] = rank
		internals.tell_rank(player, config)
	end)
end

return table.freeze({
	start = start,
})
