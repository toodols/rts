-- Piloting: a developer takes one unit of their team in hand and drives it themselves, from its own eyes. It walks
-- where they steer it at its own top speed, faces where they look, fires its first weapon at what they aim at when they
-- click, and its manual weapon, if it has one, when they ask. It ignores its orders while it is piloted, and picks
-- them up again once it is let go. Only one player may pilot a unit at a time.
--
-- The server publishes who pilots what: on the player, the id of the unit they pilot (PLAYER_ATTRIBUTE), and on the
-- unit's model, the user id of whoever pilots it (MODEL_ATTRIBUTE), and while it is piloted, how long its manual weapon
-- has left to reload (COOLDOWN_ATTRIBUTE).

local types = require(script.Parent.types)

type EntityDef = types.EntityDef
type Weapon = types.Weapon

local PLAYER_ATTRIBUTE = "piloting"
local MODEL_ATTRIBUTE = "pilot"
local COOLDOWN_ATTRIBUTE = "manual_cooldown"
-- For a piloted transport: whether its hook has something in reach to pick up, and whether it is low enough to set what
-- it carries down.
local LOAD_ATTRIBUTE = "pilot_can_load"
local UNLOAD_ATTRIBUTE = "pilot_can_unload"
-- For a piloted unit that can be carried: whether a transport of its team is near enough to call over to pick it up.
local CALL_ATTRIBUTE = "pilot_can_call"
-- For a piloted unit that has called a transport: "coming" while it is on its way, and "lost" for CALL_LOST_SECONDS
-- once it has been destroyed before it got there.
local CALL_STATE_ATTRIBUTE = "pilot_call"
local CALL_LOST_SECONDS = 4

-- How often the client sends what the pilot is doing, a second. What it sends is all of it every time, so one lost on
-- the way is made good by the next.
local INPUT_RATE = 20
-- After this long without hearing from the pilot, the server takes it that they have let go of everything: the unit
-- stops walking and holds its fire until it hears from them again.
local INPUT_TIMEOUT = 0.5

-- What a pilot can say, by the name a client asks for it by; nothing else can be said. Everyone sees it over the unit,
-- for SAY_SECONDS.
local PHRASES: { [string]: string } = table.freeze({
	hold = "Hold positions!",
	follow = "Follow me!",
	attack = "Attack!",
})
local SAY_SECONDS = 3

-- Whether a unit made from `def` can be piloted: something that moves on its own, and is not a drone, which answers
-- to its carrier alone.
local function can_pilot(def: EntityDef): boolean
	return def.kind == "unit" and def.max_speed ~= nil and def.acceleration ~= nil and def.drone ~= true
end

-- Whether weapon `index` of `def` can be the one a click fires: any it has but an anti-nuke, which fires only at
-- nuclear missiles.
local function can_select(def: EntityDef, index: number): boolean
	local weapons = def.weapons
	local weapon = if weapons ~= nil then weapons[index] else nil
	return weapon ~= nil and weapon.anti_nuke ~= true
end

-- Which of `def`'s weapons a click fires until another is chosen: the first that shoots at what it is aimed at, and
-- not only on orders; failing that, the first that can be chosen at all. Nil for something with none.
local function primary_weapon(def: EntityDef): number?
	local weapons = def.weapons
	if weapons == nil then
		return nil
	end
	for index, weapon in weapons do
		if weapon.manual_fire ~= true and can_select(def, index) then
			return index
		end
	end
	for index in weapons do
		if can_select(def, index) then
			return index
		end
	end
	return nil
end

-- What kind of weapon it is, in a word, for its key: the defs name none of their weapons.
local function weapon_label(weapon: Weapon): string
	local projectile = weapon.projectile
	if weapon.target_layer == "air" or weapon.anti_air == true then
		return "AA"
	end
	if projectile == nil then
		return if weapon.beam_time ~= nil then "LASER" else "GUN"
	end
	if projectile.torpedo == true then
		return "TORPEDO"
	end
	if projectile.dropped == true then
		return "BOMBS"
	end
	if projectile.missile ~= nil or projectile.homing == true or weapon.stockpile ~= nil then
		return "MISSILE"
	end
	-- a gun's bolt may fly straight for a while before it falls, but only a rocket speeds up
	if projectile.thrust_time > 0 and projectile.acceleration > 0 then
		return "ROCKETS"
	end
	return "CANNON"
end

-- The attribute weapon `index`'s charge is published in while its unit is piloted: how far through its reload it is,
-- from 0 to 1.
local charge_attributes: { string } = {}
local function charge_attribute(index: number): string
	local name = charge_attributes[index]
	if name == nil then
		name = `charge_{index}`
		charge_attributes[index] = name
	end
	return name
end

return table.freeze({
	PLAYER_ATTRIBUTE = PLAYER_ATTRIBUTE,
	MODEL_ATTRIBUTE = MODEL_ATTRIBUTE,
	COOLDOWN_ATTRIBUTE = COOLDOWN_ATTRIBUTE,
	LOAD_ATTRIBUTE = LOAD_ATTRIBUTE,
	UNLOAD_ATTRIBUTE = UNLOAD_ATTRIBUTE,
	CALL_ATTRIBUTE = CALL_ATTRIBUTE,
	CALL_STATE_ATTRIBUTE = CALL_STATE_ATTRIBUTE,
	CALL_LOST_SECONDS = CALL_LOST_SECONDS,
	INPUT_RATE = INPUT_RATE,
	INPUT_TIMEOUT = INPUT_TIMEOUT,
	PHRASES = PHRASES,
	SAY_SECONDS = SAY_SECONDS,
	can_pilot = can_pilot,
	primary_weapon = primary_weapon,
	can_select = can_select,
	weapon_label = weapon_label,
	charge_attribute = charge_attribute,
})
