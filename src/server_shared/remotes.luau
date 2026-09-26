--!strict
-- The one way a server hears its clients, and tells one of them something. What arrives on a remote comes from a
-- client, so nothing in it is trusted: each remote is heard through `listen` (or, for a remote function, `answer`) with
-- what it takes, as decoders (shared/decode.luau), and how often a player may send on it, and its handler is only
-- called with what those read, in the shape they read it, at no more than that rate. What a handler checks past that is
-- the game's business: whose a unit is, whether a spot is free.
--
-- How often is a rate: a player may send `burst` at once, and after that `per_second` on average. A handler that must
-- not be run too often (a ping, a request to allies) takes a burst of 1, which makes the rate a cooldown.
--
-- What the server tells one player goes through `tell`, and to everyone, the remote's own FireAllClients.
--
-- A test hands a message to a remote's handler as a client's would reach it (`deliver`), so that what it covers is what
-- a player's client meets. The player it sends as stands in for one (tests/harness.luau), with no client to tell
-- anything: what they are told is kept for the test to read instead (`stand_in`, `told`).

local ReplicatedStorage = game:GetService "ReplicatedStorage"

local decode = require(ReplicatedStorage.Shared.decode)

export type Rate = {
	per_second: number,
	burst: number,
}

-- What a remote takes: a decoder for each argument, in order, and how often.
export type Spec = {
	args: { decode.Decoder<any> },
	rate: Rate,
}

-- What a remote is heard with: the player who sent it and what they sent.
type Delivery = (player: Player, ...unknown) -> ()

-- How much of a rate a player has left, and when that was reckoned.
type Bucket = {
	tokens: number,
	at: number,
}

-- Every rate's buckets, so that a player leaving is forgotten by all of them.
local all_buckets: { { [Player]: Bucket } } = {}
-- Each remote's handler as its messages reach it, for `deliver`.
local deliveries: { [Instance]: Delivery } = {}
-- What each player a test stands in has been told, in order: the remote and what was sent on it.
local inboxes: { [Player]: { { remote: string, args: { any } } } } = {}

-- Whether `player` may send once more at `rate`, counting it if they may. The returned function is one rate's own.
local function limiter(rate: Rate): (Player) -> boolean
	local buckets: { [Player]: Bucket } = {}
	table.insert(all_buckets, buckets)
	return function(player: Player): boolean
		local now = os.clock()
		local bucket = buckets[player]
		if bucket == nil then
			bucket = { tokens = rate.burst, at = now }
			buckets[player] = bucket
		end
		bucket.tokens = math.min(rate.burst, bucket.tokens + (now - bucket.at) * rate.per_second)
		bucket.at = now
		if bucket.tokens < 1 then
			return false
		end
		bucket.tokens -= 1
		return true
	end
end

-- What `spec` reads of `sent`, the arguments as they arrived, and how many; nil when any is not what it takes.
local function read(spec: Spec, sent: { unknown }): { any }?
	local args = table.create(#spec.args)
	for index, decoder in spec.args do
		local ok, value = decoder(sent[index])
		if ok == false then
			return nil
		end
		args[index] = value
	end
	return args
end

-- Hears `remote` with `handler`, which is called with the sender and what `spec` reads of what they sent, only when
-- all of it is what it takes and the sender is within the rate.
local function listen(remote: RemoteEvent | UnreliableRemoteEvent, spec: Spec, handler: (Player, ...any) -> ())
	local within = limiter(spec.rate)
	local function delivery(player: Player, ...: unknown)
		local args = read(spec, { ... })
		if args == nil or within(player) == false then
			return
		end
		handler(player, table.unpack(args, 1, #spec.args))
	end
	deliveries[remote] = delivery;
	(remote :: RemoteEvent).OnServerEvent:Connect(delivery)
end

-- Answers `remote` with `handler`, which is called with the sender and what they sent, only when the sender is within
-- `rate`; otherwise the answer is `refused`. What a remote function takes depends on what it is asked (the lobby's
-- actions), so `handler` reads it itself, with the same decoders.
local function answer(
	remote: RemoteFunction,
	rate: Rate,
	refused: string,
	handler: (Player, ...unknown) -> (boolean, string?)
)
	local within = limiter(rate)
	remote.OnServerInvoke = function(player: Player, ...: unknown): (boolean, string?)
		if within(player) == false then
			return false, refused
		end
		return handler(player, ...)
	end
end

-- Tells `player` what is in `...` on `remote`.
local function tell(remote: RemoteEvent, player: Player, ...: any)
	local inbox = inboxes[player]
	if inbox ~= nil then
		table.insert(inbox, { remote = remote.Name, args = { ... } })
		return
	end
	remote:FireClient(player, ...)
end

-- `player` is no real player's but one a test stands in, whose client is nowhere: what they are told is kept (`told`).
local function stand_in(player: Player)
	inboxes[player] = {}
end

-- Everything the stand-in `player` has been told on the remote called `remote_name`, oldest first, each as the
-- arguments it was sent with.
local function told(player: Player, remote_name: string): { { any } }
	local found: { { any } } = {}
	local inbox = inboxes[player]
	if inbox == nil then
		return found
	end
	for _, message in inbox do
		if message.remote == remote_name then
			table.insert(found, message.args)
		end
	end
	return found
end

-- Hands `remote`'s handler a message from `player` as it would arrive from their client, checked and limited alike.
-- For the tests, which have no clients.
local function deliver(remote: Instance, player: Player, ...: unknown)
	local delivery = deliveries[remote]
	assert(delivery ~= nil, `nothing listens to {remote.Name}`)
	delivery(player, ...)
end

-- Forgets `player` in every rate, as they leave.
local function forget(player: Player)
	for _, buckets in all_buckets do
		buckets[player] = nil
	end
	inboxes[player] = nil
end

return table.freeze({
	listen = listen,
	answer = answer,
	tell = tell,
	deliver = deliver,
	stand_in = stand_in,
	told = told,
	forget = forget,
})
