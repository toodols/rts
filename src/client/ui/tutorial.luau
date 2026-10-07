-- A mission's guide's cards (the steps and what finishes them are Client.tutorial, each mission's in Client.missions):
-- across the top of the screen, the step's title over a row of cards, one for each way of doing it. Each card shows the
-- way in 3D (keys, a mouse, a cursor dragging a box, Shared.ui_art), as its `picture` says, with a caption, and a tick
-- under it, or a cross for a way that does not work. A card that is done lights green; once one is, the next step is
-- on its way.
--
-- The pictures answer the player: a key lights while it is held, the WASD card shakes and flashes red when one of
-- its keys is pressed, and the mouse's wheel lights while the middle button is held. The select and move cards play
-- a short demonstration on a loop, as do the counterattack's resurrect cards: the Resurrect command being clicked, and
-- a circle dragged over wrecks, which rise.
--
-- A mission with waves has them in a box of their own above the step (ui/wave_block.luau), as one with a time limit
-- has the time left, and once its steps are done, its objective under that; a guide that ends in a card of its own (its
-- `finish`) shows that instead. A mission played without a guide (a hard mode) still shows that box, and nothing else.

local ReplicatedStorage = game:GetService "ReplicatedStorage"
local RunService = game:GetService "RunService"
local UserInputService = game:GetService "UserInputService"

local React = require(ReplicatedStorage.Packages.react)

local campaign = require(ReplicatedStorage.Shared.campaign)
local keybinds = require(ReplicatedStorage.Shared.keybinds)

local missions = require(ReplicatedStorage.Client.missions)
local input_router = require(ReplicatedStorage.Client.input_router)
local tutorial = require(ReplicatedStorage.Client.tutorial)
local use_tutorial = require(ReplicatedStorage.Client.ui.use_tutorial)
local use_viewport = require(ReplicatedStorage.Client.ui.use_viewport)
local wave_block = require(ReplicatedStorage.Client.ui.wave_block)

local art_icon = require(ReplicatedStorage.ClientShared.art_icon)
local keybind_state = require(ReplicatedStorage.ClientShared.keybind_state)
local palette = require(ReplicatedStorage.ClientShared.palette)
local unit_picture = require(ReplicatedStorage.ClientShared.unit_picture)
local use_store = require(ReplicatedStorage.ClientShared.use_store)

type Card = missions.Card
type PictureKind = missions.PictureKind

-- What every card's picture is drawn with: what it shows, and for the WASD card, how it tells the card that a key that
-- does not work is pressed or held.
type PictureProps = {
	def_name: string,
	on_refused: () -> (),
	on_held: (held: boolean) -> (),
}

local ArtIcon = art_icon.ArtIcon
local UnitPicture = unit_picture.UnitPicture

local WASD_KEYS: { [Enum.KeyCode]: string } = {
	[Enum.KeyCode.W] = "key_w",
	[Enum.KeyCode.A] = "key_a",
	[Enum.KeyCode.S] = "key_s",
	[Enum.KeyCode.D] = "key_d",
}
-- The arrows the arrow keys' picture lights, by the keybind action of the key that pans that way.
local ARROW_GROUPS: { [string]: string } = {
	camera_up = "key_up",
	camera_left = "key_left",
	camera_down = "key_down",
	camera_right = "key_right",
}
local MIDDLE_BUTTON: { [Enum.UserInputType]: string } = {
	[Enum.UserInputType.MouseButton3] = "wheel",
}
local NO_KEYS: { [Enum.KeyCode]: string } = {}
local NO_BUTTONS: { [Enum.UserInputType]: string } = {}

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
-- The resurrect demonstrations: where the Resurrect command's row is clicked; and the middle of the circle, where it is
-- dragged out to, and the wrecks inside it.
local COMMAND_AT = Vector2.new(0.62, 0.42)
local CIRCLE_AT = Vector2.new(0.46, 0.5)
local CIRCLE_TO = Vector2.new(0.76, 0.5)
-- the circle's widest, in pixels of the picture: as far as CIRCLE_TO is from CIRCLE_AT, across a 196 wide picture
local CIRCLE_RADIUS = 59
local WRECKS_AT = { Vector2.new(0.26, 0.38), Vector2.new(0.5, 0.74), Vector2.new(0.64, 0.3) }
-- how dark a wreck is, before it is raised
local WRECK_TINT = Color3.fromRGB(80, 72, 90)
local AREA_LOOP = 4

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
		-- Watched, processed or not and whichever layer takes it: nothing bound to these keys should keep the card
		-- from answering them. Only typing into a box is not pressing them.
		return input_router.watch(function(input: InputObject, phase: input_router.Phase)
			local group = group_of(input)
			if group == nil or phase == "changed" then
				return
			end
			if phase == "ended" then
				set(group, false)
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
	end, { keys, buttons } :: { any })

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
local function BuildPicture(props: PictureProps)
	return React.createElement("Frame", {
		[React.Tag] = "tutorial-card-art",
		LayoutOrder = 1,
	}, {
		Unit = React.createElement(UnitPicture, {
			framing = "field",
			def_name = props.def_name,
			tag = "tutorial-build-unit",
			Position = UDim2.fromScale(0.5, 0.5),
		}),
	})
end

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

-- A box dragged over the unit: the cursor comes to one corner, drags the box out over it, and lets go, and the unit is
-- selected.
local function BoxDemo(props: PictureProps)
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
			framing = "field",
			def_name = props.def_name,
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

-- A left click on the unit: the cursor comes onto it and clicks, and it is selected.
local function ClickDemo(props: PictureProps)
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
			framing = "field",
			def_name = props.def_name,
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

-- A right click on the marker: the cursor goes to it and right clicks, and the unit walks there.
local function MoveDemo(props: PictureProps)
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
			framing = "field",
			def_name = props.def_name,
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

-- Resurrect mode: the cursor comes onto the Resurrect command, as the commands list shows it, and clicks it, and it
-- is on.
local function ResurrectModeDemo(_props: PictureProps)
	local phase = use_loop(CLICK_LOOP)
	-- onto it, clicking, on, back
	local stage = use_stage(phase, { 0, 0.35, 0.47, 0.88 })
	local cursor = phase:map(function(t: number): UDim2
		if t < 0.35 then
			return at(between(REST, COMMAND_AT, through(t, 0, 0.35)))
		end
		return at(between(COMMAND_AT, REST, through(t, 0.88, 1)))
	end)

	return React.createElement("Frame", {
		[React.Tag] = "tutorial-demo",
		LayoutOrder = 1,
	}, {
		Command = React.createElement("Frame", {
			[React.Tag] = if stage >= 3 then "tutorial-demo-command active" else "tutorial-demo-command",
			AnchorPoint = Vector2.new(0.5, 0.5),
			Position = UDim2.fromScale(0.5, COMMAND_AT.Y),
		}, {
			Name = React.createElement("TextLabel", {
				[React.Tag] = "command-name grow",
				LayoutOrder = 1,
				Text = "Resurrect",
			}),
			Key = React.createElement("TextLabel", {
				[React.Tag] = "command-key",
				LayoutOrder = 2,
				Text = "W",
			}),
		}),
		Mouse = React.createElement(DemoMouse, { lit = if stage == 2 then { button_left = true } else {} }),
		Cursor = React.createElement(Moving, { position = cursor }, {
			Icon = React.createElement(Cursor),
		}),
	})
end

-- An area resurrect: the cursor comes to the middle of some wrecks of the unit, drags a circle out over them with the
-- left button held and lets go, and they rise.
local function AreaResurrectDemo(props: PictureProps)
	local phase = use_loop(AREA_LOOP)
	-- to the middle, dragging, let go, risen, back
	local stage = use_stage(phase, { 0, 0.2, 0.55, 0.7, 0.92 })
	local cursor = phase:map(function(t: number): UDim2
		if t < 0.2 then
			return at(between(REST, CIRCLE_AT, through(t, 0, 0.2)))
		elseif t < 0.92 then
			return at(between(CIRCLE_AT, CIRCLE_TO, through(t, 0.2, 0.55)))
		end
		return at(between(CIRCLE_TO, REST, through(t, 0.92, 1)))
	end)
	local circle_size = phase:map(function(t: number): UDim2
		local diameter = 2 * CIRCLE_RADIUS * ease(through(t, 0.2, 0.55))
		return UDim2.fromOffset(diameter, diameter)
	end)

	local children: { [string]: any } = {
		Circle = if stage == 2 or stage == 3
			then React.createElement("Frame", {
				[React.Tag] = if stage == 3 then "tutorial-demo-circle ordered" else "tutorial-demo-circle",
				AnchorPoint = Vector2.new(0.5, 0.5),
				Position = at(CIRCLE_AT),
				Size = circle_size,
			})
			else nil,
		Mouse = React.createElement(DemoMouse, { lit = if stage == 2 then { button_left = true } else {} }),
		Cursor = React.createElement(Moving, { position = cursor }, {
			Icon = React.createElement(Cursor),
		}),
	}
	local risen = stage >= 4
	for index, point in WRECKS_AT do
		children[`Wreck{index}`] = React.createElement(UnitPicture, {
			framing = "field",
			def_name = props.def_name,
			tag = "tutorial-demo-wreck",
			Position = at(point),
			tint = if risen then nil else WRECK_TINT,
		})
	end
	return React.createElement("Frame", {
		[React.Tag] = "tutorial-demo",
		LayoutOrder = 1,
	}, children)
end

-- WASD: its keys light as they are pressed, and every press shakes it and flashes it red, since they do not move the
-- camera.
local function WasdPicture(props: PictureProps)
	local held, presses = use_held(WASD_KEYS, NO_BUTTONS)
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
		lit_color = palette.danger,
		pressed = held,
		shake = presses,
		-- laid out as the keys are on a keyboard
		fallback = "W\nA S D",
		tag = "tutorial-card-art",
		LayoutOrder = 1,
	})
