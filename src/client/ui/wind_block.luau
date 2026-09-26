-- The wind, beside metal and energy in the resource bar: its speed, which is the length of the wind vector,
-- and a gauge of where that stands between the calmest and the hardest it can blow, with both written at the
-- ends. Behind them, streaks drift across the frame along the vector,
-- faster and longer the harder it blows, for the look of it.
--
-- It shows the wind as the client draws it (Client.wind), eased toward the one the server sends, as the rain and the
-- grass do. The camera faces -Z, so the top of the screen is -Z and the right is +X: the wind's x is across the frame
-- and its z is down it.

local ReplicatedStorage = game:GetService "ReplicatedStorage"
local RunService = game:GetService "RunService"

local React = require(ReplicatedStorage.Packages.react)

local environment = require(ReplicatedStorage.Shared.environment)

local wind_mod = require(ReplicatedStorage.Client.wind)

local palette = require(ReplicatedStorage.ClientShared.palette)

local STREAK_COUNT = 14
local STREAK_COLOR = palette.accent
local STREAK_TRANSPARENCY = 0.75
local STREAK_THICKNESS = 1
-- A streak is this long even in a calm, and this much longer for every unit of wind speed.
local STREAK_BASE_LENGTH = 4
local STREAK_LENGTH_PER_SPEED = 1.5
-- How fast streaks travel, in pixels a second for every unit of wind speed.
local PIXELS_PER_SPEED = 8
-- The readout is redrawn at this interval, and only when the wind has moved enough to see.
local READOUT_INTERVAL = 0.05
local READOUT_MIN_CHANGE = 0.02

-- The wind as it is drawn, across the frame (x) and down it (z).
local function read_wind(): Vector2
	local wind = wind_mod.now()
	return Vector2.new(wind.X, wind.Z)
end

local function WindBlock(props: { LayoutOrder: number })
	local wind, set_wind = React.useState(read_wind)
	local field_ref = React.useRef(nil :: Frame?)

	React.useEffect(function()
		local since_readout = 0
		local last_readout = read_wind()
		local follow = RunService.Heartbeat:Connect(function(delta: number)
			since_readout += delta
			if since_readout >= READOUT_INTERVAL then
				since_readout = 0
				local current = read_wind()
				if (current - last_readout).Magnitude >= READOUT_MIN_CHANGE then
					last_readout = current
					set_wind(current)
				end
			end
		end)
		return function()
			follow:Disconnect()
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
			local current = read_wind()
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

	-- how far the speed is between the lowest and the highest it can be on this map
	local least = environment.min_wind()
	local most = environment.max_wind()
	local fraction = math.clamp((wind.Magnitude - least) / math.max(most - least, 1e-6), 0, 1)

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
					Size = UDim2.fromScale(fraction, 1),
				}),
			}),
			Range = React.createElement("Frame", {
				[React.Tag] = "wind-range",
				LayoutOrder = 3,
			}, {
				Min = React.createElement("TextLabel", {
					[React.Tag] = "wind-limit grow",
					LayoutOrder = 1,
					Text = `MIN {least}`,
				}),
				Max = React.createElement("TextLabel", {
					[React.Tag] = "wind-limit right",
					LayoutOrder = 2,
					Text = `MAX {most}`,
				}),
			}),
		}),
	})
end

return table.freeze({
	WindBlock = WindBlock,
})
