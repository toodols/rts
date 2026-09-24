-- The tutorial's cards (the steps and what finishes them are Client.tutorial): across the top of the screen, the
-- step's title over a row of cards, one for each way of doing it. Each card shows the way in 3D (keys, a mouse, a
-- cursor dragging a box, Client.ui_art) with a caption, and a tick under it, or a cross for a way that does not work.
-- A card that is done lights green; once one is, the next step is on its way.
--
-- The pictures answer the player: a key lights while it is held, the WASD card shakes and flashes red when one of
-- its keys is pressed, and the mouse's wheel lights while the middle button is held. The select and move cards play
-- a short demonstration on a loop.

local ReplicatedStorage = game:GetService "ReplicatedStorage"
local RunService = game:GetService "RunService"
local UserInputService = game:GetService "UserInputService"

local React = require(ReplicatedStorage.Packages.react)

local campaign = require(ReplicatedStorage.Shared.campaign)
local unit_defs = require(ReplicatedStorage.Shared.unit_defs)

local build_mode = require(ReplicatedStorage.Client.build_mode)
local client_input = require(ReplicatedStorage.Client.input)
local tutorial = require(ReplicatedStorage.Client.tutorial)
local art_icon = require(ReplicatedStorage.Client.ui.art_icon)
local unit_picture = require(ReplicatedStorage.Client.ui.unit_picture)
local use_entities = require(ReplicatedStorage.Client.ui.use_entities)
local use_tutorial = require(ReplicatedStorage.Client.ui.use_tutorial)
local use_viewport = require(ReplicatedStorage.Client.ui.use_viewport)

type Card = tutorial.Card

local ArtIcon = art_icon.ArtIcon
local UnitPicture = unit_picture.UnitPicture

local WASD_KEYS: { [Enum.KeyCode]: string } = {
	[Enum.KeyCode.W] = "key_w",
	[Enum.KeyCode.A] = "key_a",
	[Enum.KeyCode.S] = "key_s",
	[Enum.KeyCode.D] = "key_d",
}
local ARROW_KEYS: { [Enum.KeyCode]: string } = {
	[Enum.KeyCode.Up] = "key_up",
	[Enum.KeyCode.Left] = "key_left",
	[Enum.KeyCode.Down] = "key_down",
	[Enum.KeyCode.Right] = "key_right",
}
local MIDDLE_BUTTON: { [Enum.UserInputType]: string } = {
	[Enum.UserInputType.MouseButton3] = "wheel",
}

local CROSS = Color3.fromRGB(238, 88, 74)
-- how long a card stays marked as refused after a key that does not work is pressed
local REFUSED_SECONDS = 0.45
-- how far a mouse button sinks when it is pressed, in studs of the mouse's picture
local MOUSE_PRESS_DEPTH = 0.08

-- The demonstrations, in the scale of the card's picture: where the cursor rests between loops, and the corners of
-- the box it drags; where the unit stands, and where the move card's marker is.
local REST = Vector2.new(0.92, 0.55)
local BOX_FROM = Vector2.new(0.24, 0.1)
local BOX_TO = Vector2.new(0.76, 0.92)
local UNIT_AT = Vector2.new(0.5, 0.52)
local MOVE_FROM = Vector2.new(0.24, 0.55)
local MOVE_TO = Vector2.new(0.78, 0.6)
local BOX_LOOP = 3.2
local CLICK_LOOP = 2.6
local MOVE_LOOP = 3.4

local function ease(t: number): number
	t = math.clamp(t, 0, 1)
	return t * t * (3 - 2 * t)
end

-- `from` to `to`, `t` of the way, eased.
local function between(from: Vector2, to: Vector2, t: number): Vector2
	return from:Lerp(to, ease(t))
end

-- How far through `span` (from, to) `t` is, 0 before it and 1 after.
local function through(t: number, from: number, to: number): number
	return math.clamp((t - from) / (to - from), 0, 1)
end