end

-- Whether the player pans with W, A, S and D, each the way it points.
local function pans_with_wasd(): boolean
	return keybind_state.key_of "camera_up" == Enum.KeyCode.W
		and keybind_state.key_of "camera_left" == Enum.KeyCode.A
		and keybind_state.key_of "camera_down" == Enum.KeyCode.S
		and keybind_state.key_of "camera_right" == Enum.KeyCode.D
end

-- The keys that pan, each lit while it is held: W, A, S and D when the player pans with those, and otherwise the arrow
-- keys, each arrow lit by the player's key for panning that way.
local function ArrowsPicture(_props: PictureProps)
	local bindings = keybind_state.use_bindings()
	local wasd = pans_with_wasd()
	local keys = React.useMemo(function(): { [Enum.KeyCode]: string }
		if wasd then
			return WASD_KEYS
		end
		local found: { [Enum.KeyCode]: string } = {}
		for action, group in ARROW_GROUPS do
			local key = keybind_state.key_of(action)
			if key ~= nil then
				found[key] = group
			end
		end
		return found
	end, { bindings })
	local held = use_held(keys, NO_BUTTONS)
	return React.createElement(ArtIcon, {
		name = if wasd then "tutorial_wasd" else "tutorial_arrows",
		view = "above",
		lit = held,
		pressed = held,
		fallback = if wasd then "W\nA S D" else "↑\n← ↓ →",
		tag = "tutorial-card-art",
		LayoutOrder = 1,
	})
