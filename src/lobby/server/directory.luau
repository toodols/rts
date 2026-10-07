--!strict
-- Every open lobby across every server of the lobby place, for the browser.
--
-- Each server lists its own lobbies in a MemoryStore sorted map, under `<JobId>/<lobby id>`, and lists them again every
-- few seconds with a short expiry, so a server that goes away takes its lobbies out of the list with it. Each server
-- reads the whole map on the same beat. A lobby on this server is always shown as it is now rather than as it was
-- listed; a lobby elsewhere is joined by going to its server (see init.server.luau).
--
-- A place with no MemoryStore at all, like one opened from a file in Studio, shows this server's lobbies alone. A store
-- that fails to answer is only asked again later, each failure in a row waiting twice as long, so the list comes back
-- once the store does.
--
-- A friends-only lobby is shown to its host's friends alone. Whether two players are friends is a web request, so it
-- is asked once per pair and remembered: in the background while listing, when the lobby stays hidden from the viewer
-- until the answer is yes, and waited for when they ask to join.

local MemoryStoreService = game:GetService "MemoryStoreService"
local ReplicatedStorage = game:GetService "ReplicatedStorage"

local game_modes = require(ReplicatedStorage.Shared.game_modes)
local protocol = require(ReplicatedStorage.Lobby.protocol)

local lobbies = require(script.Parent.lobbies)

type Lobby = lobbies.Lobby
type Summary = protocol.Summary

local STORE = "lobbies"
local REFRESH_SECONDS = 5
-- long enough to survive a missed refresh or two
local EXPIRY_SECONDS = 20
local READ_LIMIT = 200
-- how long a failed read waits before the next, at first and at most
local FIRST_BACKOFF_SECONDS = 10
local LONGEST_BACKOFF_SECONDS = 160

-- nil until `start`, and for good where there is no MemoryStore
local store: MemoryStoreSortedMap? = nil
local listed: { [string]: boolean } = {}
local remote: { Summary } = {}
-- when the store may next be read, and how long the next failure waits
local read_after = 0
local backoff = FIRST_BACKOFF_SECONDS
-- friends[viewer][host]: true or false once known, absent while it is being asked or has not been
local friends: { [number]: { [number]: boolean } } = {}
local asking: { [number]: { [number]: boolean } } = {}

local function key_of(lobby: Lobby): string
	return `{game.JobId}/{lobby.id}`
end

local function summarize(lobby: Lobby): Summary
	local mode = game_modes.get(lobby.match.mode) :: game_modes.Mode
	local host_name = ""
	for _, seat in lobby.match.seats do
		if seat.user_id == lobby.host then
			host_name = seat.name
		end
	end
	return {
		key = key_of(lobby),
		lobby_id = lobby.id,
		job_id = game.JobId,
		host = lobby.host,
		host_name = host_name,
		mode = lobby.match.mode,
		preset = lobby.match.preset,
		players = game_modes.player_count(lobby.match.seats),
		capacity = mode.capacity,
		spectators = game_modes.spectator_count(lobby.match.seats),
		visibility = lobby.visibility,
		level_min = lobby.level_min,
		level_max = lobby.level_max,
	}
end

local function decode(key: string, value: any): Summary?
	if typeof(value) ~= "table" or typeof(value.job_id) ~= "string" or typeof(value.lobby_id) ~= "string" then
		return nil
	end
	if typeof(value.host) ~= "number" or game_modes.get(value.mode) == nil then
		return nil
	end
	return {
		key = key,
		lobby_id = value.lobby_id,
		job_id = value.job_id,
		host = value.host,
		host_name = if typeof(value.host_name) == "string" then value.host_name else "",
		mode = value.mode,
		preset = if typeof(value.preset) == "string" then value.preset else "",
		players = if typeof(value.players) == "number" then value.players else 0,
		capacity = if typeof(value.capacity) == "number" then value.capacity else 0,
		spectators = if typeof(value.spectators) == "number" then value.spectators else 0,
		visibility = if value.visibility == "friends" then "friends" else "public",
		level_min = if typeof(value.level_min) == "number" then value.level_min else protocol.LEVEL_MIN,
		level_max = if typeof(value.level_max) == "number" then value.level_max else protocol.LEVEL_MAX,
	}
end

-- Reads everyone else's lobbies from `map`, unless it failed lately and is still being waited on.
local function read_remote(map: MemoryStoreSortedMap)
	local now = os.clock()
	if now < read_after then
		return
	end
	local ok, items = pcall(function()
		return map:GetRangeAsync(Enum.SortDirection.Ascending, READ_LIMIT)
	end)
	if ok == false then
		warn(`reading the lobby list failed, showing this server's lobbies for {backoff}s: {items}`)
		remote = {}
		read_after = now + backoff
		backoff = math.min(backoff * 2, LONGEST_BACKOFF_SECONDS)
		return
	end
	backoff = FIRST_BACKOFF_SECONDS
	local found: { Summary } = {}
	for _, item in items do
		local summary = decode(item.key, item.value)
		if summary ~= nil and summary.job_id ~= game.JobId then
			table.insert(found, summary)
		end
	end
	remote = found
