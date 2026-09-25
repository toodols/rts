-- The notifications the server sends (server/notifications.luau), as toasts stacked down the top left, newest at the
-- bottom, each for a few seconds with a chirp. Clicking one dismisses it; one that says where, as a base under attack
-- does, takes the camera there first.

local ReplicatedStorage = game:GetService "ReplicatedStorage"

local React = require(ReplicatedStorage.Packages.react)

local camera = require(ReplicatedStorage.Client.camera)
local sounds = require(ReplicatedStorage.Client.sounds)

local use_viewport = require(script.Parent.use_viewport)

type Kind = "metal_request" | "metal_sent" | "base_attacked" | "air_detected" | "enemy_zone" | "wave" | "final_wave"

-- As server/notifications.luau sends it.
type Notice = {
	kind: Kind,
	from: string?,
	color: Color3?,
	amount: number?,
	at: Vector3?,
}

type Toast = {
	id: number,
	notice: Notice,
}

local notify: RemoteEvent = ReplicatedStorage.Shared.Notify

-- How long a toast stays up, in seconds, and the most shown at once; a newer one pushes the oldest out.
local TOAST_SECONDS = 6
local MOST_SHOWN = 4

local TONES: { [Kind]: string } = {
	metal_request = "metal",
	metal_sent = "metal",
	base_attacked = "danger",
	air_detected = "caution",
	enemy_zone = "caution",
	wave = "danger",
	final_wave = "danger",
}

-- The server can send one before the HUD is mounted, so notices are listened for as soon as this is required, and
-- the stack picks up whatever is still up when it mounts.
local toasts: { Toast } = {}
local next_id = 1
local listeners: { [({ Toast }) -> ()]: true } = {}

local function announce()
	local snapshot = table.clone(toasts)
	for listener in listeners do
		listener(snapshot)
	end
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

notify.OnClientEvent:Connect(function(notice: Notice)
	local id = next_id
	next_id += 1
	table.insert(toasts, { id = id, notice = notice })
	while #toasts > MOST_SHOWN do
		table.remove(toasts, 1)
	end
	announce()
	sounds.play_ui "notify"
	task.delay(TOAST_SECONDS, dismiss, id)
end)

local function text_of(notice: Notice): string
	local amount = math.floor(notice.amount or 0)
	if notice.kind == "metal_request" then
		return `{notice.from or "Ally"} needs {amount} metal`
	elseif notice.kind == "metal_sent" then
		return `{notice.from or "Ally"} sent you {amount} metal`
	elseif notice.kind == "base_attacked" then
		return "Base under attack"
	elseif notice.kind == "enemy_zone" then
		return "Enemy zone: destroyed when the enemy arrives"
	elseif notice.kind == "wave" then
		return `Wave {amount} incoming`
	elseif notice.kind == "final_wave" then
		return "Final wave incoming"
	end
	return "Enemy aircraft detected"
end

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
			Text = text_of(notice),
		}),
	})
end

local function Notifications()
	local shown, set_shown = React.useState(table.clone(toasts))
	local ui_scale = use_viewport.use_ui_scale()

	React.useEffect(function()
		set_shown(table.clone(toasts))
		listeners[set_shown] = true
		return function()
			listeners[set_shown] = nil
		end
	end, {})

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

return table.freeze({
	Notifications = Notifications,
})
