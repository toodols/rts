-- Warp: while it is on, the simulation runs as many steps as it can fit into a real-time budget every
-- Heartbeat, back to back, instead of waiting for real time to catch up between them one at a time -
-- a fast-forward, not a speed multiplier tied to the server's own frame rate. It is a debugging aid
-- switched by the pow `warp` command, so nothing about a normal game depends on it.

local Workspace = game:GetService "Workspace"

local ATTRIBUTE = "warp"

local function is_warping(): boolean
	return Workspace:GetAttribute(ATTRIBUTE) == true
end

local function set(warping: boolean)
	Workspace:SetAttribute(ATTRIBUTE, warping)
end

return table.freeze({
	is_warping = is_warping,
	set = set,
})
