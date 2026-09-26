--!strict
-- The local player's selection: which entities are selected, the outline drawn on them, and a
-- subscription the HUD listens to.
--
-- Selection is purely local. The server never hears about it; orders name entity ids explicitly. An entity that goes
-- leaves the selection as the world hears it go (world's `subscribe_removed`).

local ReplicatedStorage = game:GetService "ReplicatedStorage"

local signal = require(ReplicatedStorage.Shared.signal)
local types = require(ReplicatedStorage.Shared.types)

local world = require(ReplicatedStorage.Client.world)

local palette = require(ReplicatedStorage.ClientShared.palette)

type EntityId = types.EntityId

local OUTLINE_TRANSPARENCY = 0.35
-- How faint the outline of a selected thing is while a mode is on that it takes no part in.
local LEFT_OUT_TRANSPARENCY = 0.8

local selected: { [EntityId]: boolean } = {}
local highlights: { [EntityId]: Highlight? } = {}
-- While a mode is on: who among the selection takes part in it, outlined in its colour, the rest faint (`tint`).
local tinted: { [EntityId]: boolean }? = nil
local tint_color = palette.buildpower
-- The selected ids in order, worked out once each time the selection changes; frozen, since everyone is handed it.
local ordered: { EntityId } = table.freeze({})
local changed = signal.new() :: signal.Signal<{ EntityId }>

local function notify()
	local ids = {}
	for id in selected do
		table.insert(ids, id)
	end
	table.sort(ids)
	ordered = table.freeze(ids)
	changed.fire(ordered)
end

local function clear_highlight(id: EntityId)
	local highlight = highlights[id]
	if highlight == nil then
		return
	end
	highlight:Destroy()
	highlights[id] = nil
end

-- Outlines `id`'s highlight as the tint says: in the mode's colour if it takes part, faint if it does not, and in the
-- usual colour with no mode on.
local function paint(id: EntityId, highlight: Highlight)
	local taking_part = if tinted ~= nil then tinted[id] == true else nil
	highlight.OutlineColor = if taking_part == true then tint_color else palette.buildpower
	highlight.OutlineTransparency = if taking_part == false then LEFT_OUT_TRANSPARENCY else OUTLINE_TRANSPARENCY
end

local function add_highlight(id: EntityId)
	if highlights[id] ~= nil then
		return
	end
	local model = world.get(id)
	if model == nil then
		return
	end
	local highlight = Instance.new "Highlight"
	highlight.Name = "SelectionOutline"
	highlight.FillTransparency = 1
	highlight.DepthMode = Enum.HighlightDepthMode.AlwaysOnTop
	highlight.Adornee = model
	paint(id, highlight)
	highlight.Parent = model
	highlights[id] = highlight
end

-- While a mode is on, outlines those of the selection in `taking_part` in `color` and the rest faintly; `nil` puts
-- every outline back as it was. Only a change repaints them, so it can be said every frame.
local function same_set(a: { [EntityId]: boolean }?, b: { [EntityId]: boolean }?): boolean
	if a == nil or b == nil then
		return a == b
	end
	for id in a do
		if b[id] == nil then
			return false
		end
	end
	for id in b do
		if a[id] == nil then
			return false
		end
	end
	return true
end

local function tint(taking_part: { [EntityId]: boolean }?, color: Color3?)
	local new_color = color or palette.buildpower
	if new_color == tint_color and same_set(taking_part, tinted) then
		return
	end
	tinted = taking_part
	tint_color = new_color
	for id, highlight in highlights do
		if highlight ~= nil then
			paint(id, highlight)
		end
	end
end

local function refresh_highlights()
	for id in highlights do
		if selected[id] == nil then
			clear_highlight(id)
		end
	end
	for id in selected do
		add_highlight(id)
	end
end

local function set(ids: { EntityId })
	table.clear(selected)
	for _, id in ids do
		selected[id] = true
	end
	refresh_highlights()
	notify()
end

local function add(ids: { EntityId })
	for _, id in ids do
		selected[id] = true
	end
	refresh_highlights()
	notify()
end

-- Shift-clicking an entity that is already selected removes it; otherwise it joins the selection.
local function toggle(id: EntityId)
	if selected[id] ~= nil then
		selected[id] = nil
	else
		selected[id] = true
	end
	refresh_highlights()
	notify()
end

local function clear()
	if next(selected) == nil then
		return
	end
	table.clear(selected)
	refresh_highlights()
	notify()
end

local function contains(id: EntityId): boolean
	return selected[id] ~= nil
end

-- The selected ids, lowest first. The list is shared and frozen: it is only replaced, never changed.
local function get(): { EntityId }
	return ordered
end

local function count(): number
	return #ordered
end

local function init()
	world.subscribe_removed(function(_model: Model, id: EntityId)
		if selected[id] ~= nil then
			selected[id] = nil
			clear_highlight(id)
			notify()
		end
	end)
end

return table.freeze({
	init = init,
	set = set,
	add = add,
	toggle = toggle,
	clear = clear,
	contains = contains,
	get = get,
	count = count,
	tint = tint,
	subscribe = changed.subscribe,
})
