-- The wind, beside metal and energy in the resource bar: its speed, which is the length of the wind vector,
-- and a gauge of where that stands between the calmest and the hardest it can blow, with both written at the
-- ends. Behind them, streaks drift across the frame along the vector,
-- faster and longer the harder it blows, for the look of it.
--
-- The server sends the wind as the `wind` attribute of Workspace, a Vector2 of (x, z). The camera faces
-- -Z, so the top of the screen is -Z and the right is +X: the vector's x is across the frame and its z is
-- down it.

local ReplicatedStorage = game:GetService "ReplicatedStorage"
local RunService = game:GetService "RunService"
local Workspace = game:GetService "Workspace"

local React = require(ReplicatedStorage.Packages.react)

local config = require(ReplicatedStorage.Shared.config)

local STREAK_COUNT = 14
local STREAK_COLOR = Color3.fromRGB(96, 210, 242)
local STREAK_TRANSPARENCY = 0.75
local STREAK_THICKNESS = 1
-- A streak is this long even in a calm, and this much longer for every unit of wind speed.
local STREAK_BASE_LENGTH = 4
local STREAK_LENGTH_PER_SPEED = 1.5
-- How fast streaks travel, in pixels a second for every unit of wind speed.
local PIXELS_PER_SPEED = 8
-- The wind shown eases toward the wind the server sends rather than jumping to it: it closes most of the gap in a
-- couple of these time constants. The readout is redrawn at this interval, and only when it has moved enough to see.
local EASE_SECONDS = 1
local READOUT_INTERVAL = 0.05
local READOUT_MIN_CHANGE = 0.02

local function read_wind(): Vector2
	local wind = Workspace:GetAttribute "wind"
	if typeof(wind) == "Vector2" then
		return wind
	end
	return Vector2.zero
end

local function WindBlock(props: { LayoutOrder: number })
	-- what is drawn: the wind eased toward the one the server has, which is `target_ref`
	local wind, set_wind = React.useState(read_wind())
	local target_ref = React.useRef(wind)
	-- the drifting reads the wind being shown every frame without being re-created by it
	local wind_ref = React.useRef(wind)
	local field_ref = React.useRef(nil :: Frame?)

	React.useEffect(function()
		local connection = Workspace:GetAttributeChangedSignal("wind"):Connect(function()
			target_ref.current = read_wind()
		end)

		local since_readout = 0
		local last_readout = wind_ref.current
		local ease = RunService.Heartbeat:Connect(function(delta: number)
			local blend = 1 - math.exp(-delta / EASE_SECONDS)
			wind_ref.current = wind_ref.current:Lerp(target_ref.current, blend)
			since_readout += delta
			if since_readout >= READOUT_INTERVAL then
				since_readout = 0
				if (wind_ref.current - last_readout).Magnitude >= READOUT_MIN_CHANGE then
					last_readout = wind_ref.current
					set_wind(wind_ref.current)
				end
			end
		end)
		return function()
			connection:Disconnect()
			ease:Disconnect()
		end
	end, {})

	React.useEffect(function()
		local field = field_ref.current
		if field == nil then
			return
		end

		local random = Random.new(11)
		local streaks: { { frame: Frame, x: number, y: number } } = {}
		for index = 1, STREAK_COUNT do
			local frame = Instance.new "Frame"
			frame.Name = `Streak{index}`
			frame.BorderSizePixel = 0
			frame.BackgroundColor3 = STREAK_COLOR
			frame.BackgroundTransparency = STREAK_TRANSPARENCY
			frame.AnchorPoint = Vector2.new(0.5, 0.5)
			frame.Size = UDim2.fromOffset(STREAK_BASE_LENGTH, STREAK_THICKNESS)
			frame.Parent = field
			table.insert(streaks, { frame = frame, x = random:NextNumber(), y = random:NextNumber() })
		end

		local connection = RunService.Heartbeat:Connect(function(delta: number)
			local size = field.AbsoluteSize
			if size.X <= 0 or size.Y <= 0 then
				return
			end
			local current = wind_ref.current
			local speed = current.Magnitude
			local angle = math.deg(math.atan2(current.Y, current.X))
			local length = STREAK_BASE_LENGTH + speed * STREAK_LENGTH_PER_SPEED
			for _, streak in streaks do
				-- positions are fractions of the frame, so they wrap around its edges
				streak.x = (streak.x + current.X * PIXELS_PER_SPEED * delta / size.X) % 1
				streak.y = (streak.y + current.Y * PIXELS_PER_SPEED * delta / size.Y) % 1
				streak.frame.Position = UDim2.fromScale(streak.x, streak.y)
				streak.frame.Size = UDim2.fromOffset(length, STREAK_THICKNESS)
				streak.frame.Rotation = angle
			end
		end)
		return function()
			connection:Disconnect()
			for _, streak in streaks do
				streak.frame:Destroy()
			end
		end
	end, {})

	-- how far the speed is between the lowest and the highest it can be
	local fraction =
		math.clamp((wind.Magnitude - config.MIN_WIND) / math.max(config.MAX_WIND - config.MIN_WIND, 1e-6), 0, 1)

	return React.createElement("Frame", {
		[React.Tag] = "wind-block",
		LayoutOrder = props.LayoutOrder,
	}, {
		Field = React.createElement("Frame", {
			[React.Tag] = "wind-field",
			ref = field_ref,
			ZIndex = 1,
			ClipsDescendants = true,
		}),
		Content = React.createElement("Frame", {
			[React.Tag] = "wind-content",
			ZIndex = 2,
		}, {
			Head = React.createElement("Frame", {
				[React.Tag] = "wind-head",
				LayoutOrder = 1,
			}, {
				Label = React.createElement("TextLabel", {
					[React.Tag] = "resource-name grow",
					LayoutOrder = 1,
					Text = "WIND",
				}),
				Speed = React.createElement("TextLabel", {
					[React.Tag] = "wind-speed",
					LayoutOrder = 2,
					Text = string.format("%.1f", wind.Magnitude),
				}),
			}),
			Gauge = React.createElement("Frame", {
				[React.Tag] = "wind-gauge",
				LayoutOrder = 2,
			}, {
				Fill = React.createElement("Frame", {
					[React.Tag] = "wind-gauge-fill",
					Size = UDim2.new(fraction, 0, 1, 0),
				}),
			}),
			Range = React.createElement("Frame", {
				[React.Tag] = "wind-range",
				LayoutOrder = 3,
			}, {
				Min = React.createElement("TextLabel", {
					[React.Tag] = "wind-limit grow",
					LayoutOrder = 1,
					Text = `MIN {config.MIN_WIND}`,
				}),
				Max = React.createElement("TextLabel", {
					[React.Tag] = "wind-limit right",
					LayoutOrder = 2,
					Text = `MAX {config.MAX_WIND}`,
				}),
			}),
		}),
	})
end

return table.freeze({
	WindBlock = WindBlock,
})
