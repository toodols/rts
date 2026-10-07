-- Roblox's datatypes, for the game's code to run on outside Roblox (see ../README.md).
--
-- Vector3 is Luau's own vector, as it is in Roblox: three 32-bit floats, a value type, arithmetic built into the VM.
-- The one thing a vector cannot do outside Roblox is answer `.Magnitude`, `.Unit` or `:Dot(...)`, since the vector
-- type's metatable is Roblox's to fill in and here it is frozen; loader.luau rewrites those few uses into calls of
-- `vector_methods` below as it loads each module, and nothing else.
--
-- Vector2 and CFrame are plain tables here (they are userdata in Roblox). Random is Roblox's own generator, bit for
-- bit: PCG32 XSH-RR with Luau's increment of 105, seeded and read the way Roblox's is (checked against values Studio
-- printed), so a map built from a seed here is the map Studio builds from it.

local lune_roblox = require "@lune/roblox"

local TWO_32 = 4294967296
local TWO_64 = TWO_32 * TWO_32

-- Vector3 ------------------------------------------------------------------------------------------------------------

local vcreate = vector.create
local vmagnitude = vector.magnitude

local Vector3 = {}
function Vector3.new(x: number?, y: number?, z: number?): vector
	return vcreate(x or 0, y or 0, z or 0)
end
Vector3.zero = vcreate(0, 0, 0)
Vector3.one = vcreate(1, 1, 1)
Vector3.xAxis = vcreate(1, 0, 0)
Vector3.yAxis = vcreate(0, 1, 0)
Vector3.zAxis = vcreate(0, 0, 1)
table.freeze(Vector3)

-- Roblox works a Vector3's length out in 32-bit floats (Studio's (185.2116, 0, -1.6134).Magnitude is 185.2186279296875),
-- where vector.magnitude works in 64 bits (185.21862082414933); the last digits moved a unit a hair differently and a
-- game drifted off Studio's. Each step is rounded to 32 bits, as Roblox's own arithmetic would leave it.
local function round32(x: number): number
	return vcreate(x, 0, 0).x
end
local function magnitude32(v: vector): number
	local x, y, z = v.x, v.y, v.z
	return round32(math.sqrt(round32(round32(round32(x * x) + round32(y * y)) + round32(z * z))))
end

-- Roblox's Vector3.Unit is the vector times 1 over its length, rounded to 32 bits (dividing by the length is a bit off in
-- the last place); of a zero vector it is NaN in every component, as vector.normalize's is.
local function unit(v: vector): vector
	return v * round32(1 / magnitude32(v))
end

-- What the rewritten `.Magnitude`, `.Unit` and `:Method(...)` call: a vector's answer, or, for anything else (a
-- Vector2, a CFrame), whatever it answers itself.
local vector_methods = {}
function vector_methods.Magnitude(value: any): number
	if type(value) == "vector" then
		return magnitude32(value)
	end
	return value.Magnitude
end
function vector_methods.Unit(value: any): any
	if type(value) == "vector" then
		return unit(value)
	end
	return value.Unit
end
function vector_methods.Dot(value: any, other: any): number
	if type(value) == "vector" then
		return vector.dot(value, other)
	end
	return value:Dot(other)
end
-- Roblox's Vector3:Cross rounds each product to 32 bits and then the difference. vector.cross does too where Luau calls
-- it as a fast built-in, but a module compiled at optimization level 0, as the arena compiles the game's (loader.luau),
-- calls the library's, which rounds only the difference: a hair off, and a homing missile lost its lock a step apart
-- from Studio's (2026-09-27, held up against Studio over 100,000 of them).
local function cross32(a: vector, b: vector): vector
	return vcreate(
		round32(round32(a.y * b.z) - round32(a.z * b.y)),
		round32(round32(a.z * b.x) - round32(a.x * b.z)),
		round32(round32(a.x * b.y) - round32(a.y * b.x))
	)
