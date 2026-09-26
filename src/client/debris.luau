-- The pieces of something that dies without leaving a wreck fly apart, tumble to the ground, and fade away.
--
-- The server says when something has shattered (deaths.luau's `shatter`); art.luau hands over copies of the pieces of
-- art it was last drawn in, and they are flung out from the middle of its body, harder the more violent its death,
-- carrying whatever speed it had. It is only drawn: the pieces are anchored, client-only, and touch nothing, and the
-- ground they bounce on is the heightmap's (client/loose_pieces.luau).

local ReplicatedStorage = game:GetService "ReplicatedStorage"

local heightmap = require(ReplicatedStorage.Shared.heightmap)
local types = require(ReplicatedStorage.Shared.types)

local art = require(ReplicatedStorage.Client.art)
local world_fx = require(ReplicatedStorage.Client.world_fx)
local loose_pieces = require(ReplicatedStorage.Client.loose_pieces)

type EntityId = types.EntityId

local unit_shattered: RemoteEvent = ReplicatedStorage.Shared.UnitShattered

-- How fast a piece flies out across the ground and up, in studs a second, from the gentlest death to one of
-- FULL_SEVERITY or worse (severity as the server's `kill` has it, a percentage of the thing's health taken lately),
-- each piece somewhere between SPREAD_LOW and SPREAD_HIGH times that.
local OUT_SPEED_GENTLE = 8
local OUT_SPEED_VIOLENT = 26
local UP_SPEED_GENTLE = 12
local UP_SPEED_VIOLENT = 28
local FULL_SEVERITY = 100
local SPREAD_LOW = 0.6
local SPREAD_HIGH = 1.25
-- How fast a piece tumbles, in radians a second, at most and at least.
local SPIN_LOW = 3
local SPIN_HIGH = 11
-- How a piece falls: pulled down lighter than Roblox's own gravity, which reads as too heavy at this scale, and
-- bouncing, keeping some of its speed up off the ground and of its speed along it and its tumbling, until it comes down
-- too slowly to bounce and settles.
local FALL =
	loose_pieces.fall(80, 0, { kind = "bounce", keep_up = 0.35, keep_along = 0.55, settle = 4 }, heightmap.height_at)
-- How long a piece is whole, in seconds, and how long it then takes to fade away.
local FADE_AFTER = 1.2
local FADE_TIME = 0.9
-- The most pieces loose at once, so that a great many deaths together cost no more than this.
local MAX_PIECES = 800

local random = Random.new()

local function random_axis(): Vector3
	local axis = random:NextUnitVector()
	return if axis.Magnitude > 1e-3 then axis else Vector3.yAxis
end

local function fling(id: EntityId, severity: number, inherited: Vector3)
	local parts, middle = art.shatter(id)
	if parts == nil or middle == nil then
		return
	end
	local room = MAX_PIECES - loose_pieces.count()
	local violence = math.clamp(severity / FULL_SEVERITY, 0, 1)
	local out_speed = OUT_SPEED_GENTLE + (OUT_SPEED_VIOLENT - OUT_SPEED_GENTLE) * violence
	local up_speed = UP_SPEED_GENTLE + (UP_SPEED_VIOLENT - UP_SPEED_GENTLE) * violence
	local parent = world_fx.folder "Debris"
	for _, part in parts do
		if room <= 0 then
			part:Destroy()
			continue
		end
		room -= 1
		-- out from the middle across the ground, or any way at all for a piece right over it
		local offset = part.Position - middle
		local across = Vector3.new(offset.X, 0, offset.Z)
		local direction = if across.Magnitude > 0.05
			then across.Unit
			else CFrame.Angles(0, random:NextNumber(0, 2 * math.pi), 0).LookVector
		local velocity = direction * out_speed * random:NextNumber(SPREAD_LOW, SPREAD_HIGH)
			+ Vector3.yAxis * up_speed * random:NextNumber(SPREAD_LOW, SPREAD_HIGH)
			+ inherited
		part.Anchored = true
		part.CanCollide = false
		part.CanQuery = false
		part.CanTouch = false
		part.Parent = parent
		local size = part.Size
		loose_pieces.add({
			parts = { part },
			offsets = { CFrame.identity },
			transparencies = { part.Transparency },
			position = part.Position,
			rotation = part.CFrame.Rotation,
			velocity = velocity,
			spin_axis = random_axis(),
			spin = random:NextNumber(SPIN_LOW, SPIN_HIGH),
			half_height = math.min(size.X, size.Y, size.Z) / 2,
			age = 0,
			lifetime = FADE_AFTER + FADE_TIME,
			fade_at = FADE_AFTER,
			fade_time = FADE_TIME,
			resting = false,
			grow = nil,
			motion = FALL,
		})
	end
end

local function init()
	unit_shattered.OnClientEvent:Connect(function(event: { id: EntityId, severity: number, velocity: Vector3? })
		fling(event.id, event.severity, event.velocity or Vector3.zero)
	end)
end

return table.freeze({
	init = init,
})
