-- Which teams are allied. An alliance is transitive: allying a with b and b with c makes a and c allies too,
-- so teams fall into groups and two teams are allied when they are in the same one. A team is always allied
-- with itself. A team can leave its group (`leave`, pow's unally), which leaves the rest of the group allied.
--
-- Whether a team's weapons may hurt its allies is the match's choice (`set_ally_griefing`). BAR always lets them, so a
-- commander can disintegrate an ally's extractors; here that is off unless the lobby turned it on. A team's weapons
-- always hurt its own things either way.

local ReplicatedStorage = game:GetService "ReplicatedStorage"

local types = require(ReplicatedStorage.Shared.types)
local snapshot = require(script.Parent.snapshot)

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

-- Takes `team_id` out of its group, leaving it allied with nobody and the rest of the group still allied with each
-- other. Returns false if it was allied with nobody.
local function leave(team_id: TeamId): boolean
	local root = root_of(team_id)
	local rest: { TeamId } = {}
	local alone = true
	for other in parent do
		if root_of(other) == root and other ~= team_id then
			alone = false
			table.insert(rest, other)
		end
	end
	if alone then
		return false
	end
	-- the group is rebuilt without it, every other team pointing straight at the first of them
	table.sort(rest)
	for _, other in rest do
		parent[other] = rest[1]
	end
	parent[team_id] = nil
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

snapshot.keep("alliances", function()
	return { parent = parent, ally_griefing = ally_griefing }
end, function(saved)
	parent = saved.parent
	ally_griefing = saved.ally_griefing
end)

return table.freeze({
	ally = ally,
	leave = leave,
	are_allied = are_allied,
	set_ally_griefing = set_ally_griefing,
	is_ally_griefing = is_ally_griefing,
	may_harm = may_harm,
	group_of = group_of,
	root_of = root_of,
})
