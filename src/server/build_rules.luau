--!strict
-- What a team may build or make. The simulation asks here and knows nothing of why a team may not: whatever holds teams
-- back, like the campaign's unlocks (server/unlocks.luau), adds a rule, and something is allowed only if every rule
-- allows it.

local ReplicatedStorage = game:GetService "ReplicatedStorage"

local types = require(ReplicatedStorage.Shared.types)

type TeamId = types.TeamId

export type Rule = (team_id: TeamId, def_name: string) -> boolean

local rules: { Rule } = {}

-- Holds every team to `rule` from now on, until the returned function is called.
local function add(rule: Rule): () -> ()
	table.insert(rules, rule)
	return function()
		local index = table.find(rules, rule)
		if index ~= nil then
			table.remove(rules, index)
		end
	end
end

-- Whether `team_id` may build or make `def_name`.
local function allows(team_id: TeamId, def_name: string): boolean
	for _, rule in rules do
		if rule(team_id, def_name) == false then
			return false
		end
	end
	return true
end

return table.freeze({
	add = add,
	allows = allows,
})
