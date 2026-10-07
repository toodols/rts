--!strict
-- The levels a lobby lets in, as a slider: a track banded in the ranks' tier colours (rank.luau) with a tick every
-- protocol.LEVEL_STEP, the range lit and the rest shaded, and at either end of it a rank to drag. The host drags either
-- end, or presses the track to bring the nearer end there; the range is asked for once it is let go. Everyone else
-- only sees it.

local ReplicatedStorage = game:GetService "ReplicatedStorage"
local UserInputService = game:GetService "UserInputService"

local React = require(ReplicatedStorage.Packages.react)

local protocol = require(ReplicatedStorage.Lobby.protocol)

local rank = require(script.Parent.rank)

-- An element's properties: strict mode cannot type a table of them that mixes tags, properties and handlers.
type Props = { [any]: any }

type End = "low" | "high"
-- the end being dragged, if either
type Held = End | "none"

local SPAN = protocol.LEVEL_MAX - protocol.LEVEL_MIN

local function is_press(input: InputObject): boolean
	return input.UserInputType == Enum.UserInputType.MouseButton1 or input.UserInputType == Enum.UserInputType.Touch
end

local function is_move(input: InputObject): boolean
	return input.UserInputType == Enum.UserInputType.MouseMovement or input.UserInputType == Enum.UserInputType.Touch
end

-- Where `level` is along the track, from 0 to 1.
local function along(level: number): number
	return (level - protocol.LEVEL_MIN) / SPAN
end

local function LevelRange(props: {
	min: number,
	max: number,
	locked: boolean,
	on_change: (min: number, max: number) -> (),
	LayoutOrder: number,
})
	local rail_ref = React.useRef(nil :: GuiObject?)
	-- the end being dragged, and the range as it is dragged to
	local dragging: Held, set_dragging = React.useState("none" :: Held)
	local draft, set_draft = React.useState({ min = props.min, max = props.max })
	local shown = if dragging ~= "none" then draft else { min = props.min, max = props.max }

	-- the level under the screen position `x`, to the nearest step
	local function level_at(x: number): number
		local rail = rail_ref.current
		if rail == nil or rail.AbsoluteSize.X <= 0 then
			return protocol.LEVEL_MIN
		end
		local fraction = math.clamp((x - rail.AbsolutePosition.X) / rail.AbsoluteSize.X, 0, 1)
		local step = protocol.LEVEL_STEP
		return protocol.LEVEL_MIN + math.round(fraction * SPAN / step) * step
	end

	local function moved(range: { min: number, max: number }, which: End, level: number): { min: number, max: number }
		if which == "low" then
			return { min = math.min(level, range.max), max = range.max }
		end
		return { min = range.min, max = math.max(level, range.min) }
	end

	React.useEffect(function(): (() -> ())?
		if dragging == "none" then
			return nil
		end
		local which: End = dragging
		local latest = draft
		local on_move = UserInputService.InputChanged:Connect(function(input: InputObject)
			if is_move(input) then
				latest = moved(latest, which, level_at(input.Position.X))
				set_draft(latest)
			end
		end)
		local on_end = UserInputService.InputEnded:Connect(function(input: InputObject)
			if is_press(input) then
				set_dragging "none"
				if latest.min ~= props.min or latest.max ~= props.max then
					props.on_change(latest.min, latest.max)
				end
			end
		end)
		return function()
			on_move:Disconnect()
			on_end:Disconnect()
		end
	end, { dragging })

	local function on_press(_rail: GuiObject, input: InputObject)
		if props.locked or is_press(input) == false then
			return
		end
		local level = level_at(input.Position.X)
		local current = { min = props.min, max = props.max }
		-- the nearer end, and between two ends at one level, whichever can move that way
		local which: End = if math.abs(level - current.min) < math.abs(level - current.max)
			then "low"
			elseif math.abs(level - current.min) > math.abs(level - current.max) then "high"
			elseif level < current.min then "low"
			else "high"
		set_draft(moved(current, which, level))
		set_dragging(which)
	end

	local marks: { [string]: any } = {}
	for index, tier in rank.TIERS do
		marks[`Band{index}`] = React.createElement("Frame", {
			[React.Tag] = `level-band {tier}`,
			Position = UDim2.fromScale(along((index - 1) * rank.TIER_SPAN), 0.5),
		})
	end
	for level = protocol.LEVEL_MIN, protocol.LEVEL_MAX, protocol.LEVEL_STEP do
		marks[`Tick{level}`] = React.createElement("Frame", {
			[React.Tag] = if level % rank.TIER_SPAN == 0 then "level-tick major" else "level-tick",
			Position = UDim2.new(along(level), 0, 0.5, 5),
		})
	end
	local low, high = along(shown.min), along(shown.max)
	marks.ShadeLow = React.createElement("Frame", {
		[React.Tag] = "level-shade",
		Position = UDim2.fromScale(0, 0.5),
		Size = UDim2.new(low, 0, 0, 10),
	})
	marks.ShadeHigh = React.createElement("Frame", {
		[React.Tag] = "level-shade",
		Position = UDim2.fromScale(high, 0.5),
		Size = UDim2.new(1 - high, 0, 0, 10),
	})
	marks.Window = React.createElement("Frame", {
		[React.Tag] = "level-window",
		Position = UDim2.fromScale(low, 0.5),
		Size = UDim2.new(high - low, 0, 0, 14),
	})
	marks.Low = React.createElement("Frame", {
		[React.Tag] = if dragging == "low" then "level-handle held" else "level-handle",
		Position = UDim2.fromScale(low, 0.5),
		ZIndex = 3,
	}, {
		Rank = React.createElement(rank.Insignia, { level = shown.min }),
	})
	marks.High = React.createElement("Frame", {
		[React.Tag] = if dragging == "high" then "level-handle held" else "level-handle",
		Position = UDim2.fromScale(high, 0.5),
		-- over the low end where they meet, so the upper can always be dragged back up
		ZIndex = 4,
	}, {
		Rank = React.createElement(rank.Insignia, { level = shown.max }),
	})

	return React.createElement("Frame", {
		[React.Tag] = if props.locked then "level-range locked" else "level-range",
		LayoutOrder = props.LayoutOrder,
	}, {
		Rail = React.createElement(
			"TextButton",
			{
				[React.Tag] = "level-rail",
				Text = "",
				AutoButtonColor = false,
				Active = not props.locked,
				ref = rail_ref,
				[React.Event.InputBegan] = on_press,
			} :: Props,
			marks
		),
	})
end

return table.freeze({
	LevelRange = LevelRange,
})