end
function vector_methods.Cross(value: any, other: any): any
	if type(value) == "vector" then
		return cross32(value, other)
	end
	return value:Cross(other)
end
function vector_methods.Lerp(value: any, goal: any, alpha: number): any
	if type(value) == "vector" then
		return value + (goal - value) * alpha
	end
	return value:Lerp(goal, alpha)
end
function vector_methods.Abs(value: any): any
	if type(value) == "vector" then
		return vector.abs(value)
	end
	return value:Abs()
end
function vector_methods.Min(value: any, ...: any): any
	if type(value) == "vector" then
		return vector.min(value, ...)
	end
	return value:Min(...)
end
function vector_methods.Max(value: any, ...: any): any
	if type(value) == "vector" then
		return vector.max(value, ...)
	end
	return value:Max(...)
end
function vector_methods.FuzzyEq(value: any, other: any, epsilon: number?): boolean
	if type(value) == "vector" then
		local e = epsilon or 1e-5
		local d = vector.abs(value - other)
		return d.x <= e and d.y <= e and d.z <= e
	end
	return value:FuzzyEq(other, epsilon)
end
table.freeze(vector_methods)

-- Vector2 ------------------------------------------------------------------------------------------------------------

local Vector2Meta = {}
local vector2_methods = {}

-- Roblox's Vector2 holds 32-bit floats and works in them, as a Vector3 does; with 64-bit ones the wind (a Vector2)
-- blew a hair differently, the turbines made a hair more, and a game drifted off Studio's within a couple of minutes.
-- Each component and each answer is rounded to 32 bits, as a lone +, -, *, / or square root in 32 bits would give. A
-- number it is multiplied or divided by is a 32-bit float too, first, and dividing by one is multiplying by its 32-bit
-- reciprocal, as Roblox does it: held up against Studio over 100,000 of each (2026-09-27), when with the number left 64
-- bits the wind drifted off Studio's, and a replay with it, in a couple of minutes.
local function f32(x: number): number
	return vcreate(x, 0, 0).x
end

local function new_vector2(x: number?, y: number?): any
	return setmetatable({ X = f32(x or 0), Y = f32(y or 0) }, Vector2Meta)
end

local function length2(x: number, y: number): number
	return f32(math.sqrt(f32(f32(x * x) + f32(y * y))))
end

Vector2Meta.__type = "Vector2"
Vector2Meta.__index = function(self, key)
	if key == "Magnitude" then
		return length2(self.X, self.Y)
	elseif key == "Unit" then
		local inverse = f32(1 / length2(self.X, self.Y))
		return new_vector2(self.X * inverse, self.Y * inverse)
	elseif key == "x" then
		return self.X
	elseif key == "y" then
		return self.Y
	end
	return vector2_methods[key]
end
Vector2Meta.__add = function(a, b)
	return new_vector2(a.X + b.X, a.Y + b.Y)
end
Vector2Meta.__sub = function(a, b)
	return new_vector2(a.X - b.X, a.Y - b.Y)
end
Vector2Meta.__mul = function(a, b)
	if type(a) == "number" then
		local scale = f32(a)
		return new_vector2(scale * b.X, scale * b.Y)
	elseif type(b) == "number" then
		local scale = f32(b)
		return new_vector2(a.X * scale, a.Y * scale)
	end
	return new_vector2(a.X * b.X, a.Y * b.Y)
end
Vector2Meta.__div = function(a, b)
	if type(b) == "number" then
		local inverse = f32(1 / f32(b))
		return new_vector2(a.X * inverse, a.Y * inverse)
	elseif type(a) == "number" then
		return new_vector2(a / b.X, a / b.Y)
	end
	return new_vector2(a.X / b.X, a.Y / b.Y)
end
Vector2Meta.__unm = function(a)
	return new_vector2(-a.X, -a.Y)
end
Vector2Meta.__eq = function(a, b)
	return a.X == b.X and a.Y == b.Y
