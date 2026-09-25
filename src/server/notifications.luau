-- Notifications: short notes a player is sent about what is happening to their side, shown as toasts
-- (client/ui/notifications.luau).
--
-- - An ally asks for metal: a player drags their own metal bar in the player list up past what they have, and every
--   team allied with theirs is told how much they want (RequestMetal).
-- - An ally sent you metal (server/sharing.luau).
-- - Your base is under attack: an enemy hurts one of your buildings that has no weapon, when none of them had been hurt
--   for BASE_QUIET_SECONDS before. It says where, so the toast can take the camera there.
-- - Enemy aircraft: the first time a team not allied with yours has an aircraft, finished or still a blueprint. Once a
--   game.
-- - The third campaign mission's (server/counterattack.luau): a building of yours going up in its enemy zone, which a
--   wave arriving will destroy; and each wave as it arrives (`amount` its number, `at` where), the last as the final.

local Players = game:GetService "Players"
local ReplicatedStorage = game:GetService "ReplicatedStorage"

local types = require(ReplicatedStorage.Shared.types)
local config = require(ReplicatedStorage.Shared.config)
local unit_defs = require(ReplicatedStorage.Shared.unit_defs)
local appearance = require(ReplicatedStorage.Shared.appearance)

local state = require(script.Parent.state)
local players = require(script.Parent.players)
local alliances = require(script.Parent.alliances)
local air = require(script.Parent.air)

type Entity = types.Entity
type TeamId = types.TeamId

export type Kind =
	"metal_request"
	| "metal_sent"
	| "base_attacked"
	| "air_detected"
	| "enemy_zone"
	| "wave"
	| "final_wave"

export type Notice = {
	kind: Kind,
	-- the team it is about, for an ally's request or gift: its name and colour
	from: string?,
	color: Color3?,
	-- how much metal, for an ally's request or gift; which wave, for one arriving
	amount: number?,
	-- where it is happening, for a base under attack or a wave arriving
	at: Vector3?,
}

local notify: RemoteEvent = ReplicatedStorage.Shared.Notify
local request_metal: RemoteEvent = ReplicatedStorage.Shared.RequestMetal

-- A base is newly under attack when none of its unarmed buildings has been hurt by an enemy for this many seconds.
local BASE_QUIET_SECONDS = 10
-- A player asks for metal no more often than this, in seconds, so a jittery drag cannot flood their allies.
local MIN_REQUEST_INTERVAL = 3
-- How often the map is looked over for enemy aircraft, in seconds of game.
local AIR_SCAN_SECONDS = 1

-- Seconds of game played, by this module's own count.
local now = 0
local next_air_scan = 0
-- when an enemy last hurt one of each team's unarmed buildings
local base_hurt_at: { [TeamId]: number } = {}
-- the teams already told of enemy aircraft
local air_told: { [TeamId]: true } = {}
local last_request: { [Player]: number } = {}
-- told of every notice sent, with the team it went to; for Studio tests, which have no players to send them to
local observers: { (TeamId, Notice) -> () } = {}

-- Sends `notice` to everyone on team `team_id`.
local function to_team(team_id: TeamId, notice: Notice)
	for _, observer in observers do
		observer(team_id, notice)
	end
	for _, player in players.players_on_team(team_id) do
		notify:FireClient(player, notice)
	end
end

-- Sends `notice` to every team allied with `team_id`, but not to `team_id` itself.
local function to_allies(team_id: TeamId, notice: Notice)
	for other in state.all_teams() do
		if
			other ~= team_id
			and other ~= 0
			and other ~= config.SCAVENGER_TEAM
			and alliances.are_allied(other, team_id)
		then
			to_team(other, notice)
		end
	end
end

-- Calls `observer` with every notice sent from now on. Returns a function that stops it.
local function observe(observer: (TeamId, Notice) -> ()): () -> ()
	table.insert(observers, observer)
	return function()
		local index = table.find(observers, observer)
		if index ~= nil then
			table.remove(observers, index)
		end
	end
end

-- Team `from` sent team `to` `amount` of metal.
local function metal_sent(from: TeamId, to: TeamId, amount: number)
	local giver = state.get_team(from)
	if giver == nil or amount < 1 then
		return
	end
	to_team(to, {
		kind = "metal_sent",
		from = giver.name,
		color = appearance.team_color(from),
		amount = math.floor(amount),
	})
end

-- Team `team_id` (nil for someone with no team) asks its allies for `amount` of metal, as RequestMetal receives it:
-- no more than it has room for.
local function ask_for_metal(team_id: TeamId?, amount: unknown)
	local team = if team_id ~= nil then state.get_team(team_id) else nil
	-- NaN and infinity fail this as well
	if team_id == nil or team == nil or typeof(amount) ~= "number" or not (amount >= 1 and amount < math.huge) then
		return
	end
	local wanted = math.floor(math.min(amount, team.metal_capacity - team.metal))
	if wanted < 1 then
		return
	end
	to_allies(team_id, {
		kind = "metal_request",
		from = team.name,
		color = appearance.team_color(team_id),
		amount = wanted,
	})
end

local function on_request_metal(player: Player, amount: unknown)
	local clock = os.clock()
	if clock - (last_request[player] or -math.huge) < MIN_REQUEST_INTERVAL then
		return
	end
	last_request[player] = clock
	ask_for_metal(players.team_of(player), amount)
end

-- `target` has just been hurt by a weapon of team `attacker_team` (nil when nobody's doing, as drowning is).
local function damaged(target: Entity, attacker_team: TeamId?)
	if attacker_team == nil or target.kind ~= "building" or alliances.are_allied(attacker_team, target.team) then
		return
	end
	local def = unit_defs.of(target)
	if def.weapons ~= nil or def.manual_weapon ~= nil then
		return
	end
	local last = base_hurt_at[target.team]
	base_hurt_at[target.team] = now
	if last ~= nil and now - last < BASE_QUIET_SECONDS then
		return
	end
	to_team(target.team, { kind = "base_attacked", at = target.position })
end

-- Tells every team not yet told that an enemy has an aircraft, if one has.
local function scan_for_air()
	local owners: { [TeamId]: true } = {}
	for _, entity in state.all() do
		if entity.alive and entity.team ~= 0 and air.is_aircraft(entity) then
			owners[entity.team] = true
		end
	end
	if next(owners) == nil then
		return
	end
	for team_id in state.all_teams() do
		if team_id == 0 or team_id == config.SCAVENGER_TEAM or air_told[team_id] ~= nil then
			continue
		end
		for owner in owners do
			if alliances.are_allied(owner, team_id) == false then
				air_told[team_id] = true
				to_team(team_id, { kind = "air_detected" })
				break
			end
		end
	end
end

local function tick(delta: number)
	now += delta
	if now >= next_air_scan then
		next_air_scan = now + AIR_SCAN_SECONDS
		scan_for_air()
	end
end

-- Forgets the game before, for a new one on a new map.
local function reset()
	table.clear(base_hurt_at)
	table.clear(air_told)
end

local function init()
	request_metal.OnServerEvent:Connect(on_request_metal)
	Players.PlayerRemoving:Connect(function(player: Player)
		last_request[player] = nil
	end)
end

return table.freeze({
	init = init,
	tick = tick,
	reset = reset,
	observe = observe,
	to_team = to_team,
	metal_sent = metal_sent,
	ask_for_metal = ask_for_metal,
	damaged = damaged,
})