end

-- Lists this server's open lobbies again, takes out the ones that closed or started, and reads everyone else's.
local function refresh()
	local map = store
	if map == nil then
		return
	end
	local still: { [string]: boolean } = {}
	for _, lobby in lobbies.all() do
		if lobby.starting then
			continue
		end
		local key = key_of(lobby)
		still[key] = true
		local ok, err = pcall(function()
			map:SetAsync(key, summarize(lobby), EXPIRY_SECONDS)
		end)
		if ok == false then
			warn(`listing lobby {key} failed: {err}`)
		end
	end
	for key in listed do
		if still[key] == nil then
			pcall(function()
				map:RemoveAsync(key)
			end)
		end
	end
	listed = still
	read_remote(map)
end

-- Asks whether `viewer` is friends with `host`, now, and remembers the answer.
local function ask_friends(viewer: Player, host: number): boolean
	local ok, result = pcall(function()
		return viewer:IsFriendsWithAsync(host)
	end)
	local answer = ok and result == true
	local known = friends[viewer.UserId]
	if known == nil then
		known = {}
		friends[viewer.UserId] = known
	end
	known[host] = answer
	return answer
end

-- Whether a lobby hosted by `host` that is `visibility` is open to `viewer`, as far as is known: always for a public
-- one or their own, and a friends-only one once they are known to be friends. Nil while that is not known yet.
local function known_open(viewer: Player, host: number, visibility: string): boolean?
	if visibility == "public" or viewer.UserId == host then
		return true
	end
	local known = friends[viewer.UserId]
	return if known ~= nil then known[host] else nil
end

-- Whether `viewer` may see a lobby hosted by `host` that is `visibility`. While that is not known, this is false for
-- now and asks in the background; `on_known` is called once it is known.
local function may_see(viewer: Player, host: number, visibility: string, on_known: () -> ()): boolean
	local open = known_open(viewer, host, visibility)
	if open ~= nil then
		return open
	end
	local asked = asking[viewer.UserId]
	if asked == nil then
		asked = {}
		asking[viewer.UserId] = asked
	end
	if asked[host] ~= true then
		asked[host] = true
		task.spawn(function()
			ask_friends(viewer, host)
			on_known()
		end)
	end
	return false
end

-- Whether `viewer` may join such a lobby, waiting for the answer if it is not known: for a player asking to join, a
-- wrong "no" would be worse than a pause.
local function may_join(viewer: Player, host: number, visibility: string): boolean
	local open = known_open(viewer, host, visibility)
	if open ~= nil then
		return open
	end
	return ask_friends(viewer, host)
end

-- Every lobby `viewer` may see, this server's first.
local function visible_to(viewer: Player, on_known: () -> ()): { Summary }
	local result: { Summary } = {}
	for _, lobby in lobbies.all() do
		if lobby.starting == false and may_see(viewer, lobby.host, lobby.visibility, on_known) then
			table.insert(result, summarize(lobby))
		end
	end
	table.sort(result, function(a: Summary, b: Summary): boolean
		return (tonumber(a.lobby_id) :: number) < (tonumber(b.lobby_id) :: number)
	end)
	for _, summary in remote do
		if may_see(viewer, summary.host, summary.visibility, on_known) then
			table.insert(result, summary)
		end
	end
	return result
end

-- A lobby on another server, as it was last listed.
local function find_remote(key: string): Summary?
	for _, summary in remote do
		if summary.key == key then
			return summary
		end
	end
	return nil
end

local function forget(player: Player)
	friends[player.UserId] = nil
	asking[player.UserId] = nil
end

-- Refreshes every few seconds for as long as the server runs, calling `on_refreshed` after each.
local function start(on_refreshed: () -> ())
	local got, map = pcall(MemoryStoreService.GetSortedMap, MemoryStoreService, STORE)
	if got then
		store = map
	else
		warn(`there is no lobby list here, so only this server's lobbies are shown: {map}`)
	end
	task.spawn(function()
		while true do
			refresh()
			on_refreshed()
			task.wait(REFRESH_SECONDS)
		end
	end)
	game:BindToClose(function()
		local closing = store
		if closing == nil then
			return
		end
		for key in listed do
			pcall(function()
				closing:RemoveAsync(key)
			end)
		end
	end)
end

return table.freeze({
	start = start,
	visible_to = visible_to,
	find_remote = find_remote,
	may_join = may_join,
	forget = forget,
})