end

local function MousePicture(_props: PictureProps)
	local held = use_held(NO_KEYS, MIDDLE_BUTTON)
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

-- What draws each kind of card picture.
local PICTURES: { [PictureKind]: (props: PictureProps) -> any } = table.freeze({
	wasd = WasdPicture,
	arrows = ArrowsPicture,
	middle_mouse = MousePicture,
	box_select = BoxDemo,
	click = ClickDemo,
	move = MoveDemo,
	resurrect_mode = ResurrectModeDemo,
	area_resurrect = AreaResurrectDemo,
	unit = BuildPicture,
})

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

-- How far a card with a `rate` has got: the income a second, as the resource bar writes it, over a meter in the
-- resource's colour that fills to the goal, and the goal at its end.
local function RateMeter(props: { rate: { resource: string, goal: number }, progress: string?, done: boolean })
	local have = tonumber(props.progress or "") or 0
	local fraction = math.clamp(have / props.rate.goal, 0, 1)
	return React.createElement("Frame", {
		[React.Tag] = "tutorial-rate",
		LayoutOrder = 4,
	}, {
		Have = React.createElement("TextLabel", {
			[React.Tag] = if props.done then "tutorial-rate-have done" else `tutorial-rate-have {props.rate.resource}`,
			LayoutOrder = 1,
			Text = string.format("+%.0f/s", have),
		}),
		Track = React.createElement("Frame", {
			[React.Tag] = "tutorial-rate-track",
			LayoutOrder = 2,
		}, {
			Fill = React.createElement("Frame", {
				[React.Tag] = `resource-fill {props.rate.resource}-fill`,
				-- set inline rather than in SCSS, as the resource bar's are
				Size = UDim2.fromScale(fraction, 1),
			}),
		}),
		Goal = React.createElement("TextLabel", {
			[React.Tag] = "tutorial-rate-goal",
			LayoutOrder = 3,
			Text = `{props.rate.goal}/s`,
		}),
	})
end

local function CardView(props: {
	card: Card,
	done: boolean,
	progress: string?,
	hint: tutorial.Hint?,
	LayoutOrder: number,
})
	local card = props.card
	-- the keys a caption names are the player's own
	local bindings = keybind_state.use_bindings()
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

	local picture = React.createElement(PICTURES[card.picture.kind], {
		def_name = card.picture.def_name or "",
		on_refused = function()
			set_refused(os.clock())
		end,
		on_held = set_refusing,
	})

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
				[React.Tag] = if props.hint.next then "tutorial-hint next" else "tutorial-hint",
				LayoutOrder = 2,
				Text = props.hint.text,
			})
			else nil,
		Caption = React.createElement("TextLabel", {
			[React.Tag] = "tutorial-caption",
			LayoutOrder = 3,
			Text = keybinds.fill(card.caption, bindings),
		}),
		-- how far along a card that counts is, like 2/3, or an income against its goal
		Progress = if card.rate ~= nil
			then React.createElement(RateMeter, { rate = card.rate, progress = props.progress, done = props.done })
			elseif props.progress ~= nil then React.createElement("TextLabel", {
				[React.Tag] = if props.done then "tutorial-progress done" else "tutorial-progress",
				LayoutOrder = 4,
				Text = props.progress,
			})
			else nil,
		Mark = React.createElement(Mark, { mark = card.mark, done = props.done }),
	})
