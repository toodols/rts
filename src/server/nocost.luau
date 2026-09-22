-- Nocost: while it is on, everything builds for free and at once, as if it cost nothing. It is a debugging
-- aid switched by the pow `nocost` command, so nothing about a normal game depends on it.

local Workspace = game:GetService "Workspace"

local ATTRIBUTE = "nocost"

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
