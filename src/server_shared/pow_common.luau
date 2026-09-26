--!strict
-- The pow commands every place has, on what every place keeps of a player the same way: the developers' list
-- (developer_list.luau), skins (skin_session.luau) and campaign progress (campaign_session.luau). Each place registers
-- them from its own server extension, handing in what only it knows of a player (`Place`), and adds its own commands.

local Players = game:GetService "Players"
local ReplicatedStorage = game:GetService "ReplicatedStorage"

local campaign = require(ReplicatedStorage.Shared.campaign)
local developers = require(ReplicatedStorage.Shared.developers)
local skins = require(ReplicatedStorage.Shared.skins)
local unit_defs = require(ReplicatedStorage.Shared.unit_defs)

local developer_list = require(script.Parent.developer_list)
local skin_session = require(script.Parent.skin_session)
local campaign_session = require(script.Parent.campaign_session)
local pow_builders = require(script.Parent.pow_builders)

type Context = pow_builders.Context
type Command = pow_builders.Command

-- What a place adds to what these commands say.
export type Place = {
	-- lines about `player` that only this place knows: their team in a game, their lobby in the lobby
	player_lines: (Player) -> { string },
	-- a note about the skin `name` only this place knows, such as which teams wear it
	skin_note: ((name: string) -> string?)?,
}

local target_player = pow_builders.target_player
local readout = pow_builders.readout
local list_or = pow_builders.list_or

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

-- Whether `player`'s progress was read from the store, and so is saved as it changes.
local function is_saved(player: Player): boolean
	return campaign_session.status(player) == "loaded"
end

-- What became of a change to what is kept of `player`, as a line: `done`, and whether it was saved.
local function outcome_line(done: string, outcome: string, why: string?): (string, string)
	if outcome == "refused" then
		return "error", `Could not: {why}`
	end
	return "info", if outcome == "saved" then `{done} (saved)` else `{done} ({why or "not saved"})`
end

-- Logs the developers' list, `ids`, as developer_list hands it back, or `err`, why it could not be reached.
local function log_developers(context: Context, ids: { number }?, err: string?)
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
end

local function developer_list_command(): Command
	return {
		description = "Lists the game's developers, who alone may give lobby players a resource bonus and use this "
			.. "command bar. The list is the same in every place.",
		permissions = { "admin" },
		overloads = {
			{ returns = "nil", args = {} },
		},
		server_run = function(context: Context)
			log_developers(context, developer_list.read())
		end,
	}
end

local function developer_set(): Command
	return {
		description = "Adds a user to the game's developers, or with Listed false takes them off. The list is the "
			.. "same in every place.",
		permissions = { "admin" },
		overloads = {
			{
				returns = "nil",
				args = { { name = "UserId", type = "number" }, { name = "Listed", type = "boolean" } },
			},
		},
		server_run = function(context: Context)
			log_developers(context, developer_list.set(context.args[1], context.args[2]))
		end,
	}
end

local function skin_list(place: Place): Command
	return {
		description = "Lists every skin: whether only developers may wear it, what it changes, and who here has it "
			.. "equipped.",
		permissions = { "admin" },
		overloads = {
			{ returns = "nil", args = {} },
		},
		server_run = function(context: Context)
			local lines = {}
			for _, name in skins.names() do
				local skin = skins.get(name)
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
				if skin.donut ~= nil then
					table.insert(notes, "wears a donut")
				end
				local wearers = {}
				for _, player in Players:GetPlayers() do
					if skin_session.equipped_by(player) == name then
						table.insert(wearers, player.Name)
					end
				end
				local note = if place.skin_note ~= nil then place.skin_note(name) else nil
				table.insert(
					lines,
					`{name} ({skin.display_name}){if #notes > 0 then ": " .. table.concat(notes, "; ") else ""}`
						.. ` | equipped by: {list_or(wearers, "nobody")}{if note ~= nil then " | " .. note else ""}`
				)
			end
			readout(context, lines)
		end,
	}
end

