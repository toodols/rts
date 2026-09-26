--!strict
-- What pow commands (the command bar, see pow_setup.luau) are built from, in every place: the player a command acts on,
-- a readout logged in one go, and a command that turns a switch.

-- A pow command's context, as pow hands it to `server_run`.
export type Context = any
-- A pow command, as pow registers it.
export type Command = { [string]: any }

-- What a toggle turns (`toggle`).
export type Toggle = {
	description: string,
	-- the argument's name, as the command bar shows it
	argument: string,
	get: () -> boolean,
	set: (boolean) -> (),
	-- what it says once it is on, and once it is off
	on: string,
	off: string,
}

-- The player argument `index` of `context` names, or whoever ran the command.
local function target_player(context: Context, index: number): Player
	local given = context.args[index]
	return if given ~= nil then given else context.executor
end

-- Logs `lines` as one message, so that it copies out of the command bar in one go.
local function readout(context: Context, lines: { string })
	context:log({ type = "info", value = table.concat(lines, "\n") })
end

-- `names` joined with commas, or `empty` if there are none.
local function list_or(names: { string }, empty: string): string
	return if #names > 0 then table.concat(names, ", ") else empty
end

-- A command that turns `toggle` on or off as it is told, or with no argument the other way from how it is.
local function toggle(spec: Toggle): Command
	return {
		description = `{spec.description} With no argument it toggles.`,
		permissions = { "admin" },
		overloads = {
			{ returns = "nil", args = {} },
			{ returns = "nil", args = { { name = spec.argument, type = "boolean" } } },
		},
		server_run = function(context: Context)
			local on = if context.args[1] ~= nil then context.args[1] else spec.get() == false
			spec.set(on)
			context:log({ type = "info", value = if on then spec.on else spec.off })
		end,
	}
end

return table.freeze({
	target_player = target_player,
	readout = readout,
	list_or = list_or,
	toggle = toggle,
})
