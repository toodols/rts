--!strict
-- What the server tells every client about shots (the WeaponFired remote), for them to draw and play: one of these
-- events, told apart by its `kind`.
--
-- `projectile`  a projectile was launched; the client flies it the same way the server does (shared/projectile), from
--               where and how it was launched, `late` seconds into its flight already, steering it onto the entity
--               `homing_target_id` or, for an interceptor, the projectile `homing_projectile_id` if it homes
-- `impact`      projectile `id` went off at `at`, a blast `radius` wide: where it struck or came down (`burst`), inside
--               something it goes through and flies on from (`through`), or high in the air, caught by an interceptor
--               (`airburst`)
-- `blast`       something blew up as it died, `radius` wide
-- `beam`        a beam weapon's beam went from `from` to `to`, drawn as its beam says, in `team`'s colour if it has none
-- `lightning`   the same for a lightning gun's bolt, with where each of its sparks jumped to from `to`
-- `sweep`       a manual weapon swept everything within `radius` of the line from `from` to `to` away

local ReplicatedStorage = game:GetService "ReplicatedStorage"

local types = require(ReplicatedStorage.Shared.types)
local projectile = require(ReplicatedStorage.Shared.projectile)
local unit_defs = require(ReplicatedStorage.Shared.unit_defs)

-- Which weapon fired a shot: weapon number `weapon` of the def `def_name` as the skin `skin` has it, which is all the
-- client needs to know everything about it that is the same for every shot (`weapon_of`).
export type Fired = {
	def_name: string,
	skin: string?,
	weapon: number,
}

export type Launched = {
	kind: "projectile",
	id: number,
	def_name: string,
	skin: string?,
	weapon: number,
	from: Vector3,
	direction: Vector3,
	shot: projectile.Shot,
	aim: Vector3,
	inherited: Vector3?,
	late: number,
	homing_target_id: types.EntityId?,
	homing_projectile_id: number?,
}

export type ImpactHow = "burst" | "through" | "airburst"

export type Impact = { kind: "impact", id: number, at: Vector3, radius: number, how: ImpactHow }

export type Blast = { kind: "blast", at: Vector3, radius: number }

export type BeamFired = {
	kind: "beam",
	def_name: string,
	skin: string?,
	weapon: number,
	from: Vector3,
	to: Vector3,
	team: types.TeamId,
}

export type LightningFired = {
	kind: "lightning",
	def_name: string,
	skin: string?,
	weapon: number,
	from: Vector3,
	to: Vector3,
	team: types.TeamId,
	sparks: { Vector3 },
}

export type Sweep = { kind: "sweep", from: Vector3, to: Vector3, radius: number }

export type Event = Launched | Impact | Blast | BeamFired | LightningFired | Sweep

export type Kind = "projectile" | "impact" | "blast" | "beam" | "lightning" | "sweep"

-- The weapon that fired `fired`.
local function weapon_of(fired: Fired): types.Weapon
	local weapons = unit_defs.skinned(fired.def_name, fired.skin).weapons
	local weapon = if weapons ~= nil then weapons[fired.weapon] else nil
	assert(weapon ~= nil, `"{fired.def_name}" has no weapon {fired.weapon}`)
	return weapon
end

return table.freeze({
	weapon_of = weapon_of,
})
