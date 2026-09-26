--!strict
-- Piloting: a developer takes one unit of their team in hand and drives it themselves, from its own eyes. It walks
-- where they steer it at its own top speed, faces where they look, fires its first weapon at what they aim at when they
-- click, and its manual weapon, if it has one, when they ask. It ignores its orders while it is piloted, and picks
-- them up again once it is let go. Only one player may pilot a unit at a time.
--
-- The server publishes who pilots what: on the player, the id of the unit they pilot (`piloted_by`), and on the
-- unit's model, the user id of whoever pilots it (MODEL_ATTRIBUTE), and while it is piloted, how long its manual weapon
-- has left to reload (COOLDOWN_ATTRIBUTE).

local types = require(script.Parent.types)
local unit_defs = require(script.Parent.unit_defs)
local entity_attrs = require(script.Parent.entity_attrs)
local replicated = require(script.Parent.replicated)

type EntityDef = types.EntityDef

local PILOTED = replicated.player("pilot", "piloting", replicated.NUMBER)
local MODEL_ATTRIBUTE: entity_attrs.NumberName = "pilot"
local COOLDOWN_ATTRIBUTE: entity_attrs.NumberName = "manual_cooldown"
-- For a piloted transport: whether its hook has something in reach to pick up, and whether it is low enough to set what
-- it carries down.
local LOAD_ATTRIBUTE: entity_attrs.FlagName = "pilot_can_load"
local UNLOAD_ATTRIBUTE: entity_attrs.FlagName = "pilot_can_unload"
-- For a piloted unit that can be carried: whether a transport of its team is near enough to call over to pick it up.
local CALL_ATTRIBUTE: entity_attrs.FlagName = "pilot_can_call"
-- For a piloted unit that has called a transport: "coming" while it is on its way, and "lost" for CALL_LOST_SECONDS
-- once it has been destroyed before it got there.
local CALL_STATE_ATTRIBUTE: entity_attrs.TextName = "pilot_call"
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

-- The unit `player` pilots, if they pilot one.
local function piloted_by(player: Player): number?
	return PILOTED.get(player)
end

-- Calls `listener` whenever what `player` pilots changes, until the returned function is called.
local function piloted_changed(player: Player, listener: () -> ()): () -> ()
	return PILOTED.changed(player, listener)
end

-- The server's side: `player` pilots `entity_id` now, or nothing.
local function publish_piloted(player: Player, entity_id: number?)
	PILOTED.set(player, entity_id)
end

-- Whether a unit made from `def` can be piloted: something that moves on its own, and is not a drone, which answers
-- to its carrier alone.
local function can_pilot(def: EntityDef): boolean
	return unit_defs.moves(def) and unit_defs.is_drone(def) == false
end

-- Whether weapon `index` of `def` can be the one a click fires: any it has but an anti-nuke, which fires only at
-- nuclear missiles.
local function can_select(def: EntityDef, index: number): boolean
	local weapons = def.weapons
	local weapon = if weapons ~= nil then weapons[index] else nil
	return weapon ~= nil and unit_defs.is_anti_nuke(weapon) == false
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

return table.freeze({
	piloted_by = piloted_by,
	piloted_changed = piloted_changed,
	publish_piloted = publish_piloted,
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
})
