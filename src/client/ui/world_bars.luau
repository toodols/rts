-- Bars floating over entities: health for finished things, build progress for blueprints, and for a weapon that
-- takes longer than `config.RELOAD_BAR_MIN_SECONDS` to reload how far along it is to its next shot. A launcher that
-- stockpiles missiles shows how far along its next missile is, and how many it holds.
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
-- Entity state lives on Workspace models, so the bars sample those attributes ten times a second.
-- Positions are a different matter: they have to follow the camera every frame, so they are written
-- straight to the frames rather than going through a re-render.

local ReplicatedStorage = game:GetService "ReplicatedStorage"
local RunService = game:GetService "RunService"
local Workspace = game:GetService "Workspace"

local React = require(ReplicatedStorage.Packages.react)

local types = require(ReplicatedStorage.Shared.types)
local config = require(ReplicatedStorage.Shared.config)
local unit_defs = require(ReplicatedStorage.Shared.unit_defs)
local art = require(ReplicatedStorage.Shared.art)

local world = require(ReplicatedStorage.Client.world)

type EntityId = types.EntityId

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
local MID_HEALTH = 0.6
local LOW_HEALTH = 0.3

local history: { [EntityId]: { Sample } } = {}
local frames: { [EntityId]: Frame } = {}

local function number_of(model: Model, name: string, fallback: number): number
	local value = model:GetAttribute(name)
	if typeof(value) ~= "number" then
		return fallback
	end
	return value
end

-- Records every blueprint's progress and forgets the ones that are gone or finished.
local function sample_history()
	local now = os.clock()
	local seen: { [EntityId]: boolean } = {}
	for _, model in world.all() do
		local id = world.id_of(model)
		if id == nil or model:GetAttribute "state" ~= "blueprint" then
			continue
		end
		seen[id] = true

		local samples = history[id]
		if samples == nil then
			samples = {}
			history[id] = samples
		end
		table.insert(samples, { at = now, progress = number_of(model, "build_progress", 0) })
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