local function skin_equip(): Command
	return {
		description = "Equips a skin for you, or for the player given, as the lobby's Skins tab does: it is saved, and "
			.. "worn in their games from then on, and at once in this one. Unlike the tab it may equip anything, "
			.. "golden too. With no arguments it says what you have equipped.",
		permissions = { "admin" },
		overloads = {
			{ returns = "nil", args = {} },
			{ returns = "nil", args = { { name = "Skin", type = "skin" } } },
			{ returns = "nil", args = { { name = "Skin", type = "skin" }, { name = "Player", type = "player" } } },
		},
		server_run = function(context: Context)
			local target = target_player(context, 2)
			local skin_name = context.args[1]
			if skin_name == nil then
				context:log({ type = "info", value = `{target.Name} has {skin_session.equipped_by(target)} equipped` })
				return
			end
			local outcome, why = skin_session.equip(target, skin_name, true)
			local kind, line = outcome_line(`{target.Name} now has {skin_name} equipped`, outcome, why)
			context:log({ type = kind, value = line })
		end,
	}
end

local function mission_complete(): Command
	return {
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
		server_run = function(context: Context)
			local id = context.args[1]
			local target = target_player(context, 2)
			local outcome, why = campaign_session.complete(target, id, false)
			local kind, line = outcome_line(`Completed {id} for {target.Name}`, outcome, why)
			context:log({ type = kind, value = line })
		end,
	}
end

local function player_reset(): Command
	return {
		description = "Wipes what is saved for you, or for the player given, as though they had never played: no "
			.. "missions done, the starting unlocks, and the default skin. That is saved.",
		permissions = { "admin" },
		overloads = {
			{ returns = "nil", args = {} },
			{ returns = "nil", args = { { name = "Player", type = "player" } } },
		},
		server_run = function(context: Context)
			local target = target_player(context, 1)
			local campaign_outcome, campaign_why = campaign_session.reset(target)
			local skin_outcome, skin_why = skin_session.equip(target, skins.DEFAULT_SKIN, true)
			local _, campaign_line = outcome_line("campaign reset", campaign_outcome, campaign_why)
			local _, skin_line = outcome_line("skin reset", skin_outcome, skin_why)
			context:log({
				type = if campaign_outcome == "refused" or skin_outcome == "refused" then "error" else "info",
				value = `{target.Name}: {campaign_line}; {skin_line}`,
			})
		end,
	}
end

-- Read-only readouts, for debugging. Each logs once, everything newline-joined, so that it copies in one go.
local function unlock_list(): Command
	return {
		description = "Shows your campaign progress, or the player given's: each mission and whether it is done, what "
			.. "it unlocks, every def they have unlocked and every one still locked, and whether their progress was "
			.. "read from the store (and so is saved).",
		permissions = { "admin" },
		overloads = {
			{ returns = "nil", args = {} },
			{ returns = "nil", args = { { name = "Player", type = "player" } } },
		},
		server_run = function(context: Context)
			local target = target_player(context, 1)
			local progress = campaign_session.progress_of(target)
			local unlocked, locked = split_unlocks(progress.unlocks)
			local lines = {
				`{target.Name}'s campaign ({if is_saved(target)
					then "read from the store, saved"
					else "not read, never saved"}):`,
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
			readout(context, lines)
		end,
	}
end

local function player_info(place: Place): Command
	return {
		description = "Shows everything about you, or the player given: user id, developer or not, skin, campaign "
			.. "progress, and what they are doing here.",
		permissions = { "admin" },
		overloads = {
			{ returns = "nil", args = {} },
			{ returns = "nil", args = { { name = "Player", type = "player" } } },
		},
		server_run = function(context: Context)
			local target = target_player(context, 1)
			local progress = campaign_session.progress_of(target)
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
					.. ` | skin equipped: {skin_session.equipped_by(target)}`,
				`  campaign: {done} / {#campaign.MISSIONS} missions done, {#unlocked} lockable defs unlocked`
					.. ` ({if is_saved(target) then "saved" else "not saved"}; unlock_list for the list)`,
			}
			for _, line in place.player_lines(target) do
				table.insert(lines, line)
			end
			readout(context, lines)
		end,
	}
end

-- Registers every command here into pow's `commands`, `place` saying what only it knows.
local function register(commands: { [string]: Command }, place: Place)
	commands.developer_list = developer_list_command()
	commands.developer_set = developer_set()
	commands.skin_list = skin_list(place)
	commands.skin_equip = skin_equip()
	commands.mission_complete = mission_complete()
	commands.player_info = player_info(place)
	commands.player_reset = player_reset()
	commands.unlock_list = unlock_list()
end

return table.freeze({
	split_unlocks = split_unlocks,
	register = register,
})