local function at(point: Vector2): UDim2
	return UDim2.fromScale(point.X, point.Y)
end

-- Which of `keys` and `buttons` are held, by the art group each lights, and a count of presses of the keys that goes
-- up with each. Keys the game has already taken (typing in a text box) do not count; mouse buttons always do, since
-- the cards and panels under the cursor take those.
local function use_held(
	keys: { [Enum.KeyCode]: string },
	buttons: { [Enum.UserInputType]: string }
): ({ [string]: boolean }, number)
	local held, set_held = React.useState({} :: { [string]: boolean })
	local presses, set_presses = React.useState(0)

	React.useEffect(function()
		local function group_of(input: InputObject): string?
			local group = keys[input.KeyCode]
			if group ~= nil then
				return group
			end
			return buttons[input.UserInputType]
		end
		local function set(group: string, down: boolean)
			set_held(function(current: { [string]: boolean })
				if (current[group] == true) == down then
					return current
				end
				local next_held = table.clone(current)
				next_held[group] = if down then true else nil
				return next_held
			end)
		end
		-- Straight from UserInputService, processed or not: nothing bound to these keys should keep the card from
		-- answering them. Only typing into a box is not pressing them.
		local began = UserInputService.InputBegan:Connect(function(input: InputObject)
			local group = group_of(input)
			if group == nil then
				return
			end
			local is_key = keys[input.KeyCode] ~= nil
			if is_key and UserInputService:GetFocusedTextBox() ~= nil then
				return
			end
			set(group, true)
			if is_key then
				set_presses(function(count: number)
					return count + 1
				end)
			end
		end)
		local ended = UserInputService.InputEnded:Connect(function(input: InputObject)
			local group = group_of(input)
			if group ~= nil then
				set(group, false)
			end
		end)
		return function()
			began:Disconnect()
			ended:Disconnect()
		end
	end, {})

	return held, presses
end

-- A loop `period` seconds long, as a binding of how far through it is, 0 to 1, updated every frame.
local function use_loop(period: number): any
	local phase, set_phase = React.useBinding(0)
	React.useEffect(function()
		local began = os.clock()
		local connection = RunService.RenderStepped:Connect(function()
			set_phase(((os.clock() - began) / period) % 1)
		end)
		return function()
			connection:Disconnect()
		end
	end, { period })
	return phase
end

-- Which of `marks` (the start of each stage of a loop, ascending from 0) the loop in `phase` is in, as state, so that
-- the few things that change from stage to stage re-render only then.
local function use_stage(phase: any, marks: { number }): number
	local stage, set_stage = React.useState(1)
	React.useEffect(function()
		-- a binding cannot be listened to, so it is read every frame; state is only set when the stage changes
		local shown = 0
		local function update()
			local value = phase:getValue()
			local current = 1
			for index, mark in marks do
				if value >= mark then
					current = index
				end
			end
			if current ~= shown then
				shown = current
				set_stage(current)
			end
		end
		update()
		local connection = RunService.RenderStepped:Connect(update)
		return function()
			connection:Disconnect()
		end
	end, { phase })
	return stage
end

-- What a building step asks for, in its own art, filling the card's picture.
local function BuildPicture(props: { def_name: string })
	return React.createElement("Frame", {
		[React.Tag] = "tutorial-card-art",
		LayoutOrder = 1,
	}, {
		Unit = React.createElement(UnitPicture, {
			def_name = props.def_name,
			tag = "tutorial-build-unit",
			Position = UDim2.fromScale(0.5, 0.5),
		}),
	})
end

-- What each building step's card shows, by card id.
local BUILD_PICTURES: { [string]: string } = {
	extractors = "metal_extractor",
	solars = "solar_collector",
	bot_lab = "bot_lab",
	grunts = "grunt",
	dgun = "commander",
	destroy = "grunt",
	edge_thugs = "thug",
	energy = "solar_collector",
}

