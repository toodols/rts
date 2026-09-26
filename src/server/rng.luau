--!strict
-- Everything the simulation leaves to chance is rolled here, from named streams that all come from one seed: the
-- match's (`seed`). Each part of the game rolls from a stream of its own ("wind", "projectiles", "orbits",
-- "scavengers", and each computer player's, "ai <team>"), so how much one of them rolls never changes what another gets,
-- and the same seed plays the same game in a live server, a Studio test and the headless AI arena alike. Until a seed is
-- given, it is one from entropy.
--
-- A stream is asked for by name every time something is rolled (`stream`), never kept, since a new seed replaces it.

-- Each stream's seed is the match's, in its high bits, beside its name's hash, in the low ones.
local NAME_BITS = 2 ^ 32
local SEED_SPAN = 2 ^ 20
local HASH_PRIME = 2147483647

local base = Random.new():NextInteger(0, SEED_SPAN - 1)
local streams: { [string]: Random } = {}

-- A number for `name`, the same everywhere, under NAME_BITS: its bytes as the digits of a number base 131, kept under a
-- prime so that every step stays exact.
local function hash(name: string): number
	local value = 0
	for index = 1, #name do
		value = (value * 131 + string.byte(name, index)) % HASH_PRIME
	end
	return value
end

-- Rolls everything from `seed` from now on, every stream starting over from it.
local function seed(value: number)
	base = math.floor(value) % SEED_SPAN
	table.clear(streams)
end

-- The stream `name` rolls from.
local function stream(name: string): Random
	local found: Random? = streams[name]
	if found ~= nil then
		return found
	end
	local made = Random.new(base * NAME_BITS + hash(name))
	streams[name] = made
	return made
end

return table.freeze({
	seed = seed,
	stream = stream,
})
