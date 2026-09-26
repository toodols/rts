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

local selected: { [EntityId]: boolean } = {}
local highlights: { [EntityId]: Highlight? } = {}
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
	highlight.OutlineTransparency = OUTLINE_TRANSPARENCY
	highlight.OutlineColor = palette.buildpower
	highlight.DepthMode = Enum.HighlightDepthMode.AlwaysOnTop
	highlight.Adornee = model
	highlight.Parent = model
	highlights[id] = highlight
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
	subscribe = changed.subscribe,
})
