-- Which teams are allied. An alliance is transitive: allying a with b and b with c makes a and c allies too,
-- so teams fall into groups and two teams are allied when they are in the same one. A team is always allied
-- with itself, and nothing here ever splits a group.
--
-- Whether a team's weapons may hurt its allies is the match's choice (`set_ally_griefing`). BAR always lets them, so a
-- commander can disintegrate an ally's extractors; here that is off unless the lobby turned it on. A team's weapons
-- always hurt its own things either way.

local ReplicatedStorage = game:GetService "ReplicatedStorage"

local types = require(ReplicatedStorage.Shared.types)

type TeamId = types.TeamId

-- Each team that has been allied with another points at a team nearer the group's root; the root points at itself.
local parent: { [TeamId]: TeamId } = {}

local ally_griefing = false

local function root_of(team_id: TeamId): TeamId
	local current = team_id
	while parent[current] ~= nil and parent[current] ~= current do
		current = parent[current]
	end
	return current
end

local function are_allied(a: TeamId, b: TeamId): boolean
	return a == b or root_of(a) == root_of(b)
end

-- Joins the groups of `a` and `b`. Returns false if they already were allied.
local function ally(a: TeamId, b: TeamId): boolean
	if are_allied(a, b) then
		return false
	end
	parent[root_of(a)] = root_of(b)
	parent[root_of(b)] = root_of(b)
	return true
end

-- Every team in `team_id`'s group, itself included, among `teams`, in order.
local function group_of(team_id: TeamId, teams: { [TeamId]: types.Team }): { TeamId }
	local result = {}
	for other in teams do
		if are_allied(team_id, other) then
			table.insert(result, other)
		end
	end
	table.sort(result)
	return result
end

local function set_ally_griefing(enabled: boolean)
	ally_griefing = enabled
end

local function is_ally_griefing(): boolean
	return ally_griefing
end

-- Whether a weapon of `attacker`'s may hurt what `target` owns: its own things and anyone not allied with it, always;
-- an ally's only with ally griefing on.
local function may_harm(attacker: TeamId, target: TeamId): boolean
	return ally_griefing or attacker == target or are_allied(attacker, target) == false
end

return table.freeze({
	ally = ally,
	are_allied = are_allied,
	set_ally_griefing = set_ally_griefing,
	is_ally_griefing = is_ally_griefing,
	may_harm = may_harm,
	group_of = group_of,
	root_of = root_of,
})
