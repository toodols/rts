--!strict
-- Where each weapon's shots come from. It is part of the simulation: a weapon's line of fire, and so what is in the way
-- of it, and how far it reaches, are measured from there.
--
-- Everything here is the def's: a weapon on a turret piece of its owner's model fires from its `turret_mount`, the tip
-- of the piece's barrel, turned with the turret's aim (`Entity.weapon_aims`); any other weapon fires from its def's
-- `offset`, in the entity's own frame, or with none from the usual spot just above its middle (`unit_defs.muzzle_of`).
-- The model's art is only built to agree with a turret mount (tools/model_pipeline), so it never moves a shot.

local ReplicatedStorage = game:GetService "ReplicatedStorage"

local types = require(ReplicatedStorage.Shared.types)
local unit_defs = require(ReplicatedStorage.Shared.unit_defs)

type Entity = types.Entity
type Weapon = types.Weapon

-- Where a weapon is mounted:
--   turret  on the turret piece for weapon `index`: its pivot, from the model's origin (the ground under the
--           collider's middle, which `drop` takes the entity's middle down to), and the muzzle relative to the pivot
--   offset  at `offset` in the entity's frame
--   middle  at the usual spot above its middle
export type Mount =
	{ kind: "turret", index: number, pivot: CFrame, point: Vector3, drop: CFrame }
	| { kind: "offset", offset: Vector3 }
	| { kind: "middle" }

local MIDDLE: Mount = { kind = "middle" }
table.freeze(MIDDLE)

-- Worked out once for each weapon, which its def owns.
local mounts: { [Weapon]: Mount } = {}

-- Where weapon `index` of `def` is mounted.
local function mount_of(def: types.EntityDef, index: number): Mount
	local weapon = (def.weapons :: { Weapon })[index]
	local found = mounts[weapon]
	if found ~= nil then
		return found
	end
	local turret = weapon.turret_mount
	if turret ~= nil then
		found = {
			kind = "turret",
			index = index,
			pivot = CFrame.new(turret.pivot),
			point = turret.muzzle,
			drop = CFrame.new(0, -unit_defs.collider_height(def) / 2, 0),
		}
	elseif weapon.offset ~= nil then
		found = { kind = "offset", offset = weapon.offset }
	else
		found = MIDDLE
	end
	local mount = found :: Mount
	mounts[weapon] = mount
	return mount
end

-- Where weapon `index` of `entity`, standing in `frame`, fires from now.
local function origin_of(entity: Entity, frame: CFrame, index: number): Vector3
	local mount = mount_of(entity.def, index)
	if mount.kind == "turret" then
		local aim = entity.weapon_aims[mount.index] or 0
		return (frame * mount.drop * mount.pivot * CFrame.Angles(0, aim, 0)):PointToWorldSpace(mount.point)
	elseif mount.kind == "offset" then
		return frame:PointToWorldSpace(mount.offset)
	end
	return unit_defs.muzzle_of(entity.def, entity.position)
end

-- The frame `entity` stands in, which its weapons' origins are worked out in.
local function frame_of(entity: Entity): CFrame
	return CFrame.new(entity.position) * CFrame.Angles(0, entity.facing, 0)
end

return table.freeze({
	mount_of = mount_of,
	origin_of = origin_of,
	frame_of = frame_of,
})
