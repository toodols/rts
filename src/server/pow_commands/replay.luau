-- The pow commands that control a replay being played back (server/replay.luau): where it is, and seeking.
--
-- pow calls its extension modules to let them register commands, so this one returns a function rather than the
-- dictionary RULES.md asks of every other module.

local ReplicatedStorage = game:GetService "ReplicatedStorage"
local ServerScriptService = game:GetService "ServerScriptService"
local Workspace = game:GetService "Workspace"

local pow_types = require(ReplicatedStorage.Shared.pow_types)

local pow_builders = require(ServerScriptService.ServerShared.pow_builders)

local replay = require(ServerScriptService.Server.replay)
local state = require(ServerScriptService.Server.state)

-- Seconds as m:ss.
local function clock(seconds: number): string
	return `{math.floor(seconds // 60)}:{string.format("%02d", math.floor(seconds % 60))}`
end

-- Where `text` asks to be in a replay `length` seconds long: seconds ("600"), minutes and seconds ("10:00"), or a share
-- of it ("90%"); nil for none of those.
local function parse_time(text: string, length: number): number?
	local share = string.match(text, "^([%d%.]+)%%$")
	if share ~= nil then
		local value = tonumber(share)
		return if value ~= nil then length * value / 100 else nil
	end
	local minutes, seconds = string.match(text, "^(%d+):(%d%d?)$")
	if minutes ~= nil then
		return (tonumber(minutes) :: number) * 60 + (tonumber(seconds) :: number)
	end
	return tonumber(text)
end

return function(extras: pow_types.Extras)
	local commands = extras.commands

	commands.replay = {
		description = "Controls the replay being played back (set up with tools/ai_arena/replay.py studio). "
			.. "`replay status` says where it is and whether it is still the recorded game; `replay seek <at>` goes to "
			.. "a moment of it, given as seconds (600), minutes and seconds (10:00) or a share of it (90%), from the "
			.. "nearest jump point before it. pause and warp work on it as on any game.",
		permissions = { "admin" },
		overloads = {
			{ returns = "nil", args = { { name = "Action", type = "string" } } },
			{ returns = "nil", args = { { name = "Action", type = "string" }, { name = "At", type = "string" } } },
		},
		server_run = function(context: pow_builders.Context)
			if replay.playing() == false then
				context:log({ type = "error", value = "No replay is being played" })
				return
			end
			local manifest = replay.read_manifest()
			local action = context.args[1]
			if action == "status" then
				local status = Workspace:GetAttribute(replay.REPLAY_ATTRIBUTES.status)
				context:log({
					type = "info",
					value = `Replay at {clock(state.now())} of {clock(manifest.length)}, {status}; `
						.. `{#manifest.keyframes} jump points {manifest.keyframe_every} s apart`,
				})
			elseif action == "seek" then
				local at = if context.args[2] ~= nil then parse_time(context.args[2], manifest.length) else nil
				if at == nil then
					context:log({ type = "error", value = "Seek to what? 600, 10:00 or 90%" })
					return
				end
				local target = replay.seek(at)
				context:log({ type = "info", value = `Seeking to {clock(target)}` })
			else
				context:log({ type = "error", value = "replay status, or replay seek <at>" })
			end
		end,
	}
end
