-- The pieces of something that dies without leaving a wreck fly apart, tumble to the ground, and fade away.
--
-- The server says when something has shattered (combat.luau's `shatter`); art.luau hands over copies of the pieces of
-- art it was last drawn in, and they are flung out from the middle of its body, harder the more violent its death,
-- carrying whatever speed it had. It is only drawn: the pieces are anchored, client-only, and touch nothing, and the
-- ground they bounce on is the heightmap's.

local ReplicatedStorage = game:GetService "ReplicatedStorage"
local RunService = game:GetService "RunService"
local Workspace = game:GetService "Workspace"

local heightmap = require(ReplicatedStorage.Shared.heightmap)
local types = require(ReplicatedStorage.Shared.types)
local art = require(ReplicatedStorage.Client.art)

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
-- The pull down, in studs a second squared: lighter than Roblox's own, which reads as too heavy at this scale.
local GRAVITY = 80
-- What a bounce keeps of a piece's speed up off the ground, and of its speed along it and its tumbling, and the speed up
-- below which it settles instead.
local BOUNCE = 0.35
local GROUND_FRICTION = 0.55
local SETTLE_SPEED = 4
-- How long a piece is whole, in seconds, and how long it then takes to fade away.
local FADE_AFTER = 1.2
local FADE_TIME = 0.9
-- The most pieces in flight at once, so that a great many deaths together cost no more than this.
local MAX_SHARDS = 800

type Shard = {
	part: MeshPart,
	velocity: Vector3,
	-- its tumbling: about which axis, in the world, and how fast
	axis: Vector3,
	spin: number,
	-- how far above its middle its lowest point may reach, which is what touches the ground
	reach: number,
	settled: boolean,
	-- how opaque it was drawn, which it fades from
	transparency: number,
	age: number,
}

local random = Random.new()
local shards: { Shard } = {}
local folder: Folder? = nil

local function debris_folder(): Folder
	if folder == nil or folder.Parent == nil then
		local created = Instance.new "Folder"
		created.Name = "Debris"
		created.Parent = Workspace
		folder = created
	end
	return folder :: Folder
end

local function random_axis(): Vector3
	local axis = random:NextUnitVector()
	return if axis.Magnitude > 1e-3 then axis else Vector3.yAxis
end

local function fling(id: EntityId, severity: number, inherited: Vector3)
	local parts, middle = art.shatter(id)
	if parts == nil or middle == nil then
		return
	end
	local room = MAX_SHARDS - #shards
	local violence = math.clamp(severity / FULL_SEVERITY, 0, 1)
	local out_speed = OUT_SPEED_GENTLE + (OUT_SPEED_VIOLENT - OUT_SPEED_GENTLE) * violence
	local up_speed = UP_SPEED_GENTLE + (UP_SPEED_VIOLENT - UP_SPEED_GENTLE) * violence
	local parent = debris_folder()
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
		table.insert(shards, {
			part = part,
			velocity = velocity,
			axis = random_axis(),
			spin = random:NextNumber(SPIN_LOW, SPIN_HIGH),
			reach = math.min(size.X, size.Y, size.Z) / 2,
			settled = false,
			transparency = part.Transparency,
			age = 0,
		})
	end
end

local moved_parts: { BasePart } = {}
local moved_frames: { CFrame } = {}

local function step(dt: number)
	if #shards == 0 then
		return
	end
	table.clear(moved_parts)
	table.clear(moved_frames)
	local index = 1
	while index <= #shards do
		local shard = shards[index]
		shard.age += dt
		if shard.age >= FADE_AFTER + FADE_TIME then
			shard.part:Destroy()
			-- swap the last one in, the order does not matter
			shards[index] = shards[#shards]
			shards[#shards] = nil
			continue
		end
		if shard.age > FADE_AFTER then
			local faded = (shard.age - FADE_AFTER) / FADE_TIME
			shard.part.Transparency = shard.transparency + (1 - shard.transparency) * faded
		end
		if shard.settled == false then
			local frame = shard.part.CFrame
			local velocity = shard.velocity - Vector3.yAxis * GRAVITY * dt
			local at = frame.Position + velocity * dt
			local ground = heightmap.height_at(at.X, at.Z) + shard.reach
			if at.Y <= ground then
				at = Vector3.new(at.X, ground, at.Z)
				if -velocity.Y < SETTLE_SPEED then
					shard.settled = true
				end
				velocity = Vector3.new(velocity.X * GROUND_FRICTION, -velocity.Y * BOUNCE, velocity.Z * GROUND_FRICTION)
				shard.spin *= GROUND_FRICTION
			end
			shard.velocity = velocity
			local turn = CFrame.fromAxisAngle(shard.axis, shard.spin * dt)
			table.insert(moved_parts, shard.part)
			table.insert(moved_frames, CFrame.new(at) * turn * frame.Rotation)
		end
		index += 1
	end
	if #moved_parts > 0 then
		Workspace:BulkMoveTo(moved_parts, moved_frames, Enum.BulkMoveMode.FireCFrameChanged)
	end
end

local function init()
	RunService.Heartbeat:Connect(step)
	unit_shattered.OnClientEvent:Connect(function(event: { id: EntityId, severity: number, velocity: Vector3? })
		fling(event.id, event.severity, event.velocity or Vector3.zero)
	end)
end

return table.freeze({
	init = init,
})