end
Vector2Meta.__tostring = function(a)
	return `{a.X}, {a.Y}`
end
function vector2_methods.Dot(a, b)
	return f32(f32(a.X * b.X) + f32(a.Y * b.Y))
end
function vector2_methods.Cross(a, b)
	return f32(f32(a.X * b.Y) - f32(a.Y * b.X))
end
function vector2_methods.Lerp(a, b, t)
	return new_vector2(a.X + f32(f32(b.X - a.X) * t), a.Y + f32(f32(b.Y - a.Y) * t))
end
function vector2_methods.Abs(a)
	return new_vector2(math.abs(a.X), math.abs(a.Y))
end
function vector2_methods.Min(a, ...)
	local x, y = a.X, a.Y
	for _, b in { ... } do
		x, y = math.min(x, b.X), math.min(y, b.Y)
	end
	return new_vector2(x, y)
end
function vector2_methods.Max(a, ...)
	local x, y = a.X, a.Y
	for _, b in { ... } do
		x, y = math.max(x, b.X), math.max(y, b.Y)
	end
	return new_vector2(x, y)
end
function vector2_methods.FuzzyEq(a, b, epsilon)
	local e = epsilon or 1e-5
	return math.abs(a.X - b.X) <= e and math.abs(a.Y - b.Y) <= e
end

local Vector2 = table.freeze({
	new = new_vector2,
	zero = new_vector2(0, 0),
	one = new_vector2(1, 1),
	xAxis = new_vector2(1, 0),
	yAxis = new_vector2(0, 1),
})

-- CFrame -------------------------------------------------------------------------------------------------------------

-- A position and a rotation matrix, row by row: r00 r01 r02 / r10 r11 r12 / r20 r21 r22.
local CFrameMeta = {}
local cframe_methods = {}

local function make_cframe(p: vector, r00, r01, r02, r10, r11, r12, r20, r21, r22): any
	return setmetatable({
		p = p,
		r00 = r00,
		r01 = r01,
		r02 = r02,
		r10 = r10,
		r11 = r11,
		r12 = r12,
		r20 = r20,
		r21 = r21,
		r22 = r22,
	}, CFrameMeta)
end

local function rotate(c, v: vector): vector
	local x, y, z = v.x, v.y, v.z
	return vcreate(
		c.r00 * x + c.r01 * y + c.r02 * z,
		c.r10 * x + c.r11 * y + c.r12 * z,
		c.r20 * x + c.r21 * y + c.r22 * z
	)
end

local function unrotate(c, v: vector): vector
	local x, y, z = v.x, v.y, v.z
	return vcreate(
		c.r00 * x + c.r10 * y + c.r20 * z,
		c.r01 * x + c.r11 * y + c.r21 * z,
		c.r02 * x + c.r12 * y + c.r22 * z
	)
end

local function compose(a, b): any
	return make_cframe(
		a.p + rotate(a, b.p),
		a.r00 * b.r00 + a.r01 * b.r10 + a.r02 * b.r20,
		a.r00 * b.r01 + a.r01 * b.r11 + a.r02 * b.r21,
		a.r00 * b.r02 + a.r01 * b.r12 + a.r02 * b.r22,
		a.r10 * b.r00 + a.r11 * b.r10 + a.r12 * b.r20,
		a.r10 * b.r01 + a.r11 * b.r11 + a.r12 * b.r21,
		a.r10 * b.r02 + a.r11 * b.r12 + a.r12 * b.r22,
		a.r20 * b.r00 + a.r21 * b.r10 + a.r22 * b.r20,
		a.r20 * b.r01 + a.r21 * b.r11 + a.r22 * b.r21,
		a.r20 * b.r02 + a.r21 * b.r12 + a.r22 * b.r22
	)
end

local function inverse(c): any
	local p = -unrotate(c, c.p)
	return make_cframe(p, c.r00, c.r10, c.r20, c.r01, c.r11, c.r21, c.r02, c.r12, c.r22)
