--!strict
-- What the client draws into the world for itself: order markers, ghosts, beams, blasts, rings, debris. It all goes in
-- the Effects folder the place is built with (rts-game.project.json), apart from the entities, or a folder of its own
-- in there (`folder`), as parts that nothing collides with, touches or picks (`part`).
--
-- What is redrawn every frame comes from a pool, so that its parts are reused rather than made again: each frame
-- `acquire` hands out the pool's parts in turn, and `release_rest` puts away whatever that frame did not use. What is
-- drawn once and fades away is let go with `fade` (after any `tween` before it).
--
-- A line laid over the ground, climbing the hills rather than cutting through them (an order's path, a range ring, a
-- start box's edge), is a row of dashes from point to point (`lay_line`), through points along the ground
-- (`ground_points`, `arc_points`).

local Debris = game:GetService "Debris"
local ReplicatedStorage = game:GetService "ReplicatedStorage"
local TweenService = game:GetService "TweenService"
local Workspace = game:GetService "Workspace"

local heightmap = require(ReplicatedStorage.Shared.heightmap)
local model_fit = require(ReplicatedStorage.Shared.model_fit)

local art_models = require(ReplicatedStorage.ClientShared.art_models)

-- A pool of parts, made by `make` as more are wanted, of which the first `used` are out this frame.
export type Pool = {
	parts: { Part },
	used: number,
	make: () -> Part,
}

-- How a line laid over the ground is drawn: how far above the points it runs, how thick it is, and whether each dash
-- runs on past its end by its thickness, which closes the corners of a line drawn once but doubles up the colour where
-- two see-through dashes meet.
export type LineStyle = { lift: number, thickness: number, closed_corners: boolean }

-- A Cylinder part's flat faces point along X, so one that is to lie flat is rolled this way.
local LIE_FLAT = CFrame.Angles(0, 0, math.pi / 2)
-- How see-through a ghost model's parts are at least.
local GHOST_TRANSPARENCY = 0.55

-- Where the client's own drawn things go: the Effects folder, or the folder called `name` in it, made the first time it
-- is asked for.
local function folder(name: string?): Instance
	local effects = Workspace:FindFirstChild "Effects" or Workspace
	if name == nil then
		return effects
	end
	local found = effects:FindFirstChild(name)
	if found == nil then
		local made = Instance.new "Folder"
		made.Name = name
		made.Parent = effects
		found = made
	end
	return found :: Instance
end

-- A part called `name` for drawing with: anchored, glowing, casting no shadow, and out of every collision, touch and
-- pick, not yet parented.
local function part(name: string): Part
	local made = Instance.new "Part"
	made.Name = name
	made.Anchored = true
	made.CanCollide = false
	made.CanQuery = false
	made.CanTouch = false
	made.CastShadow = false
	made.Material = Enum.Material.Neon
	return made
end

-- A Cylinder part's frame lying flat with its middle at `at`.
local function lying_flat(at: Vector3): CFrame
	return CFrame.new(at) * LIE_FLAT
end

-- Tweens `instance` to `goal` over `seconds`, easing out (Quad unless `style` says), after `delay` if given.
local function tween(
	instance: Instance,
	seconds: number,
	goal: { [string]: any },
	style: Enum.EasingStyle?,
	delay: number?
)
	local info = TweenInfo.new(seconds, style or Enum.EasingStyle.Quad, Enum.EasingDirection.Out, 0, false, delay or 0)
	TweenService:Create(instance, info, goal):Play()
end

-- Tweens `instance` as `tween` does, for the last time: it is rid of once that is done.
local function fade(
	instance: Instance,
	seconds: number,
	goal: { [string]: any },
	style: Enum.EasingStyle?,
	delay: number?
)
	tween(instance, seconds, goal, style, delay)
	Debris:AddItem(instance, seconds + (delay or 0))
end

local function pool(make: () -> Part): Pool
	return { parts = {}, used = 0, make = make }
end

-- The pool's next part for this frame, in the Effects folder.
local function acquire(from: Pool): Part
	from.used += 1
	if from.used > #from.parts then
		table.insert(from.parts, from.make())
	end
	local found = from.parts[from.used]
	if found.Parent == nil then
		found.Parent = folder()
	end
	return found
end

-- Puts away every part of the pool not acquired since the last call, and starts the next frame over.
local function release_rest(from: Pool)
	for index = from.used + 1, #from.parts do
		local unused = from.parts[index]
		if unused.Parent ~= nil then
			unused.Parent = nil
		end
	end
	from.used = 0
end

-- Lays a line through `points` as one dash from each point to the next, drawn as `style` says, each a part that
-- `next_dash` hands out (a fresh one, or one from a pool); when it hands out none the line stops there.
local function lay_line(points: { Vector3 }, style: LineStyle, next_dash: () -> Part?)
	local lift = Vector3.new(0, style.lift, 0)
	local overrun = if style.closed_corners then style.thickness else 0
	for index = 2, #points do
		local start = points[index - 1] + lift
		local finish = points[index] + lift
		local length = (finish - start).Magnitude
		if length < 1e-3 then
			continue
		end
		local dash = next_dash()
		if dash == nil then
			return
		end
		dash.Size = Vector3.new(style.thickness, style.thickness, length + overrun)
		dash.CFrame = CFrame.lookAt((start + finish) / 2, finish)
	end
end

-- The points of a leg from `from` to `to` over the ground, about `step` apart across it: `from` and `to` themselves at
-- the ends, and between them each where `place` puts its (x, z), on the ground without it.
local function ground_points(
	from: Vector3,
	to: Vector3,
	step: number,
	place: ((x: number, z: number) -> Vector3)?
): { Vector3 }
	local put: (x: number, z: number) -> Vector3 = if place ~= nil then place else heightmap.ground_position
	local run = Vector2.new(to.X - from.X, to.Z - from.Z).Magnitude
	local steps = math.max(1, math.ceil(run / step))
	local points = table.create(steps + 1)
	points[1] = from
	for index = 1, steps - 1 do
		local t = index / steps
		points[index + 1] = put(from.X + (to.X - from.X) * t, from.Z + (to.Z - from.Z) * t)
	end
	points[steps + 1] = to
	return points
end

-- The points on the ground round `center` from bearing `from` to bearing `to` (measured the way entities face),
-- `radius(direction)` out in each direction, `per_turn` of them to a whole turn.
local function arc_points(
	center: Vector3,
	radius: (direction: Vector3) -> number,
	from: number,
	to: number,
	per_turn: number
): { Vector3 }
	local steps = math.max(2, math.ceil(per_turn * (to - from) / (math.pi * 2)))
	local points = table.create(steps + 1)
	for index = 0, steps do
		local bearing = from + (to - from) * index / steps
		local direction = Vector3.new(math.sin(bearing), 0, math.cos(bearing))
		local out = radius(direction)
		points[index + 1] = heightmap.ground_position(center.X + direction.X * out, center.Z + direction.Z * out)
	end
	return points
end

-- A see-through copy of `def_name`'s art in `color`, sat on its collider the way the real one will be (`collider_height`
-- tall), for what is yet to be built; nil for a def whose art is not built.
local function ghost_model(def_name: string, color: Color3, collider_height: number): Model?
	local model = art_models.copy(def_name)
	if model == nil then
		return nil
	end
	for _, descendant in model:GetDescendants() do
		if descendant:IsA "BasePart" then
			descendant.Anchored = true
			descendant.CanCollide = false
			descendant.CanQuery = false
			descendant.CanTouch = false
			descendant.CastShadow = false
			descendant.Material = Enum.Material.ForceField
			descendant.Color = color
			-- parts that were meant to be invisible stay that way
			descendant.Transparency = math.max(descendant.Transparency, GHOST_TRANSPARENCY)
		end
	end
	model_fit.align_to_collider_bottom(model, collider_height)
	return model
end

return table.freeze({
	folder = folder,
	part = part,
	lying_flat = lying_flat,
	tween = tween,
	fade = fade,
	pool = pool,
	acquire = acquire,
	release_rest = release_rest,
	lay_line = lay_line,
	ground_points = ground_points,
	arc_points = arc_points,
	ghost_model = ghost_model,
})
