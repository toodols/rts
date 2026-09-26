--!strict
-- What a server does as each player joins and leaves, in one ordered list of stages that its entry point hands `run`
-- once (the game's server/bootstrap.luau, the lobby's init.server.luau). No module connects to PlayerAdded or
-- PlayerRemoving itself: a module with something to do then gives the list a stage, so that the order they run in is
-- written down in one place, where it can be read.
--
-- Stages are run in the order given as a player joins, and in the same order as they leave; a player already here when
-- the list is run joins at once.

local Players = game:GetService "Players"

export type Stage = {
	joined: ((Player) -> ())?,
	left: ((Player) -> ())?,
}

local function run(stages: { Stage })
	local function joined(player: Player)
		for _, stage in stages do
			if stage.joined ~= nil then
				stage.joined(player)
			end
		end
	end
	Players.PlayerAdded:Connect(joined)
	Players.PlayerRemoving:Connect(function(player: Player)
		for _, stage in stages do
			if stage.left ~= nil then
				stage.left(player)
			end
		end
	end)
	for _, player in Players:GetPlayers() do
		joined(player)
	end
end

return table.freeze({
	run = run,
})
