-- The lobby's pow commands: those of the game's (server/pow_server_ext.luau) that mean something without a match, the
-- developer list, skins and saved campaign progress, and a readout of this server's lobbies.
--
-- pow calls its extension modules to let them register commands, so this one returns a function rather than the
-- dictionary RULES.md asks of every other module.

local Players = game:GetService "Players"
local ReplicatedStorage = game:GetService "ReplicatedStorage"

local campaign = require(ReplicatedStorage.Shared.campaign)
local config = require(ReplicatedStorage.Shared.config)
local developers = require(ReplicatedStorage.Shared.developers)
local shared_skins = require(ReplicatedStorage.Shared.skins)
local unit_defs = require(ReplicatedStorage.Shared.unit_defs)

local lobbies = require(script.Parent.lobbies)
local missions = require(script.Parent.missions)
local skins = require(script.Parent.skins)

type Lobby = lobbies.Lobby

local function list_or(names: { string }, empty: string): string
	return if #names > 0 then table.concat(names, ", ") else empty
end

-- Every def that can be locked in the campaign, split by whether `unlocks` has it, each sorted.
local function split_unlocks(unlocks: { [string]: boolean }): ({ string }, { string })
	local unlocked: { string } = {}
	local locked: { string } = {}
	for name in unit_defs.defs do
		if campaign.is_lockable(name) then
			table.insert(if unlocks[name] == true then unlocked else locked, name)
		end
	end
	table.sort(unlocked)
	table.sort(locked)
	return unlocked, locked
end

local function saved_note(saved: boolean): string
	return if saved then "saved" else "not saved: their progress was never read from the store"
end

-- `lobby` in a few lines: its settings, then each seat.
local function describe_lobby(lobby: Lobby): { string }
	local host = Players:GetPlayerByUserId(lobby.host)
	local stage = if lobby.teleporting then "teleporting" elseif lobby.starting then "starting" else "open"
	local ok, blocked = lobbies.can_start(lobby)
	local lines = {
		`{lobby.id}: host {if host ~= nil then host.Name else tostring(lobby.host)} | {lobby.mode} on {lobby.preset}`
			.. ` (seed {lobby.seed}) | {lobby.visibility} | ally griefing {if lobby.ally_griefing then "on" else "off"}`
			.. ` | ends {lobby.end_mode} | {stage}{if ok then ", can start" else ` ({blocked})`}`,
	}
	for _, seat in lobby.seats do
		local bonus = lobby.bonuses[tostring(seat.user_id)]
		table.insert(
			lines,
			`  side {seat.side}: {seat.name} ({seat.user_id})`
				.. `{if lobby.ready[seat.user_id] == true then ", ready" else ""}`
				.. `{if bonus ~= nil then `, bonus {bonus}%` else ""}`
		)
	end
	return lines
end

