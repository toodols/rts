--!strict
-- pow command-bar types, for the pow extensions of every place (the game's server/pow_shared_ext.luau, the lobby's
-- lobby/server/pow_shared_ext.luau): those for things picked by name out of a fixed list, such as a map or a skin, and
-- the ones every place's commands take (`register_common`, server_shared/pow_common.luau).

local ReplicatedStorage = game:GetService "ReplicatedStorage"

local campaign = require(ReplicatedStorage.Shared.campaign)
local skins = require(ReplicatedStorage.Shared.skins)

-- What a pow extension module is called with: the types and commands it registers into.
export type Extras = { types: { [string]: any }, commands: { [string]: any } }

-- The arguments of a command that acts on your team, or on the team given.
local TEAM_OR_YOURS = table.freeze({
	{ returns = "nil", args = {} },
	{ returns = "nil", args = { { name = "Team", type = "number" } } },
})

-- A pow type called `type_name` that takes any of `names`, suggesting them, and refuses anything else, saying what
-- there is. `names` is sorted in place.
local function named(type_name: string, description: string, names: { string }): { [string]: any }
	table.sort(names)
	local function as_name(name: string): { ok: string?, err: string? }
		if table.find(names, name) ~= nil then
			return { ok = name }
		end
		return { err = `there is no {type_name} "{name}"; there are {table.concat(names, ", ")}` }
	end
	return {
		name = type_name,
		description = description,
		autocomplete_simple = names,
		coerce_expression = function(expression: any): { ok: string?, err: string? }
			if expression.type == "string" then
				return as_name(expression.value)
			end
			return { err = `cannot coerce {expression.type} to {type_name}` }
		end,
		coerce_value = function(value: any): { ok: string?, err: string? }
			if typeof(value) == "string" then
				return as_name(value)
			end
			return { err = `cannot coerce {typeof(value)} to {type_name}` }
		end,
	}
end

-- The types every place's commands take: a skin, by name, and a campaign mission, by id.
local function register_common(extras: Extras)
	local mission_ids: { string } = {}
	for _, mission in campaign.MISSIONS do
		table.insert(mission_ids, mission.id)
	end
	extras.types.skin = named("skin", "A skin, by name", skins.names())
	extras.types.mission = named("mission", "A campaign mission, by id", mission_ids)
end

return table.freeze({
	TEAM_OR_YOURS = TEAM_OR_YOURS,
	named = named,
	register_common = register_common,
})
