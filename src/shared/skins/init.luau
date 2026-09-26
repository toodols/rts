--!strict
-- Skins: other looks for the same units. A team wears one, and everything it makes wears it too, as `Entity.skin`,
-- which the client reads off the `skin` attribute. Every special skin is opt in: a team wears DEFAULT_SKIN, which
-- has to be plain, until its player equips something else (server/skins.luau).
--
-- A skin can be a different model altogether (`art`: the art to draw instead, by def name), the same model repainted
-- (`paint`), or the same model with a pool donut on it (`donut`). All of that is only drawn, on the client
-- (client/art.luau and client/donuts.luau). A developer's skin may also change the numbers (`stats`), which the server
-- reads through `unit_defs.skinned`; `boost` is what it does to a def.

local ReplicatedStorage = game:GetService "ReplicatedStorage"

local types = require(ReplicatedStorage.Shared.types)
local replicated = require(ReplicatedStorage.Shared.replicated)

local skin_types = require(script.types)
local default = require(script.default)
local golden = require(script.golden)
local pool = require(script.pool)

type EntityDef = types.EntityDef
type Weapon = types.Weapon

export type Skin = skin_types.Skin
export type SkinStats = skin_types.SkinStats
export type SkinPaint = skin_types.SkinPaint
export type DonutSettings = skin_types.DonutSettings
export type DonutVariant = skin_types.DonutVariant

-- The skin every team starts in, and what everything wears that nobody chose a skin for: units as they are. Every
-- special skin is opt in: a team wears one only when its player has equipped it, or a developer's command puts it on.
local DEFAULT_SKIN = "default"

local SKINS: { [string]: Skin } = {
	[default.name] = default,
	[pool.name] = pool,
	[golden.name] = golden,
}

for name, skin in SKINS do
	-- a skin that changes the game has to be kept from players
	assert(skin.stats == nil or skin.developer_only, `skin "{name}" has stats, so it must be developer_only`)
end
assert(SKINS[DEFAULT_SKIN] ~= nil, `DEFAULT_SKIN "{DEFAULT_SKIN}" is not a skin`)
do
	-- special skins are opt in, so what everyone wears unasked is units as they are
	local plain = SKINS[DEFAULT_SKIN]
	assert(
		plain.stats == nil and plain.art == nil and plain.paint == nil and plain.donut == nil,
		`DEFAULT_SKIN "{DEFAULT_SKIN}" must be a plain skin: special skins are opt in`
	)
end

-- The skin each player has equipped, as a server publishes it on them (server_shared/skin_session.luau).
local EQUIPPED = replicated.player("skin", "equipped", replicated.STRING)

-- The skin `player` has equipped, as a server published it; the default until it has.
local function equipped_by(player: Player): string
	return EQUIPPED.get(player) or DEFAULT_SKIN
end

-- Calls `listener` whenever the skin `player` has equipped is published, until the returned function is called.
local function equipped_changed(player: Player, listener: () -> ()): () -> ()
	return EQUIPPED.changed(player, listener)
end

-- The server's side.
local function publish_equipped(player: Player, skin_name: string)
	EQUIPPED.set(player, skin_name)
end

local function exists(name: string): boolean
	return SKINS[name] ~= nil
end

-- The skin called `name`, or the default one for a name that is not a skin.
local function get(name: string?): Skin
	local skin = if name ~= nil then SKINS[name] else nil
	if skin == nil then
		return SKINS[DEFAULT_SKIN]
	end
	return skin
end

-- Every skin's name, in order.
local function names(): { string }
	local found = {}
	for name in SKINS do
		table.insert(found, name)
	end
	table.sort(found)
	return found
end

-- Whether someone may put on the skin called `name`: anyone, unless it is a developer's.
local function may_wear(name: string, developer: boolean): boolean
	local skin = SKINS[name]
	return skin ~= nil and (skin.developer_only == false or developer)
end

local function boost_weapon(weapon: Weapon, damage: number, range: number): Weapon
	local boosted = table.clone(weapon)
	boosted.damage = weapon.damage * damage
	boosted.range = weapon.range * range
	local delivery = weapon.delivery
	-- a shell's reach is bounded by how fast it leaves the barrel, which goes as the root of the range; a bomb, or a
	-- shot that nothing pulls down, gets there anyway
	if delivery.kind ~= "beam" and delivery.kind ~= "bomb" and delivery.projectile.gravity > 0 then
		local faster = table.clone(delivery)
		faster.projectile = table.clone(delivery.projectile)
		faster.projectile.speed = delivery.projectile.speed * math.sqrt(range)
		boosted.delivery = faster
	end
	return boosted
end

-- A copy of `def` with `stats` applied to it: more health, and every weapon (the manual one too) reaching further and
-- hitting harder, as does a carrier's reach with its drones.
local function boost(def: EntityDef, stats: SkinStats): EntityDef
	local health = stats.health or 1
	local damage = stats.damage or 1
	local range = stats.range or 1
	local boosted = table.clone(def)
	boosted.health = if def.health ~= nil then def.health * health else nil
	if def.weapons ~= nil then
		local weapons = table.create(#def.weapons)
		for index, weapon in def.weapons do
			weapons[index] = boost_weapon(weapon, damage, range)
		end
		boosted.weapons = weapons
	end
	if def.manual_weapon ~= nil then
		local manual = table.clone(def.manual_weapon)
		manual.range = def.manual_weapon.range * range
		boosted.manual_weapon = manual
	end
	if def.carrier ~= nil then
		local carrier = table.clone(def.carrier)
		carrier.engage_range = def.carrier.engage_range * range
		boosted.carrier = carrier
	end
	return boosted
end

return table.freeze({
	DEFAULT_SKIN = DEFAULT_SKIN,
	equipped_by = equipped_by,
	equipped_changed = equipped_changed,
	publish_equipped = publish_equipped,
	exists = exists,
	get = get,
	names = names,
	may_wear = may_wear,
	boost = boost,
})
