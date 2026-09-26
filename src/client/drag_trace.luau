--!strict
-- The ground the cursor passes over while a button is dragged to lay out a line of orders, and where along it each
-- unit goes. The preview drawn during the drag and the order sent when it ends both come from here, so what is shown
-- is what is ordered.

local ReplicatedStorage = game:GetService "ReplicatedStorage"

local unit_defs = require(ReplicatedStorage.Shared.unit_defs)
local surface = require(ReplicatedStorage.Shared.surface)
local heightmap = require(ReplicatedStorage.Shared.heightmap)
local geometry = require(ReplicatedStorage.Shared.geometry)

local world = require(ReplicatedStorage.Client.world)
local selection = require(ReplicatedStorage.Client.selection)
local cursor = require(ReplicatedStorage.Client.cursor)
local markers = require(ReplicatedStorage.Client.markers)
local selected = require(ReplicatedStorage.Client.selected)

type Entry = selected.Entry

-- A point is added once the cursor is this many studs on from the last one.
local TRACE_STEP = 1
-- A right-drag shorter than this is treated as a plain right-click rather than a formation line.
local FORMATION_DRAG_THRESHOLD = 8

-- the drag going on now, from where it began
local trace: { Vector3 } = {}

-- Where a waypoint at (x, z) sits for what is selected: on the water's surface if a selected unit that moves rides it
-- there, a ship or a hovercraft, and on the ground otherwise, so a ship's path is drawn on the sea and not on the sea
-- floor beneath it.
local function waypoint_ground(x: number, z: number): Vector3
	for _, id in selection.get() do
		local def = world.def_of_id(id)
		if def ~= nil and def.max_speed ~= nil and unit_defs.rides_surface(def) then
			return surface.position(def, x, z)
		end
	end
	return heightmap.ground_position(x, z)
end

local function begin(point: Vector3)
	trace = { point }
end

-- Follows the cursor on from where the trace has got to.
local function extend()
	local last: Vector3? = trace[#trace]
	local point = cursor.ground_point()
	if last ~= nil and point ~= nil and geometry.distance_2d(last, point) >= TRACE_STEP then
		table.insert(trace, point)
	end
end

-- How far along the ground `path` runs, however it winds.
local function path_length(path: { Vector3 }): number
	local length = 0
	for index = 2, #path do
		length += geometry.distance_2d(path[index - 1], path[index])
	end
	return length
end

-- Whether `path` has gone far enough to be a line of orders rather than a click. A drag that comes back round to where
-- it began is still a line.
local function is_line(path: { Vector3 }): boolean
	return #path >= 2 and path_length(path) >= FORMATION_DRAG_THRESHOLD
end

-- The trace as it stands when the button comes up, taken on to wherever the cursor let go, and cleared for the next
-- drag, with what showed it.
local function finish(): { Vector3 }
	local path = trace
	trace = {}
	markers.hide_trace()
	markers.clear_points()
	local last: Vector3? = path[#path]
	local point = cursor.ground_point()
	if last ~= nil and point ~= nil and geometry.distance_2d(last, point) > 1e-3 then
		table.insert(path, point)
	end
	return path
end

-- Drops the trace, and what showed it, if a drag was going on, without anything coming of it.
local function cancel()
	if #trace == 0 then
		return
	end
	trace = {}
	markers.hide_trace()
	markers.clear_points()
end

-- Where a line along `path` puts `count` units: spread evenly along it and set on the ground, or the water.
local function formation_points(path: { Vector3 }, count: number): { Vector3 }
	local points = geometry.points_along_path(path, count)
	local grounded = table.create(count)
	for index, point in points do
		grounded[index] = waypoint_ground(point.X, point.Z)
	end
	return grounded
end

-- Puts `entries` in the order they lie along the way from the start of `path` to its end, so that giving the first one
-- the first point, the next the next, and so on, does not send their paths across each other.
local function sort_along(entries: { Entry }, path: { Vector3 })
	local direction = geometry.flatten(path[#path] - path[1])
	direction = if direction.Magnitude < 1e-3 then Vector3.new(1, 0, 0) else direction.Unit
	table.sort(entries, function(a: Entry, b: Entry): boolean
		return world.position_of(a.model):Dot(direction) < world.position_of(b.model):Dot(direction)
	end)
end

-- While a button is held to drag out a line of `count` orders of `kind`, shows the shape traced so far, in that order's
-- colour, and one dot per unit along it where each would land. Until the drag is long enough to be a line, a move shows
-- a single dot under the cursor (`single`), and anything else nothing.
local function preview(count: number, kind: string, single: boolean)
	extend()
	if count > 0 and is_line(trace) then
		markers.show_trace(trace, kind)
		markers.show_points(formation_points(trace, count), kind)
		return
	end
	markers.hide_trace()
	local to = cursor.ground_point()
	if count > 0 and single and to ~= nil then
		markers.show_points({ waypoint_ground(to.X, to.Z) }, kind)
	else
		markers.clear_points()
	end
end

return table.freeze({
	FORMATION_DRAG_THRESHOLD = FORMATION_DRAG_THRESHOLD,
	waypoint_ground = waypoint_ground,
	begin = begin,
	is_line = is_line,
	finish = finish,
	cancel = cancel,
	formation_points = formation_points,
	sort_along = sort_along,
	preview = preview,
})
