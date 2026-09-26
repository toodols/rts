-- Notifications: short notes a player is sent about what is happening to their side, shown as toasts
-- (client/ui/notifications.luau).
--
-- - An ally asks for metal: a player drags their own metal bar in the player list up past what they have, and every
--   team allied with theirs is told how much they want (RequestMetal).
-- - An ally sent you metal (server/sharing.luau).
-- - Your base is under attack: an enemy hurts one of your buildings that has no weapon, when none of them had been hurt
--   for BASE_QUIET_SECONDS before. It says where, so the toast can take the camera there.
-- - Your commander is under attack: an enemy hurts one of your commanders, when none of them had been hurt for
--   BASE_QUIET_SECONDS before. It says where, as a base under attack does.
-- - Enemy aircraft: the first time a team not allied with yours has an aircraft, finished or still a blueprint. Once a
--   game.
--
-- Another module may send its players notices through `to_team`, as the third campaign mission does
-- (server/missions/counterattack.luau). Every kind of notice is one of `types.NoticeKind`, which the client has a text
-- for each of (client/ui/notifications.luau).
--
-- Every notice sent goes out through `on_sent`, which is how it reaches the players on the team it is for (`init`).

local ReplicatedStorage = game:GetService "ReplicatedStorage"
local ServerScriptService = game:GetService "ServerScriptService"

local types = require(ReplicatedStorage.Shared.types)
local teams = require(ReplicatedStorage.Shared.teams)
local unit_defs = require(ReplicatedStorage.Shared.unit_defs)
local appearance = require(ReplicatedStorage.Shared.appearance)
local signal = require(ReplicatedStorage.Shared.signal)
local decode = require(ReplicatedStorage.Shared.decode)

local remotes = require(ServerScriptService.ServerShared.remotes)

local state = require(script.Parent.state)
local players = require(script.Parent.players)
local alliances = require(script.Parent.alliances)

type Entity = types.Entity
type TeamId = types.TeamId
type Notice = types.Notice

local notify: RemoteEvent = ReplicatedStorage.Shared.Notify
local metal_requested: RemoteEvent = ReplicatedStorage.Shared.RequestMetal

-- A base is newly under attack when none of its unarmed buildings has been hurt by an enemy for this many seconds, and
-- a commander likewise when none of its team's commanders has.
local BASE_QUIET_SECONDS = 10
-- A player asks for metal no more often than once in three seconds, so a jittery drag cannot flood their allies.
local REQUEST_RATE = { per_second = 1 / 3, burst = 1 }
-- How often the map is looked over for enemy aircraft, in seconds of game.
local AIR_SCAN_SECONDS = 1

-- Seconds of game played, by this module's own count.
local now = 0
local next_air_scan = 0
-- when an enemy last hurt one of each team's unarmed buildings
local base_hurt_at: { [TeamId]: number } = {}
-- when an enemy last hurt one of each team's commanders
local commander_hurt_at: { [TeamId]: number } = {}
-- the teams already told of enemy aircraft
local air_told: { [TeamId]: true } = {}
-- every notice sent, with the team it is for
local sent = signal.new() :: signal.Signal<TeamId, Notice>

-- Sends `notice` to everyone on team `team_id`.
local function to_team(team_id: TeamId, notice: Notice)
	sent.fire(team_id, notice)
end

-- Sends `notice` to every team allied with `team_id`, but not to `team_id` itself.
local function to_allies(team_id: TeamId, notice: Notice)
	for other in state.all_teams() do
		if other ~= team_id and teams.is_playable(other) and alliances.are_allied(other, team_id) then
			to_team(other, notice)
		end
	end
end

-- Tells `listener` of every notice sent from now on, and the team it is for, until the returned function is called.
local function on_sent(listener: (TeamId, Notice) -> ()): () -> ()
	return sent.subscribe(listener)
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

-- Team `team_id` asks its allies for `amount` of metal: no more than it has room for, and nothing if that is less than
-- a whole one.
local function request_metal(team_id: TeamId, amount: number)
	local team = state.get_team(team_id)
	if team == nil then
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

local function on_request_metal(player: Player, amount: number)
	local team_id = players.team_of(player)
	if team_id ~= nil then
		request_metal(team_id, amount)
	end
end

-- Sends team `team_id` a notice of `kind` at `at`, unless an earlier hit logged in `hurt_at` came less than
-- BASE_QUIET_SECONDS ago.
local function attacked(hurt_at: { [TeamId]: number }, team_id: TeamId, kind: types.NoticeKind, at: Vector3)
	local last = hurt_at[team_id]
	hurt_at[team_id] = now
	if last ~= nil and now - last < BASE_QUIET_SECONDS then
		return
	end
	to_team(team_id, { kind = kind, at = at })
end

-- `target` has just been hurt by a weapon of team `attacker_team` (nil when nobody's doing, as drowning is).
local function damaged(target: Entity, attacker_team: TeamId?)
	if attacker_team == nil or alliances.are_allied(attacker_team, target.team) then
		return
	end
	local def = target.def
	if unit_defs.is_commander(def) then
		attacked(commander_hurt_at, target.team, "commander_attacked", target.position)
	elseif target.kind == "building" and def.weapons == nil and def.manual_weapon == nil then
		attacked(base_hurt_at, target.team, "base_attacked", target.position)
	end
end

-- Tells every team not yet told that an enemy has an aircraft, if one has.
local function scan_for_air()
	local owners: { [TeamId]: true } = {}
	for _, entity in state.all() do
		if entity.alive and entity.team ~= teams.NEUTRAL and unit_defs.is_air(entity.def) then
			owners[entity.team] = true
		end
	end
	if next(owners) == nil then
		return
	end
	for team_id in state.all_teams() do
		if teams.is_playable(team_id) == false or air_told[team_id] ~= nil then
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
	now = 0
	next_air_scan = 0
	table.clear(base_hurt_at)
	table.clear(commander_hurt_at)
	table.clear(air_told)
end

local function init()
	sent.subscribe(function(team_id: TeamId, notice: Notice)
		for _, player in players.players_on_team(team_id) do
			remotes.tell(notify, player, notice)
		end
	end)
	remotes.listen(metal_requested, { args = { decode.number }, rate = REQUEST_RATE }, on_request_metal)
end

return table.freeze({
	init = init,
	tick = tick,
	on_sent = on_sent,
	to_team = to_team,
	metal_sent = metal_sent,
	request_metal = request_metal,
	damaged = damaged,
	reset = reset,
})
