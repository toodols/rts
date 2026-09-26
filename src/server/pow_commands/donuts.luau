-- The server halves of the pool skin's donut commands, for debugging it: the donuts' state is the server's
-- (server/donuts.luau), so what they do every player sees. They act on the units you have selected, which the client
-- half hands over (client/pow_client_ext.luau, linked by name), or with nothing selected on everything of your team, or
-- of the team given.
--
-- pow calls its extension modules to let them register commands, so this one returns a function rather than the
-- dictionary RULES.md asks of every other module.

local ReplicatedStorage = game:GetService "ReplicatedStorage"
local ServerScriptService = game:GetService "ServerScriptService"

local pow_types = require(ReplicatedStorage.Shared.pow_types)
local types = require(ReplicatedStorage.Shared.types)

local pow_builders = require(ServerScriptService.ServerShared.pow_builders)

local donuts = require(ServerScriptService.Server.donuts)
local players = require(ServerScriptService.Server.players)
local state = require(ServerScriptService.Server.state)

type Context = pow_builders.Context
type Entity = types.Entity

-- What a donut command acts on: the units selected, or everything of the team given, or of the runner's team.
local function targets(context: Context): { Entity }
	local found: { Entity } = {}
	local ids = if typeof(context.data) == "table" then context.data.selected else nil
	if context.args[1] == nil and typeof(ids) == "table" and #ids > 0 then
		for _, id in ids do
			local entity = if typeof(id) == "number" then state.get(id) else nil
			if entity ~= nil then
				table.insert(found, entity)
			end
		end
		return found
	end
	local team_id = if context.args[1] ~= nil then context.args[1] else players.team_of(context.executor)
	for _, entity in state.all() do
		if entity.team == team_id then
			table.insert(found, entity)
		end
	end
	return found
end

local function donut_command(description: string, act: (entity: Entity) -> boolean, done: string): pow_builders.Command
	return {
		description = description
			.. " Acts on the units you have selected, or with none selected on your team, or on the team given.",
		permissions = { "admin" },
		overloads = pow_types.TEAM_OR_YOURS,
		server_run = function(context: Context)
			local count = 0
			local list = targets(context)
			for _, entity in list do
				if act(entity) then
					count += 1
				end
			end
			context:log({ type = "info", value = `{done} {count} donut(s) of the {#list} unit(s) aimed at` })
		end,
	}
end

return function(extras: pow_types.Extras)
	local commands = extras.commands

	commands.donut_pop = donut_command("Pops donuts as a hit would.", function(entity: Entity): boolean
		return donuts.force_off(entity, "pop")
	end, "Popped")

	commands.donut_flyoff = donut_command(
		"Throws donuts off as a fast aircraft does, on anything, not only aircraft.",
		function(entity: Entity): boolean
			return donuts.force_off(entity, "fly")
		end,
		"Threw off"
	)

	commands.donut_float = donut_command(
		"Floats donuts off as going deep under the water does, on anything: up to the surface, to bob there a while.",
		function(entity: Entity): boolean
			return donuts.force_off(entity, "float")
		end,
		"Floated off"
	)

	commands.donut_regen = donut_command(
		"Puts new donuts on at once, without waiting out the regen time.",
		function(entity: Entity): boolean
			return donuts.force_on(entity)
		end,
		"Put back"
	)

	commands.donut_status = {
		description = "Says how many units wear a donut, how many have it on or off, and how many are shaking one "
			.. "loose: of your team, or of the team given, or of everyone if you are on no team.",
		permissions = { "admin" },
		overloads = pow_types.TEAM_OR_YOURS,
		server_run = function(context: Context)
			local team_id = if context.args[1] ~= nil then context.args[1] else players.team_of(context.executor)
			local counts = donuts.census(team_id)
			context:log({
				type = "info",
				value = `{if team_id ~= nil then "Team " .. tostring(team_id) else "Everyone"}: {counts.wearing} wear a `
					.. `donut, {counts.on} on ({counts.shaking} shaking), {counts.off} off`,
			})
		end,
	}
end