end

CFrameMeta.__type = "CFrame"
CFrameMeta.__index = function(self, key)
	if key == "Position" then
		return self.p
	elseif key == "X" then
		return self.p.x
	elseif key == "Y" then
		return self.p.y
	elseif key == "Z" then
		return self.p.z
	elseif key == "LookVector" then
		return vcreate(-self.r02, -self.r12, -self.r22)
	elseif key == "RightVector" then
		return vcreate(self.r00, self.r10, self.r20)
	elseif key == "UpVector" then
		return vcreate(self.r01, self.r11, self.r21)
	elseif key == "Rotation" then
		return make_cframe(
			vcreate(0, 0, 0),
			self.r00,
			self.r01,
			self.r02,
			self.r10,
			self.r11,
			self.r12,
			self.r20,
			self.r21,
			self.r22
		)
	end
	return cframe_methods[key]
end
CFrameMeta.__mul = function(a, b)
	if type(b) == "vector" then
		return a.p + rotate(a, b)
	end
	return compose(a, b)
end
CFrameMeta.__add = function(a, v)
	return make_cframe(a.p + v, a.r00, a.r01, a.r02, a.r10, a.r11, a.r12, a.r20, a.r21, a.r22)
end
CFrameMeta.__sub = function(a, v)
	return make_cframe(a.p - v, a.r00, a.r01, a.r02, a.r10, a.r11, a.r12, a.r20, a.r21, a.r22)
end
CFrameMeta.__tostring = function(a)
	return `{a.p}, {a.r00}, {a.r01}, {a.r02}, {a.r10}, {a.r11}, {a.r12}, {a.r20}, {a.r21}, {a.r22}`
end
function cframe_methods.PointToWorldSpace(c, v)
	return c.p + rotate(c, v)
end
function cframe_methods.VectorToWorldSpace(c, v)
	return rotate(c, v)
end
function cframe_methods.PointToObjectSpace(c, v)
	return unrotate(c, v - c.p)
end
function cframe_methods.VectorToObjectSpace(c, v)
	return unrotate(c, v)
end
function cframe_methods.Inverse(c)
	return inverse(c)
end
function cframe_methods.ToWorldSpace(c, other)
	return compose(c, other)
end
function cframe_methods.ToObjectSpace(c, other)
	return compose(inverse(c), other)
end
function cframe_methods.GetComponents(c)
	return c.p.x, c.p.y, c.p.z, c.r00, c.r01, c.r02, c.r10, c.r11, c.r12, c.r20, c.r21, c.r22
end
cframe_methods.components = cframe_methods.GetComponents

local function from_euler_xyz(rx: number, ry: number, rz: number): any
	-- Rx * Ry * Rz, as Roblox's CFrame.Angles / fromEulerAnglesXYZ
	local cx, sx = math.cos(rx), math.sin(rx)
	local cy, sy = math.cos(ry), math.sin(ry)
	local cz, sz = math.cos(rz), math.sin(rz)
	return make_cframe(
		vcreate(0, 0, 0),
		cy * cz,
		-cy * sz,
		sy,
		cx * sz + sx * sy * cz,
		cx * cz - sx * sy * sz,
		-sx * cy,
		sx * sz - cx * sy * cz,
		sx * cz + cx * sy * sz,
		cx * cy
	)
end

