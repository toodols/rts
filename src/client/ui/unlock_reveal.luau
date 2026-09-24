-- What finishing a campaign mission unlocks, revealed like a pack being opened: a card for each def, dealt face down,
-- that one after another charges up (its glow swelling and turning the colour of its tier, the card shaking harder
-- and harder) and bursts open with a flash, a ring, sparks and light rays turning behind it, to show the def's own
-- model turning slowly, its name, what it is, and a banner with its tier. Nothing is rolled: what is revealed is
-- exactly `def_names`, and each def's tier is fixed by what it costs (`tier_of`). The cheapest is opened first, so the
-- best comes last. A tally beside the heading counts the reveals.
--
-- Everything that moves runs off one clock (`use_clock`), a binding set every frame, so none of it re-renders
-- anything; the stylesheet only has how things look at rest. A click, or Space or Enter, speeds the rest of the reveal
-- up. Once it is all open `on_done` is called, and the cards stay, their rays still turning. An open card answers the
-- pointer like a button: it lifts, swells and shines under it, dips as it is pressed, and a click bursts it again.
--
-- `UnlockVignette` darkens the edges of the screen behind it, fading in.

local ReplicatedStorage = game:GetService "ReplicatedStorage"
local RunService = game:GetService "RunService"
local TweenService = game:GetService "TweenService"
local UserInputService = game:GetService "UserInputService"

local React = require(ReplicatedStorage.Packages.react)

local unit_defs = require(ReplicatedStorage.Shared.unit_defs)

local unit_descriptions = require(ReplicatedStorage.Client.ui.unit_descriptions)
local unit_picture = require(ReplicatedStorage.Client.ui.unit_picture)

local UnitPicture = unit_picture.UnitPicture

-- How rare a def is made to look. A def is of the first tier its power (unit_defs.power: metal plus energy / 60) is
-- below.
export type Tier = {
	label: string,
	-- the class its card and banner take in the stylesheet
	tag: string,
	color: Color3,
	below: number,
}

-- One card: what it shows, and when each of its beats lands, in seconds of the reveal's clock.
type Card = {
	def_name: string,
	tier: Tier,
	index: number,
	-- dealt onto the table face down; starts to charge; bursts open
	deal_at: number,
	charge_at: number,
	burst_at: number,
}

type Plan = {
	cards: { Card },
	-- when the last card has settled, and the reveal is over
	done_at: number,
}

-- `t` is the reveal's own time, which a click speeds up; `now` is plain seconds since it began, for what keeps moving
-- at its own pace (a shake, the rays turning).
type Clock = { t: number, now: number }

-- A value easing from `from` to `to` over TOUCH_SECONDS since `at`, in seconds of the clock's `now`.
type Eased = { from: number, to: number, at: number }

-- How the pointer is handling a card, kept by its events: how far it is over it and pressing it, and when it last
-- came over it and clicked it.
type Touch = { hover: Eased, press: Eased, hovered_at: number, clicked_at: number }

-- What that comes to at some moment: how hovered and pressed the card looks, how much of a click's punch is left, and
-- the seconds since the pointer came over it. All nothing until the card is open.
type Handling = { hover: number, press: number, punch: number, since_hover: number }

type Binding = any

-- Roughly: the cheapest T1 things common, the rest of T1 uncommon, T2 rare, the priciest T2 and the T2 labs epic, T3
-- legendary, and the biggest experimentals mythic.
local TIERS: { Tier } = {
	{ label = "COMMON", tag = "common", color = Color3.fromRGB(178, 190, 204), below = 100 },
	{ label = "UNCOMMON", tag = "uncommon", color = Color3.fromRGB(110, 222, 96), below = 400 },
	{ label = "RARE", tag = "rare", color = Color3.fromRGB(96, 210, 242), below = 1200 },
	{ label = "EPIC", tag = "epic", color = Color3.fromRGB(176, 96, 240), below = 3500 },
	{ label = "LEGENDARY", tag = "legendary", color = Color3.fromRGB(255, 196, 64), below = 15000 },
	{ label = "MYTHIC", tag = "mythic", color = Color3.fromRGB(255, 98, 74), below = math.huge },
}

local WHITE = Color3.new(1, 1, 1)
local BLACK = Color3.new(0, 0, 0)
local CENTER = UDim2.fromScale(0.5, 0.5)
local MIDDLE = Vector2.new(0.5, 0.5)

-- The timeline, in seconds of the reveal's clock: the heading pops in, the cards are dealt one after another, and then
-- each in turn charges and bursts, the last charging longest. A click runs it SKIP_SPEED times as fast.
local HEADER_AT = 0.45
local HEADER_SECONDS = 0.45
local DEAL_AT = 0.75
local DEAL_STAGGER = 0.14
local DEAL_SECONDS = 0.5
local CHARGE_GAP = 0.3
local CHARGE_SECONDS = 0.8
local FINAL_CHARGE_SECONDS = 1.15
local SETTLE_SECONDS = 0.45
local DONE_AFTER = 0.7
local SKIP_SPEED = 6
local VIGNETTE_SECONDS = 0.8

-- Dealing: how far below its place a card starts, how small, and how far turned.
local DEAL_DROP = 90
local DEAL_SCALE = 0.4
local DEAL_TURN = 10

