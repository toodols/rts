--!strict
-- Roblox's Random, bit for bit, in Luau: PCG32 XSH-RR with Luau's increment of 105, seeded and read as Roblox's is (the
-- headless arena's stand-in of it, tools/lib/datatypes.luau, was checked against values Studio printed, and the
-- `pcg32` test checks this against Random itself). Unlike Random, its state is two numbers anyone can read and set, so
-- a game that rolls from it can be kept and put back mid-sequence (server/snapshot).
--
-- Only what the game asks of Random: NextNumber and NextInteger.

local TWO_32 = 4294967296
local TWO_64 = TWO_32 * TWO_32

-- 0x5851F42D4C957F2D, PCG's multiplier, in two halves.
local MULT_HI = 0x5851F42D
local MULT_LO = 0x4C957F2D
local INCREMENT = 105

-- Where a generator is in its sequence: the high and low 32 bits of its 64-bit state.
export type Generator = {
	hi: number,
	lo: number,
}

-- a * b for two 32-bit numbers, exactly, as its high and low 32 bits
local function mul32(a: number, b: number): (number, number)
	local a1, a0 = a // 65536, a % 65536
	local b1, b0 = b // 65536, b % 65536
	local middle = a0 * b1 + a1 * b0
	local low = a0 * b0 + (middle % 65536) * 65536
	local carry = low // TWO_32
	return (a1 * b1 + middle // 65536 + carry) % TWO_32, low % TWO_32
end

-- One step: the next 32 bits.
local function next32(self: Generator): number
	local hi, lo = self.hi, self.lo
	local product_hi, product_lo = mul32(lo, MULT_LO)
	local _, cross_a = mul32(hi, MULT_LO)
	local _, cross_b = mul32(lo, MULT_HI)
	local new_lo = product_lo + INCREMENT
	local new_hi = (product_hi + cross_a + cross_b + new_lo // TWO_32) % TWO_32
	self.hi, self.lo = new_hi, new_lo % TWO_32
	local t_lo = bit32.bxor(lo, bit32.bor(bit32.rshift(lo, 18), bit32.lshift(hi, 14)))
	local t_hi = bit32.bxor(hi, bit32.rshift(hi, 18))
	local xorshifted = bit32.bor(bit32.rshift(t_lo, 27), bit32.lshift(t_hi, 5))
	return bit32.rrotate(xorshifted, bit32.rshift(hi, 27))
end

local function next_double(self: Generator): number
	local low = next32(self)
	local high = next32(self)
	return (low + high * TWO_32) / TWO_64
end

-- As Random:NextNumber: in [0, 1), or between `min` and `max`.
local function next_number(self: Generator, min: number?, max: number?): number
	local x = next_double(self)
	if min == nil then
		return x
	end
	local low, high = min :: number, max :: number
	return low * (1 - x) + high * x
end

-- As Random:NextInteger: a whole number from `min` to `max`, both included.
local function next_integer(self: Generator, min: number, max: number): number
	assert(min <= max, "invalid argument #2 to 'NextInteger' (interval is empty)")
	local count = max - min + 1
	if count < TWO_32 then
		local high = mul32(next32(self), count)
		return min + high
	elseif count == TWO_32 then
		-- the whole 32-bit range takes the high word of 64 bits
		next32(self)
		return min + next32(self)
	end
	return math.floor(min + next_double(self) * (max - min))
end

-- A generator seeded as Random.new(`seed`) is.
local function new(seed: number): Generator
	local whole = if seed >= 0 then math.floor(seed) else math.ceil(seed)
	local self: Generator = { hi = 0, lo = 0 }
	next32(self)
	local seed_lo = whole % TWO_32
	local seed_hi = (whole // TWO_32) % TWO_32
	local lo = self.lo + seed_lo
	self.hi = (self.hi + seed_hi + lo // TWO_32) % TWO_32
	self.lo = lo % TWO_32
	next32(self)
	return self
end

return table.freeze({
	new = new,
	next_number = next_number,
	next_integer = next_integer,
})
