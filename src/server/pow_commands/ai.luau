-- The pow commands that hand teams to the AI and say how it is getting on.
--
-- pow calls its extension modules to let them register commands, so this one returns a function rather than the
-- dictionary RULES.md asks of every other module.

local ReplicatedStorage = game:GetService "ReplicatedStorage"
local ServerScriptService = game:GetService "ServerScriptService"

local ai_profiles = require(ReplicatedStorage.Shared.ai_profiles)
local heightmap = require(ReplicatedStorage.Shared.heightmap)
local pow_types = require(ReplicatedStorage.Shared.pow_types)
local starts = require(ReplicatedStorage.Shared.starts)
local teams = require(ReplicatedStorage.Shared.teams)

local pow_builders = require(ServerScriptService.ServerShared.pow_builders)

local ai = require(ServerScriptService.Server.ai)
local spawning = require(ServerScriptService.Server.spawning)
local state = require(ServerScriptService.Server.state)

type Context = pow_builders.Context

return function(extras: pow_types.Extras)
	local commands = extras.commands

	-- ai_add's arguments come in this order, each overload taking one more: where it starts is either a start box
	-- (Start, 0 for the free start furthest from everyone) or a spot (X, Z), and the two are told apart by what comes
	-- fourth, a number only for a spot.
	local AI_NAME = { name = "Name", type = "string" }
	local AI_COUNT = { name = "Count", type = "number" }
	local AI_START = { name = "Start", type = "number" }
	local AI_X = { name = "X", type = "number" }
	local AI_Z = { name = "Z", type = "number" }
	local AI_SIDE = { name = "Side", type = "ai_side" }
	local AI_TEAM = { name = "Team", type = "number" }
	local AI_LINE = { name = "Line", type = "ai_line" }
	local AI_PROFILE = { name = "Profile", type = "ai_profile" }
	local PROFILE_NAMES = table.concat(ai_profiles.names(), ", ")

	commands.ai_add = {
		description = "Adds AI players, by default one enemy at the free start furthest from everyone. Start: a box, 0 "
			.. "for the furthest. Side: enemy, ally (of Team) or join (plays Team). Line: bot, vehicle or any. "
			.. `Profile: how it plays ({PROFILE_NAMES}).`,
		permissions = { "admin" },
		overloads = {
			{ returns = "nil", args = {} },
			{ returns = "nil", args = { AI_NAME } },
			{ returns = "nil", args = { AI_NAME, AI_COUNT } },
			{ returns = "nil", args = { AI_NAME, AI_COUNT, AI_START } },
			{ returns = "nil", args = { AI_NAME, AI_COUNT, AI_X, AI_Z } },
			{ returns = "nil", args = { AI_NAME, AI_COUNT, AI_START, AI_SIDE, AI_TEAM } },
			{ returns = "nil", args = { AI_NAME, AI_COUNT, AI_X, AI_Z, AI_SIDE, AI_TEAM } },
			{ returns = "nil", args = { AI_NAME, AI_COUNT, AI_START, AI_SIDE, AI_TEAM, AI_LINE } },
			{ returns = "nil", args = { AI_NAME, AI_COUNT, AI_X, AI_Z, AI_SIDE, AI_TEAM, AI_LINE } },
			{ returns = "nil", args = { AI_NAME, AI_COUNT, AI_START, AI_SIDE, AI_TEAM, AI_LINE, AI_PROFILE } },
			{ returns = "nil", args = { AI_NAME, AI_COUNT, AI_X, AI_Z, AI_SIDE, AI_TEAM, AI_LINE, AI_PROFILE } },
		},
		server_run = function(context: Context)
			local args = context.args
			local name: string? = args[1]
			local count: number = if args[2] ~= nil then math.floor(args[2]) else 1
			local at: Vector2? = nil
			local box: number? = nil
			local next_arg = 4
			if typeof(args[4]) == "number" then
				if heightmap.in_bounds(args[3], args[4]) == false then
					context:log({ type = "error", value = `({args[3]}, {args[4]}) is off the map` })
					return
				end
				at = Vector2.new(args[3], args[4])
				next_arg = 5
			elseif args[3] ~= nil and args[3] ~= 0 then
				box = math.floor(args[3])
				if box < 1 or box > starts.box_count() then
					context:log({
						type = "error",
						value = `There is no start {box}; there are 1 to {starts.box_count()}`,
					})
					return
				end
			end
			local side: string = args[next_arg] or "enemy"
			local team: number = args[next_arg + 1] or 0
			local line: string? = args[next_arg + 2]
			-- "any" leaves the line to the profile, or to the AI
			if line == "any" then
				line = nil
			end
			local profile_name: string = args[next_arg + 3] or "default"
			local profile = ai_profiles.get(profile_name)
			if profile == nil then
				context:log({ type = "error", value = `There is no AI profile {profile_name}` })
				return
			end

			if count < 1 then
				context:log({ type = "error", value = "Count must be at least 1" })
				return
			end
			if side ~= "enemy" and (teams.is_playable(team) == false or state.get_team(team) == nil) then
				context:log({ type = "error", value = `There is no team {team} to {side}` })
				return
			end

			-- Where the next commander goes, worked out afresh for each so that each keeps clear of the last, or why
			-- there is nowhere.
			local function start(): (Vector2?, string?)
				if at ~= nil then
					return at, nil
				elseif box ~= nil then
					local spot = spawning.box_start(box)
					return spot,
						if spot == nil
							then `Start {box} has no ground left {spawning.MIN_START_SPACING} studs from everyone`
							else nil
				end
				local spot = spawning.free_start()
				return spot,
					if spot == nil
						then `Nowhere on the map is {spawning.MIN_START_SPACING} studs from everyone; give a start or X Z`
						else nil
			end

			-- joining plays a team that is already there, so there is only ever the one
			if side == "join" then
				local team_id = team
				local spot: Vector2? = nil
				if spawning.owns_anything(team_id) == false then
					local reason
					spot, reason = start()
					if spot == nil then
						context:log({ type = "error", value = reason })
						return
					end
				end
				local placed = ai.take_over(team_id, spot, profile)
				if placed and line ~= nil then
					ai.set_line(team_id, line :: any)
				end
				context:log({
					type = if placed then "info" else "error",
					value = if placed
						then `Team {team_id} is played by the AI`
						else "There was no room for the AI's commander",
				})
				return
			end

			-- every AI is put down before anything is said, so that a log that fails cannot leave the rest undone
			local lines: { string } = {}
			local failed = false
			for index = 1, count do
				local spot, reason = start()
				if spot == nil then
					table.insert(lines, reason :: string)
					failed = true
					break
				end
				local team_name = if name ~= nil and count > 1 then `{name} {index}` else name
				local team_id = ai.spawn_opponent(team_name, spot, if side == "ally" then team else nil, profile)
				if team_id == nil then
					table.insert(lines, "There was no room for the AI's commander")
					failed = true
					break
				end
				if line ~= nil then
					ai.set_line(team_id, line :: any)
				end
				table.insert(
					lines,
					if side == "ally"
						then `Team {team_id} is played by the AI, allied with team {team}`
						else `Team {team_id} is played by the AI`
				)
			end
			context:log({ type = if failed then "error" else "info", value = table.concat(lines, "\n") })
		end,
	}

	commands.ai_control = {
		description = "Hands a team to the AI, or takes it back. Without Enabled it flips whether the AI plays it.",
		permissions = { "admin" },
		overloads = {
			{ returns = "nil", args = { { name = "Team", type = "number" } } },
			{ returns = "nil", args = { { name = "Team", type = "number" }, { name = "Enabled", type = "boolean" } } },
		},
		server_run = function(context: Context)
			local team_id = context.args[1]
			-- the neutral team and the scavengers are nothing for the AI to play
			if teams.is_playable(team_id) == false or state.get_team(team_id) == nil then
				context:log({ type = "error", value = `There is no team {team_id}` })
				return
			end
			local enabled = context.args[2]
			if enabled == nil then
				enabled = ai.is_ai(team_id) == false
			end
			if enabled then
				ai.add(team_id)
			else
				ai.remove(team_id)
			end
			context:log({
				type = "info",
				value = if enabled then `Team {team_id} is played by the AI` else `The AI lets team {team_id} go`,
			})
		end,
	}

	commands.ai_profile = {
		description = `Makes the AI playing Team play by Profile from now on ({PROFILE_NAMES}).`,
		permissions = { "admin" },
		overloads = {
			{ returns = "nil", args = { { name = "Team", type = "number" }, AI_PROFILE } },
		},
		server_run = function(context: Context)
			local team_id = context.args[1]
			local profile = ai_profiles.get(context.args[2])
			if profile == nil then
				context:log({ type = "error", value = `There is no AI profile {context.args[2]}` })
				return
			end
			if ai.set_profile(team_id, profile) == false then
				context:log({ type = "error", value = `The AI does not play team {team_id}` })
				return
			end
			context:log({ type = "info", value = `Team {team_id}'s AI plays as {profile.name}` })
		end,
	}

	commands.ai_status = {
		description = "Says how each team the AI plays is getting on.",
		permissions = { "admin" },
		overloads = {
			{ returns = "nil", args = {} },
		},
		server_run = function(context: Context)
			local played = ai.teams()
			local lines: { string } = {}
			for _, team_id in played do
				table.insert(lines, ai.describe(team_id) or `Team {team_id}`)
			end
			pow_builders.readout(context, if #lines > 0 then lines else { "The AI plays no team" })
		end,
	}
end