-- The cursor, its tip at the top left of its picture, where `Moving` puts it.
local function Cursor()
	return React.createElement(ArtIcon, {
		name = "tutorial_cursor",
		view = "front",
		fallback = "↖",
		tag = "tutorial-demo-cursor",
	})
end

-- The mouse, its `lit` buttons lit, where the demonstrations put it: in the picture's corner.
local function DemoMouse(props: { lit: { [string]: boolean } })
	return React.createElement(ArtIcon, {
		name = "tutorial_mouse",
		view = "above",
		lit = props.lit,
		fallback = "MOUSE",
		tag = "tutorial-demo-mouse",
	})
end

-- A point a demonstration moves about, placed by a binding, with what it holds hanging from it: an empty frame the
-- stylesheet leaves alone, so that the binding's position is not fought over.
local function Moving(props: { position: any, children: any? })
	return React.createElement("Frame", {
		[React.Tag] = "tutorial-demo-anchor",
		Size = UDim2.new(),
		Position = props.position,
	}, props.children)
end

-- A box dragged over the commander: the cursor comes to one corner, drags the box out over it, and lets go, and the
-- commander is selected.
local function BoxDemo()
	local phase = use_loop(BOX_LOOP)
	-- to the corner, dragging, selected, back
	local stage = use_stage(phase, { 0, 0.2, 0.62, 0.9 })
	local cursor = phase:map(function(t: number): UDim2
		if t < 0.2 then
			return at(between(REST, BOX_FROM, through(t, 0, 0.2)))
		elseif t < 0.62 then
			return at(between(BOX_FROM, BOX_TO, through(t, 0.2, 0.62)))
		end
		return at(between(BOX_TO, REST, through(t, 0.9, 1)))
	end)
	local box_size = phase:map(function(t: number): UDim2
		local corner = between(BOX_FROM, BOX_TO, through(t, 0.2, 0.62))
		return UDim2.fromScale(corner.X - BOX_FROM.X, corner.Y - BOX_FROM.Y)
	end)

	return React.createElement("Frame", {
		[React.Tag] = "tutorial-demo",
		LayoutOrder = 1,
	}, {
		Unit = React.createElement(UnitPicture, {
			def_name = "commander",
			tag = "tutorial-demo-unit",
			Position = at(UNIT_AT),
		}),
		Selected = if stage >= 3
			then React.createElement("Frame", {
				[React.Tag] = "tutorial-demo-selected",
				AnchorPoint = Vector2.new(0.5, 0.5),
				Position = at(UNIT_AT),
			})
			else nil,
		Box = if stage == 2
			then React.createElement("Frame", {
				[React.Tag] = "selection-box tutorial-demo-box",
				Position = at(BOX_FROM),
				Size = box_size,
			})
			else nil,
		Mouse = React.createElement(DemoMouse, { lit = if stage == 2 then { button_left = true } else {} }),
		Cursor = React.createElement(Moving, { position = cursor }, {
			Icon = React.createElement(Cursor),
		}),
	})
end

-- A left click on the commander: the cursor comes onto it and clicks, and it is selected.
local function ClickDemo()
	local phase = use_loop(CLICK_LOOP)
	-- onto it, clicking, selected, back
	local stage = use_stage(phase, { 0, 0.35, 0.47, 0.88 })
	local cursor = phase:map(function(t: number): UDim2
		if t < 0.35 then
			return at(between(REST, UNIT_AT, through(t, 0, 0.35)))
		end
		return at(between(UNIT_AT, REST, through(t, 0.88, 1)))
	end)

	return React.createElement("Frame", {
		[React.Tag] = "tutorial-demo",
		LayoutOrder = 1,
	}, {
		Unit = React.createElement(UnitPicture, {
			def_name = "commander",
			tag = "tutorial-demo-unit",
			Position = at(UNIT_AT),
		}),
		Selected = if stage >= 3
			then React.createElement("Frame", {
				[React.Tag] = "tutorial-demo-selected",
				AnchorPoint = Vector2.new(0.5, 0.5),
				Position = at(UNIT_AT),
			})
			else nil,
		Mouse = React.createElement(DemoMouse, { lit = if stage == 2 then { button_left = true } else {} }),
		Cursor = React.createElement(Moving, { position = cursor }, {
			Icon = React.createElement(Cursor),
		}),
	})
