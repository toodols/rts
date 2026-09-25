-- This game's pow types, which the command bar on the client needs as much as the server does. pow copies this
-- module into ReplicatedStorage and runs it on both sides.
--
-- pow calls its extension modules to let them register types and commands, so this one returns a function rather
-- than the dictionary RULES.md asks of every other module.

local ReplicatedStorage = game:GetService "ReplicatedStorage"

local ai_profiles = require(ReplicatedStorage.Shared.ai_profiles)
local map_presets = require(ReplicatedStorage.Shared.map_presets)
local pow_types = require(ReplicatedStorage.Shared.pow_types)
local skins = require(ReplicatedStorage.Shared.skins)
local unit_defs = require(ReplicatedStorage.Shared.unit_defs)

return function(extras: { types: { [string]: any }, commands: { [string]: any } })
	local map_names: { string } = {}
	for name in map_presets.presets do
		table.insert(map_names, name)
	end

	-- One of map_presets' maps, by name.
	extras.types.map = pow_types.named("map", "A map, by name", map_names)
	-- One of shared/skins' skins, by name.
	extras.types.skin = pow_types.named("skin", "A skin, by name", skins.names())
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

	-- The pool skin's donut commands, for debugging it. The donut's state is the server's (server/donuts.luau), so what
	-- they do every player sees. They act on the units you have selected, or with nothing selected on everything of
	-- your team, or of the team given. Each starts on the client, which alone knows what is selected, and carries on
	-- on the server, which alone has the donuts: that is why they are here, where both sides register them, and why
	-- each side's modules are only required inside the half that runs on it.
	local function targets(context: any): { any }
		local ServerScriptService = game:GetService "ServerScriptService"
		local state = require(ServerScriptService.Server.state) :: any
		local players = require(ServerScriptService.Server.players) :: any
		local found = {}
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

	local function with_selection(context: any)
		local selection = require(ReplicatedStorage.Client.selection) :: any
		context.data.selected = selection.get()
		context:defer()
	end

	local TARGET_OVERLOADS = {
		{ returns = "nil", args = {} },
		{ returns = "nil", args = { { name = "Team", type = "number" } } },
	}

	local function donut_command(description: string, act: (donuts: any, entity: any) -> boolean, done: string): any
		return {
			description = description
				.. " Acts on the units you have selected, or with none selected on your team, or on the team given.",
			permissions = { "admin" },
			overloads = TARGET_OVERLOADS,
			client_run = with_selection,
			server_run = function(context: any)
				local donuts = require(game:GetService("ServerScriptService").Server.donuts) :: any
				local count = 0
				local list = targets(context)
				for _, entity in list do
					if act(donuts, entity) then
						count += 1
					end
				end
				context:log({ type = "info", value = `{done} {count} donut(s) of the {#list} unit(s) aimed at` })
			end,
		}
	end

	extras.commands.donut_pop = donut_command("Pops donuts as a hit would.", function(donuts: any, entity: any): boolean
		return donuts.force_off(entity, "pop")
	end, "Popped")

	extras.commands.donut_flyoff = donut_command(
		"Throws donuts off as a fast aircraft does, on anything, not only aircraft.",
		function(donuts: any, entity: any): boolean
			return donuts.force_off(entity, "fly")
		end,
		"Threw off"
	)

	extras.commands.donut_float = donut_command(
		"Floats donuts off as going deep under the water does, on anything: up to the surface, to bob there a while.",
		function(donuts: any, entity: any): boolean
			return donuts.force_off(entity, "float")
		end,
		"Floated off"
	)

	extras.commands.donut_regen = donut_command(
		"Puts new donuts on at once, without waiting out the regen time.",
		function(donuts: any, entity: any): boolean
			return donuts.force_on(entity)
		end,
		"Put back"
	)

	extras.commands.donut_status = {
		description = "Says how many units wear a donut, how many have it on or off, and how many are shaking one "
			.. "loose: of your team, or of the team given, or of everyone if you are on no team.",
		permissions = { "admin" },
		overloads = {
			{ returns = "nil", args = {} },
			{ returns = "nil", args = { { name = "Team", type = "number" } } },
		},
		server_run = function(context: any)
			local ServerScriptService = game:GetService "ServerScriptService"
			local donuts = require(ServerScriptService.Server.donuts) :: any
			local players = require(ServerScriptService.Server.players) :: any
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
