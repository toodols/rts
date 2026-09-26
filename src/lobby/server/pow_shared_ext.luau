--!strict
-- The lobby's pow types, which the command bar on the client needs as much as the server does. pow copies this module
-- into ReplicatedStorage and runs it on both sides.
--
-- pow calls its extension modules to let them register types and commands, so this one returns a function rather
-- than the dictionary RULES.md asks of every other module.

local ReplicatedStorage = game:GetService "ReplicatedStorage"

local pow_types = require(ReplicatedStorage.Shared.pow_types)

return function(extras: pow_types.Extras)
	pow_types.register_common(extras)
end
