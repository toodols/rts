--!strict
-- What is drawn in the world while a mode is on, besides the outline on what a click would land on (hover.luau): those
-- of the selection who take part are outlined in the mode's colour and the rest faintly, the spot a click would send
-- them to is marked on the ground, and in a mode that attacks a line runs from each attacker to what it would attack,
-- strong if that is in its reach and faint if it would have to go closer first. Whether a click would do anything at
-- all is told to whoever subscribes (`subscribe`), for the badge on the cursor.

local ReplicatedStorage = game:GetService "ReplicatedStorage"

local signal = require(ReplicatedStorage.Shared.signal)
local types = require(ReplicatedStorage.Shared.types)
local unit_defs = require(ReplicatedStorage.Shared.unit_defs)
local geometry = require(ReplicatedStorage.Shared.geometry)
local world_scale = require(ReplicatedStorage.Shared.world_scale)

local world = require(ReplicatedStorage.Client.world)
local world_fx = require(ReplicatedStorage.Client.world_fx)
local markers = require(ReplicatedStorage.Client.markers)
local selection = require(ReplicatedStorage.Client.selection)
local selected = require(ReplicatedStorage.Client.selected)
local commands = require(ReplicatedStorage.Client.commands)
local modifiers = require(ReplicatedStorage.Client.modifiers)
local queue_paths = require(ReplicatedStorage.Client.queue_paths)
local order_modes = require(ReplicatedStorage.Client.order_modes)
local command_state = require(ReplicatedStorage.Client.command_state)

type EntityId = types.EntityId
type ModeInfo = order_modes.ModeInfo

-- How far out the ring round the spot a click would go to is.
local SPOT_RADIUS = world_scale.CELL_STUDS * 0.75
-- How many attackers a line is drawn from at most, and how far apart the points of each are along the ground: coarser
-- than an order's path, since there can be many of them.
local MOST_LINES = 16
local LINE_STEP = world_scale.CELL_STUDS * 4
local LINE_STYLE: world_fx.LineStyle = table.freeze({ lift = 0.45, thickness = 0.2, closed_corners = false })
local IN_REACH_TRANSPARENCY = 0.35
local OUT_OF_REACH_TRANSPARENCY = 0.8

local function dash_of(transparency: number): () -> Part
	return function(): Part
		local dash = world_fx.part "ModeAimLine"
		dash.Transparency = transparency
		return dash
	end
end

local spot_pool = world_fx.pool(markers.make_dash)
local in_reach_pool = world_fx.pool(dash_of(IN_REACH_TRANSPARENCY))
local out_of_reach_pool = world_fx.pool(dash_of(OUT_OF_REACH_TRANSPARENCY))

local aimed = true
local aimed_changed = signal.new() :: signal.Signal<boolean>

-- Whether a click in the mode that is on would give an order: false over nothing it can be aimed at.
local function get_aimed(): boolean
	return aimed
end

local function set_aimed(now: boolean)
	if now ~= aimed then
		aimed = now
		aimed_changed.fire(now)
	end
end

local function colored(pool: world_fx.Pool, color: Color3): () -> Part?
	return function(): Part?
		local dash = world_fx.acquire(pool)
		dash.Color = color
		return dash
	end
end

-- A line from each of `entries` (the first MOST_LINES of them that shoot on an order) to `to`, from where it would be
-- once done with its queue when shift queues the order.
local function draw_reach(info: ModeInfo, entries: { selected.Entry }, to: Vector3)
	local queued = modifiers.shift_held()
	local drawn = 0
	for _, entry in entries do
		local range = unit_defs.order_range(entry.def, info.launch)
		if range == nil then
			continue
		end
		local from = if queued then queue_paths.expected_end(entry.model) else world.position_of(entry.model)
		local pool = if geometry.distance_2d(from, to) <= range then in_reach_pool else out_of_reach_pool
		world_fx.lay_line(world_fx.ground_points(from, to, LINE_STEP, "surface"), LINE_STYLE, colored(pool, info.color))
		drawn += 1
		if drawn >= MOST_LINES then
			return
		end
	end
end

local function release_drawn()
	world_fx.release_rest(spot_pool)
	world_fx.release_rest(in_reach_pool)
	world_fx.release_rest(out_of_reach_pool)
end

-- Every frame while the mode `info` is on, `drag` the line or circle being dragged out in it, if one is: a drag draws
-- its own shape (command_input.luau), so only the outlines are kept up then.
local function render(info: ModeInfo, drag: command_state.ModeDrag?)
	local entries = selected.for_mode(info)
	local taking_part: { [EntityId]: boolean } = {}
	for _, entry in entries do
		taking_part[entry.id] = true
	end
	selection.tint(taking_part, info.color)

	spot_pool.used = 0
	in_reach_pool.used = 0
	out_of_reach_pool.used = 0
	if drag ~= nil then
		set_aimed(true)
		release_drawn()
		return
	end

	local target, spot = commands.aim(info, entries)
	set_aimed(target ~= nil or spot ~= nil)
	-- a manual shot's sweep is drawn already, and marks where it goes
	if spot ~= nil and info.click ~= "manual" then
		markers.draw_circle(spot_pool, spot, SPOT_RADIUS, info.color)
	end
	if info.click == "attack" then
		local to = if target ~= nil then world.position_of(target) else spot
		if to ~= nil then
			draw_reach(info, entries, to)
		end
	end
	release_drawn()
end

-- Takes it all down, as the mode ends.
local function clear()
	selection.tint(nil, nil)
	spot_pool.used = 0
	in_reach_pool.used = 0
	out_of_reach_pool.used = 0
	release_drawn()
	set_aimed(true)
end

return table.freeze({
	render = render,
	clear = clear,
	get_aimed = get_aimed,
	subscribe = aimed_changed.subscribe,
})