return function(extras: { commands: { [string]: any } })
	local commands = extras.commands

	commands.developer = {
		description = "Adds a user to the game's developers, who alone may give lobby players a resource bonus, "
			.. "or takes them off it. The list is the same in every place. With no arguments it says who is on it.",
		permissions = { "admin" },
		overloads = {
			{ returns = "nil", args = {} },
			{
				returns = "nil",
				args = { { name = "UserId", type = "number" }, { name = "Developer", type = "boolean" } },
			},
		},
		server_run = function(context: any)
			local user_id, listed = context.args[1], context.args[2]
			local ids, err
			if user_id == nil then
				ids, err = developers.read()
			else
				ids, err = developers.set(user_id, listed)
			end
			if ids == nil then
				context:log({ type = "error", value = `Could not reach the developer list: {err}` })
				return
			end
			local names: { string } = {}
			for _, id in ids do
				table.insert(names, tostring(id))
			end
			context:log({
				type = "info",
				value = if #names > 0
					then `Developers: {table.concat(names, ", ")} (and the game's owner)`
					else "No developers listed (only the game's owner is one)",
			})
		end,
	}

	commands.skins = {
		description = "Lists every skin: whether only developers may wear it, what it changes, and who here has it "
			.. "equipped.",
		permissions = { "admin" },
		overloads = {
			{ returns = "nil", args = {} },
		},
		server_run = function(context: any)
			local lines = {}
			for _, name in shared_skins.names() do
				local skin = shared_skins.get(name)
				local notes = {}
				if skin.developer_only then
					table.insert(notes, "developers only")
				end
				local stats = skin.stats
				if stats ~= nil then
					table.insert(
						notes,
						`health x{stats.health or 1}, range x{stats.range or 1}, damage x{stats.damage or 1}`
					)
				end
				if skin.paint ~= nil then
					table.insert(notes, "repainted")
				end
				if skin.art ~= nil then
					table.insert(notes, "other art")
				end
				for _, attachment in skin.attachments do
					table.insert(notes, `wears a {attachment.kind}`)
				end
				local wearers = {}
				for _, player in Players:GetPlayers() do
					if skins.equipped_by(player) == name then
						table.insert(wearers, player.Name)
					end
				end
				table.insert(
					lines,
					`{name} ({skin.display_name}){if #notes > 0 then ": " .. table.concat(notes, "; ") else ""}`
						.. ` | equipped by: {list_or(wearers, "nobody")}`
				)
			end
			context:log({ type = "info", value = table.concat(lines, "\n") })
		end,
	}

	commands.equip = {
		description = "Equips a skin for you, or for the player given, as the Skins tab does: it is saved, and worn in "
			.. "their games from then on. Unlike the tab it may equip anything, golden too. With no arguments it says "
			.. "what you have equipped.",
		permissions = { "admin" },
		overloads = {
			{ returns = "nil", args = {} },
			{ returns = "nil", args = { { name = "Skin", type = "skin" } } },
			{ returns = "nil", args = { { name = "Skin", type = "skin" }, { name = "Player", type = "player" } } },
		},
		server_run = function(context: any)
			local target: Player = if context.args[2] ~= nil then context.args[2] else context.executor
			local skin_name = context.args[1]
			if skin_name == nil then
				context:log({ type = "info", value = `{target.Name} has {skins.equipped_by(target)} equipped` })
				return
			end
			local ok, reason = skins.equip(target, skin_name, true)
			context:log({
				type = if ok then "info" else "error",
				value = if ok then `{target.Name} now has {skin_name} equipped` else `Could not equip it: {reason}`,
			})
		end,
	}

	commands.complete_mission = {
		description = "Finishes a campaign mission for you, or for the player given, as winning it would: it is marked "
			.. "done and what it unlocks is theirs, and that is saved.",
		permissions = { "admin" },
		overloads = {
			{ returns = "nil", args = { { name = "Mission", type = "mission" } } },
			{
				returns = "nil",
				args = { { name = "Mission", type = "mission" }, { name = "Player", type = "player" } },
			},
		},
		server_run = function(context: any)
			local id = context.args[1]
			local target: Player = if context.args[2] ~= nil then context.args[2] else context.executor
			local _, saved = missions.complete(target, id)
			context:log({ type = "info", value = `Completed {id} for {target.Name} ({saved_note(saved)})` })
		end,
	}

	commands.reset_data = {
		description = "Wipes what is saved for you, or for the player given, as though they had never played: no "
			.. "missions done, the starting unlocks, and the default skin. That is saved.",
		permissions = { "admin" },
		overloads = {
			{ returns = "nil", args = {} },
			{ returns = "nil", args = { { name = "Player", type = "player" } } },
		},
		server_run = function(context: any)
			local target: Player = if context.args[1] ~= nil then context.args[1] else context.executor
			local saved = missions.reset(target)
			local skin_ok, skin_reason = skins.equip(target, config.DEFAULT_SKIN, true)
			context:log({
				type = if skin_ok then "info" else "error",
				value = `Reset {target.Name}'s campaign ({saved_note(saved)})`
					.. if skin_ok then " and skin" else `; their skin was not: {skin_reason}`,
			})
		end,
	}

	-- Read-only readouts, for debugging. Each logs once, everything newline-joined, so it copies in one go.
	commands.unlocks = {
		description = "Shows your campaign progress, or the player given's: each mission and whether it is done, what "
			.. "it unlocks, every def they have unlocked and every one still locked, and whether their progress was "
			.. "read from the store (and so is saved).",
		permissions = { "admin" },
		overloads = {
			{ returns = "nil", args = {} },
			{ returns = "nil", args = { { name = "Player", type = "player" } } },
		},
		server_run = function(context: any)
			local target: Player = if context.args[1] ~= nil then context.args[1] else context.executor
			local progress, saved = missions.status(target)
			local unlocked, locked = split_unlocks(progress.unlocks)
			local lines = {
				`{target.Name}'s campaign ({if saved then "read from the store, saved" else "not read, never saved"}):`,
			}
			for _, mission in campaign.MISSIONS do
				table.insert(
					lines,
					`  [{if progress.completed[mission.id] then "x" else " "}] {mission.label} ({mission.id})`
						.. ` unlocks: {list_or(mission.unlocks, "nothing")}`
				)
			end
			table.insert(lines, `Unlocked ({#unlocked}): {list_or(unlocked, "nothing")}`)
			table.insert(lines, `Locked ({#locked}): {list_or(locked, "nothing")}`)
			context:log({ type = "info", value = table.concat(lines, "\n") })
		end,
	}

	commands.player_stats = {
		description = "Shows everything about you, or the player given: user id, developer or not, skin, campaign "
			.. "progress, and the lobby or mission they are in.",
		permissions = { "admin" },
		overloads = {
			{ returns = "nil", args = {} },
			{ returns = "nil", args = { { name = "Player", type = "player" } } },
		},
		server_run = function(context: any)
			local target: Player = if context.args[1] ~= nil then context.args[1] else context.executor
			local progress, saved = missions.status(target)
			local done = 0
			for _, mission in campaign.MISSIONS do
				if progress.completed[mission.id] then
					done += 1
				end
			end
			local unlocked = split_unlocks(progress.unlocks)
			local lines = {
				`{target.Name} ({target.DisplayName}) | user id {target.UserId}`
					.. ` | developer: {if developers.is_developer(target) then "yes" else "no"}`
					.. ` | skin equipped: {skins.equipped_by(target)}`,
				`  campaign: {done} / {#campaign.MISSIONS} missions done, {#unlocked} lockable defs unlocked`
					.. ` ({if saved then "saved" else "not saved"}; /unlocks for the list)`,
			}
			local mission = missions.mission_of(target)
			if mission ~= nil then
				local why = if mission.reason ~= nil then ` ({mission.reason})` else ""
				table.insert(lines, `  mission: {mission.id}, {mission.stage}{why}`)
			end
			local lobby = lobbies.of_user(target.UserId)
			if lobby == nil then
				table.insert(lines, "  in no lobby")
			else
				for _, line in describe_lobby(lobby) do
					table.insert(lines, `  {line}`)
				end
			end
			context:log({ type = "info", value = table.concat(lines, "\n") })
		end,
	}

	commands.lobbies = {
		description = "Lists the lobbies on this server: each one's settings, whether it can start, and who is in it "
			.. "on which side.",
		permissions = { "admin" },
		overloads = {
			{ returns = "nil", args = {} },
		},
		server_run = function(context: any)
			local ids: { string } = {}
			for id in lobbies.all() do
				table.insert(ids, id)
			end
			table.sort(ids)
			local lines = { `{#ids} lobbies on this server ({#Players:GetPlayers()} players here)` }
			for _, id in ids do
				local lobby = lobbies.get(id)
				if lobby ~= nil then
					for _, line in describe_lobby(lobby) do
						table.insert(lines, line)
					end
				end
			end
			context:log({ type = "info", value = table.concat(lines, "\n") })
		end,
	}
end