end

-- A right click on the marker: the cursor goes to it and right clicks, and the commander walks there.
local function MoveDemo()
	local phase = use_loop(MOVE_LOOP)
	-- to the marker, clicking, walking, arrived
	local stage = use_stage(phase, { 0, 0.3, 0.4, 0.85 })
	local cursor = phase:map(function(t: number): UDim2
		if t < 0.3 then
			return at(between(REST, MOVE_TO, through(t, 0, 0.3)))
		end
		return at(between(MOVE_TO, REST, through(t, 0.4, 0.6)))
	end)
	local unit = phase:map(function(t: number): UDim2
		return at(between(MOVE_FROM, MOVE_TO, through(t, 0.4, 0.85)))
	end)

	return React.createElement("Frame", {
		[React.Tag] = "tutorial-demo",
		LayoutOrder = 1,
	}, {
		Marker = React.createElement("Frame", {
			[React.Tag] = if stage >= 2 then "tutorial-demo-marker ordered" else "tutorial-demo-marker",
			AnchorPoint = Vector2.new(0.5, 0.5),
			Position = at(MOVE_TO),
		}),
		Unit = React.createElement(UnitPicture, {
			def_name = "commander",
			tag = "tutorial-demo-unit",
			Position = unit,
		}),
		Selected = React.createElement(Moving, { position = unit }, {
			Ring = React.createElement("Frame", {
				[React.Tag] = "tutorial-demo-selected",
				AnchorPoint = Vector2.new(0.5, 0.5),
			}),
		}),
		Mouse = React.createElement(DemoMouse, { lit = if stage == 2 then { button_right = true } else {} }),
		Cursor = React.createElement(Moving, { position = cursor }, {
			Icon = React.createElement(Cursor),
		}),
	})
end

-- WASD: its keys light as they are pressed, and every press shakes it and flashes it red, since they do not move the
-- camera.
local function WasdPicture(props: { on_refused: () -> (), on_held: (held: boolean) -> () })
	local held, presses = use_held(WASD_KEYS, {})
	React.useEffect(function()
		if presses > 0 then
			props.on_refused()
		end
	end, { presses })
	local any_held = next(held) ~= nil
	React.useEffect(function()
		props.on_held(any_held)
	end, { any_held })
	return React.createElement(ArtIcon, {
		name = "tutorial_wasd",
		view = "above",
		lit = held,
		lit_color = CROSS,
		pressed = held,
		shake = presses,
		-- laid out as the keys are on a keyboard
		fallback = "W\nA S D",
		tag = "tutorial-card-art",
		LayoutOrder = 1,
	})
end

local function ArrowsPicture()
	local held = use_held(ARROW_KEYS, {})
	return React.createElement(ArtIcon, {
		name = "tutorial_arrows",
		view = "above",
		lit = held,
		pressed = held,
		fallback = "↑\n← ↓ →",
		tag = "tutorial-card-art",
		LayoutOrder = 1,
	})
end

local function MousePicture()
	local held = use_held({}, MIDDLE_BUTTON)
	return React.createElement(ArtIcon, {
		name = "tutorial_mouse",
		view = "above",
		lit = held,
		pressed = held,
		press_depth = MOUSE_PRESS_DEPTH,
		fallback = "MIDDLE MOUSE",
		tag = "tutorial-card-art",
		LayoutOrder = 1,
	})
end

-- The tick or cross under a card.
local function Mark(props: { mark: "check" | "cross", done: boolean })
	local is_check = props.mark == "check"
	return React.createElement(ArtIcon, {
		name = if is_check then "tutorial_check" else "tutorial_cross",
		view = "front",
		-- a tick is grey until done, and then its own green, glowing; a cross is always its own red
		muted = is_check and props.done == false,
		glow = props.done,
		fallback = if is_check then "✓" else "✕",
		tag = if is_check
			then (if props.done then "tutorial-mark done" else "tutorial-mark")
			else "tutorial-mark cross",
		LayoutOrder = 5,
	})
