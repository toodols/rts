-- The pow commands that turn the game's switches (shared/switches.luau) and warp it.
--
-- pow calls its extension modules to let them register commands, so this one returns a function rather than the
-- dictionary RULES.md asks of every other module.

local ReplicatedStorage = game:GetService "ReplicatedStorage"
local ServerScriptService = game:GetService "ServerScriptService"

local tick_rate = require(ReplicatedStorage.Shared.tick_rate)
local pow_types = require(ReplicatedStorage.Shared.pow_types)
local switches = require(ReplicatedStorage.Shared.switches)

local pow_builders = require(ServerScriptService.ServerShared.pow_builders)

local warp = require(ServerScriptService.Server.warp)

-- A toggle of switch `name`.
local function switch_toggle(
	name: switches.Name,
	argument: string,
	description: string,
	on: string,
	off: string
): pow_builders.Command
	return pow_builders.toggle({
		description = description,
		argument = argument,
		get = function(): boolean
			return switches.is_on(name)
		end,
		set = function(value: boolean)
			switches.set(name, value)
		end,
		on = on,
		off = off,
	})
end

return function(extras: pow_types.Extras)
	local commands = extras.commands

	commands.godmode = switch_toggle(
		"godmode",
		"Enabled",
		"Lets every player command every team.",
		"Godmode on: you can command every team",
		"Godmode off"
	)
	commands.nocost = switch_toggle(
		"nocost",
		"Enabled",
		"Makes everything build for free and at once, as if it cost nothing.",
		"Nocost on: everything builds free and instantly",
		"Nocost off"
	)
	commands.pause = switch_toggle(
		"paused",
		"Paused",
		"Stops the simulation stepping at all, as if the game's speed were zero.",
		"Paused",
		"Unpaused"
	)
	commands.scavengers = switch_toggle(
		"scavengers",
		"Enabled",
		"Turns the scavengers gamemode on or off: whether beacons appear and make anything.",
		"Scavengers on",
		"Scavengers off"
	)

	commands.warp = {
		description = "Runs the next Ticks ticks of the simulation as fast as it can, every step right after "
			.. "the last with no real-time pacing between them, instead of the usual one tick per (roughly) "
			.. "1/20th of a second, then goes back to normal. Replaces any warp already running; warp_stop "
			.. "stops it early. With no argument it says how many ticks are left.",
		permissions = { "admin" },
		overloads = {
			{ returns = "nil", args = {} },
			{ returns = "nil", args = { { name = "Ticks", type = "number" } } },
		},
		server_run = function(context: pow_builders.Context)
			local ticks = context.args[1]
			if ticks == nil then
				local remaining = warp.ticks_remaining()
				context:log({
					type = "info",
					value = if remaining == 0
						then "Not warping"
						elseif remaining == math.huge then "Warping until stopped"
						else `Warping, {remaining} ticks left`,
				})
				return
			end
			ticks = math.floor(ticks)
			if ticks <= 0 then
				context:log({ type = "error", value = "Ticks must be at least 1" })
				return
			end
			warp.start(ticks)
			context:log({
				type = "info",
				value = `Warping {ticks} ticks ({string.format("%.1f", ticks * tick_rate.TICK_DELTA)}s of sim time)`,
			})
		end,
	}

	commands.warp_stop = {
		description = "Stops a warp early, going back to one tick per (roughly) 1/20th of a second.",
		permissions = { "admin" },
		overloads = {
			{ returns = "nil", args = {} },
		},
		server_run = function(context: pow_builders.Context)
			if warp.is_warping() == false then
				context:log({ type = "info", value = "Not warping" })
				return
			end
			local remaining = warp.ticks_remaining()
			warp.stop()
			context:log({
				type = "info",
				value = if remaining == math.huge then "Warp stopped" else `Warp stopped with {remaining} ticks left`,
			})
		end,
	}
end
