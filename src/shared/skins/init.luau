-- Skins: other looks for the same units. A team wears one, and everything it makes wears it too, as `Entity.skin`,
-- which the client reads off the `skin` attribute. Every special skin is opt in: a team wears config.DEFAULT_SKIN, which
-- has to be plain, until its player equips something else (server/skins.luau).
--
-- A skin can be a different model altogether (`art`: the art to draw instead, by def name), the same model repainted
-- (`paint`), or the same model with things hung on it (`attachments`, like the pool skin's donut). All of that is
-- only drawn, on the client (client/art.luau and client/donuts.luau). A developer's skin may also change the numbers
-- (`stats`), which the server reads through `unit_defs.of`; `boost` is what it does to a def.

local ReplicatedStorage = game:GetService "ReplicatedStorage"

local config = require(ReplicatedStorage.Shared.config)
local types = require(ReplicatedStorage.Shared.types)

local default = require(script.default)
local golden = require(script.golden)
local pool = require(script.pool)

type EntityDef = types.EntityDef
type Skin = types.Skin
type SkinStats = types.SkinStats
type Weapon = types.Weapon

local SKINS: { [string]: Skin } = {
	[default.name] = default,
	[pool.name] = pool,
	[golden.name] = golden,
}

for name, skin in SKINS do
	-- a skin that changes the game has to be kept from players
	assert(skin.stats == nil or skin.developer_only, `skin "{name}" has stats, so it must be developer_only`)
end
assert(SKINS[config.DEFAULT_SKIN] ~= nil, `config.DEFAULT_SKIN "{config.DEFAULT_SKIN}" is not a skin`)
do
	-- special skins are opt in, so what everyone wears unasked is units as they are
	local plain = SKINS[config.DEFAULT_SKIN]
	assert(
		plain.stats == nil and plain.art == nil and plain.paint == nil and #plain.attachments == 0,
		`config.DEFAULT_SKIN "{config.DEFAULT_SKIN}" must be a plain skin: special skins are opt in`
	)
end

local function exists(name: string): boolean
	return SKINS[name] ~= nil
end

-- The skin called `name`, or the default one for a name that is not a skin.
local function get(name: string?): Skin
	local skin = if name ~= nil then SKINS[name] else nil
	if skin == nil then
		return SKINS[config.DEFAULT_SKIN]
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
	local projectile = weapon.projectile
	-- a shell's reach is bounded by how fast it leaves the barrel, which goes as the root of the range; one that is
	-- let go, or that nothing pulls down, gets there anyway
	if projectile ~= nil and projectile.gravity > 0 and projectile.dropped ~= true then
		local faster = table.clone(projectile)
		faster.speed = projectile.speed * math.sqrt(range)
		boosted.projectile = faster
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
	boosted.health = def.health * health
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
	exists = exists,
	get = get,
	names = names,
	may_wear = may_wear,
	boost = boost,
})