end

local function CardView(
	props: {
		card: Card,
		done: boolean,
		progress: string?,
		hint: string?,
		-- the hint is what to do next rather than what has to be done first
		hint_is_next: boolean?,
		LayoutOrder: number,
	}
)
	local card = props.card
	-- when a key that does not work was last pressed on this card, to mark it refused for a moment
	local refused, set_refused = React.useState(0)
	-- whether one of those keys is held right now, which keeps it marked for as long as it is
	local refusing, set_refusing = React.useState(false)

	React.useEffect(function(): (() -> ())?
		if refused == 0 then
			return nil
		end
		local thread = task.delay(REFUSED_SECONDS, function()
			set_refused(0)
		end)
		return function()
			task.cancel(thread)
		end
	end, { refused })

	local picture
	if card.id == "wasd" then
		picture = React.createElement(WasdPicture, {
			on_refused = function()
				set_refused(os.clock())
			end,
			on_held = set_refusing,
		})
	elseif card.id == "arrows" then
		picture = React.createElement(ArrowsPicture)
	elseif card.id == "middle_drag" then
		picture = React.createElement(MousePicture)
	elseif card.id == "box_select" then
		picture = React.createElement(BoxDemo)
	elseif card.id == "click_select" then
		picture = React.createElement(ClickDemo)
	elseif card.id == "right_click" then
		picture = React.createElement(MoveDemo)
	elseif BUILD_PICTURES[card.id] ~= nil then
		picture = React.createElement(BuildPicture, { def_name = BUILD_PICTURES[card.id] })
	end

	local tag = "tutorial-card"
	if card.mark == "cross" then
		tag ..= " cross"
	end
	if props.done then
		tag ..= " done"
	end
	if refused ~= 0 or refusing then
		tag ..= " refused"
	end

	return React.createElement("Frame", {
		[React.Tag] = tag,
		LayoutOrder = props.LayoutOrder,
	}, {
		Picture = picture,
		-- what to do before the caption can be, when it is not done yet
		Hint = if props.hint ~= nil and props.done == false
			then React.createElement("TextLabel", {
				[React.Tag] = if props.hint_is_next == true then "tutorial-hint next" else "tutorial-hint",
				LayoutOrder = 2,
				Text = props.hint,
			})
			else nil,
		Caption = React.createElement("TextLabel", {
			[React.Tag] = "tutorial-caption",
			LayoutOrder = 3,
			Text = card.caption,
		}),
		-- how far along a card that counts is, like 2/3
		Progress = if props.progress ~= nil
			then React.createElement("TextLabel", {
				[React.Tag] = if props.done then "tutorial-progress done" else "tutorial-progress",
				LayoutOrder = 4,
				Text = props.progress,
			})
			else nil,
		Mark = React.createElement(Mark, { mark = card.mark, done = props.done }),
	})
end

-- What to select first, for a step that needs something selected to be done ("First select your commander"), or nil
-- when something that can do it is selected already.
local function use_builder_hint(builder: string?): string?
	local views = use_entities.use_views(use_entities.use_selection())
	if builder == nil then
		return nil
	end
	for _, view in views do
		if view.def_name == builder then
			return nil
		end
	end
	local name = if builder == "commander" then "commander" else unit_defs.get(builder).display_name
	return `First select your {name}`
end

