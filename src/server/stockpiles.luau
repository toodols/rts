-- Stockpiles: things built up ahead of time and held until they are used, one at a time. A weapon's missiles are
-- (`Weapon.stockpile`), and so are a carrier's drones (`Carrier.stockpile`), as BAR's drone carriers build theirs.
-- Every `build_time` seconds one more is finished, up to `limit`, and it is paid for as it is built, a share of its
-- `metal` and `energy` with each moment of work (`economy.spend`). A moment that cannot be paid for is not
-- worked, so one that cannot be afforded waits until it can. Nothing is built while the stockpile is full, and
-- building goes on whatever what uses it is doing: a weapon reloading, or drones out fighting.

local ReplicatedStorage = game:GetService "ReplicatedStorage"

local types = require(ReplicatedStorage.Shared.types)
local entity_attrs = require(ReplicatedStorage.Shared.entity_attrs)

local economy = require(script.Parent.economy)

-- Works `delta` seconds on the next of `owner`'s `stockpile`, whose `stocked` it adds to.
local function grow(owner: types.Entity, stockpile: types.Stockpile, stocked: types.Stocked, delta: number)
	if stocked.held >= stockpile.limit then
		stocked.progress = 0
		return
	end
	local step = math.min(stockpile.build_time - stocked.progress, delta)
	if step > 0 then
		local share = step / stockpile.build_time
		if economy.spend(owner.team, stockpile.metal * share, stockpile.energy * share, owner.id) == false then
			return
		end
		stocked.progress += step
	end
	if stocked.progress >= stockpile.build_time then
		stocked.held += 1
		stocked.progress = 0
	end
end

-- The stockpile of `entity`'s of `def` it shows, and what that holds: a carrier's drones in reserve, or else the
-- missiles of its first weapon that stockpiles any; nil for something with none.
local function shown(entity: types.Entity, def: types.EntityDef): (types.Stockpile?, types.Stocked?)
	if def.carrier ~= nil then
		return def.carrier.stockpile, entity.drone_stockpile
	end
	local weapons: { types.Weapon } = def.weapons or {}
	for index, weapon in weapons do
		if weapon.stockpile ~= nil then
			return weapon.stockpile, entity.weapon_stockpiles[index]
		end
	end
	return nil, nil
end

-- Publishes how many of `entity`'s stockpile (`shown`) are held ready (`stockpile`), the most it can hold
-- (`stockpile_limit`), and how far along the next one is (`stockpile_progress`, to a hundredth).
local function publish(entity: types.Entity, def: types.EntityDef, write: entity_attrs.Publish)
	local stockpile, stocked = shown(entity, def)
	if stockpile == nil or stocked == nil then
		return
	end
	write("stockpile", stocked.held)
	write("stockpile_limit", stockpile.limit)
	write(
		"stockpile_progress",
		if stocked.held >= stockpile.limit then 1 else math.floor(stocked.progress / stockpile.build_time * 100) / 100
	)
end

return table.freeze({
	grow = grow,
	publish = publish,
})
