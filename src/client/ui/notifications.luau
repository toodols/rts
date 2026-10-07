-- The notifications the server sends (server/notifications.luau), as toasts stacked in the upper middle of the screen,
-- newest at the bottom, each for a few seconds with a chirp. Clicking one dismisses it; one that says where, as a base
-- or commander under attack does, takes the camera there first.

local ReplicatedStorage = game:GetService "ReplicatedStorage"

local React = require(ReplicatedStorage.Packages.react)

local signal = require(ReplicatedStorage.Shared.signal)
local types = require(ReplicatedStorage.Shared.types)

local camera = require(ReplicatedStorage.Client.camera)

local format = require(ReplicatedStorage.ClientShared.format)
local sounds = require(ReplicatedStorage.ClientShared.sounds)
local use_store = require(ReplicatedStorage.ClientShared.use_store)

local use_viewport = require(script.Parent.use_viewport)

type Notice = types.Notice

type Toast = {
	id: number,
	notice: Notice,
}

local notify: RemoteEvent = ReplicatedStorage.Shared.Notify

-- How long a toast stays up, in seconds, and the most shown at once; a newer one pushes the oldest out.
local TOAST_SECONDS = 6
local MOST_SHOWN = 4

local TONES: types.PerNoticeKind<string> = {
	metal_request = "metal",
	metal_sent = "metal",
	base_attacked = "danger",
	commander_attacked = "danger",
	air_detected = "caution",
	atomic_bomber_detected = "danger",
	nuke_launched = "danger",
	enemy_zone = "caution",
	wave = "danger",
	final_wave = "danger",
}

-- The server can send one before the HUD is mounted, so notices are listened for as the client starts (`init`), and
-- the stack picks up whatever is still up when it mounts.
local toasts: { Toast } = {}
local next_id = 1
local changed = signal.new() :: signal.Signal<{ Toast }>

local function announce()
	changed.fire(table.clone(toasts))
end

local function dismiss(id: number)
	for index, toast in toasts do
		if toast.id == id then
			table.remove(toasts, index)
			announce()
			return
		end
	end
end

local function add(notice: Notice)
	local id = next_id
	next_id += 1
	table.insert(toasts, { id = id, notice = notice })
	while #toasts > MOST_SHOWN do
		table.remove(toasts, 1)
	end
	announce()
	sounds.play_ui "notify"
	task.delay(TOAST_SECONDS, dismiss, id)
end

local function amount_of(notice: Notice): number
	return math.floor(notice.amount or 0)
end

local function sender_of(notice: Notice): string
	return format.escape(notice.from or "Ally")
end

-- What the toast says of each kind of notice.
local TEXTS: types.PerNoticeKind<(Notice) -> string> = {
	metal_request = function(notice: Notice): string
		return `{sender_of(notice)} needs {amount_of(notice)} metal`
	end,
	metal_sent = function(notice: Notice): string
		return `{sender_of(notice)} sent you {amount_of(notice)} metal`
	end,
	base_attacked = function(): string
		return "Base under attack"
	end,
	commander_attacked = function(): string
		return "Commander under attack"
	end,
	air_detected = function(): string
		return "Enemy aircraft detected"
	end,
	atomic_bomber_detected = function(): string
		return "Atomic bomber detected"
	end,
	nuke_launched = function(): string
		return "Nuclear launch detected"
	end,
	enemy_zone = function(): string
		return "Enemy zone: destroyed when the enemy arrives"
	end,
	wave = function(notice: Notice): string
		return `Wave {amount_of(notice)} incoming`
	end,
	final_wave = function(): string
		return "Final wave incoming"
	end,
}
table.freeze(TEXTS)

local function ToastCard(props: { toast: Toast, LayoutOrder: number })
	local notice = props.toast.notice
	return React.createElement("TextButton", {
		[React.Tag] = `toast {TONES[notice.kind]}`,
		LayoutOrder = props.LayoutOrder,
		Text = "",
		AutoButtonColor = false,
		[React.Event.Activated] = function()
			if notice.at ~= nil then
				camera.glide_to(notice.at)
			end
			dismiss(props.toast.id)
		end,
	}, {
		-- the team's colour for an ally's, set inline, which is why it is an ImageLabel: the stylesheet makes every
		-- Frame's background transparent
		Stripe = React.createElement("ImageLabel", {
			[React.Tag] = "toast-stripe",
			LayoutOrder = 1,
			BackgroundColor3 = notice.color,
		}),
		Text = React.createElement("TextLabel", {
			[React.Tag] = "toast-text",
			LayoutOrder = 2,
			Text = TEXTS[notice.kind](notice),
		}),
	})
end

-- The toasts up now, a list of its own each time, so that a change to it renders again.
local function current_toasts(): { Toast }
	return table.clone(toasts)
end

local function Notifications()
	local shown = use_store.use_store(current_toasts, changed.subscribe)
	local ui_scale = use_viewport.use_ui_scale()

	local children: { [string]: any } = {
		Scale = React.createElement("UIScale", { Scale = ui_scale }),
	}
	for index, toast in shown do
		children[`Toast{toast.id}`] = React.createElement(ToastCard, { toast = toast, LayoutOrder = index })
	end
	return React.createElement("Frame", {
		[React.Tag] = "toasts",
	}, children)
end

local function init()
	notify.OnClientEvent:Connect(add)
end

return table.freeze({
	init = init,
	Notifications = Notifications,
})
