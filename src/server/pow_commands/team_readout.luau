-- A team as the pow commands describe it (team_list, team_info, player_info): a line of who plays it, its allies and
-- its bank, and in full, its flow, what it has on the map and what it has done this game.

local ReplicatedStorage = game:GetService "ReplicatedStorage"
local ServerScriptService = game:GetService "ServerScriptService"

local types = require(ReplicatedStorage.Shared.types)
local unit_defs = require(ReplicatedStorage.Shared.unit_defs)

local pow_builders = require(ServerScriptService.ServerShared.pow_builders)
local pow_common = require(ServerScriptService.ServerShared.pow_common)

local ai = require(ServerScriptService.Server.ai)
local alliances = require(ServerScriptService.Server.alliances)
local economy = require(ServerScriptService.Server.economy)
local match_stats = require(ServerScriptService.Server.match_stats)
local players = require(ServerScriptService.Server.players)
local state = require(ServerScriptService.Server.state)
local unlocks = require(ServerScriptService.Server.unlocks)

type TeamId = types.TeamId

local list_or = pow_builders.list_or

local function one_decimal(value: number): string
	return string.format("%.1f", value)
end

-- Team `team_id` in a line: its name, who plays it, its allies, and its bank. Nil for a team there is not.
local function summary(team_id: TeamId): string?
	local team = state.get_team(team_id)
	if team == nil then
		return nil
	end
	local names: { string } = {}
	for _, player in players.players_on_team(team_id) do
		table.insert(names, player.Name)
	end
	local allies: { string } = {}
	for _, ally in alliances.group_of(team_id, state.all_teams()) do
		if ally ~= team_id then
			table.insert(allies, tostring(ally))
		end
	end
	return `Team {team_id} "{team.name}" | players: {list_or(names, "none")} | allies: {list_or(allies, "none")}`
		.. ` | metal {math.floor(team.metal)} / {math.floor(team.metal_capacity)}, energy {math.floor(team.energy)}`
		.. ` / {math.floor(team.energy_capacity)}`
end

-- Team `team_id` in full: its summary, its skin, bonus and whether the AI plays it, its bank and flow, what it has on
-- the map and what it has done this game. Nil for a team there is not.
local function full(team_id: TeamId): { string }?
	local team = state.get_team(team_id)
	local head = summary(team_id)
	if team == nil or head == nil then
		return nil
	end

	local units, buildings, blueprints = 0, 0, 0
	local by_def: { [string]: number } = {}
	local commander_health: string? = nil
	for _, entity in state.all() do
		if entity.team ~= team_id or (entity.kind ~= "unit" and entity.kind ~= "building") then
			continue
		end
		if entity.state == "blueprint" then
			blueprints += 1
			continue
		end
		if entity.kind == "unit" then
			units += 1
		else
			buildings += 1
		end
		by_def[entity.def_name] = (by_def[entity.def_name] or 0) + 1
		if unit_defs.is_commander(entity.def) then
			commander_health = `{math.floor(entity.health)} / {math.floor(entity.max_health)}`
		end
	end
	local counts: { { name: string, count: number } } = {}
	for name, count in by_def do
		table.insert(counts, { name = name, count = count })
	end
	table.sort(counts, function(a: { name: string, count: number }, b: { name: string, count: number }): boolean
		return if a.count ~= b.count then a.count > b.count else a.name < b.name
	end)
	local top: { string } = {}
	for index, row in counts do
		if index > 10 then
			table.insert(top, `+{#counts - 10} more kinds`)
			break
		end
		table.insert(top, `{row.name} x{row.count}`)
	end

	local tally = match_stats.tally_for(team_id)
	local unlocked = unlocks.of_team(team_id)
	local may_build = if unlocked ~= nil
		then `{#(pow_common.split_unlocks(unlocked))} lockable defs unlocked`
		else "anything (no player on it)"
	local bonus = economy.bonus_of(team_id)
	return {
		head,
		`  skin: {team.skin}{if bonus ~= 0 then ` | bonus {one_decimal(bonus)}%` else ""}{if ai.is_ai(team_id)
			then " | played by the AI"
			else ""}`,
		`  metal income {one_decimal(team.metal_income)}/s (in {one_decimal(team.metal_revenue)}, out`
			.. ` {one_decimal(team.metal_expense)}), energy income {one_decimal(team.energy_income)}/s (in`
			.. ` {one_decimal(team.energy_revenue)}, out {one_decimal(team.energy_expense)})`,
		`  {units} units, {buildings} buildings, {blueprints} blueprints | commander: {commander_health or "none"}`,
		`  most: {list_or(top, "nothing")}`,
		`  this game: {math.floor(tally.damage)} damage (worth {math.floor(tally.destroyed)}), {tally.kills} kills,`
			.. ` {tally.lost} lost, {math.floor(tally.metal)} metal made`,
		`  may build: {may_build}`,
	}
end

return table.freeze({
	one_decimal = one_decimal,
	summary = summary,
	full = full,
})
