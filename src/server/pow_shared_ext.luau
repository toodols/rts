-- This game's pow types, which the command bar on the client needs as much as the server does. pow copies this
-- module into ReplicatedStorage and runs it on both sides, so it needs nothing but what both sides have.
--
-- pow calls its extension modules to let them register types and commands, so this one returns a function rather
-- than the dictionary RULES.md asks of every other module.

local ReplicatedStorage = game:GetService "ReplicatedStorage"

local ai_profiles = require(ReplicatedStorage.Shared.ai_profiles)
local map_presets = require(ReplicatedStorage.Shared.map_presets)
local pow_types = require(ReplicatedStorage.Shared.pow_types)
local unit_defs = require(ReplicatedStorage.Shared.unit_defs)

return function(extras: pow_types.Extras)
	pow_types.register_common(extras)

	local map_names: { string } = {}
	for name in map_presets.presets do
		table.insert(map_names, name)
	end
	-- One of map_presets' maps, by name.
	extras.types.map = pow_types.named("map", "A map, by name", map_names)
	-- Whose side an AI that ai_add puts down is on: a team of its own, a new team allied with the team given, or the
	-- team given itself.
	extras.types.ai_side = pow_types.named("ai_side", "enemy, ally or join", { "enemy", "ally", "join" })
	-- Which labs an AI builds its army from; "any" leaves it to the AI's profile, or to the AI.
	extras.types.ai_line = pow_types.named("ai_line", "bot, vehicle or any labs", { "bot", "vehicle", "any" })
	-- One of shared/ai_profiles' profiles, by name: how an AI plays.
	extras.types.ai_profile = pow_types.named("ai_profile", "An AI profile, by name", ai_profiles.names())

	local def_names: { string } = {}
	for name in unit_defs.defs do
		table.insert(def_names, name)
	end
	table.sort(def_names)

	-- Any def, unit or building, by name. Only suggested: what is not one passes as it is, for each command to check.
	extras.types.unit = {
		name = "unit",
		description = "A unit or building, by def name",
		autocomplete_simple = def_names,
	}
end
