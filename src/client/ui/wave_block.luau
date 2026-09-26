-- A mission's waves, in a box of their own at the top of the mission's guide (ui/tutorial.luau): the time until the
-- next wave's enemies arrive and which wave that is of how many, and once the final wave has arrived, how many of the
-- enemy's are left. The server publishes them (Shared.mission_state) only while such a mission is played. A mission
-- with a time limit has the time left in the same box instead.

local ReplicatedStorage = game:GetService "ReplicatedStorage"

local React = require(ReplicatedStorage.Packages.react)

local mission_state = require(ReplicatedStorage.Shared.mission_state)

local format = require(ReplicatedStorage.ClientShared.format)
local use_store = require(ReplicatedStorage.ClientShared.use_store)

type Waves = mission_state.Waves

-- The waves as they stand, or nil outside a mission with waves.
local function use_waves(): Waves?
	return use_store.use_store(mission_state.waves, mission_state.subscribe_waves)
end

-- One half of the box: a caption over a big readout.
local function Readout(props: { caption: string, value: string, tone: string?, LayoutOrder: number })
	return React.createElement("Frame", {
		[React.Tag] = "wave-readout",
		LayoutOrder = props.LayoutOrder,
	}, {
		Caption = React.createElement("TextLabel", {
			[React.Tag] = "wave-caption",
			LayoutOrder = 1,
			Text = props.caption,
		}),
		Value = React.createElement("TextLabel", {
			[React.Tag] = if props.tone ~= nil then `wave-value {props.tone}` else "wave-value",
			LayoutOrder = 2,
			Text = props.value,
		}),
	})
end

-- ENEMIES IN 4:05 | WAVE 2/7, or once the last has arrived, FINAL WAVE | 12 LEFT; and for a mission lost once enough
-- of the enemy get through, ESCAPED 3/10 after either.
local function WaveBox(props: { LayoutOrder: number, waves: Waves })
	local waves = props.waves
	local final = waves.wave_in == nil and waves.wave > 0
	return React.createElement("Frame", {
		[React.Tag] = "wave-box",
		LayoutOrder = props.LayoutOrder,
	}, {
		When = if final
			then React.createElement(Readout, {
				caption = "FINAL WAVE",
				value = `{waves.waves}/{waves.waves}`,
				LayoutOrder = 1,
			})
			else React.createElement(Readout, {
				caption = "ENEMIES IN",
				value = format.clock(waves.wave_in or 0),
				tone = "danger",
				LayoutOrder = 1,
			}),
		Divider = React.createElement("Frame", {
			[React.Tag] = "wave-divider",
			LayoutOrder = 2,
		}),
		Which = if final
			then React.createElement(Readout, {
				caption = "ENEMIES LEFT",
				value = tostring(waves.left),
				tone = "danger",
				LayoutOrder = 3,
			})
			else React.createElement(Readout, {
				caption = "WAVE",
				value = `{waves.wave + 1}/{waves.waves}`,
				LayoutOrder = 3,
			}),
		EscapedDivider = if waves.escape_limit ~= nil
			then React.createElement("Frame", {
				[React.Tag] = "wave-divider",
				LayoutOrder = 4,
			})
			else nil,
		Escaped = if waves.escape_limit ~= nil
			then React.createElement(Readout, {
				caption = "ESCAPED",
				value = `{waves.escaped or 0}/{waves.escape_limit}`,
				tone = "danger",
				LayoutOrder = 5,
			})
			else nil,
	})
end

-- How long is left before a mission with a time limit is lost, or nil outside one.
local function use_time_left(): number?
	return use_store.use_store(mission_state.time_left, mission_state.subscribe_time_left)
end

-- The time left under LOW_TIME seconds reads as danger.
local LOW_TIME = 60

-- TIME LEFT 12:30, in the wave box's plate.
local function TimeBox(props: { LayoutOrder: number, seconds: number })
	return React.createElement("Frame", {
		[React.Tag] = "wave-box",
		LayoutOrder = props.LayoutOrder,
	}, {
		Left = React.createElement(Readout, {
			caption = "TIME LEFT",
			value = format.clock(props.seconds),
			tone = if props.seconds < LOW_TIME then "danger" else nil,
			LayoutOrder = 1,
		}),
	})
end

return table.freeze({
	use_waves = use_waves,
	use_time_left = use_time_left,
	WaveBox = WaveBox,
	TimeBox = TimeBox,
})
