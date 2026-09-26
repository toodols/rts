--!strict
-- Sending players to another place of the experience, the one way every server does it: the lobby sending a party to
-- the game it started (reserved_match.luau), or a player to a lobby on another lobby server (lobby/server/launch.luau),
-- and a game server sending a player back to the lobby (server/campaign_exit.luau).
--
-- A party is sent together, and tried again RETRY_SECONDS later if it could not be, ATTEMPTS times in all. A player
-- whose teleport was accepted can still fail on the way, which Roblox reports through TeleportInitFailed: they are sent
-- again on their own, to the same place with the same options, until they have been tried ATTEMPTS times, and then
-- handed to what the sender said to tell of it. A player leaving the server is what a teleport that worked looks like
-- from here (`forget`).
--
-- Teleports only work on a live server, and only to a place that is set up (shared/places.luau): anywhere else a send
-- is refused at once, and says why (`refusal`).

local RunService = game:GetService "RunService"
local TeleportService = game:GetService "TeleportService"

-- Told of a player whose teleport failed every time it was tried, and why.
export type GivenUp = (player: Player, reason: string) -> ()

type Pending = {
	place: number,
	options: TeleportOptions,
	tries: number,
	given_up: GivenUp,
}

local ATTEMPTS = 3
local RETRY_SECONDS = 2

-- players on their way, with what they were sent with, until they leave this server or are given up on
local pending: { [Player]: Pending } = {}

-- Why nobody can be sent to `place` from here, if nobody can.
local function refusal(place: number): string?
	if RunService:IsStudio() then
		return "Teleports don't work in Studio: only on a live server"
	end
	if place == 0 then
		return "That place isn't set up yet"
	end
	return nil
end

-- Sends `party` to `place` with `options`. Returns why it could not, if it could not.
local function try(place: number, party: { Player }, options: TeleportOptions): string?
	local sent, err = pcall(function()
		TeleportService:TeleportAsync(place, party, options)
	end)
	return if sent then nil else tostring(err)
end

-- Sends `party` to `place` with `options`, together. Yields until they are on their way, or returns why they could
-- not be sent. Someone whose teleport fails on the way after that is handed to `given_up` once it has failed every
-- time.
local function send(party: { Player }, place: number, options: TeleportOptions, given_up: GivenUp): (boolean, string?)
	local refused = refusal(place)
	if refused ~= nil then
		return false, refused
	end
	local waiting: { [Player]: Pending } = {}
	for _, player in party do
		local entry: Pending = { place = place, options = options, tries = 0, given_up = given_up }
		waiting[player] = entry
		pending[player] = entry
	end
	local last = "not tried"
	for attempt = 1, ATTEMPTS do
		-- anyone who has left, or been sent elsewhere, meanwhile is not sent
		local going: { Player } = {}
		for _, player in party do
			local entry = waiting[player]
			if pending[player] == entry and player.Parent ~= nil then
				entry.tries += 1
				table.insert(going, player)
			end
		end
		if #going == 0 then
			return false, "Everyone being sent has gone"
		end
		local err = try(place, going, options)
		if err == nil then
			return true, nil
		end
		last = err
		warn(`teleporting {#going} to place {place} failed (try {attempt}): {err}`)
		if attempt < ATTEMPTS then
			task.wait(RETRY_SECONDS)
		end
	end
	for _, player in party do
		if pending[player] == waiting[player] then
			pending[player] = nil
		end
	end
	return false, last
end

-- A teleport that was accepted failed on the way: it is tried again while it has tries left.
local function on_init_failed(player: Player, result: Enum.TeleportResult, message: string)
	local entry = pending[player]
	if entry == nil then
		return
	end
	warn(`{player.Name}'s teleport failed ({result.Name}, try {entry.tries}): {message}`)
	if entry.tries >= ATTEMPTS then
		pending[player] = nil
		entry.given_up(player, message)
		return
	end
	task.wait(RETRY_SECONDS)
	-- they may have got there, or gone, meanwhile
	if pending[player] ~= entry or player.Parent == nil then
		return
	end
	entry.tries += 1
	local err = try(entry.place, { player }, entry.options)
	if err ~= nil then
		on_init_failed(player, Enum.TeleportResult.Failure, err)
	end
end

-- A player leaving: which is what a teleport that worked looks like from here.
local function forget(player: Player)
	pending[player] = nil
end

-- Hears of every teleport that fails on the way, from now on.
local function init()
	TeleportService.TeleportInitFailed:Connect(on_init_failed)
end

return table.freeze({
	refusal = refusal,
	send = send,
	forget = forget,
	init = init,
})