-- Charging: how far the card shakes at the end of it, in pixels and degrees, how many shakes a second, and how much it
-- swells.
local SHAKE_PIXELS = 6
local SHAKE_DEGREES = 4
local SHAKE_RATE = 9
local CHARGE_SWELL = 0.08

-- Bursting: the card folds shut edge on over FLIP_HALF and opens on its face over FLIP_OPEN_SECONDS, overshooting; it
-- pops from POP_FROM of its size back to its own, wobbling; a flash washes over it and fades, and a fainter one over the
-- whole screen.
local FLIP_HALF = 0.1
local FLIP_OPEN_SECONDS = 0.32
local POP_FROM = 1.22
local POP_SECONDS = 0.8
local FLASH_SECONDS = 0.4
local SCREEN_FLASH = 0.62
local SCREEN_FLASH_SECONDS = 0.3
local SCREEN_FLASH_SIZE = 4000
-- The banner slams down from BANNER_FROM of its size, just after the card opens.
local BANNER_AT = 0.14
local BANNER_SECONDS = 0.4
local BANNER_FROM = 2.6
local BANNER_TURN = 14
local BANNER_REST_TURN = -4
-- The ring that spreads from it, in pixels across.
local RING_FROM = 60
local RING_TO = 460
local RING_SECONDS = 0.6
local RING_THICKNESS = 6
-- The light rays behind it, which grow out over RAYS_SECONDS and then keep turning.
local RAYS = 10
local RAY_LENGTH = 440
local RAY_WIDE = 30
local RAY_NARROW = 14
local RAYS_SECONDS = 0.55
local RAY_SPEED = 16
-- The sparks it throws, each out along its own angle (turned by the golden angle from the last, so they spread
-- evenly) and fading.
local SPARKLES = 16
local SPARKLE_SECONDS = 0.7
local SPARKLE_REACH = 130
local GOLDEN_ANGLE = math.rad(137.508)
-- The glints that keep twinkling round an open card, at these places on it.
local TWINKLES: { Vector2 } = {
	Vector2.new(0.04, 0.12),
	Vector2.new(0.97, 0.3),
	Vector2.new(0.06, 0.78),
	Vector2.new(0.94, 0.92),
}
local TWINKLE_SIZE = 12
-- The glow behind a card, in pixels across at a size of 1: three soft discs at a third of a turn to each other.
local GLOW_SIZE = 210
local GLOW_PETALS = 3
-- The model turns this fast, in radians a second.
local MODEL_SPIN = 0.6
-- An open card answers the pointer: over TOUCH_SECONDS it lifts HOVER_LIFT pixels and swells by HOVER_SWELL while
-- hovered, with a shine sweeping across it over SHINE_SECONDS, and dips by PRESS_SQUEEZE while pressed. A click punches
-- it CLICK_PUNCH bigger, wiggling it CLICK_TURN degrees, and bursts a ring and sparks from it again.
local TOUCH_SECONDS = 0.16
local HOVER_LIFT = 10
local HOVER_SWELL = 0.07
local PRESS_SQUEEZE = 0.05
local SHINE_SECONDS = 0.5
local CLICK_PUNCH = 0.14
local CLICK_SECONDS = 0.6
local CLICK_TURN = 5

-- A disc fading out to its rim along one axis, for a glow; and a bar fading out to both ends, for a ray.
local GLOW_FADE = NumberSequence.new({
	NumberSequenceKeypoint.new(0, 1),
	NumberSequenceKeypoint.new(0.5, 0),
	NumberSequenceKeypoint.new(1, 1),
})
local RAY_FADE = NumberSequence.new({
	NumberSequenceKeypoint.new(0, 1),
	NumberSequenceKeypoint.new(0.3, 0.55),
	NumberSequenceKeypoint.new(0.5, 0),
	NumberSequenceKeypoint.new(0.7, 0.55),
	NumberSequenceKeypoint.new(1, 1),
})
-- The screen's edges darkened, the middle left clear.
local VIGNETTE_FADE = NumberSequence.new({
	NumberSequenceKeypoint.new(0, 0),
	NumberSequenceKeypoint.new(0.3, 1),
	NumberSequenceKeypoint.new(0.7, 1),
	NumberSequenceKeypoint.new(1, 0),
})
local VIGNETTE_DARKNESS = 0.35

