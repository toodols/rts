-- Bars floating over entities: health for finished things, build progress for blueprints, and for a weapon that takes
-- longer than `RELOAD_BAR_MIN_SECONDS` (server/weapons.luau) to reload how far along it is to its next shot. A launcher
-- that stockpiles missiles shows how far along its next missile is, and how many it holds.
--
-- Something of yours counting down to destroy itself shows how long it has left, flashing.
--
-- Anything with EMP on it shows how much, as a share of what stuns it, and while it is stunned how long it has left.
--
-- Blueprints also carry a time estimate. It comes from how much progress was made over the last
-- second, so it follows the real build rate as builders come and go. A blueprint that nobody has
-- been building on long enough to be falling apart shows how long until it is gone instead, and
-- that readout flashes.
--
-- Over everything that belongs to a team is its team's mark, a dot in its colour or a commander's nametag. Past
-- `BAR_MAX_DISTANCE` from the camera that mark is all a bar keeps, and it keeps it at any zoom, the same size on the
-- screen, so a zoomed-out view reads as a map of who holds what.
--
-- Every bar is styled from the stylesheet by tag, like the rest of the HUD. The only things set here
-- are the ones a stylesheet cannot know: where on the screen the entity is, and how full the bar is.
--
-- What a bar shows of its entity is read as the selection panel reads it (use_entities' `view_of`), and laid out as a
-- stack of bars and lines of text (`tracks_of`, `lines_of`) under its team's mark.
--
-- Entity state lives on Workspace models. A bar is drawn again only when the world says one of the attributes it shows
-- has changed (world's `subscribe_changed`), at most ten times a second, and a blueprint's every tenth of a second for
-- its estimate; the list of bars changes only as entities come and go. Positions are a different matter: they have
-- to follow the camera every frame, so they are written straight to the frames rather than going through a re-render.

local ReplicatedStorage = game:GetService "ReplicatedStorage"
local RunService = game:GetService "RunService"
local Workspace = game:GetService "Workspace"

local React = require(ReplicatedStorage.Packages.react)

local art = require(ReplicatedStorage.Shared.art)
local blueprint_decay = require(ReplicatedStorage.Shared.blueprint_decay)
local signal = require(ReplicatedStorage.Shared.signal)
local types = require(ReplicatedStorage.Shared.types)
local unit_defs = require(ReplicatedStorage.Shared.unit_defs)
local entity_attrs = require(ReplicatedStorage.Shared.entity_attrs)

local world = require(ReplicatedStorage.Client.world)
local use_entities = require(ReplicatedStorage.Client.ui.use_entities)

local format = require(ReplicatedStorage.ClientShared.format)
local use_store = require(ReplicatedStorage.ClientShared.use_store)

type EntityId = types.EntityId
type EntityView = use_entities.EntityView

type Sample = {
	at: number,
	progress: number,
}

local PLACE_STEP = "rts_world_bars"
local SAMPLE_INTERVAL = 0.1
-- The estimate is the average rate over this many seconds, and needs at least MIN_SPAN of them.
local RATE_WINDOW = 1
local MIN_SPAN = 0.3
-- Below this much progress a second the blueprint is treated as stalled.
local STALL_RATE = 0.5
local FLASHES_PER_SECOND = 3

-- How far above the top of an entity its bar floats, in studs.
local BAR_GAP = 1.2
-- Past this far from the camera, in studs, a bar is cut down to its team's mark: the dot, or a commander's nametag.
-- The camera sits about 1.2 times its height from what it looks at, so this is where a high zoom stops showing health
-- and the rest. The marks stay at any zoom, and since every frame here is sized in pixels they stay the same size on
-- the screen however far out the camera goes: zoomed all the way out, as in BAR's strategic view, the dots are how
-- you read who holds which part of the map.
local BAR_MAX_DISTANCE = 200
-- The attributes a bar shows: a change to any other (a turret's aim, say) leaves it as it is.
local SHOWN_ATTRIBUTES: { [entity_attrs.Name]: true } = table.freeze({
	kind = true,
	state = true,
	def_name = true,
	team = true,
	team_name = true,
	team_color = true,
	health = true,
	max_health = true,
	build_progress = true,
	buildpower_cost = true,
	decaying = true,
	reclaim_left = true,
	reclaim_total = true,
	energy_left = true,
	resurrect_progress = true,
	exit_blocked = true,
	need_energy = true,
	self_destruct = true,
	reload_progress = true,
	stockpile_progress = true,
	stockpile = true,
	stockpile_limit = true,
	shield_power = true,
	shield_max = true,
	emp = true,
	stun = true,
})

local history: { [EntityId]: { Sample } } = {}
local frames: { [EntityId]: Frame } = {}
-- Each bar's way to have itself drawn again, and the bars whose entity has changed since they were last drawn.
local redraws: { [EntityId]: () -> () } = {}
local stale: { [EntityId]: boolean } = {}
-- Whether what flashes is lit right now, and its flips.
local lit = true
local flashed = signal.new() :: signal.Signal<boolean>

local function is_lit(): boolean
	return lit
end

-- Records every blueprint's progress and forgets the ones that are gone or finished. A blueprint's estimate moves with
-- the time, so its bar is drawn again each time.
local function sample_history()
	local now = os.clock()
	local seen: { [EntityId]: boolean } = {}
	for _, model in world.all() do
		local id = world.id_of(model)
		if id == nil or entity_attrs.state(model) ~= "blueprint" then
			continue
		end
		seen[id] = true
		stale[id] = true

		local samples = history[id]
		if samples == nil then
			samples = {}
			history[id] = samples
		end
		table.insert(samples, { at = now, progress = entity_attrs.number(model, "build_progress") or 0 })
		-- keep one sample from at or before the start of the window as the baseline, and no more
		while #samples > 2 and samples[2].at <= now - RATE_WINDOW do
			table.remove(samples, 1)
		end
	end
	for id in history do
		if seen[id] == nil then
			history[id] = nil
		end
	end
end

-- Buildpower per second over the window, or nil before there is enough history to say.
local function progress_rate(id: EntityId): number?
	local samples = history[id]
	if samples == nil or #samples < 2 then
		return nil
	end
	local first = samples[1]
	local last = samples[#samples]
	local elapsed = last.at - first.at
	if elapsed < MIN_SPAN then
		return nil
	end
	return (last.progress - first.progress) / elapsed
end

-- A commander has a nametag, its team's name, and everything else a dot, both in the team's own colour, which the
-- stylesheet cannot know. A wreck belongs to nobody and has neither, and neither does a rock or a tree. Far away the
-- dot is drawn a little larger and more firmly ringed, and the nametag larger and outlined, since each is then all
-- there is to see of what it marks.
local function team_mark(model: Model, far: boolean): any
	if world.is_remains(model) then
		return nil
	end
	local def = world.def_of(model)
	local team_name = entity_attrs.text(model, "team_name")
	local color = entity_attrs.color(model, "team_color")
	if def ~= nil and unit_defs.is_commander(def) and team_name ~= nil then
		return React.createElement("TextLabel", {
			[React.Tag] = if far then "bar-name far" else "bar-name",
			LayoutOrder = 0,
			Text = format.escape(team_name),
			TextColor3 = color,
		})
	elseif color ~= nil then
		return React.createElement("Frame", {
			[React.Tag] = if far then "bar-dot far" else "bar-dot",
			LayoutOrder = 0,
			BackgroundColor3 = color,
		})
	end
	return nil
end

-- The frame every bar hangs in, which `place_frames` moves over its entity.
local function bar_frame(id: EntityId, is_blueprint: boolean, children: { [string]: any })
	return React.createElement("Frame", {
		[React.Tag] = if is_blueprint then "world-bar blueprint" else "world-bar",
		AnchorPoint = Vector2.new(0.5, 1),
		-- parked off screen until the first frame's placement has run
		Position = UDim2.fromOffset(-1000, -1000),
		ref = function(instance: Frame?)
			if instance ~= nil then
				frames[id] = instance
			else
				frames[id] = nil
			end
		end,
	}, children)
end

-- What flashes over a bar (a warning, a countdown), lit and unlit in turn; only these are drawn again as they flash.
local function FlashLabel(props: { tag: string, text: string, LayoutOrder: number })
	local on = use_store.use_store(is_lit, flashed.subscribe)
	return React.createElement("TextLabel", {
		[React.Tag] = if on then `{props.tag} lit` else props.tag,
		LayoutOrder = props.LayoutOrder,
		Text = props.text,
	})
end

-- One bar of a bar's stack: how full it is, its fill's tags, and where in the stack it goes.
type Track = { fraction: number, fill: string, order: number }

-- One line of text in a bar's stack: what it says, its tags, where in the stack it goes, and whether it flashes.
type Line = { text: string, tag: string, order: number, flashes: boolean }

local function TrackBar(props: { track: Track })
	local track = props.track
	return React.createElement("Frame", {
		[React.Tag] = "bar-track",
		LayoutOrder = track.order,
	}, {
		Fill = React.createElement("Frame", {
			[React.Tag] = track.fill,
			-- inline because Roblox's Size covers both axes at once
			Size = UDim2.fromScale(math.clamp(track.fraction, 0, 1), 1),
		}),
	})
end

local function LineLabel(props: { line: Line })
	local line = props.line
	if line.flashes then
		return React.createElement(FlashLabel, { tag = line.tag, text = line.text, LayoutOrder = line.order })
	end
	return React.createElement("TextLabel", {
		[React.Tag] = line.tag,
		LayoutOrder = line.order,
		Text = line.text,
	})
end

-- A health bar's track, `order` in its stack.
local function health_track(view: EntityView, order: number): Track
	local fraction = math.clamp(view.health / math.max(1, view.max_health), 0, 1)
	return { fraction = fraction, fill = `bar-fill health {format.health_level(fraction)}`, order = order }
end

-- The bars `view` shows, in its stack: for a rock or a tree what is left of it to reclaim, once someone has started;
-- for a wreck the same always, its own health (it can still be shot away) and how far raising it has got; for a
-- blueprint how far it is built, and its health once it is hurt; for anything else its health once it is hurt; and
-- for anything but a wreck its EMP, and for anything finished that has them a slow weapon's reload, a launcher's next
-- missile and a shield's power.
local function tracks_of(view: EntityView): { Track }
	local tracks: { Track } = {}
	local function add(fraction: number, fill: string, order: number)
		table.insert(tracks, { fraction = fraction, fill = fill, order = order })
	end
	local is_wreck = view.kind == "wreck"
	local is_blueprint = view.state == "blueprint"
	if unit_defs.is_remains_kind(view.kind) then
		local total = math.max(1, view.reclaim_total or 1)
		local left = math.clamp((view.reclaim_left or total) / total, 0, 1)
		if is_wreck or left < 1 then
			-- a tree, which still has energy in it, fills in yellow, where a rock does not
			local energy = view.kind == "reclaimable" and (view.energy_left or 0) > 0
			add(left, if energy then "bar-fill reclaim energy" else "bar-fill reclaim", 1)
		end
		if is_wreck then
			table.insert(tracks, health_track(view, 2))
			local raised = math.clamp(view.resurrect_progress or 0, 0, 1)
			if raised > 0 then
				add(raised, "bar-fill resurrect", 3)
			end
		end
	elseif is_blueprint then
		add(view.build_progress / math.max(1, view.buildpower_cost), "bar-fill progress", 1)
		if view.health < view.max_health then
			table.insert(tracks, health_track(view, 2))
		end
	elseif view.health < view.max_health then
		table.insert(tracks, health_track(view, 1))
	end
	if is_wreck == false and view.emp ~= nil and view.emp > 0 then
		add(view.emp / 100, "bar-fill emp", 2)
	end
	if is_blueprint == false and is_wreck == false then
		-- a weapon that is ready has nothing to wait for, so its bar is only up while it is still reloading
		if view.reload_progress ~= nil and view.reload_progress < 1 then
			add(view.reload_progress, "bar-fill reload", 4)
		end
		if view.stockpile_progress ~= nil then
			add(view.stockpile_progress, "bar-fill stockpile", 5)
		end
	end
	local shield = view.shield
	if is_blueprint == false and shield ~= nil then
		add(shield.value / math.max(1, shield.most), "bar-fill shield", 7)
	end
	return tracks
end

-- What `view` says over or under its bars: how long it is stunned for, how long yours has before it destroys itself,
-- what is stopping it (a shooter that has a target and cannot pay for the shot, or a lab that cannot start its next
-- unit for something standing where it goes), when a blueprint will be done or gone (`rate` being how fast it is being
-- built, if that is known), and how many missiles a launcher holds.
local function lines_of(view: EntityView, rate: number?): { Line }
	local lines: { Line } = {}
	local function add(text: string, tag: string, order: number, flashes: boolean)
		table.insert(lines, { text = text, tag = tag, order = order, flashes = flashes })
	end
	if view.kind ~= "wreck" and view.emp ~= nil and view.emp > 0 and view.stun ~= nil then
		add(`STUN {format.countdown(view.stun)}`, "bar-stun", -3, false)
	end
	if view.self_destruct ~= nil and view.mine then
		add(`SELF-D {view.self_destruct}s`, "bar-self-destruct", -2, true)
	end
	if view.exit_blocked then
		add("Exit blocked", "bar-warning", -1, true)
	elseif view.need_energy then
		add("Need energy", "bar-warning", -1, true)
	end
	if view.state == "blueprint" then
		local progress = view.build_progress
		if view.decaying then
			-- falling apart: how long until nothing is left of it
			add(
				`DECAY {format.countdown(progress / blueprint_decay.BLUEPRINT_DECAY_RATE)}`,
				"bar-eta decaying",
				3,
				true
			)
		else
			local left = math.max(1, view.buildpower_cost) - progress
			add(if rate ~= nil and rate > STALL_RATE then format.countdown(left / rate) else "--", "bar-eta", 3, false)
		end
	elseif view.kind ~= "wreck" and view.stockpile_progress ~= nil then
		local missiles = view.missiles
		add(
			`{if missiles ~= nil then missiles.value else 0} / {if missiles ~= nil then missiles.most else 0}`,
			"bar-count",
			6,
			false
		)
	end
	return lines
end

local function Bar(props: { id: EntityId, model: Model, far: boolean })
	local model = props.model
	-- drawn again when its entity changes (`redraws`)
	use_store.use_changes(function(redraw: () -> ()): () -> ()
		local id = props.id
		redraws[id] = redraw
		return function()
			if redraws[id] == redraw then
				redraws[id] = nil
			end
		end
	end, { props.id })
	local is_blueprint = entity_attrs.state(model) == "blueprint"

	-- Far away there is only the team's mark to draw, so nothing else is read: zoomed out is when the most bars are
	-- on the screen at once, and this keeps each of them to a handful of attribute reads. How far is decided by
	-- `WorldBars`.
	if props.far then
		local mark = team_mark(model, true)
		if mark == nil then
			return nil
		end
		return bar_frame(props.id, is_blueprint, { Name = mark })
	end

	local view = use_entities.view_of(props.id)
	if view == nil then
		return nil
	end
	local tracks = tracks_of(view)
	local lines = lines_of(view, if is_blueprint then progress_rate(props.id) else nil)
	local nametag = team_mark(model, false)
	-- nothing to show: an unhurt thing with no nametag, no dot and nothing to say
	if #tracks == 0 and #lines == 0 and nametag == nil then
		return nil
	end
	local children: { [string]: any } = { Name = nametag }
	for index, track in tracks do
		children[`Track{index}`] = React.createElement(TrackBar, { track = track })
	end
	for index, line in lines do
		children[`Line{index}`] = React.createElement(LineLabel, { line = line })
	end
	return bar_frame(props.id, is_blueprint, children)
end

-- The point a bar hangs from: over the top of its entity's art where that stands taller than its collider, like the
-- commander's. The model's position is its collider's middle, and its art stands on the collider's bottom.
local function anchor_of(model: Model): Vector3
	local def = world.def_of(model)
	local half_height = if def ~= nil then unit_defs.collider_height(def) / 2 else 1
	local art_height = if def ~= nil then art.height(def.name) else nil
	local above = if art_height ~= nil then math.max(half_height, art_height - half_height) else half_height
	return world.position_of(model) + Vector3.new(0, above + BAR_GAP, 0)
end

-- Puts every bar over its entity. The viewport point is in the same space as the frames because the
-- overlay ignores the GUI inset.
local function place_frames()
	local camera = Workspace.CurrentCamera
	if camera == nil then
		return
	end
	for id, frame in frames do
		local model = world.get(id)
		if model == nil then
			continue
		end
		-- nothing is hidden for being far away: past `BAR_MAX_DISTANCE` a bar is already cut down to its team's mark,
		-- which stays up at any zoom
		local point, on_screen = camera:WorldToViewportPoint(anchor_of(model))
		frame.Visible = on_screen
		if on_screen then
			frame.Position = UDim2.fromOffset(math.floor(point.X), math.floor(point.Y))
		end
	end
end

local MemoBar = React.memo(Bar)

-- Every entity that may have a bar, by id: all but the rocks and trees, and of those only the ones someone has started
-- reclaiming, since the rest, nearly all of them, have nothing to show.
local function listed(): { [EntityId]: Model }
	local found: { [EntityId]: Model } = {}
	for _, list in { world.all(), world.reclaimables_started() } do
		for _, model in list do
			local id = world.id_of(model)
			if id ~= nil then
				found[id] = model
			end
		end
	end
	return found
end

local function WorldBars()
	local shown, set_shown = React.useState(listed)
	-- the bars cut down to their team's mark for being far from the camera
	local far, set_far = React.useState({} :: { [EntityId]: boolean })

	React.useEffect(function(): () -> ()
		local models = listed()
		local models_changed = true
		local far_now: { [EntityId]: boolean } = {}
		local stop_listed = world.subscribe_listed(function(model: Model)
			local id = world.id_of(model)
			if id ~= nil then
				models[id] = model
				models_changed = true
			end
		end)
		local stop_removed = world.subscribe_removed(function(model: Model, id: EntityId)
			if models[id] == model then
				models[id] = nil
				stale[id] = nil
				models_changed = true
			end
		end)
		local stop_changed = world.subscribe_changed(function(id: EntityId, attribute: string)
			if SHOWN_ATTRIBUTES[attribute :: entity_attrs.Name] == true then
				stale[id] = true
			end
		end)

		local accumulator = SAMPLE_INTERVAL
		local connection = RunService.Heartbeat:Connect(function(delta: number)
			accumulator += delta
			if accumulator < SAMPLE_INTERVAL then
				return
			end
			accumulator = 0
			sample_history()
			local now_lit = math.floor(os.clock() * FLASHES_PER_SECOND) % 2 == 0
			if now_lit ~= lit then
				lit = now_lit
				flashed.fire(lit)
			end
			if models_changed then
				models_changed = false
				set_shown(table.clone(models))
			end
			-- How far is decided here, ten times a second, rather than as the bars are placed each frame, so a bar
			-- crossing `BAR_MAX_DISTANCE` is cut down or filled back out a tenth of a second at most after, and nothing is
			-- drawn again just because the camera moved.
			local camera = Workspace.CurrentCamera
			local eye = if camera ~= nil then camera.CFrame.Position else nil
			local next_far: { [EntityId]: boolean } = {}
			local crossed = false
			for id, model in models do
				local is_far = eye ~= nil and (anchor_of(model) - eye).Magnitude > BAR_MAX_DISTANCE
				if is_far then
					next_far[id] = true
				end
				if is_far ~= (far_now[id] == true) then
					crossed = true
				end
			end
			if crossed then
				far_now = next_far
				set_far(next_far)
			end
			for id in stale do
				local redraw = redraws[id]
				if redraw ~= nil then
					redraw()
				end
			end
			table.clear(stale)
		end)
		return function()
			stop_listed()
			stop_removed()
			stop_changed()
			connection:Disconnect()
		end
	end, {})

	React.useEffect(function()
		-- One step after the camera's: a bar placed by last frame's camera trails the entity it labels.
		RunService:BindToRenderStep(PLACE_STEP, Enum.RenderPriority.Camera.Value + 1, place_frames)
		return function()
			RunService:UnbindFromRenderStep(PLACE_STEP)
		end
	end, {})

	local children = {}
	for id, model in shown do
		children[tostring(id)] = React.createElement(MemoBar, { id = id, model = model, far = far[id] == true })
	end
	return React.createElement(React.Fragment, {}, children)
end

return table.freeze({
	WorldBars = WorldBars,
})