local CFrame = {}
function CFrame.new(...): any
	local count = select("#", ...)
	if count == 0 then
		return make_cframe(vcreate(0, 0, 0), 1, 0, 0, 0, 1, 0, 0, 0, 1)
	end
	local a, b, c = ...
	if count == 1 then
		return make_cframe(a, 1, 0, 0, 0, 1, 0, 0, 0, 1)
	elseif count == 3 then
		return make_cframe(vcreate(a, b, c), 1, 0, 0, 0, 1, 0, 0, 0, 1)
	elseif count == 12 then
		local x, y, z, r00, r01, r02, r10, r11, r12, r20, r21, r22 = ...
		return make_cframe(vcreate(x, y, z), r00, r01, r02, r10, r11, r12, r20, r21, r22)
	elseif count == 2 then
		-- CFrame.new(at, look_at)
		local look = vector.normalize(b - a)
		local right = vector.cross(look, vcreate(0, 1, 0))
		if vmagnitude(right) < 1e-6 then
			right = vcreate(1, 0, 0)
		else
			right = vector.normalize(right)
		end
		local up = vector.cross(right, look)
		return make_cframe(a, right.x, up.x, -look.x, right.y, up.y, -look.y, right.z, up.z, -look.z)
	end
	error(`CFrame.new with {count} arguments is not shimmed`)
end
CFrame.Angles = from_euler_xyz
CFrame.fromEulerAnglesXYZ = from_euler_xyz
function CFrame.fromAxisAngle(axis: vector, angle: number): any
	local u = vector.normalize(axis)
	local x, y, z = u.x, u.y, u.z
	local c, s = math.cos(angle), math.sin(angle)
	local t = 1 - c
	return make_cframe(
		vcreate(0, 0, 0),
		t * x * x + c,
		t * x * y - s * z,
		t * x * z + s * y,
		t * x * y + s * z,
		t * y * y + c,
		t * y * z - s * x,
		t * x * z - s * y,
		t * y * z + s * x,
		t * z * z + c
	)
end
function CFrame.fromMatrix(p: vector, right: vector, up: vector, back: vector?): any
	local b = back or vector.cross(right, up)
	return make_cframe(p, right.x, up.x, b.x, right.y, up.y, b.y, right.z, up.z, b.z)
end
function CFrame.lookAt(at: vector, look_at: vector): any
	return CFrame.new(at, look_at)
end
CFrame.identity = CFrame.new()
table.freeze(CFrame)

-- Random -------------------------------------------------------------------------------------------------------------

-- 0x5851F42D4C957F2D, PCG's multiplier, in two halves.
local MULT_HI = 0x5851F42D
local MULT_LO = 0x4C957F2D
local INCREMENT = 105