-- The mode the cursor is in right now (input's: "attack", "disintegrator", ...), if any.
local function use_mode(): string?
	local mode, set_mode = React.useState(nil :: string?)
	React.useEffect(function()
		return client_input.subscribe_mode(set_mode)
	end, {})
	return mode
end

-- What is being placed right now, if anything.
local function use_placing(): string?
	local placing, set_placing = React.useState(build_mode.active())
	React.useEffect(function()
		set_placing(build_mode.active())
		return build_mode.subscribe(set_placing)
	end, {})
	return placing
end

local function Tutorial()
	local state = use_tutorial.use_tutorial()
	local ui_scale = use_viewport.use_ui_scale()
	-- hooks, so called on every render, whether or not there is a step to take them from
	local shown = tutorial.current_step()
	local placing = use_placing()
	local mode = use_mode()
	local builder_hint = use_builder_hint(if shown ~= nil then shown.builder else nil)
	-- What the card says to do first: select the builder, or, once what the step asks for is being placed, where to
	-- click next (the build menu stops pointing at it then).
	local hint: string? = builder_hint
	local hint_is_next = false
	if hint == nil and shown ~= nil and shown.build ~= nil and placing == shown.build and shown.placing_hint ~= nil then
		hint = shown.placing_hint
		hint_is_next = true
	elseif hint == nil and shown ~= nil and shown.command ~= nil and mode == shown.command then
		hint = shown.command_hint
		hint_is_next = hint ~= nil
	end
	if state.active == false then
		return nil
	end
	-- once the metal and energy bar is up, the cards sit below it rather than over it
	local root_tag = if tutorial.shown "economy" then "tutorial below-resources" else "tutorial"

	local steps = tutorial.steps()
	local step = steps[state.step]
	local mission = campaign.get(state.mission or "")
	local kicker = if mission ~= nil then string.upper(mission.label) else "TUTORIAL"
	-- past the last suggestion of a mission that only suggests, there is nothing more to say: it has been won
	if step == nil and state.mission ~= "tutorial" then
		return nil
	end
	if step == nil then
		return React.createElement("Frame", {
			[React.Tag] = `{root_tag} tutorial-finished`,
		}, {
			Scale = React.createElement("UIScale", { Scale = ui_scale }),
			Kicker = React.createElement("TextLabel", {
				[React.Tag] = "tutorial-kicker",
				LayoutOrder = 1,
				Text = "TUTORIAL",
			}),
			Title = React.createElement("TextLabel", {
				[React.Tag] = "tutorial-title",
				LayoutOrder = 2,
				Text = "Nice work!",
			}),
			Status = React.createElement("TextLabel", {
				[React.Tag] = "tutorial-status",
				LayoutOrder = 3,
				Text = "That's all for now. More coming soon.",
			}),
		})
	end

	local cards = {}
	local checks = 0
	for index, card in step.cards do
		if card.mark == "check" then
			checks += 1
		end
		cards[card.id] = React.createElement(CardView, {
			card = card,
			done = state.completed[card.id] == true,
			progress = state.progress[card.id],
			hint = hint,
			hint_is_next = hint_is_next,
			LayoutOrder = index,
		})
	end

	local status = if state.advancing
		then (step.done_note or "Nice! Next step coming up...")
		elseif checks > 1 and step.every_card ~= true then "Any one of these will do"
		else nil

	return React.createElement("Frame", {
		[React.Tag] = root_tag,
	}, {
		Scale = React.createElement("UIScale", { Scale = ui_scale }),
		Kicker = React.createElement("TextLabel", {
			[React.Tag] = "tutorial-kicker",
			LayoutOrder = 1,
			Text = `{kicker} · STEP {state.step} OF {#steps}`,
		}),
		Title = React.createElement("TextLabel", {
			[React.Tag] = "tutorial-title",
			LayoutOrder = 2,
			Text = step.title,
		}),
		Cards = React.createElement("Frame", {
			[React.Tag] = "tutorial-cards",
			LayoutOrder = 3,
		}, cards),
		Status = if status ~= nil
			then React.createElement("TextLabel", {
				[React.Tag] = if state.advancing then "tutorial-status advancing" else "tutorial-status",
				LayoutOrder = 4,
				Text = status,
			})
			else nil,
	})
end

return table.freeze({
	Tutorial = Tutorial,
})
