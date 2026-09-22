-- Godmode: while it is on, every player can command every team's units and buildings. It is a
-- debugging aid switched by the pow `godmode` command, so nothing about a normal game depends on it.
--
-- The switch lives in a Workspace attribute rather than a variable, which is what lets the client
-- see it too: it has to know whose units it may select and order.

local Workspace = game:GetService "Workspace"

local ATTRIBUTE = "godmode"

local function is_enabled(): boolean
	return Workspace:GetAttribute(ATTRIBUTE) == true
end

local function set(enabled: boolean)
	Workspace:SetAttribute(ATTRIBUTE, enabled)
end

return table.freeze({
	is_enabled = is_enabled,
	set = set,
})