-- a * b for two 32-bit numbers, exactly, as its high and low 32 bits
local function mul32(a: number, b: number): (number, number)
	local a1, a0 = a // 65536, a % 65536
	local b1, b0 = b // 65536, b % 65536
	local middle = a0 * b1 + a1 * b0
	local low = a0 * b0 + (middle % 65536) * 65536
	local carry = low // TWO_32
	return (a1 * b1 + middle // 65536 + carry) % TWO_32, low % TWO_32
end

local RandomMeta = {}
local random_methods = {}
RandomMeta.__type = "Random"
RandomMeta.__index = random_methods

-- One step of PCG32 XSH-RR: the next 32 bits.
local function next32(self): number
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

local function next_double(self): number
	local low = next32(self)
	local high = next32(self)
	return (low + high * TWO_32) / TWO_64
end

function random_methods.NextNumber(self, min: number?, max: number?): number
	local x = next_double(self)
	if min == nil then
		return x
	end
	local low, high = min :: number, max :: number
	return low * (1 - x) + high * x
end

function random_methods.NextInteger(self, min: number, max: number): number
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

function random_methods.NextUnitVector(self): vector
	-- not Roblox's exact method; nothing the game asks of it headless
	local z = self:NextNumber(-1, 1)
	local angle = self:NextNumber(0, math.pi * 2)
	local r = math.sqrt(1 - z * z)
	return vcreate(r * math.cos(angle), r * math.sin(angle), z)
end

function random_methods.Clone(self): any
	return setmetatable({ hi = self.hi, lo = self.lo }, RandomMeta)
end

-- Seeds for Random.new() with no seed, which in Roblox come from entropy; here from `unseeded_base` on, so that a
-- match is repeatable from its seed.
local unseeded_base = 0
local unseeded_count = 0

local function new_random(seed: number?): any
	local value = seed
	if value == nil then
		unseeded_count += 1
		value = unseeded_base + unseeded_count * 7919
	end
	local whole = if value >= 0 then math.floor(value) else math.ceil(value)
	local self = setmetatable({ hi = 0, lo = 0 }, RandomMeta)
	next32(self)
	local seed_lo = whole % TWO_32
	local seed_hi = (whole // TWO_32) % TWO_32
	local lo = self.lo + seed_lo
	self.hi = (self.hi + seed_hi + lo // TWO_32) % TWO_32
	self.lo = lo % TWO_32
	next32(self)
	return self
end

local Random = table.freeze({ new = new_random })

-- Seeds Random.new() with no seed from `base` on, for a match to be repeatable.
local function seed_unseeded(base: number)
	unseeded_base = base
	unseeded_count = 0
end

-- Enum ---------------------------------------------------------------------------------------------------------------

-- Roblox's Enum.Material.Grass is the same object every time, so the game keys tables by enum items (ground_paint's and
-- scenery's grounds, the maps' materials); lune's makes a new one at every access, equal by == but never the same key,
-- so every such lookup missed and, among other things, no rock or tree was ever laid. Each item is kept the first time
-- it is asked for and handed out again after.
local enum_types: { [string]: any } = {}
local function enum_type(name: string): any
	local found = enum_types[name]
	if found ~= nil then
		return found
	end
	local real = lune_roblox.Enum[name]
	local items: { [string]: any } = {}
	local function item(key: string): any
		local kept = items[key]
		if kept == nil then
			kept = real[key]
			items[key] = kept
		end
		return kept
	end
	found = setmetatable({}, {
		__index = function(_, key: string): any
			if key == "GetEnumItems" then
				return function(): { any }
					local all = {}
					for _, each in real:GetEnumItems() do
						table.insert(all, item(each.Name))
					end
					return all
				end
			end
			return item(key)
		end,
		__tostring = function(): string
			return tostring(real)
		end,
	})
	enum_types[name] = found
	return found
end
local Enum = setmetatable({}, {
	__index = function(_, name: string): any
		return enum_type(name)
	end,
})

-- typeof -------------------------------------------------------------------------------------------------------------

local lune_typeof = typeof
local function roblox_typeof(value: any): string
	local kind = type(value)
	if kind == "vector" then
		return "Vector3"
	elseif kind == "table" then
		local meta = getmetatable(value)
		if type(meta) == "table" and rawget(meta, "__type") ~= nil then
			return rawget(meta, "__type")
		end
		return "table"
	end
	return lune_typeof(value)
end

return {
	Vector3 = Vector3,
	Vector2 = Vector2,
	CFrame = CFrame,
	Random = Random,
	vector_methods = vector_methods,
	seed_unseeded = seed_unseeded,
	typeof = roblox_typeof,
	-- plain data the server's code only builds and compares
	Color3 = lune_roblox.Color3,
	BrickColor = lune_roblox.BrickColor,
	Enum = Enum,
	UDim = lune_roblox.UDim,
	UDim2 = lune_roblox.UDim2,
	NumberRange = lune_roblox.NumberRange,
	NumberSequence = lune_roblox.NumberSequence,
	NumberSequenceKeypoint = lune_roblox.NumberSequenceKeypoint,
	ColorSequence = lune_roblox.ColorSequence,
	ColorSequenceKeypoint = lune_roblox.ColorSequenceKeypoint,
	Rect = lune_roblox.Rect,
	Font = lune_roblox.Font,
	PhysicalProperties = lune_roblox.PhysicalProperties,
	Faces = lune_roblox.Faces,
	Axes = lune_roblox.Axes,
	Vector3int16 = lune_roblox.Vector3int16,
	Vector2int16 = lune_roblox.Vector2int16,
}
