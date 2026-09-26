--!strict
-- The one place anything reaches past pow's public API (pow_setup.luau): pow has no call to change a player's rank
-- while the server runs, and pow is a submodule this project does not edit, so a player's command bar is told of a new
-- rank the way pow's own `rank` command tells it, through pow's private util and its remote. What of pow's that is, is
-- asserted to be there as pow is started, so that a pow that has moved on fails at once rather than when a rank next
-- changes.

-- What of pow's private util is used.
type Util = {
	get_user_permission_and_rank: (permissions: { [string]: any }, user_id: number) -> any,
	serialize_config: (config: { [string]: any }, permission: any) -> any,
}

export type Internals = {
	-- Tells `player`'s command bar what pow's `config` now lets them do.
	tell_rank: (player: Player, config: { [string]: any }) -> (),
}

-- pow's internals, from `pow_module` (the package, as the place mounts it) and the remote it made as it started.
local function open(pow_module: ModuleScript, remote: RemoteFunction): Internals
	local util = require((pow_module :: any).shared.util) :: any
	assert(
		typeof(util) == "table"
			and typeof(util.get_user_permission_and_rank) == "function"
			and typeof(util.serialize_config) == "function",
		"pow's util no longer has what pow_internals.luau uses: see how pow's own rank command tells a player now"
	)
	local private = util :: Util
	local function tell_rank(player: Player, config: { [string]: any })
		local permission = private.get_user_permission_and_rank(config.permissions, player.UserId)
		task.spawn(
			pcall,
			remote.InvokeClient,
			remote,
			player,
			"config_updated",
			private.serialize_config(config, permission)
		)
	end
	return table.freeze({
		tell_rank = tell_rank,
	})
end

return table.freeze({
	open = open,
})