local function tier_of(def_name: string): Tier
	local power = unit_defs.power(unit_defs.get(def_name))
	for _, tier in TIERS do
		if power < tier.below then
			return tier
		end
	end
	return TIERS[#TIERS]
end

-- The cards for `def_names`, cheapest first, and when each beat of each lands.
local function plan(def_names: { string }): Plan
	local power_of: { [string]: number } = {}
	local first_at: { [string]: number } = {}
	for index, def_name in def_names do
		power_of[def_name] = unit_defs.power(unit_defs.get(def_name))
		if first_at[def_name] == nil then
			first_at[def_name] = index
		end
	end
	local order = table.clone(def_names)
	table.sort(order, function(a: string, b: string): boolean
		if power_of[a] ~= power_of[b] then
			return power_of[a] < power_of[b]
		end
		return first_at[a] < first_at[b]
	end)

	local count = #order
	local cards: { Card } = {}
	local charge_at = DEAL_AT + DEAL_STAGGER * math.max(count - 1, 0) + DEAL_SECONDS + CHARGE_GAP
	for index, def_name in order do
		local seconds = if index == count and count > 1 then FINAL_CHARGE_SECONDS else CHARGE_SECONDS
		local burst_at = charge_at + seconds
		table.insert(cards, {
			def_name = def_name,
			tier = tier_of(def_name),
			index = index,
			deal_at = DEAL_AT + DEAL_STAGGER * (index - 1),
			charge_at = charge_at,
			burst_at = burst_at,
		})
		charge_at = burst_at + SETTLE_SECONDS
	end
	local last = cards[count]
	return { cards = cards, done_at = if last ~= nil then last.burst_at + DONE_AFTER else DEAL_AT }
end

-- How far `t` is through the `seconds` from `from`, 0 before and 1 after.
local function through(t: number, from: number, seconds: number): number
	return math.clamp((t - from) / seconds, 0, 1)
end

local function ease(alpha: number, style: Enum.EasingStyle, direction: Enum.EasingDirection): number
	return TweenService:GetValue(math.clamp(alpha, 0, 1), style, direction)
end

local function lerp(from: number, to: number, alpha: number): number
	return from + (to - from) * alpha
end

-- How far into its charge `card` is at `t`, 0 to 1.
local function charge_of(card: Card, t: number): number
	return through(t, card.charge_at, card.burst_at - card.charge_at)
end

-- How many of `cards` are open at `t`.
local function opened(cards: { Card }, t: number): number
	local count = 0
	for _, card in cards do
		if t >= card.burst_at + FLIP_HALF then
			count += 1
		end
	end
	return count
end

local function eased(value: Eased, now: number): number
	local alpha = ease(through(now, value.at, TOUCH_SECONDS), Enum.EasingStyle.Quad, Enum.EasingDirection.Out)
	return lerp(value.from, value.to, alpha)
end

-- Sets `value` easing to `to` from wherever it is at `now`.
local function ease_to(value: Eased, to: number, now: number)
	value.from = eased(value, now)
	value.to = to
	value.at = now
end

local function new_touch(): Touch
	return {
		hover = { from = 0, to = 0, at = -math.huge },
		press = { from = 0, to = 0, at = -math.huge },
		hovered_at = -math.huge,
		clicked_at = -math.huge,
	}
end

local UNTOUCHED: Handling = table.freeze({ hover = 0, press = 0, punch = 0, since_hover = math.huge })

-- How `touch` is handling `card` at `clock`.
local function handling(card: Card, touch: Touch, clock: Clock): Handling
	if clock.t < card.burst_at + FLIP_HALF then
		return UNTOUCHED
	end
	local punch = through(clock.now, touch.clicked_at, CLICK_SECONDS)
	return {
		hover = eased(touch.hover, clock.now),
		press = eased(touch.press, clock.now),
		-- starts full, then wobbles away
		punch = 1 - ease(punch, Enum.EasingStyle.Elastic, Enum.EasingDirection.Out),
		since_hover = clock.now - touch.hovered_at,
	}
end

-- The reveal's clock (see Clock), and whether it has reached `done_at`. A click, a touch, Space or Enter before then
-- speeds it up.
local function use_clock(done_at: number): (Binding, boolean)
	local clock, set_clock = React.useBinding({ t = 0, now = 0 } :: Clock)
	local done, set_done = React.useState(false)
	React.useEffect(function()
		local t = 0
		local now = 0
		local speed = 1
		local finished = false
		local stepped = RunService.RenderStepped:Connect(function(delta: number)
			t += delta * speed
			now += delta
			set_clock({ t = t, now = now })
			if finished == false and t >= done_at then
				finished = true
				speed = 1
				set_done(true)
			end
		end)
		local skipped = UserInputService.InputBegan:Connect(function(input: InputObject)
			local kind = input.UserInputType
			local pressed = kind == Enum.UserInputType.MouseButton1
				or kind == Enum.UserInputType.Touch
				or input.KeyCode == Enum.KeyCode.Space
				or input.KeyCode == Enum.KeyCode.Return
			if pressed and finished == false then
				speed = SKIP_SPEED
			end
		end)
		return function()
			stepped:Disconnect()
			skipped:Disconnect()
		end
	end, { done_at })
	return clock, done
end

-- A plain coloured shape for an effect: its look is all set here, from the clock, so its tag only keeps the
-- stylesheet from sizing it.
local function fx(props: { [any]: any }, children: { [string]: any }?): any
	props[React.Tag] = "unlock-fx"
	if props.AnchorPoint == nil then
		props.AnchorPoint = MIDDLE
	end
	return React.createElement("ImageLabel", props, children)
end

-- The glow behind a card: faint while it lies sealed, swelling and turning its tier's colour as it charges, blazing
-- as it bursts and settling to a pulse, which swells and brightens while the card is hovered or clicked.
local function Glow(props: { card: Card, clock: Binding, touch: Touch })
	local card = props.card
	local look = props.clock:map(function(clock: Clock): { size: number, transparency: number, color: Color3 }
		local t = clock.t
		if t < card.deal_at + DEAL_SECONDS * 0.5 then
			return { size = 0, transparency = 1, color = WHITE }
		elseif t < card.charge_at then
			local breath = math.sin(clock.now * 3 + card.index * 1.3)
			return { size = 1.15, transparency = 0.84 + 0.05 * breath, color = WHITE }
		elseif t < card.burst_at then
			local charge = charge_of(card, t)
			return {
				size = lerp(1.15, 2, charge ^ 1.5),
				transparency = lerp(0.8, 0.12, charge),
				color = WHITE:Lerp(card.tier.color, charge * charge),
			}
		end
		local settle = ease(through(t, card.burst_at, 0.8), Enum.EasingStyle.Quad, Enum.EasingDirection.Out)
		local handled = handling(card, props.touch, clock)
		return {
			size = lerp(2.7, 1.7, settle)
				+ 0.08 * math.sin(clock.now * 2.2 + card.index)
				+ 0.35 * handled.hover
				+ 0.5 * handled.punch,
			transparency = math.max(lerp(0, 0.4, settle) - 0.22 * handled.hover - 0.3 * handled.punch, 0),
			color = card.tier.color,
		}
	end)
	local size = look:map(function(value: { size: number }): UDim2
		return UDim2.fromOffset(GLOW_SIZE * value.size, GLOW_SIZE * value.size)
	end)
	local transparency = look:map(function(value: { transparency: number }): number
		return value.transparency
	end)
	local color = look:map(function(value: { color: Color3 }): Color3
		return value.color
	end)

	local petals: { [string]: any } = {}
	for index = 1, GLOW_PETALS do
		petals[`Petal{index}`] = fx({
			Position = CENTER,
			Size = size,
			Rotation = (index - 1) * 180 / GLOW_PETALS,
			BackgroundColor3 = color,
			BackgroundTransparency = transparency,
			ZIndex = 1,
		}, {
			Corner = React.createElement("UICorner", { CornerRadius = UDim.new(0.5, 0) }),
			Fade = React.createElement("UIGradient", { Transparency = GLOW_FADE }),
		})
	end
	return React.createElement(React.Fragment, nil, petals)
end

-- The light rays that fan out behind an open card and keep turning, reaching further and brighter while it is hovered.
local function Rays(props: { card: Card, clock: Binding, touch: Touch })
	local card = props.card
	local rays: { [string]: any } = {}
	local transparency = props.clock:map(function(clock: Clock): number
		local settle = ease(through(clock.t, card.burst_at, 1), Enum.EasingStyle.Quad, Enum.EasingDirection.Out)
		local handled = handling(card, props.touch, clock)
		return lerp(0.05, 0.5, settle) + 0.06 * math.sin(clock.now * 1.7) - 0.2 * handled.hover - 0.25 * handled.punch
	end)
	for index = 1, RAYS do
		rays[`Ray{index}`] = fx({
			Position = CENTER,
			Size = UDim2.new(0, if index % 2 == 0 then RAY_NARROW else RAY_WIDE, 1, 0),
			Rotation = (index - 1) * 180 / RAYS,
			BackgroundColor3 = card.tier.color,
			BackgroundTransparency = transparency,
		}, {
			Fade = React.createElement("UIGradient", { Transparency = RAY_FADE, Rotation = 90 }),
		})
	end
	return fx({
		Position = CENTER,
		BackgroundTransparency = 1,
		ZIndex = 2,
		Visible = props.clock:map(function(clock: Clock): boolean
			return clock.t >= card.burst_at
		end),
		Size = props.clock:map(function(clock: Clock): UDim2
			local grow =
				ease(through(clock.t, card.burst_at, RAYS_SECONDS), Enum.EasingStyle.Back, Enum.EasingDirection.Out)
			local handled = handling(card, props.touch, clock)
			local length = RAY_LENGTH * grow * (1 + 0.15 * handled.hover + 0.25 * handled.punch)
			return UDim2.fromOffset(length, length)
		end),
		Rotation = props.clock:map(function(clock: Clock): number
			return clock.now * RAY_SPEED + card.index * 9
		end),
	}, rays)
end

-- The ring that spreads out from a card as it bursts (or is clicked): `since` is how long ago that was at a moment.
local function Ring(props: { card: Card, clock: Binding, since: (Clock) -> number })
	local card = props.card
	local since = props.since
	local spread = props.clock:map(function(clock: Clock): number
		return through(since(clock), 0, RING_SECONDS)
	end)
	return fx({
		Position = CENTER,
		BackgroundTransparency = 1,
		ZIndex = 3,
		Visible = props.clock:map(function(clock: Clock): boolean
			local seconds = since(clock)
			return seconds >= 0 and seconds < RING_SECONDS
		end),
		Size = spread:map(function(alpha: number): UDim2
			local across = lerp(RING_FROM, RING_TO, ease(alpha, Enum.EasingStyle.Quart, Enum.EasingDirection.Out))
			return UDim2.fromOffset(across, across)
		end),
	}, {
		Corner = React.createElement("UICorner", { CornerRadius = UDim.new(0.5, 0) }),
		Stroke = React.createElement("UIStroke", {
			Color = card.tier.color,
			Thickness = spread:map(function(alpha: number): number
				return RING_THICKNESS * (1 - alpha) + 1
			end),
			Transparency = spread:map(function(alpha: number): number
				return ease(alpha, Enum.EasingStyle.Quad, Enum.EasingDirection.In)
			end),
		}),
	})
end

-- The sparks a card throws as it bursts (or is clicked): `since` is how long ago that was at a moment, and `turn`
-- turns them all, so a second burst doesn't retrace the first.
local function Sparks(props: { card: Card, clock: Binding, since: (Clock) -> number, turn: number })
	local card = props.card
	local since = props.since
	local children: { [string]: any } = {}
	for index = 1, SPARKLES do
		local angle = index * GOLDEN_ANGLE + card.index + props.turn
		local direction = Vector2.new(math.cos(angle), math.sin(angle))
		local reach = SPARKLE_REACH * (0.7 + (index * 37 % 11) / 11 * 0.6)
		local seconds = SPARKLE_SECONDS * (0.75 + (index % 4) * 0.12)
		local size = 5 + index % 5
		local flight = props.clock:map(function(clock: Clock): number
			return through(since(clock), 0, seconds)
		end)
		children[`Spark{index}`] = fx({
			BackgroundColor3 = if index % 3 == 0 then WHITE else card.tier.color:Lerp(WHITE, 0.35),
			ZIndex = 6,
			Visible = props.clock:map(function(clock: Clock): boolean
				local flown = since(clock)
				return flown >= 0 and flown < seconds
			end),
			Position = flight:map(function(alpha: number): UDim2
				local out = direction * reach * ease(alpha, Enum.EasingStyle.Quart, Enum.EasingDirection.Out)
				-- they drift down a little as they slow
				return UDim2.new(0.5, out.X, 0.5, out.Y + 30 * alpha * alpha)
			end),
			Size = flight:map(function(alpha: number): UDim2
				local across = size * (1 - alpha * 0.6)
				return UDim2.fromOffset(across, across)
			end),
			Rotation = flight:map(function(alpha: number): number
				return 45 + alpha * 180
			end),
			BackgroundTransparency = flight:map(function(alpha: number): number
				return ease(alpha, Enum.EasingStyle.Quad, Enum.EasingDirection.In)
			end),
		})
	end
	return React.createElement(React.Fragment, nil, children)
end

-- The glints that keep twinkling round a card once it is open.
local function Twinkles(props: { card: Card, clock: Binding })
	local card = props.card
	local children: { [string]: any } = {}
	for index, place in TWINKLES do
		children[`Twinkle{index}`] = fx({
			BackgroundColor3 = WHITE,
			Position = UDim2.fromScale(place.X, place.Y),
			Rotation = 45,
			ZIndex = 6,
			Visible = props.clock:map(function(clock: Clock): boolean
				return clock.t >= card.burst_at + SPARKLE_SECONDS * 0.5
			end),
			Size = props.clock:map(function(clock: Clock): UDim2
				local across = TWINKLE_SIZE * math.max(0, math.sin(clock.now * 2.4 + index * 1.9))
				return UDim2.fromOffset(across, across)
			end),
		})
	end
	return React.createElement(React.Fragment, nil, children)
end

-- The back of a card: sealed, with a meter along its foot that fills as it charges.
local function CardBack(props: { card: Card, clock: Binding })
	local card = props.card
	return React.createElement("Frame", {
		[React.Tag] = "unlock-card-back",
		Visible = props.clock:map(function(clock: Clock): boolean
			return clock.t < card.burst_at + FLIP_HALF
		end),
	}, {
		Seal = React.createElement("Frame", { [React.Tag] = "unlock-card-seal" }),
		Mark = React.createElement("TextLabel", { [React.Tag] = "unlock-card-mark", Text = "?" }),
		Caption = React.createElement("TextLabel", { [React.Tag] = "unlock-card-sealed", Text = "SEALED" }),
		Charge = React.createElement("Frame", { [React.Tag] = "unlock-charge-track" }, {
			Fill = fx({
				AnchorPoint = Vector2.zero,
				Size = props.clock:map(function(clock: Clock): UDim2
					return UDim2.fromScale(charge_of(card, clock.t), 1)
				end),
				BackgroundColor3 = props.clock:map(function(clock: Clock): Color3
					local charge = charge_of(card, clock.t)
					return WHITE:Lerp(card.tier.color, charge * charge)
				end),
			}),
		}),
	})
end

-- The face of a card: the def's model turning, its name, what it is, and what it is for.
local function CardFace(props: { card: Card, clock: Binding })
	local card = props.card
	local def = unit_defs.get(card.def_name)
	local kind = if def.subtitle ~= nil then def.subtitle elseif def.kind == "building" then "Building" else "Unit"
	local description = unit_descriptions[card.def_name]
	return React.createElement("Frame", {
		[React.Tag] = `unlock-card-face {card.tier.tag}`,
		Visible = props.clock:map(function(clock: Clock): boolean
			return clock.t >= card.burst_at + FLIP_HALF
		end),
	}, {
		Art = React.createElement("Frame", {
			[React.Tag] = "unlock-card-art",
			LayoutOrder = 1,
		}, {
			Model = React.createElement(UnitPicture, {
				def_name = card.def_name,
				tag = "unlock-card-model",
				Position = CENTER,
				spin = MODEL_SPIN,
				fallback = def.display_name,
			}),
		}),
		Name = React.createElement("TextLabel", {
			[React.Tag] = "unlock-card-name",
			LayoutOrder = 2,
			Text = def.display_name,
		}),
		Kind = React.createElement("TextLabel", {
			[React.Tag] = "unlock-card-kind",
			LayoutOrder = 3,
			Text = kind,
		}),
		Description = if description ~= nil and description.text ~= nil
			then React.createElement("TextLabel", {
				[React.Tag] = "unlock-card-text",
				LayoutOrder = 4,
				Text = description.text,
			})
			else nil,
	})
end

-- One card and everything round it, in its place in the row. Once open it is a button: see TOUCH_SECONDS.
local function CardSlot(props: { card: Card, clock: Binding })
	local card = props.card
	local clock = props.clock
	local touch = React.useMemo(new_touch, {})

	local function now(): number
		return clock:getValue().now
	end
	local handled = clock:map(function(value: Clock): Handling
		return handling(card, touch, value)
	end)

	local body = React.createElement("ImageButton", {
		[React.Tag] = "unlock-card",
		AutoButtonColor = false,
		AnchorPoint = MIDDLE,
		ZIndex = 4,
		Visible = clock:map(function(value: Clock): boolean
			return value.t >= card.deal_at
		end),
		-- dealt up from below, overshooting; shaking as it charges; lifted while hovered
		Position = clock:map(function(value: Clock): UDim2
			local deal =
				ease(through(value.t, card.deal_at, DEAL_SECONDS), Enum.EasingStyle.Back, Enum.EasingDirection.Out)
			local shake = if value.t < card.burst_at then charge_of(card, value.t) ^ 2 * SHAKE_PIXELS else 0
			local x = math.sin(value.now * SHAKE_RATE * math.pi * 2) * shake
			local y = math.cos(value.now * SHAKE_RATE * 1.7 * math.pi) * shake * 0.6
			local lift = HOVER_LIFT * handling(card, touch, value).hover
			return UDim2.new(0.5, x, 0.5, DEAL_DROP * (1 - deal) + y - lift)
		end),
		-- wiggling as a click's punch wears off
		Rotation = clock:map(function(value: Clock): number
			local deal =
				ease(through(value.t, card.deal_at, DEAL_SECONDS), Enum.EasingStyle.Quad, Enum.EasingDirection.Out)
			local turn = (1 - deal) * DEAL_TURN * (if card.index % 2 == 0 then 1 else -1)
			local shake = if value.t < card.burst_at then charge_of(card, value.t) ^ 2 * SHAKE_DEGREES else 0
			local punch = handling(card, touch, value).punch
			local wiggle = if punch ~= 0 then CLICK_TURN * punch * math.sin((value.now - touch.clicked_at) * 30) else 0
			return turn + math.sin(value.now * SHAKE_RATE * 1.3 * math.pi * 2) * shake + wiggle
		end),
		-- folding edge on and opening again on its face
		Size = clock:map(function(value: Clock): UDim2
			local since = value.t - card.burst_at
			if since < 0 then
				return UDim2.fromScale(1, 1)
			elseif since < FLIP_HALF then
				return UDim2.fromScale(1 - since / FLIP_HALF, 1)
			end
			local open = ease((since - FLIP_HALF) / FLIP_OPEN_SECONDS, Enum.EasingStyle.Back, Enum.EasingDirection.Out)
			return UDim2.fromScale(math.max(open, 0), 1)
		end),
		[React.Event.MouseEnter] = function()
			touch.hovered_at = now()
			ease_to(touch.hover, 1, now())
		end,
		[React.Event.MouseLeave] = function()
			ease_to(touch.hover, 0, now())
			ease_to(touch.press, 0, now())
		end,
		[React.Event.InputBegan] = function(_: GuiObject, input: InputObject)
			local kind = input.UserInputType
			if kind == Enum.UserInputType.MouseButton1 or kind == Enum.UserInputType.Touch then
				ease_to(touch.press, 1, now())
			end
		end,
		[React.Event.InputEnded] = function(_: GuiObject, input: InputObject)
			local kind = input.UserInputType
			if kind == Enum.UserInputType.MouseButton1 or kind == Enum.UserInputType.Touch then
				ease_to(touch.press, 0, now())
			end
		end,
		[React.Event.Activated] = function()
			if clock:getValue().t >= card.burst_at + FLIP_HALF then
				touch.clicked_at = now()
			end
		end,
	}, {
		Scale = React.createElement("UIScale", {
			Scale = clock:map(function(value: Clock): number
				if value.t < card.burst_at then
					local deal = ease(
						through(value.t, card.deal_at, DEAL_SECONDS),
						Enum.EasingStyle.Back,
						Enum.EasingDirection.Out
					)
					return lerp(DEAL_SCALE, 1, deal) + CHARGE_SWELL * charge_of(card, value.t)
				end
				local pop = ease(
					through(value.t, card.burst_at, POP_SECONDS),
					Enum.EasingStyle.Elastic,
					Enum.EasingDirection.Out
				)
				local feel = handling(card, touch, value)
				return lerp(POP_FROM, 1, pop)
					* (1 + HOVER_SWELL * feel.hover - PRESS_SQUEEZE * feel.press + CLICK_PUNCH * feel.punch)
			end),
		}),
		Back = React.createElement(CardBack, { card = card, clock = clock }),
		Face = React.createElement(CardFace, { card = card, clock = clock }),
		-- whitening as it charges, a full flash as it bursts, then gone
		Flash = fx({
			AnchorPoint = Vector2.zero,
			Size = UDim2.fromScale(1, 1),
			BackgroundColor3 = WHITE,
			ZIndex = 5,
			BackgroundTransparency = clock:map(function(value: Clock): number
				if value.t < card.burst_at then
					return 1 - 0.45 * charge_of(card, value.t) ^ 3
				end
				return ease(
					through(value.t, card.burst_at, FLASH_SECONDS),
					Enum.EasingStyle.Quad,
					Enum.EasingDirection.In
				)
			end),
		}),
		-- tinted the tier's colour and rimmed in white while hovered, flashing a little brighter as it is clicked
		Rim = fx({
			AnchorPoint = Vector2.zero,
			Size = UDim2.fromScale(1, 1),
			BackgroundColor3 = card.tier.color,
			ZIndex = 5,
			BackgroundTransparency = handled:map(function(feel: Handling): number
				return 1 - 0.1 * feel.hover - 0.25 * feel.punch
			end),
		}, {
			Stroke = React.createElement("UIStroke", {
				Color = WHITE,
				Thickness = 2,
				Transparency = handled:map(function(feel: Handling): number
					return 1 - 0.85 * math.max(feel.hover, feel.punch)
				end),
			}),
		}),
		-- a band of light sweeping across it as the pointer comes over it
		Shine = fx({
			AnchorPoint = Vector2.zero,
			Size = UDim2.fromScale(1, 1),
			BackgroundTransparency = 1,
			ClipsDescendants = true,
			ZIndex = 5,
			Visible = handled:map(function(feel: Handling): boolean
				return feel.since_hover < SHINE_SECONDS
			end),
		}, {
			Band = fx({
				Size = UDim2.fromScale(0.35, 1.6),
				Rotation = 20,
				BackgroundColor3 = WHITE,
				BackgroundTransparency = 0.55,
				Position = handled:map(function(feel: Handling): UDim2
					local sweep = ease(
						through(feel.since_hover, 0, SHINE_SECONDS),
						Enum.EasingStyle.Quad,
						Enum.EasingDirection.InOut
					)
					return UDim2.fromScale(lerp(-0.3, 1.3, sweep), 0.5)
				end),
			}, {
				Fade = React.createElement("UIGradient", { Transparency = GLOW_FADE }),
			}),
		}),
		New = React.createElement("TextLabel", {
			[React.Tag] = "unlock-card-new",
			Text = "NEW!",
			Visible = clock:map(function(value: Clock): boolean
				return value.t >= card.burst_at + BANNER_AT
			end),
		}),
	})

	local banner = React.createElement("TextLabel", {
		[React.Tag] = `unlock-banner {card.tier.tag}`,
		Text = card.tier.label,
		AnchorPoint = MIDDLE,
		ZIndex = 7,
		Visible = clock:map(function(value: Clock): boolean
			return value.t >= card.burst_at + BANNER_AT
		end),
		-- riding up with the card as it lifts, and straightening out
		Position = handled:map(function(feel: Handling): UDim2
			return UDim2.new(0.5, 0, 0, -HOVER_LIFT * feel.hover)
		end),
		Rotation = clock:map(function(value: Clock): number
			local alpha = through(value.t, card.burst_at + BANNER_AT, BANNER_SECONDS)
			local rest =
				lerp(BANNER_TURN, BANNER_REST_TURN, ease(alpha, Enum.EasingStyle.Back, Enum.EasingDirection.Out))
			return lerp(rest, 0, handling(card, touch, value).hover)
		end),
	}, {
		Scale = React.createElement("UIScale", {
			Scale = clock:map(function(value: Clock): number
				local alpha = through(value.t, card.burst_at + BANNER_AT, BANNER_SECONDS)
				local feel = handling(card, touch, value)
				return lerp(BANNER_FROM, 1, ease(alpha, Enum.EasingStyle.Back, Enum.EasingDirection.Out))
					* (1 + 0.1 * feel.hover + 0.2 * feel.punch)
			end),
		}),
	})

	local function since_burst(value: Clock): number
		return value.t - card.burst_at
	end
	local function since_click(value: Clock): number
		return value.now - touch.clicked_at
	end

	return React.createElement("Frame", {
		[React.Tag] = "unlock-slot",
		LayoutOrder = card.index,
	}, {
		Glow = React.createElement(Glow, { card = card, clock = clock, touch = touch }),
		Rays = React.createElement(Rays, { card = card, clock = clock, touch = touch }),
		Ring = React.createElement(Ring, { card = card, clock = clock, since = since_burst }),
		ClickRing = React.createElement(Ring, { card = card, clock = clock, since = since_click }),
		Card = body,
		Sparks = React.createElement(Sparks, { card = card, clock = clock, since = since_burst, turn = 0 }),
		ClickSparks = React.createElement(Sparks, { card = card, clock = clock, since = since_click, turn = 0.5 }),
		Twinkles = React.createElement(Twinkles, { card = card, clock = clock }),
		Banner = banner,
		ScreenFlash = fx({
			Position = CENTER,
			Size = UDim2.fromOffset(SCREEN_FLASH_SIZE, SCREEN_FLASH_SIZE),
			BackgroundColor3 = WHITE,
			ZIndex = 8,
			Visible = clock:map(function(value: Clock): boolean
				return value.t >= card.burst_at and value.t < card.burst_at + SCREEN_FLASH_SECONDS
			end),
			BackgroundTransparency = clock:map(function(value: Clock): number
				local fade = through(value.t, card.burst_at, SCREEN_FLASH_SECONDS)
				return lerp(SCREEN_FLASH, 1, ease(fade, Enum.EasingStyle.Quad, Enum.EasingDirection.Out))
			end),
		}),
	})
end

-- The reveal of `def_names`, a card each: a heading with a tally, the cards, and a hint that a click skips ahead.
-- `on_done` is called once every card is open.
local function UnlockReveal(props: { def_names: { string }, on_done: (() -> ())?, LayoutOrder: number? })
	local key = table.concat(props.def_names, ",")
	local reveal = React.useMemo(function(): Plan
		return plan(props.def_names)
	end, { key })
	local clock, done = use_clock(reveal.done_at)

	local on_done = props.on_done
	React.useEffect(function()
		if done and on_done ~= nil then
			on_done()
		end
	end, { done })

	local total = #reveal.cards
	local cards: { [string]: any } = {}
	for _, card in reveal.cards do
		cards[card.def_name] = React.createElement(CardSlot, { card = card, clock = clock })
	end

	return React.createElement("Frame", {
		[React.Tag] = "unlock-reveal",
		LayoutOrder = props.LayoutOrder,
	}, {
		Header = React.createElement("Frame", {
			[React.Tag] = "unlock-header",
			LayoutOrder = 1,
			Visible = clock:map(function(value: Clock): boolean
				return value.t >= HEADER_AT
			end),
		}, {
			Scale = React.createElement("UIScale", {
				Scale = clock:map(function(value: Clock): number
					local pop = through(value.t, HEADER_AT, HEADER_SECONDS)
					return ease(pop, Enum.EasingStyle.Back, Enum.EasingDirection.Out)
				end),
			}),
			Title = React.createElement("TextLabel", {
				[React.Tag] = "unlock-title",
				LayoutOrder = 1,
				Text = "NEW UNLOCKS",
			}),
			Tally = React.createElement("TextLabel", {
				[React.Tag] = "unlock-tally",
				LayoutOrder = 2,
				Text = clock:map(function(value: Clock): string
					local count = opened(reveal.cards, value.t)
					return if count >= total then `{total} NEW` else `{count} / {total}`
				end),
			}, {
				-- jumps each time the count goes up
				Scale = React.createElement("UIScale", {
					Scale = clock:map(function(value: Clock): number
						local latest = -math.huge
						for _, card in reveal.cards do
							if value.t >= card.burst_at + FLIP_HALF then
								latest = card.burst_at + FLIP_HALF
							end
						end
						local settle =
							ease(through(value.t, latest, 0.4), Enum.EasingStyle.Back, Enum.EasingDirection.Out)
						return lerp(1.5, 1, settle)
					end),
				}),
			}),
		}),
		Cards = React.createElement("Frame", {
			[React.Tag] = "unlock-cards",
			LayoutOrder = 2,
		}, cards),
		Hint = React.createElement("TextLabel", {
			[React.Tag] = "unlock-hint",
			LayoutOrder = 3,
			Text = clock:map(function(value: Clock): string
				return if value.t < reveal.done_at then "CLICK TO SKIP" else ""
			end),
		}),
	})
end

-- The edges of the screen darkening behind a reveal, fading in: one band across and one down, each dark at its ends.
local function UnlockVignette()
	local fade, set_fade = React.useBinding(1)
	React.useEffect(function()
		local began = os.clock()
		local stepped: RBXScriptConnection
		stepped = RunService.RenderStepped:Connect(function()
			local alpha = through(os.clock(), began, VIGNETTE_SECONDS)
			set_fade(lerp(1, VIGNETTE_DARKNESS, ease(alpha, Enum.EasingStyle.Quad, Enum.EasingDirection.Out)))
			if alpha >= 1 then
				stepped:Disconnect()
			end
		end)
		return function()
			stepped:Disconnect()
		end
	end, {})

	local bands: { [string]: any } = {}
	for index, rotation in { 0, 90 } do
		bands[`Band{index}`] = fx({
			AnchorPoint = Vector2.zero,
			Size = UDim2.fromScale(1, 1),
			BackgroundColor3 = BLACK,
			BackgroundTransparency = fade,
		}, {
			Fade = React.createElement("UIGradient", { Transparency = VIGNETTE_FADE, Rotation = rotation }),
		})
	end
	return React.createElement("Frame", { [React.Tag] = "unlock-vignette" }, bands)
end

return table.freeze({
	TIERS = TIERS,
	UnlockReveal = UnlockReveal,
	UnlockVignette = UnlockVignette,
	tier_of = tier_of,
})
