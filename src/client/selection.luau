-- The local player's selection: which entities are selected, the outline drawn on them, and a
-- subscription the HUD listens to.
--
-- Selection is purely local. The server never hears about it; orders name entity ids explicitly.

local ReplicatedStorage = game:GetService "ReplicatedStorage"
local RunService = game:GetService "RunService"

local types = require(ReplicatedStorage.Shared.types)

local world = require(ReplicatedStorage.Client.world)

type EntityId = types.EntityId

local OUTLINE_COLOR = Color3.fromRGB(126, 240, 154)
local OUTLINE_TRANSPARENCY = 0.35

local selected: { [EntityId]: boolean } = {}
local highlights: { [EntityId]: Highlight } = {}
local listeners: { (ids: { EntityId }) -> () } = {}

local function ordered_ids(): { EntityId }
	local ids = {}
	for id in selected do
		table.insert(ids, id)
	end
	table.sort(ids)
	return ids
end

local function notify()
	local ids = ordered_ids()
	for _, listener in listeners do
		listener(ids)
	end
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
	highlight.OutlineColor = OUTLINE_COLOR
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

local function get(): { EntityId }
	return ordered_ids()
end

local function count(): number
	local total = 0
	for _ in selected do
		total += 1
	end
	return total
end

local function subscribe(listener: (ids: { EntityId }) -> ()): () -> ()
	table.insert(listeners, listener)
	return function()
		local index = table.find(listeners, listener)
		if index ~= nil then
			table.remove(listeners, index)
		end
	end
end

-- Entities die without telling the selection, so drop ids whose model has gone.
local function prune()
	local removed = false
	for id in selected do
		if world.get(id) == nil then
			selected[id] = nil
			clear_highlight(id)
			removed = true
		end
	end
	if removed then
		notify()
	end
end

local function init()
	RunService.Heartbeat:Connect(function()
		prune()
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
	subscribe = subscribe,
})
