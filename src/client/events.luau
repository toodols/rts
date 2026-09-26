--!strict
-- What the player does with the controls, told as it happens to whoever wants to know (a mission's guide, which waits
-- on it): the view panned, something selected with the mouse, units sent somewhere. The camera, picking and commands
-- fire these and know nothing of who listens.

local ReplicatedStorage = game:GetService "ReplicatedStorage"

local signal = require(ReplicatedStorage.Shared.signal)

local types = require(ReplicatedStorage.Shared.types)

type EntityId = types.EntityId

-- How the view was panned: with the arrow keys, or by dragging with the middle mouse button.
export type PanMethod = "keys" | "drag"
-- How something was selected: by dragging a box, or by clicking it.
export type SelectMethod = "box" | "click"

-- Every frame the view's focus moves, and only then; turning and zooming are not panning.
local panned = signal.new() :: signal.Signal<PanMethod>
-- Each time the mouse selects: how, and the ids the box or the click took, once the selection has them.
local selected = signal.new() :: signal.Signal<SelectMethod, { EntityId }>
-- Every move order sent: the ids, and where each was sent.
local moved = signal.new() :: signal.Signal<{ EntityId }, { Vector3 }>

return table.freeze({
	panned = panned,
	selected = selected,
	moved = moved,
})
