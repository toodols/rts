--!strict
-- What each kind of weapon (`types.WeaponKind`) is: what the HUD calls it, the short code on its slot and its icon
-- (Shared.ui_art), and what goes with being one of its kind that no other field of a weapon says. Every weapon names
-- its kind, so nothing works out what a weapon is from the rest of it.
--
-- `anti_air`: dedicated anti-air, which does its full damage to aircraft where any other weapon does only
--   `NON_AA_AIR_DAMAGE_FRACTION` of it, and which does no more than `AA_NON_AIR_DAMAGE` to anything else.
-- `anti_nuke`: an interceptor, which shoots down nuclear missiles in flight and at nothing else.
-- `nuclear`: a nuclear missile, which is what an interceptor goes after.
-- `plasma`: a plasma shell, which a plasma deflector stops, and which is drawn glowing.
-- `pierces`: goes through what it strikes rather than going off on it, as BAR's `noexplode` gauss ball does: for every
--   thirtieth of a second it spends inside something it goes off again, blast and all, and it flies on until it comes
--   down on the ground, where it goes off one last time.
-- `sound`: what it is heard firing as (ClientShared.sounds), played at `pitch` (1 without it): a missile's launch is the
--   cannon's pitched up into more of a whoosh, and a lightning bolt, which has no sound of its own yet, the laser's
--   pitched down into a crack. A laser whose beam is charged, a tachyon accelerator (the Pulsar's and the Starlight's),
--   is heard as the pulsar instead (`sound_of`).

local ReplicatedStorage = game:GetService "ReplicatedStorage"

local types = require(ReplicatedStorage.Shared.types)

type WeaponKind = types.WeaponKind

-- The sounds a weapon is heard firing as.
export type FiringSound = "laser" | "heat_ray" | "pulsar" | "cannon" | "anti_air" | "torpedo"

export type Info = {
	name: string,
	slot: string,
	icon: string,
	anti_air: boolean?,
	anti_nuke: boolean?,
	nuclear: boolean?,
	plasma: boolean?,
	pierces: boolean?,
	sound: { name: FiringSound, pitch: number? },
}

-- What is left of a weapon's damage when it hits an aircraft and the weapon is not dedicated anti air.
local NON_AA_AIR_DAMAGE_FRACTION = 0.15
-- The most a dedicated anti-air weapon's hit or blast does to anything that is not an aircraft. BAR gives its anti-air
-- weapons damage against aircraft (`vtol`) and nothing else, and the engine does its default of 1 to the rest, so a
-- missile that misses an aircraft on the ground and goes off among ground units hardly scratches them.
local AA_NON_AIR_DAMAGE = 1

local LASER = table.freeze({ name = "laser" :: FiringSound })
local HEAT_RAY = table.freeze({ name = "heat_ray" :: FiringSound })
local PULSAR = table.freeze({ name = "pulsar" :: FiringSound })
local CRACK = table.freeze({ name = "laser" :: FiringSound, pitch = 0.55 })
local CANNON = table.freeze({ name = "cannon" :: FiringSound })
local WHOOSH = table.freeze({ name = "cannon" :: FiringSound, pitch = 1.5 })
local ANTI_AIR = table.freeze({ name = "anti_air" :: FiringSound })
local TORPEDO = table.freeze({ name = "torpedo" :: FiringSound })

local KINDS: { [WeaponKind]: Info } = {
	laser = { name = "LASER", slot = "LSR", icon = "icon_laser", sound = LASER },
	heat_ray = { name = "HEAT RAY", slot = "HRY", icon = "icon_heat_ray", sound = HEAT_RAY },
	emp_laser = { name = "EMP LASER", slot = "EMP", icon = "icon_emp", sound = LASER },
	lightning = { name = "LIGHTNING GUN", slot = "LTN", icon = "icon_lightning", sound = CRACK },
	sniper = { name = "SNIPER RIFLE", slot = "SNP", icon = "icon_sniper", sound = LASER },
	flamethrower = { name = "FLAMETHROWER", slot = "FLM", icon = "icon_flamethrower", sound = CANNON },
	plasma_cannon = {
		name = "PLASMA CANNON",
		slot = "PLS",
		icon = "icon_plasma_cannon",
		plasma = true,
		sound = CANNON,
	},
	cannon = { name = "CANNON", slot = "CNN", icon = "icon_cannon", sound = CANNON },
	gauss = { name = "GAUSS CANNON", slot = "GSS", icon = "icon_gauss", pierces = true, sound = CANNON },
	shotgun = { name = "SHOTGUN", slot = "SHG", icon = "icon_shotgun", sound = CANNON },
	machine_gun = { name = "MACHINE GUN", slot = "MG", icon = "icon_machine_gun", sound = CANNON },
	flak = { name = "FLAK", slot = "FLK", icon = "icon_flak", anti_air = true, sound = CANNON },
	rockets = { name = "ROCKETS", slot = "RKT", icon = "icon_rocket", sound = CANNON },
	missiles = { name = "MISSILES", slot = "MSL", icon = "icon_missile", sound = WHOOSH },
	aa_missiles = { name = "AA MISSILES", slot = "AA", icon = "icon_anti_air", anti_air = true, sound = ANTI_AIR },
	emp_missile = { name = "EMP MISSILE", slot = "EMP", icon = "icon_emp", sound = WHOOSH },
	nuke = { name = "NUCLEAR MISSILE", slot = "NUK", icon = "icon_nuke", nuclear = true, sound = WHOOSH },
	anti_nuke = { name = "ANTI-NUKE", slot = "ABM", icon = "icon_anti_nuke", anti_nuke = true, sound = CANNON },
	torpedo = { name = "TORPEDO", slot = "TRP", icon = "icon_torpedo", sound = TORPEDO },
	depth_charge = { name = "DEPTH CHARGES", slot = "DPC", icon = "icon_depth_charge", sound = CANNON },
	bombs = { name = "BOMBS", slot = "BMB", icon = "icon_bombs", sound = CANNON },
	emp_bombs = { name = "EMP BOMBS", slot = "EMP", icon = "icon_emp", sound = CANNON },
}

for _, info in KINDS do
	table.freeze(info)
end

local function get(kind: WeaponKind): Info
	local info = KINDS[kind]
	assert(info ~= nil, `unknown weapon kind "{kind}"`)
	return info
end

-- What `weapon` is heard firing as.
local function sound_of(weapon: types.Weapon): { name: FiringSound, pitch: number? }
	local delivery = weapon.delivery
	if weapon.kind == "laser" and delivery.kind == "beam" and delivery.charged == true then
		return PULSAR
	end
	return get(weapon.kind).sound
end

return table.freeze({
	NON_AA_AIR_DAMAGE_FRACTION = NON_AA_AIR_DAMAGE_FRACTION,
	AA_NON_AIR_DAMAGE = AA_NON_AIR_DAMAGE,
	get = get,
	sound_of = sound_of,
})
