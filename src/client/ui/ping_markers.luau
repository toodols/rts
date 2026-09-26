-- The name of the team that pinged, over each ping an ally or you made (client/pings.luau). While a ping is off
-- screen its name sits at the edge of the screen instead, the side it is on, behind an arrow pointing the way to it.
--
-- Like the world bars, everything is styled from the stylesheet by tag but for what it cannot know: the team's
-- colour, and where on the screen each marker goes, which follows the camera every frame and so is written straight
-- to the frames rather than going through a re-render.

local GuiService = game:GetService "GuiService"
local ReplicatedStorage = game:GetService "ReplicatedStorage"
local RunService = game:GetService "RunService"
local Workspace = game:GetService "Workspace"

local React = require(ReplicatedStorage.Packages.react)

local appearance = require(ReplicatedStorage.Shared.appearance)

local pings = require(ReplicatedStorage.Client.pings)

local format = require(ReplicatedStorage.ClientShared.format)
local use_store = require(ReplicatedStorage.ClientShared.use_store)

type Ping = pings.Ping

local PLACE_STEP = "rts_ping_markers"
-- How far above the top of a ping's column its name floats, in studs.
local NAME_GAP = 2
-- How far in from the edge of the screen an off-screen ping's arrow points from, in pixels, and how far the name
-- sits in from the arrow.
local EDGE_MARGIN = 28
local NAME_GAP_PIXELS = 12
-- The arrow is a chevron: two arms ARM_LENGTH pixels long, each ARM_SPREAD degrees off the way it points.
local ARM_LENGTH = 18
-- The name is the team's colour this far toward white, since a dark team colour is lost over dark ground.
local NAME_LIGHTEN = 0.5
local ARM_SPREAD = 40

type Parts = {
	marker: Frame,
	name: TextLabel,
	arms: { Frame },
}

local placed: { [Ping]: Parts } = {}

-- Puts one arm of the chevron whose tip is the marker's origin, pointing along `angle` (radians, screen space), turned
-- `side` ARM_SPREADs off it.
local function place_arm(arm: Frame, angle: number, side: number)
	-- the arm runs back from the tip
	local back = angle + math.pi + side * math.rad(ARM_SPREAD)
	local center = Vector2.new(math.cos(back), math.sin(back)) * (ARM_LENGTH / 2)
	arm.Position = UDim2.fromOffset(center.X, center.Y)
	arm.Rotation = math.deg(back)
	arm.Visible = true
end

local function place(camera: Camera, ping_info: Ping, parts: Parts)
	local viewport = camera.ViewportSize
	local top = Vector3.new(ping_info.at.X, ping_info.at.Y + pings.BEAM_HEIGHT + NAME_GAP, ping_info.at.Z)
	local point, on_screen = camera:WorldToViewportPoint(top)
	-- the foot counts too: a column whose top is off the top of the screen can still stand plainly in view
	local _, foot_on_screen = camera:WorldToViewportPoint(ping_info.at)
	if on_screen then
		parts.marker.Position = UDim2.fromOffset(math.floor(point.X), math.floor(point.Y))
		parts.name.AnchorPoint = Vector2.new(0.5, 1)
		parts.name.Position = UDim2.fromOffset(0, 0)
		for _, arm in parts.arms do
			arm.Visible = false
		end
		return
	end
	if foot_on_screen then
		local foot = camera:WorldToViewportPoint(ping_info.at)
		parts.marker.Position = UDim2.fromOffset(math.floor(foot.X), math.floor(foot.Y))
		parts.name.AnchorPoint = Vector2.new(0.5, 0)
		parts.name.Position = UDim2.fromOffset(0, 4)
		for _, arm in parts.arms do
			arm.Visible = false
		end
		return
	end

	-- off screen: the way to it from the middle of the screen, the other way if it is behind the camera
	local center = viewport / 2
	local toward = Vector2.new(point.X, point.Y) - center
	if point.Z < 0 then
		toward = -toward
	end
	if toward.Magnitude < 1e-3 then
		toward = Vector2.new(0, 1)
	end
	local unit = toward.Unit
	-- as far along that way as fits inside the margin, which clears the Roblox top bar along the top
	local inset = GuiService:GetGuiInset()
	local left, right = EDGE_MARGIN, viewport.X - EDGE_MARGIN
	local upper, lower = inset.Y + EDGE_MARGIN, viewport.Y - EDGE_MARGIN
	local reach_x = if unit.X > 0
		then (right - center.X) / unit.X
		elseif unit.X < 0 then (left - center.X) / unit.X
		else math.huge
	local reach_y = if unit.Y > 0
		then (lower - center.Y) / unit.Y
		elseif unit.Y < 0 then (upper - center.Y) / unit.Y
		else math.huge
	local edge = center + unit * math.min(reach_x, reach_y)
	parts.marker.Position = UDim2.fromOffset(math.floor(edge.X), math.floor(edge.Y))

	local angle = math.atan2(unit.Y, unit.X)
	place_arm(parts.arms[1], angle, 1)
	place_arm(parts.arms[2], angle, -1)
	-- the name hangs back from the arrow, into the screen
	parts.name.AnchorPoint = Vector2.new(0.5 + 0.5 * unit.X, 0.5 + 0.5 * unit.Y)
	local back = -unit * (ARM_LENGTH + NAME_GAP_PIXELS)
	parts.name.Position = UDim2.fromOffset(back.X, back.Y)
