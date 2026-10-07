--!strict
-- A replay being watched (server/replay.luau), as a video player shows one: a bar along the bottom with play and pause,
-- the time played and the time left, a track of the whole game to click or drag along to go to any moment of it, and
-- how fast it plays. The one watching who has the controls (the server's `replay_controller`) seeks and plays; anyone
-- else only watches. A mark on the track stands at every jump point, where a seek lands at once; anywhere else the
-- server plays on to it from the one before, or from where it is, if that is nearer. Under the bar, whether the replay
-- is still the recorded game.

local Players = game:GetService "Players"
local ReplicatedStorage = game:GetService "ReplicatedStorage"
local UserInputService = game:GetService "UserInputService"
local Workspace = game:GetService "Workspace"

local React = require(ReplicatedStorage.Packages.react)

local switches = require(ReplicatedStorage.Shared.switches)

local control: RemoteEvent = ReplicatedStorage.Shared.ReplayControl

-- An element's properties: strict mode cannot type a table of them that mixes tags, properties and handlers.
type Props = { [any]: any }

-- What the server publishes on Workspace (server/replay.luau's REPLAY_ATTRIBUTES).
local ATTRIBUTES = {
	time = "replay_time",
	length = "replay_length",
	status = "replay_status",
	controller = "replay_controller",
	speed = "replay_speed",
	seeking = "replay_seeking",
	jump_every = "replay_jump_every",
}
-- The speeds the speed button goes through, in turn.
local SPEEDS = { 1, 2, 4, 8 }

type Replay = {
	time: number,
	length: number,
	status: string,
	controller: number?,
	speed: number,
	seeking: boolean,
	jump_every: number?,
	paused: boolean,
}

local function read(): Replay?
	local length = Workspace:GetAttribute(ATTRIBUTES.length)
	if typeof(length) ~= "number" or length <= 0 then
		return nil
	end
	local time = Workspace:GetAttribute(ATTRIBUTES.time)
	local status = Workspace:GetAttribute(ATTRIBUTES.status)
	local controller = Workspace:GetAttribute(ATTRIBUTES.controller)
	local speed = Workspace:GetAttribute(ATTRIBUTES.speed)
	local jump_every = Workspace:GetAttribute(ATTRIBUTES.jump_every)
	return {
		time = if typeof(time) == "number" then time else 0,
		length = length,
		status = if typeof(status) == "string" then status else "",
		controller = if typeof(controller) == "number" then controller else nil,
		speed = if typeof(speed) == "number" then speed else 1,
		seeking = Workspace:GetAttribute(ATTRIBUTES.seeking) == true,
		jump_every = if typeof(jump_every) == "number" then jump_every else nil,
		paused = switches.is_on "paused",
	}
end

-- The replay as it stands, redrawn whenever anything of it changes.
local function use_replay(): Replay?
	local replay, set_replay = React.useState(read)
	React.useEffect(function(): () -> ()
		local connections: { RBXScriptConnection } = {}
		local function refresh()
			set_replay(read())
		end
		for _, name in ATTRIBUTES do
			table.insert(connections, Workspace:GetAttributeChangedSignal(name):Connect(refresh))
		end
		local stop_pause = switches.changed("paused", refresh)
		return function()
			for _, connection in connections do
				connection:Disconnect()
			end
			stop_pause()
		end
	end, {})
	return replay
end

-- Seconds as m:ss.
local function clock(seconds: number): string
	-- a game's clock is a sum of step lengths, a hair under a whole second where it should be on one
	local whole = math.max(0, math.floor(seconds + 1e-6))
	return `{whole // 60}:{string.format("%02d", whole % 60)}`
end

-- A console button with its words on a label of their own, so that the gradient on its face leaves them alone.
local function Button(props: { text: string, enabled: boolean, on_click: () -> (), LayoutOrder: number })
	return React.createElement(
		"TextButton",
		{
			[React.Tag] = if props.enabled then "replay-button" else "replay-button disabled",
			LayoutOrder = props.LayoutOrder,
			Text = "",
			Active = props.enabled,
			AutoButtonColor = props.enabled,
			[React.Event.Activated] = function()
				if props.enabled then
					props.on_click()
				end
			end,
		} :: Props,
		{
			Label = React.createElement("TextLabel", {
				[React.Tag] = "replay-button-label",
				Text = props.text,
			}),
		}
	)
end

local function is_press(input: InputObject): boolean
	return input.UserInputType == Enum.UserInputType.MouseButton1 or input.UserInputType == Enum.UserInputType.Touch
end

local function is_move(input: InputObject): boolean
	return input.UserInputType == Enum.UserInputType.MouseMovement or input.UserInputType == Enum.UserInputType.Touch
end

local function ReplaySeeker()
	local replay = use_replay()
	local track_ref = React.useRef(nil :: GuiObject?)
	-- where the track is being dragged to, in seconds of game, while it is
	local dragging: number?, set_dragging = React.useState(nil :: number?)

	-- the moment under the screen position `x`
	local function moment_at(x: number): number
		local track = track_ref.current
		if replay == nil or track == nil or track.AbsoluteSize.X <= 0 then
			return 0
		end
		return math.clamp((x - track.AbsolutePosition.X) / track.AbsoluteSize.X, 0, 1) * replay.length
	end

	React.useEffect(function(): (() -> ())?
		if dragging == nil then
			return nil
		end
		local latest = dragging
		local on_move = UserInputService.InputChanged:Connect(function(input: InputObject)
			if is_move(input) then
				latest = moment_at(input.Position.X)
				set_dragging(latest)
			end
		end)
		local on_release = UserInputService.InputEnded:Connect(function(input: InputObject)
			if is_press(input) then
				control:FireServer("seek", latest)
				set_dragging(nil)
			end
		end)
		return function()
			on_move:Disconnect()
			on_release:Disconnect()
		end
	end, { dragging ~= nil })

	if replay == nil then
		return nil
	end
	local mine = replay.controller == Players.LocalPlayer.UserId
	local shown = if dragging ~= nil then dragging else math.min(replay.time, replay.length)
	local fraction = math.clamp(shown / replay.length, 0, 1)

	local marks: { [string]: any } = {}
	if replay.jump_every ~= nil and replay.jump_every > 0 then
		local at = replay.jump_every
		while at < replay.length do
			marks[`Mark{at}`] = React.createElement(
				"Frame",
				{
					[React.Tag] = "replay-mark",
					Position = UDim2.fromScale(at / replay.length, 0),
				} :: Props
			)
			at += replay.jump_every
		end
	end
	marks.Fill = React.createElement(
		"Frame",
		{
			[React.Tag] = "replay-fill",
			Size = UDim2.fromScale(fraction, 1),
		} :: Props
	)
	marks.Head = React.createElement(
		"Frame",
		{
			[React.Tag] = "replay-head",
			Position = UDim2.fromScale(fraction, 0.5),
		} :: Props
	)

	local speed_index = table.find(SPEEDS, replay.speed) or 1
	local status = if replay.seeking
		then "seeking…"
		elseif dragging ~= nil then `go to {clock(dragging)}`
		else replay.status
	return React.createElement("Frame", {
		[React.Tag] = "replay-seeker",
	}, {
		Bar = React.createElement("Frame", {
			[React.Tag] = "replay-bar",
			LayoutOrder = 1,
		}, {
			Play = React.createElement(Button, {
				text = if replay.paused then "PLAY" else "PAUSE",
				enabled = mine,
				on_click = function()
					control:FireServer(if replay.paused then "play" else "pause", 0)
				end,
				LayoutOrder = 1,
			}),
			Elapsed = React.createElement("TextLabel", {
				[React.Tag] = "replay-time",
				LayoutOrder = 2,
				Text = clock(shown),
			}),
			Track = React.createElement(
				"Frame",
				{
					[React.Tag] = "replay-track",
					LayoutOrder = 3,
					ref = track_ref,
					Active = mine,
					[React.Event.InputBegan] = function(_: Frame, input: InputObject)
						if mine and is_press(input) then
							set_dragging(moment_at(input.Position.X))
						end
					end,
				} :: Props,
				marks
			),
			Left = React.createElement("TextLabel", {
				[React.Tag] = "replay-time",
				LayoutOrder = 4,
				Text = `-{clock(replay.length - shown)}`,
			}),
			Speed = React.createElement(Button, {
				text = `{replay.speed}x`,
				enabled = mine,
				on_click = function()
					control:FireServer("speed", SPEEDS[speed_index % #SPEEDS + 1])
				end,
				LayoutOrder = 5,
			}),
		}),
		Status = React.createElement("TextLabel", {
			[React.Tag] = "replay-status",
			LayoutOrder = 2,
			Text = if mine then status else `{status} · view only`,
		}),
	})
end

return table.freeze({
	ReplaySeeker = ReplaySeeker,
})
