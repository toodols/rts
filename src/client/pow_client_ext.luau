-- The halves of this game's pow commands that start on the client, which alone knows what is selected: the pool skin's
-- donut commands (see server/pow_commands/donuts.luau, where each carries on, on the server, by the same name, and whose
-- descriptions pow shows here). Each takes what is selected along and hands it to the server.
--
-- pow calls its extension modules to let them register commands, so this one returns a function rather than the
-- dictionary RULES.md asks of every other module.

local ReplicatedStorage = game:GetService "ReplicatedStorage"

local pow_types = require(ReplicatedStorage.Shared.pow_types)

local selection = require(ReplicatedStorage.Client.selection)

-- The commands that act on what is selected.
local ON_SELECTION = { "donut_pop", "donut_flyoff", "donut_float", "donut_regen" }

local function with_selection(context: any)
	context.data.selected = selection.get()
	context:defer()
end

return function(extras: pow_types.Extras)
	for _, name in ON_SELECTION do
		extras.commands[name] = {
			permissions = { "admin" },
			overloads = pow_types.TEAM_OR_YOURS,
			client_run = with_selection,
		}
	end
end