end

local function place_all()
	local camera = Workspace.CurrentCamera
	if camera == nil then
		return
	end
	for ping_info, parts in placed do
		place(camera, ping_info, parts)
	end
end

local function Marker(props: { ping: Ping })
	local ping_info = props.ping
	local color = appearance.team_color(ping_info.team)
	local marker_ref = React.useRef(nil :: Frame?)
	local name_ref = React.useRef(nil :: TextLabel?)
	local arm_refs = { React.useRef(nil :: Frame?), React.useRef(nil :: Frame?) }

	React.useEffect(function()
		local marker, name = marker_ref.current, name_ref.current
		local first, second = arm_refs[1].current, arm_refs[2].current
		if marker == nil or name == nil or first == nil or second == nil then
			return
		end
		placed[ping_info] = { marker = marker, name = name, arms = { first, second } }
		return function()
			placed[ping_info] = nil
		end
	end, { ping_info })

	return React.createElement("Frame", {
		[React.Tag] = "ping-marker",
		-- parked off screen until the first frame's placement has run
		Position = UDim2.fromOffset(-1000, -1000),
		ref = marker_ref,
	}, {
		Name = React.createElement("TextLabel", {
			[React.Tag] = "ping-name",
			Text = format.escape(ping_info.name),
			TextColor3 = color:Lerp(Color3.new(1, 1, 1), NAME_LIGHTEN),
			ref = name_ref,
		}),
		ArmA = React.createElement("Frame", {
			[React.Tag] = "ping-arm",
			AnchorPoint = Vector2.new(0.5, 0.5),
			BackgroundColor3 = color,
			Visible = false,
			ref = arm_refs[1],
		}),
		ArmB = React.createElement("Frame", {
			[React.Tag] = "ping-arm",
			AnchorPoint = Vector2.new(0.5, 0.5),
			BackgroundColor3 = color,
			Visible = false,
			ref = arm_refs[2],
		}),
	})
end

-- The pings up now, a list of its own each time, so that a change to it renders again.
local function active_pings(): { pings.Ping }
	return table.clone(pings.active())
end

local function PingMarkers()
	local shown = use_store.use_store(active_pings, pings.subscribe)

	React.useEffect(function()
		-- one step after the camera's, as the world bars are, so a marker never trails its ping
		RunService:BindToRenderStep(PLACE_STEP, Enum.RenderPriority.Camera.Value + 1, place_all)
		return function()
			RunService:UnbindFromRenderStep(PLACE_STEP)
		end
	end, {})

	local children = {}
	for _, ping_info in shown do
		-- keyed by when it ends and whose it is, which no two pings share
		children[`{ping_info.ends}_{ping_info.team}`] = React.createElement(Marker, { ping = ping_info })
	end
	return React.createElement(React.Fragment, {}, children)
end

return table.freeze({
	PingMarkers = PingMarkers,
})