local function format_time(seconds: number): string
	local whole = math.ceil(seconds)
	if whole >= 60 then
		return string.format("%d:%02d", whole // 60, whole % 60)
	end
	return `{whole}s`
end

-- A commander has a nametag, its team's name, and everything else a dot, both in the team's own colour, which the
-- stylesheet cannot know. A wreck belongs to nobody and has neither, and neither does a rock or a tree. Far away the
-- dot is drawn a little larger and more firmly ringed, and the nametag larger and outlined, since each is then all
-- there is to see of what it marks.
local function team_mark(model: Model, far: boolean): any
	local kind = model:GetAttribute "kind"
	if kind == "wreck" or kind == "reclaimable" then
		return nil
	end
	local def_name = model:GetAttribute "def_name"
	local def = if typeof(def_name) == "string" then unit_defs.defs[def_name] else nil
	local team_name = model:GetAttribute "team_name"
	local team_color = model:GetAttribute "team_color"
	local color = if typeof(team_color) == "Color3" then team_color else nil
	if def ~= nil and def.nametag == true and typeof(team_name) == "string" then
		return React.createElement("TextLabel", {
			[React.Tag] = if far then "bar-name far" else "bar-name",
			LayoutOrder = 0,
			Text = team_name,
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

local function Bar(props: { id: EntityId, model: Model, lit: boolean, far: boolean })
	local model = props.model
	local is_blueprint = model:GetAttribute "state" == "blueprint"

	-- Far away there is only the team's mark to draw, so nothing else is read: zoomed out is when the most bars are
	-- on the screen at once, and this keeps each of them to a handful of attribute reads. How far is decided here,
	-- ten times a second, rather than as the bars are placed each frame, so a bar crossing `BAR_MAX_DISTANCE` is cut
	-- down or filled back out a tenth of a second at most after, and nothing re-renders just because the camera moved.
	if props.far then
		local mark = team_mark(model, true)
		if mark == nil then
			return nil
		end
		return bar_frame(props.id, is_blueprint, { Name = mark })
	end

	local is_wreck = model:GetAttribute "kind" == "wreck"
	local is_reclaimable = model:GetAttribute "kind" == "reclaimable"

	local fraction: number
	local fill_tags: string
	-- a unit or building has a bar only once it is hurt; blueprints and wrecks always have theirs
	local show_track = true
	local eta: any = nil
	-- a second bar under the first: a hurt blueprint's health, or a wreck's own health
	local health_track: any = nil
	-- a third bar, under the wreck's health, for how far along raising it is
	local resurrect_track: any = nil

	if is_reclaimable then
		-- a rock or a tree has no health, only what is left of it to reclaim, shown once someone has started
		local total = math.max(1, number_of(model, "reclaim_total", 1))
		fraction = math.clamp(number_of(model, "reclaim_left", total) / total, 0, 1)
		-- one that still has energy in it, a tree rather than a rock, fills in yellow
		fill_tags = if number_of(model, "energy_left", 0) > 0 then "bar-fill reclaim energy" else "bar-fill reclaim"
		show_track = fraction < 1
	elseif is_wreck then
		local total = math.max(1, number_of(model, "reclaim_total", 1))
		fraction = math.clamp(number_of(model, "reclaim_left", total) / total, 0, 1)
		fill_tags = "bar-fill reclaim"
		-- wrecks always show their reclaim bar
		show_track = true

		-- a wreck can still be shot at and destroyed outright, so it shows its own health under what
		-- is left of it to reclaim
		local max_health = math.max(1, number_of(model, "max_health", 1))
		local health = math.clamp(number_of(model, "health", max_health) / max_health, 0, 1)
		local health_tag = if health <= LOW_HEALTH
			then "bar-fill health low"
			elseif health <= MID_HEALTH then "bar-fill health mid"
			else "bar-fill health"
		health_track = React.createElement("Frame", {
			[React.Tag] = "bar-track",
			LayoutOrder = 2,
		}, {
			Fill = React.createElement("Frame", {
				[React.Tag] = health_tag,
				Size = UDim2.new(health, 0, 1, 0),
			}),
		})

		-- a wreck being raised shows how far along that is, in purple, under its health
		local raised = math.clamp(number_of(model, "resurrect_progress", 0), 0, 1)
		if raised > 0 then
			resurrect_track = React.createElement("Frame", {
				[React.Tag] = "bar-track",
				LayoutOrder = 3,
			}, {
				Fill = React.createElement("Frame", {
					[React.Tag] = "bar-fill resurrect",
					Size = UDim2.new(raised, 0, 1, 0),
				}),
			})
		end
	elseif is_blueprint then
		local cost = math.max(1, number_of(model, "buildpower_cost", 1))
		local progress = number_of(model, "build_progress", 0)
		fraction = math.clamp(progress / cost, 0, 1)
		fill_tags = "bar-fill progress"

		local text: string
		local tags = "bar-eta"
		if model:GetAttribute "decaying" == true then
			-- falling apart: how long until nothing is left of it
			text = `DECAY {format_time(progress / config.BLUEPRINT_DECAY_RATE)}`
			tags = if props.lit then "bar-eta decaying lit" else "bar-eta decaying"
		else
			local rate = progress_rate(props.id)
			text = if rate ~= nil and rate > STALL_RATE then format_time((cost - progress) / rate) else "--"
		end
		eta = React.createElement("TextLabel", {
			[React.Tag] = tags,
			LayoutOrder = 3,
			Text = text,
		})

		local max_health = math.max(1, number_of(model, "max_health", 1))
		local health = math.clamp(number_of(model, "health", max_health) / max_health, 0, 1)
		if health < 1 then
			health_track = React.createElement("Frame", {
				[React.Tag] = "bar-track",
				LayoutOrder = 2,
			}, {
				Fill = React.createElement("Frame", {
					[React.Tag] = if health <= LOW_HEALTH
						then "bar-fill health low"
						elseif health <= MID_HEALTH then "bar-fill health mid"
						else "bar-fill health",
					Size = UDim2.new(health, 0, 1, 0),
				}),
			})
		end
	else
		local max_health = math.max(1, number_of(model, "max_health", 1))
		fraction = math.clamp(number_of(model, "health", max_health) / max_health, 0, 1)
		show_track = fraction < 1
		fill_tags = if fraction <= LOW_HEALTH
			then "bar-fill health low"
			elseif fraction <= MID_HEALTH then "bar-fill health mid"
			else "bar-fill health"
	end

	-- what is stopping it says so, flashing above its bar: a shooter that has a target and cannot pay for the
	-- shot, or a lab that cannot start its next unit for something standing where it goes
	local complaint: string? = nil
	if model:GetAttribute "exit_blocked" == true then
		complaint = "Exit blocked"
	elseif model:GetAttribute "need_energy" == true then
		complaint = "Need energy"
	end
	local warning: any = nil
	if complaint ~= nil then
		warning = React.createElement("TextLabel", {
			[React.Tag] = if props.lit then "bar-warning lit" else "bar-warning",
			LayoutOrder = -1,
			Text = complaint,
		})
	end

	local self_destruct: any = nil
	local self_destruct_left = model:GetAttribute "self_destruct"
	if typeof(self_destruct_left) == "number" and world.is_mine(model) then
		self_destruct = React.createElement("TextLabel", {
			[React.Tag] = if props.lit then "bar-self-destruct lit" else "bar-self-destruct",
			LayoutOrder = -2,
			Text = `SELF-D {self_destruct_left}s`,
		})
	end

	local nametag = team_mark(model, false)

	-- how far along a slow weapon is to its next shot, and a missile launcher's stockpile: how far along its next
	-- missile is and how many it holds. Neither belongs to a blueprint, which cannot shoot yet, or a wreck.
	local reload_track: any = nil
	local stockpile_track: any = nil
	local stockpile_count: any = nil
	if is_blueprint == false and is_wreck == false then
		local reload = model:GetAttribute "reload_progress"
		-- a weapon that is ready has nothing to wait for, so its bar is only up while it is still reloading
		if typeof(reload) == "number" and reload < 1 then
			reload_track = React.createElement("Frame", {
				[React.Tag] = "bar-track",
				LayoutOrder = 4,
			}, {
				Fill = React.createElement("Frame", {
					[React.Tag] = "bar-fill reload",
					Size = UDim2.new(math.clamp(reload, 0, 1), 0, 1, 0),
				}),
			})
		end

		local progress = model:GetAttribute "stockpile_progress"
		if typeof(progress) == "number" then
			stockpile_track = React.createElement("Frame", {
				[React.Tag] = "bar-track",
				LayoutOrder = 5,
			}, {
				Fill = React.createElement("Frame", {
					[React.Tag] = "bar-fill stockpile",
					Size = UDim2.new(math.clamp(progress, 0, 1), 0, 1, 0),
				}),
			})
			stockpile_count = React.createElement("TextLabel", {
				[React.Tag] = "bar-count",
				LayoutOrder = 6,
				Text = `{number_of(model, "stockpile", 0)} / {number_of(model, "stockpile_limit", 0)}`,
			})
		end
	end

	-- a plasma deflector's shield: how much power it has left
	local shield_track: any = nil
	local shield_power = model:GetAttribute "shield_power"
	local shield_max = model:GetAttribute "shield_max"
	if is_blueprint == false and typeof(shield_power) == "number" and typeof(shield_max) == "number" then
		shield_track = React.createElement("Frame", {
			[React.Tag] = "bar-track",
			LayoutOrder = 7,
		}, {
			Fill = React.createElement("Frame", {
				[React.Tag] = "bar-fill shield",
				Size = UDim2.new(math.clamp(shield_power / math.max(1, shield_max), 0, 1), 0, 1, 0),
			}),
		})
	end

	-- its EMP, filling toward the stun, and once stunned how long for
	local emp_track: any = nil
	local stun_label: any = nil
	local emp_percent = model:GetAttribute "emp"
	if is_wreck == false and typeof(emp_percent) == "number" and emp_percent > 0 then
		emp_track = React.createElement("Frame", {
			[React.Tag] = "bar-track",
			LayoutOrder = 2,
		}, {
			Fill = React.createElement("Frame", {
				[React.Tag] = "bar-fill emp",
				Size = UDim2.new(math.clamp(emp_percent / 100, 0, 1), 0, 1, 0),
			}),
		})
		local stun_left = model:GetAttribute "stun"
		if typeof(stun_left) == "number" then
			stun_label = React.createElement("TextLabel", {
				[React.Tag] = "bar-stun",
				LayoutOrder = -3,
				Text = `STUN {format_time(stun_left)}`,
			})
		end
	end

	-- nothing to show: an unhurt thing with no nametag, no dot and nothing to say
	if
		show_track == false
		and emp_track == nil
		and health_track == nil
		and eta == nil
		and warning == nil
		and self_destruct == nil
		and nametag == nil
		and reload_track == nil
		and stockpile_track == nil
		and shield_track == nil
	then
		return nil
	end

	local track: any = nil
	if show_track then
		track = React.createElement("Frame", {
			[React.Tag] = "bar-track",
			LayoutOrder = 1,
		}, {
			Fill = React.createElement("Frame", {
				[React.Tag] = fill_tags,
				-- inline because Roblox's Size covers both axes at once
				Size = UDim2.new(fraction, 0, 1, 0),
			}),
		})
	end

	return bar_frame(props.id, is_blueprint, {
		Stun = stun_label,
		SelfDestruct = self_destruct,
		Warning = warning,
		Name = nametag,
		Track = track,
		Health = health_track,
		Emp = emp_track,
		Resurrect = resurrect_track,
		Eta = eta,
		Reload = reload_track,
		Stockpile = stockpile_track,
		Count = stockpile_count,
		Shield = shield_track,
	})
end

-- The point a bar hangs from: over the top of its entity's art where that stands taller than its collider, like the
-- commander's. The model's position is its collider's middle, and its art stands on the collider's bottom.
local function anchor_of(model: Model): Vector3
	local def_name = model:GetAttribute "def_name"
	local def = if typeof(def_name) == "string" then unit_defs.defs[def_name] else nil
	local half_height = if def ~= nil then unit_defs.collider_height(def) / 2 else 1
	local art_height = if typeof(def_name) == "string" then art.height(def_name) else nil
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

local function WorldBars()
	local models, set_models = React.useState({} :: { Model })
	local lit, set_lit = React.useState(true)

	React.useEffect(function()
		local accumulator = 0
		local connection = RunService.Heartbeat:Connect(function(delta: number)
			accumulator += delta
			if accumulator < SAMPLE_INTERVAL then
				return
			end
			accumulator = 0
			sample_history()
			set_lit(math.floor(os.clock() * FLASHES_PER_SECOND) % 2 == 0)
			-- a fresh table each time, which is what has the bars re-read their entities, and of the rocks and trees
			-- only those someone has started on: the rest, nearly all of them, have nothing to show
			local shown = table.clone(world.all())
			table.move(world.reclaimables_started(), 1, #world.reclaimables_started(), #shown + 1, shown)
			set_models(shown)
		end)
		return function()
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

	local camera = Workspace.CurrentCamera
	local eye = if camera ~= nil then camera.CFrame.Position else nil
	local children = {}
	for _, model in models do
		local id = world.id_of(model)
		if id == nil or model.Parent == nil then
			continue
		end
		-- the rocks and trees nobody has touched, which is nearly all of them, have nothing to show
		if
			model:GetAttribute "kind" == "reclaimable"
			and number_of(model, "reclaim_left", 0) >= number_of(model, "reclaim_total", 0)
		then
			continue
		end
		local far = eye ~= nil and (anchor_of(model) - eye).Magnitude > BAR_MAX_DISTANCE
		children[tostring(id)] = React.createElement(Bar, { id = id, model = model, lit = lit, far = far })
	end
	return React.createElement(React.Fragment, {}, children)
end

return table.freeze({
	WorldBars = WorldBars,
})
