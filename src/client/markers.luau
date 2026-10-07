--!strict
-- What an order being given is drawn as in the world, while it is given:
--
--   dots        where each unit will go, while a move is dragged out, and for a moment once it is given
--   trace       the shape a drag has traced so far
--   area        the circle an area order is being dragged out to
--   blast       where a manual shot would sweep
--   lock        the line from the cursor to the metal spot a building being placed locks onto
--   hover       the outline on whatever a click would land on
--
-- The rest of what is drawn for orders is each its own: the rings of how far something reaches (range_rings.luau), the
-- queues of the selected units (queue_paths.luau), and what builders work on (work_beams.luau). What is redrawn as
-- the cursor moves comes from pools (world_fx).

local ReplicatedStorage = game:GetService "ReplicatedStorage"

local types = require(ReplicatedStorage.Shared.types)
local world_scale = require(ReplicatedStorage.Shared.world_scale)

local world_fx = require(ReplicatedStorage.Client.world_fx)
local order_colors = require(ReplicatedStorage.Client.order_colors)

local palette = require(ReplicatedStorage.ClientShared.palette)

type Pool = world_fx.Pool

local DOT_SIZE = Vector3.new(0.2, 2, 2)
local DOT_LIFT = 0.3
local DOT_TRANSPARENCY = 0.4
-- How thick the blast preview is, lying on the ground.
local BLAST_THICKNESS = 0.15
local BLAST_TRANSPARENCY = 0.55
-- Lines are laid along the ground in short dashes, one per PATH_STEP studs, so they climb hills rather than cutting
-- through them.
local PATH_STEP = world_scale.CELL_STUDS
local PATH_STYLE: world_fx.LineStyle = table.freeze({ lift = 0.45, thickness = 0.35, closed_corners = false })
local PATH_TRANSPARENCY = 0.3
-- How many rings fill in an area order's circle.
local AREA_RING_COUNT = 8
local RING_SEGMENTS = 48

-- Bumped by every change to the dots, so a delayed clear can tell whether it is still the one that owns them.
local dots_generation = 0

local function make_dot(): Part
	local dot = world_fx.part "OrderDot"
	dot.Shape = Enum.PartType.Cylinder
	dot.Size = DOT_SIZE
	dot.Transparency = DOT_TRANSPARENCY
	return dot
end

local function make_dash(): Part
	local dash = world_fx.part "PathSegment"
	dash.Transparency = PATH_TRANSPARENCY
	return dash
end

local dot_pool = world_fx.pool(make_dot)
local trace_pool = world_fx.pool(make_dash)
local area_pool = world_fx.pool(make_dash)
local lock_pool = world_fx.pool(make_dash)

-- A dot on the ground at `point`, in `color`, from `pool`.
local function place_dot(pool: Pool, point: Vector3, color: Color3)
	local dot = world_fx.acquire(pool)
	dot.CFrame = world_fx.lying_flat(point + Vector3.new(0, DOT_LIFT, 0))
	dot.Color = color
end

-- The dashes of a line in `color` from `pool`, as `world_fx.lay_line` asks for them, `most` of them at most.
local function dashes_from(pool: Pool, color: Color3, most: number?): () -> Part?
	return function(): Part?
		if most ~= nil and pool.used >= most then
			return nil
		end
		local dash = world_fx.acquire(pool)
		dash.Color = color
		return dash
	end
end

-- A line from `from` to `to` in `color` that follows the ground between them, from `pool` (`most` dashes of it at
-- most). For something of `traveller` that rides the water it runs along the water's surface instead, and only comes
-- down to `to` at the very end.
local function draw_leg(
	pool: Pool,
	from: Vector3,
	to: Vector3,
	color: Color3,
	traveller: types.EntityDef?,
	most: number?
)
	local footing: world_fx.Footing = world_fx.footing_of(traveller)
	world_fx.lay_line(world_fx.ground_points(from, to, PATH_STEP, footing), PATH_STYLE, dashes_from(pool, color, most))
end

