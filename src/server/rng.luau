--!strict
-- Everything the simulation leaves to chance is rolled here, from named streams that all come from one seed: the
-- match's (`seed`). Each part of the game rolls from a stream of its own ("wind", "projectiles", "orbits",
-- "scavengers", and each computer player's, "ai <team>"), so how much one of them rolls never changes what another gets,
-- and the same seed plays the same game in a live server, a Studio test and the headless AI arena alike. Until a seed is
-- given, it is one from entropy.
--
-- A stream is asked for by name every time something is rolled (`stream`), never kept, since a new seed replaces it.
--
-- Each stream is Roblox's Random bit for bit, worked out in Luau (server/pcg32.luau) so that where it is in its sequence
-- can be kept with the rest of the game (server/snapshot) and put back.

local pcg32 = require(script.Parent.pcg32)
local snapshot = require(script.Parent.snapshot)

-- Each stream's seed is the match's, in its high bits, beside its name's hash, in the low ones.
local NAME_BITS = 2 ^ 32
local SEED_SPAN = 2 ^ 20
local HASH_PRIME = 2147483647

local base = Random.new():NextInteger(0, SEED_SPAN - 1)
local generators: { [string]: pcg32.Generator } = {}

-- What a stream is asked through: Random's own methods, on the stream's generator.
type Stream = { name: string }
local stream_methods = {}
local StreamMeta = { __index = stream_methods }
local handles: { [string]: Stream } = {}

-- A number for `name`, the same everywhere, under NAME_BITS: its bytes as the digits of a number base 131, kept under a
-- prime so that every step stays exact.
local function hash(name: string): number
	local value = 0
	for index = 1, #name do
		value = (value * 131 + string.byte(name, index)) % HASH_PRIME
	end
	return value
end

-- The generator of the stream `name`, begun from the seed the first time it is asked for.
local function generator(name: string): pcg32.Generator
	local found = generators[name]
	if found ~= nil then
		return found
	end
	local made = pcg32.new(base * NAME_BITS + hash(name))
	generators[name] = made
	return made
end

function stream_methods.NextNumber(self: Stream, min: number?, max: number?): number
	return pcg32.next_number(generator(self.name), min, max)
end

function stream_methods.NextInteger(self: Stream, min: number, max: number): number
	return pcg32.next_integer(generator(self.name), min, max)
end

-- Rolls everything from `seed` from now on, every stream starting over from it.
local function seed(value: number)
	base = math.floor(value) % SEED_SPAN
	table.clear(generators)
end

-- The stream `name` rolls from, which answers as a Random does.
local function stream(name: string): Random
	local handle = handles[name]
	if handle == nil then
		handle = setmetatable({ name = name }, StreamMeta) :: any
		handles[name] = handle
	end
	return handle :: any
end

snapshot.keep("rng", function()
	return { base = base, generators = generators }
end, function(saved)
	base = saved.base
	generators = saved.generators
end)

return table.freeze({
	seed = seed,
	stream = stream,
})
