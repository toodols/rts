-- Pings: double click the middle mouse button to mark the spot under the cursor for yourself and your allies. The
-- server passes it on to everyone allied with you (server/pings.luau), and each of them sees a column of light in your
-- team's colour stand there for a few seconds, with flat pulses of light spreading out from its foot, and hears a
-- chirp. The name of the player who pinged floats over the column, or while it is off screen marks the edge of the
-- screen the way to it (ui/ping_markers.luau, which reads `active`).
--
-- The middle button also drags the camera about (camera.luau), so a press only counts as a click if the cursor
-- stays put while it is down, and two only make a double click if they land close together.

local ReplicatedStorage = game:GetService "ReplicatedStorage"
local TweenService = game:GetService "TweenService"
local UserInputService = game:GetService "UserInputService"

local signal = require(ReplicatedStorage.Shared.signal)
local types = require(ReplicatedStorage.Shared.types)
local appearance = require(ReplicatedStorage.Shared.appearance)

local cursor = require(ReplicatedStorage.Client.cursor)
local input_router = require(ReplicatedStorage.Client.input_router)
local world_fx = require(ReplicatedStorage.Client.world_fx)

local sounds = require(ReplicatedStorage.ClientShared.sounds)

local ping: RemoteEvent = ReplicatedStorage.Shared.Ping

-- The most seconds between the two clicks of a double click, and the most pixels the cursor may move, while the
-- button is down or between the clicks, for them to still count as clicks on one spot.
local DOUBLE_CLICK_SECONDS = 0.4
local CLICK_SLOP = 6

-- How a ping looks: a column BEAM_HEIGHT studs tall standing for PING_SECONDS, and RING_COUNT flat discs, one every
-- RING_GAP seconds, each spreading out to RING_RADIUS studs as it fades over RING_SECONDS.
local PING_SECONDS = 4
local BEAM_HEIGHT = 40
local BEAM_WIDTH = 0.6
local RING_COUNT = 3
local RING_GAP = 0.5
local RING_SECONDS = 1.2
local RING_RADIUS = 10
local RING_THICKNESS = 0.2

export type Ping = {
	at: Vector3,
	team: types.TeamId,
	-- the UserId and display name of the player who pinged
	player: number,
	name: string,
	-- os.clock() when it is gone
	ends: number,
}

-- The pings standing now, oldest first; `changed` tells whoever subscribes whenever one comes or goes.
local active: { Ping } = {}
local changed = signal.new()

local function add(ping_info: Ping)
	table.insert(active, ping_info)
	changed.fire()
	task.delay(PING_SECONDS, function()
		local index = table.find(active, ping_info)
		if index ~= nil then
			table.remove(active, index)
			changed.fire()
		end
	end)
end

local function all_active(): { Ping }
	return active
end

local press_location: Vector2? = nil
local last_click_time = -math.huge
local last_click_location = Vector2.zero

-- A glowing part in `color` for a ping, in the Pings folder of the Effects.
local function neon_part(name: string, color: Color3): Part
	local part = world_fx.part(name)
	part.Color = color
	part.Parent = world_fx.folder "Pings"
	return part
end

local function draw(at: Vector3, team: types.TeamId)
	local color = appearance.team_color(team)

	local beam = neon_part("PingBeam", color)
	beam.Shape = Enum.PartType.Cylinder
	-- a cylinder's length runs along its own x, so rolled as one lying flat is, it stands on end
	beam.Size = Vector3.new(BEAM_HEIGHT, BEAM_WIDTH, BEAM_WIDTH)
	beam.CFrame = world_fx.lying_flat(at + Vector3.yAxis * (BEAM_HEIGHT / 2))
	beam.Transparency = 0.2
	TweenService
		:Create(beam, TweenInfo.new(PING_SECONDS, Enum.EasingStyle.Quad, Enum.EasingDirection.In), { Transparency = 1 })
		:Play()
	task.delay(PING_SECONDS, beam.Destroy, beam)

	for index = 0, RING_COUNT - 1 do
		task.delay(index * RING_GAP, function()
			local ring = neon_part("PingRing", color)
			ring.Shape = Enum.PartType.Cylinder
			ring.Size = Vector3.new(RING_THICKNESS, 1, 1)
			ring.CFrame = world_fx.lying_flat(at + Vector3.yAxis * 0.2)
			ring.Transparency = 0.1
			world_fx.fade(
				ring,
				RING_SECONDS,
				{ Size = Vector3.new(RING_THICKNESS, RING_RADIUS * 2, RING_RADIUS * 2), Transparency = 1 }
			)
		end)
	end
end

local function on_input_began(input: InputObject, processed: boolean): boolean
	if processed or input.UserInputType ~= Enum.UserInputType.MouseButton3 then
		return false
	end
	press_location = UserInputService:GetMouseLocation()
	return true
end

local function on_input_ended(_: InputObject)
	if press_location == nil then
		return
	end
	local location = UserInputService:GetMouseLocation()
	local dragged = (location - press_location).Magnitude > CLICK_SLOP
	press_location = nil
	if dragged then
		-- that was the camera being dragged, and not a click
		last_click_time = -math.huge
		return
	end
	local now = os.clock()
	if now - last_click_time <= DOUBLE_CLICK_SECONDS and (location - last_click_location).Magnitude <= CLICK_SLOP then
		last_click_time = -math.huge
		local at = cursor.ground_point()
		if at ~= nil then
			ping:FireServer(at)
		end
		return
	end
	last_click_time = now
	last_click_location = location
end

local function init()
	input_router.push({ began = on_input_began, ended = on_input_ended, exclusive = false })
	ping.OnClientEvent:Connect(function(message: { at: Vector3, team: types.TeamId, player: number, name: string })
		draw(message.at, message.team)
		add({
			at = message.at,
			team = message.team,
			player = message.player,
			name = message.name,
			ends = os.clock() + PING_SECONDS,
		})
		sounds.play_ui "notify"
	end)
end

return table.freeze({
	init = init,
	subscribe = changed.subscribe,
	active = all_active,
	-- how tall a ping's column stands, so its label can float over it
	BEAM_HEIGHT = BEAM_HEIGHT,
})