-- An arc round `center` from bearing `from` to bearing `to`, `radius(direction)` out in each direction, laid on the
-- ground in `color` from `pool`. Returns the points it starts and ends at.
local function draw_arc(
	pool: Pool,
	center: Vector3,
	radius: (Vector3) -> number,
	color: Color3,
	from: number,
	to: number
): (Vector3, Vector3)
	local points = world_fx.arc_points(center, radius, from, to, RING_SEGMENTS, "surface")
	world_fx.lay_line(points, PATH_STYLE, dashes_from(pool, color))
	return points[1], points[#points]
end

-- A ring round `center`, `radius(direction)` out in each direction, laid on the ground in `color` from `pool`.
local function draw_ring(pool: Pool, center: Vector3, radius: (Vector3) -> number, color: Color3)
	draw_arc(pool, center, radius, color, 0, math.pi * 2)
end

-- A ring round `center`, `radius` out all round.
local function draw_circle(pool: Pool, center: Vector3, radius: number, color: Color3)
	draw_ring(pool, center, function(_: Vector3): number
		return radius
	end, color)
end

-- Draws one dot per point, on the ground, in the colour of the order of `kind` they are for, replacing whatever was
-- shown before.
local function show_points(points: { Vector3 }, kind: string?)
	dots_generation += 1
	dot_pool.used = 0
	local color = order_colors.of(kind)
	for _, point in points do
		place_dot(dot_pool, point, color)
	end
	world_fx.release_rest(dot_pool)
end

local function clear_points()
	dots_generation += 1
	world_fx.release_rest(dot_pool)
end

-- Shows the points and takes them away again, unless a newer drag or order has claimed the dots in the meantime.
local function flash_points(points: { Vector3 }, seconds: number, kind: string?)
	show_points(points, kind)
	local generation = dots_generation
	task.delay(seconds, function()
		if dots_generation == generation then
			clear_points()
		end
	end)
end

-- The outline on whatever the cursor is over. One highlight is kept and moved from thing to thing.
local hover_highlight: Highlight? = nil

local function make_highlight(): Highlight
	local made = Instance.new "Highlight"
	made.Name = "HoverHighlight"
	made.FillTransparency = 0.85
	made.OutlineTransparency = 0
	made.DepthMode = Enum.HighlightDepthMode.AlwaysOnTop
	made.Parent = world_fx.folder()
	return made
end

local function show_hover(model: Model?, color: Color3)
	if hover_highlight == nil and model == nil then
		return
	end
	local highlight = hover_highlight or make_highlight()
	hover_highlight = highlight
	highlight.FillColor = color
	highlight.OutlineColor = color
	if highlight.Adornee ~= model then
		highlight.Adornee = model
	end
end

-- Where a manual shot would sweep, as a rectangle in the disintegrator's colour from `from` to `to` that wide.
local blast_preview: Part? = nil

local function make_blast_preview(): Part
	local made = world_fx.part "BlastPreview"
	made.Color = palette.disintegrator
	made.Transparency = BLAST_TRANSPARENCY
	return made
end

local function show_blast(from: Vector3, to: Vector3, half_width: number)
	local length = (to - from).Magnitude
	if length < 1e-3 then
		return
	end
	local part = blast_preview or make_blast_preview()
	blast_preview = part
	local lift = Vector3.new(0, DOT_LIFT, 0)
	part.Size = Vector3.new(half_width * 2, BLAST_THICKNESS, length)
	part.CFrame = CFrame.lookAt((from + to) / 2 + lift, to + lift)
	if part.Parent == nil then
		part.Parent = world_fx.folder()
	end
end

local function hide_blast()
	if blast_preview ~= nil and blast_preview.Parent ~= nil then
		blast_preview.Parent = nil
	end
end

-- The shape a drag has traced so far, laid on the ground in the colour of the order of `kind` it will give.
local function show_trace(path: { Vector3 }, kind: string?)
	trace_pool.used = 0
	local color = order_colors.of(kind)
	for index = 2, #path do
		draw_leg(trace_pool, path[index - 1], path[index], color)
	end
	world_fx.release_rest(trace_pool)
end

local function hide_trace()
	trace_pool.used = 0
	world_fx.release_rest(trace_pool)
end

-- The circle an area command (reclaim, repair, resurrect or attack) is being dragged out to: concentric rings, in the
-- colour of the order it gives, filling the circle in and laid on the ground so they climb hills instead of a flat
-- disc that would sink into them or float over dips.
local function show_area(center: Vector3, radius: number, kind: string?)
	area_pool.used = 0
	local color = order_colors.of(kind)
	for step = 1, AREA_RING_COUNT do
		draw_circle(area_pool, center, radius * step / AREA_RING_COUNT, color)
	end
	world_fx.release_rest(area_pool)
end

local function hide_area()
	area_pool.used = 0
	world_fx.release_rest(area_pool)
end

-- A dashed line from the cursor to the metal spot a placement is locking onto.
local function show_lock(from: Vector3, to: Vector3)
	lock_pool.used = 0
	draw_leg(lock_pool, from, to, palette.metal)
	world_fx.release_rest(lock_pool)
end

local function hide_lock()
	lock_pool.used = 0
	world_fx.release_rest(lock_pool)
end

return table.freeze({
	make_dot = make_dot,
	make_dash = make_dash,
	place_dot = place_dot,
	draw_leg = draw_leg,
	draw_arc = draw_arc,
	draw_ring = draw_ring,
	draw_circle = draw_circle,
	show_points = show_points,
	clear_points = clear_points,
	flash_points = flash_points,
	show_hover = show_hover,
	show_blast = show_blast,
	hide_blast = hide_blast,
	show_trace = show_trace,
	hide_trace = hide_trace,
	show_area = show_area,
	hide_area = hide_area,
	show_lock = show_lock,
	hide_lock = hide_lock,
})
