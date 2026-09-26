--!strict
-- BAR's commander hurt vignette (luaui/Widgets/gui_commanderhurt.lua): when one of your commanders loses more than
-- DAMAGE_THRESHOLD health at once while it is out of view, the edges of the screen flash red, fading over
-- FADE_SECONDS. The look is the stylesheet's (_commander_hurt.scss); how strongly it shows is written straight to the
-- group every frame rather than going through a re-render.

local ReplicatedStorage = game:GetService "ReplicatedStorage"
local RunService = game:GetService "RunService"
local Workspace = game:GetService "Workspace"

local React = require(ReplicatedStorage.Packages.react)

local types = require(ReplicatedStorage.Shared.types)
local entity_attrs = require(ReplicatedStorage.Shared.entity_attrs)

local world = require(ReplicatedStorage.Client.world)

type EntityId = types.EntityId

-- BAR's `damage > 3`, `maxOpacity` and `duration`.
local DAMAGE_THRESHOLD = 3
local MAX_OPACITY = 0.55
local FADE_SECONDS = 1.55
-- How often your commanders are looked for again, in seconds.
local SCAN_SECONDS = 0.5

local function off_screen(model: Model): boolean
	local camera = Workspace.CurrentCamera
	if camera == nil then
		return true
	end
	local _, on_screen = camera:WorldToViewportPoint(world.position_of(model))
	return on_screen == false
end

local function health_of(model: Model): number
	return entity_attrs.number(model, "health") or 0
end

local function CommanderHurt()
	local group_ref = React.useRef(nil :: CanvasGroup?)

	React.useEffect(function()
		local opacity = 0
		-- the health each of your commanders had when last seen, by entity id
		local watched: { [EntityId]: number } = {}

		local function scan()
			local found: { [EntityId]: number } = {}
			for _, model in world.my_commanders() do
				local id = world.id_of(model) :: EntityId
				found[id] = watched[id] or health_of(model)
			end
			watched = found
		end

		local unsubscribe = world.subscribe_changed(function(id: EntityId, attribute: string)
			local last = watched[id]
			local model = world.get(id)
			if attribute ~= "health" or last == nil or model == nil then
				return
			end
			local now = health_of(model)
			watched[id] = now
			if last - now > DAMAGE_THRESHOLD and off_screen(model) then
				opacity = MAX_OPACITY
			end
		end)

		local since_scan = math.huge
		local step = RunService.RenderStepped:Connect(function(delta: number)
			since_scan += delta
			if since_scan >= SCAN_SECONDS then
				since_scan = 0
				scan()
			end
			if opacity > 0 then
				opacity = math.max(0, opacity - MAX_OPACITY * delta / FADE_SECONDS)
			end
			local group = group_ref.current
			if group ~= nil then
				-- hidden when clear, so the group is not drawn at all
				group.Visible = opacity > 0.01
				group.GroupTransparency = 1 - opacity
			end
		end)

		return function()
			step:Disconnect()
			unsubscribe()
		end
	end, {})

	return React.createElement("CanvasGroup", {
		[React.Tag] = "commander-hurt",
		ref = group_ref,
		Visible = false,
		GroupTransparency = 1,
	}, {
		Top = React.createElement("Frame", { [React.Tag] = "hurt-edge top" }),
		Bottom = React.createElement("Frame", { [React.Tag] = "hurt-edge bottom" }),
		Left = React.createElement("Frame", { [React.Tag] = "hurt-edge left" }),
		Right = React.createElement("Frame", { [React.Tag] = "hurt-edge right" }),
	})
end

return table.freeze({
	CommanderHurt = CommanderHurt,
})
