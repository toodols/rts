-- Pause: while it is on, the simulation does not step at all, as if the game's speed were zero. It is
-- a debugging aid switched by the pow `pause` command, so nothing about a normal game depends on it.

local Workspace = game:GetService "Workspace"

local ATTRIBUTE = "paused"

local function is_paused(): boolean
	return Workspace:GetAttribute(ATTRIBUTE) == true
end

local function set(paused: boolean)
	Workspace:SetAttribute(ATTRIBUTE, paused)
end

return table.freeze({
	is_paused = is_paused,
	set = set,
})
