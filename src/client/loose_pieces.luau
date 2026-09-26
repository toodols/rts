--!strict
-- Whatever flies loose, falls, tumbles and fades away, only drawn: the pieces of something that shattered
-- (client/debris.luau), and a donut flown off its aircraft, the scraps and puff of one that popped, and one floating up
-- off something under the water (client/donuts.luau). Each piece is some anchored parts moved as one, which touch
-- nothing, and the ground it lands on is the heightmap's.
--
-- How a piece moves is its own (`motion`): most fall (`fall`), pulled down and slowed by the air, tumbling as they go,
-- and land as their kind does, bouncing until they settle or lying flat where they come down; one can move any other
-- way. Every piece is whole until `fade_at` and then fades out over `fade_time`, and is gone at `lifetime` whatever
-- has happened.

local ReplicatedStorage = game:GetService "ReplicatedStorage"
local RunService = game:GetService "RunService"
local Workspace = game:GetService "Workspace"

local frame_profile = require(ReplicatedStorage.Client.frame_profile)

-- What a falling piece does as it comes down on the ground: bounces, keeping `keep_up` of its speed off the ground and
-- `keep_along` of its speed along it and of its tumbling, until it comes down slower than `settle` and stays where it
-- is; or lands flat, turned whichever way it was, and lies there `rest` seconds before it fades.
export type Landing =
	{ kind: "bounce", keep_up: number, keep_along: number, settle: number }
	| { kind: "lie", rest: number }

export type Piece = {
	parts: { BasePart },
	-- where each part sits against the whole, and how see-through it was drawn, which it fades from
	offsets: { CFrame },
	transparencies: { number },
	position: Vector3,
	rotation: CFrame,
	velocity: Vector3,
	-- its tumbling: about which axis, in the world, and how fast, in radians a second
	spin_axis: Vector3,
	spin: number,
	-- how far its lowest point is below its middle, which is what touches the ground
	half_height: number,
	age: number,
	lifetime: number,
	fade_at: number,
	fade_time: number,
	-- whether it has come to rest, and moves no more
	resting: boolean,
	-- a puff swells from `from` to `to` across its lifetime
	grow: { from: Vector3, to: Vector3 }?,
	-- moves it on by `dt` seconds
	motion: (piece: Piece, dt: number) -> (),
}

local pieces: { Piece } = {}
local moved_parts: { BasePart } = {}
local moved_frames: { CFrame } = {}

-- A motion that falls under `gravity` (studs a second a second), the air taking `drag` of its speed each second, and
-- comes down on the ground as `landing` says, where `ground(x, z)` is; nil for what never lands.
local function fall(
	gravity: number,
	drag: number,
	landing: Landing?,
	ground: (x: number, z: number) -> number
): (piece: Piece, dt: number) -> ()
	return function(piece: Piece, dt: number)
		local velocity = piece.velocity * math.exp(-drag * dt) - Vector3.yAxis * gravity * dt
		local position = piece.position + velocity * dt
		local rotation = CFrame.fromAxisAngle(piece.spin_axis, piece.spin * dt) * piece.rotation
		local floor = if landing ~= nil then ground(position.X, position.Z) + piece.half_height else -math.huge
		if landing ~= nil and position.Y <= floor then
			position = Vector3.new(position.X, floor, position.Z)
			if landing.kind == "bounce" then
				if -velocity.Y < landing.settle then
					piece.resting = true
				end
				velocity = Vector3.new(
					velocity.X * landing.keep_along,
					-velocity.Y * landing.keep_up,
					velocity.Z * landing.keep_along
				)
				piece.spin *= landing.keep_along
			else
				local _, yaw, _ = rotation:ToEulerAnglesYXZ()
				rotation = CFrame.Angles(0, yaw, 0)
				piece.resting = true
				piece.fade_at = math.min(piece.fade_at, piece.age + landing.rest)
				piece.lifetime = math.min(piece.lifetime, piece.fade_at + piece.fade_time)
			end
		end
		piece.velocity = velocity
		piece.position = position
		piece.rotation = rotation
	end
end

-- Sets `piece` loose.
local function add(piece: Piece)
	table.insert(pieces, piece)
end

-- How many pieces are loose.
local function count(): number
	return #pieces
end

local function step(dt: number)
	if #pieces == 0 then
		return
	end
	table.clear(moved_parts)
	table.clear(moved_frames)
	local index = 1
	while index <= #pieces do
		local piece = pieces[index]
		piece.age += dt
		if piece.age >= piece.lifetime then
			for _, part in piece.parts do
				part:Destroy()
			end
			-- swap the last one in, the order does not matter
			pieces[index] = pieces[#pieces]
			pieces[#pieces] = nil
			continue
		end
		if piece.resting == false then
			piece.motion(piece, dt)
			local frame = CFrame.new(piece.position) * piece.rotation
			for part_index, part in piece.parts do
				table.insert(moved_parts, part)
				table.insert(moved_frames, frame * piece.offsets[part_index])
			end
		end
		local grow = piece.grow
		if grow ~= nil then
			for _, part in piece.parts do
				part.Size = grow.from:Lerp(grow.to, piece.age / piece.lifetime)
			end
		end
		if piece.age > piece.fade_at then
			local faded = math.clamp((piece.age - piece.fade_at) / piece.fade_time, 0, 1)
			for part_index, part in piece.parts do
				local drawn = piece.transparencies[part_index]
				part.Transparency = drawn + (1 - drawn) * faded
			end
		end
		index += 1
	end
	if #moved_parts > 0 then
		Workspace:BulkMoveTo(moved_parts, moved_frames, Enum.BulkMoveMode.FireCFrameChanged)
	end
end

local function init()
	RunService.PreRender:Connect(frame_profile.wrap("loose_pieces", step))
end

return table.freeze({
	fall = fall,
	add = add,
	count = count,
	init = init,
})
