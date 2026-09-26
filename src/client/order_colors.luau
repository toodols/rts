--!strict
-- The colour each kind of order is drawn in, wherever it is drawn: its dots and the line through a unit's queue
-- (markers.luau), the shape a drag traces out, and what the cursor lights while a mode that gives it is on.

local ReplicatedStorage = game:GetService "ReplicatedStorage"

local types = require(ReplicatedStorage.Shared.types)

local palette = require(ReplicatedStorage.ClientShared.palette)

type OrderKind = types.OrderKind

-- What an order of no kind in particular is drawn in: a move's colour.
local DEFAULT = palette.buildpower

-- An area order is drawn in the colour of the order it gives over its circle.
local COLORS: { [OrderKind]: Color3 } = table.freeze({
	move = palette.buildpower,
	attack = palette.danger,
	attack_ground = palette.danger,
	area_attack = palette.danger,
	fight = palette.fight,
	dgun = palette.disintegrator,
	reclaim = palette.caution,
	area_reclaim = palette.caution,
	assist = palette.accent,
	guard = palette.guard,
	build = palette.accent,
	repair = palette.energy,
	area_repair = palette.energy,
	resurrect = palette.resurrect,
	area_resurrect = palette.resurrect,
	load = palette.accent,
	unload = palette.caution,
})

-- The colour an order of `kind` is drawn in; a kind named by the server's published path is a string, and anything
-- that is not a kind of order is drawn in the default.
local function of(kind: string?): Color3
	local color = if kind ~= nil then COLORS[kind :: OrderKind] else nil
	return if color ~= nil then color else DEFAULT
end

return table.freeze({
	of = of,
})