end

local function Tutorial()
	local state = use_tutorial.use_tutorial()
	local ui_scale = use_viewport.use_ui_scale()
	-- a card may be shown only for some keybinds
	keybind_state.use_bindings()
	-- hooks, so called on every render, whether or not there is a step to take them from
	local hint = use_store.use_store(tutorial.hint, tutorial.subscribe_hint)
	-- nil outside a mission with waves, or with a time limit
	local waves = wave_block.use_waves()
	local time_left = wave_block.use_time_left()
	-- once the metal and energy bar is up, the cards sit below it rather than over it
	local root_tag = if tutorial.shown "economy" then "tutorial below-resources" else "tutorial"
	local wave_box = if waves ~= nil
		then React.createElement(wave_block.WaveBox, { LayoutOrder = 0, waves = waves })
		elseif time_left ~= nil then React.createElement(
			wave_block.TimeBox,
			{ LayoutOrder = 0, seconds = time_left }
		)
		else nil
	-- a mission played with no guide (its hard mode) still shows its waves or its time
	if state.active == false then
		if wave_box == nil then
			return nil
		end
		return React.createElement("Frame", {
			[React.Tag] = "tutorial below-resources",
		}, {
			Scale = React.createElement("UIScale", { Scale = ui_scale }),
			Waves = wave_box,
		})
	end

	local steps = tutorial.steps()
	local step = steps[state.step]
	local guide = tutorial.guide()
	local finish = if guide ~= nil then guide.finish else nil
	local mission = campaign.get(state.mission or "")
	local kicker = if mission ~= nil then string.upper(mission.label) else "GUIDE"
	-- Past the last step of a guide that does not end in a card of its own, what is left is its objective, if it says;
	-- otherwise there is nothing more to say: it has been won.
	if step == nil and finish == nil then
		local objective = tutorial.objective()
		if objective == nil and wave_box == nil then
			return nil
		end
		local objective_children: { [string]: any } = {}
		if objective ~= nil then
			objective_children.Kicker = React.createElement("TextLabel", {
				[React.Tag] = "tutorial-kicker",
				LayoutOrder = 1,
				Text = "OBJECTIVE",
			})
			objective_children.Title = React.createElement("TextLabel", {
				[React.Tag] = "tutorial-title",
				LayoutOrder = 2,
				Text = objective.title,
			})
			for index, line in objective.lines do
				objective_children[`Line{index}`] = React.createElement("TextLabel", {
					[React.Tag] = "tutorial-status",
					LayoutOrder = 2 + index,
					Text = line,
				})
			end
		end
		return React.createElement("Frame", {
			[React.Tag] = root_tag,
		}, {
			Scale = React.createElement("UIScale", { Scale = ui_scale }),
			Waves = wave_box,
			Objective = if objective ~= nil
				then React.createElement("Frame", {
					[React.Tag] = "tutorial-objective",
					LayoutOrder = 1,
				}, objective_children)
				else nil,
		})
	end
	if step == nil and finish ~= nil then
		return React.createElement("Frame", {
			[React.Tag] = `{root_tag} tutorial-finished`,
		}, {
			Scale = React.createElement("UIScale", { Scale = ui_scale }),
			Kicker = React.createElement("TextLabel", {
				[React.Tag] = "tutorial-kicker",
				LayoutOrder = 1,
				Text = kicker,
			}),
			Title = React.createElement("TextLabel", {
				[React.Tag] = "tutorial-title",
				LayoutOrder = 2,
				Text = finish.title,
			}),
			Status = React.createElement("TextLabel", {
				[React.Tag] = "tutorial-status",
				LayoutOrder = 3,
				Text = finish.status,
			}),
		})
	end

	local cards = {}
	local checks = 0
	for index, card in step.cards do
		if card.shown ~= nil and card.shown() == false then
			continue
		end
		if card.mark == "check" then
			checks += 1
		end
		cards[card.id] = React.createElement(CardView, {
			card = card,
			done = state.completed[card.id] == true,
			progress = state.progress[card.id],
			hint = hint,
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
		Waves = wave_box,
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
