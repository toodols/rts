--!strict
-- How rare a def is made to look, on an unlock's card at the end of a campaign mission and a unit's card in the lobby's
-- encyclopedia: a def is of the first tier its power (unit_defs.power: metal plus energy / 60) is below. Roughly, the
-- cheapest T1 things are common, the rest of T1 uncommon, T2 rare, the priciest T2 and the T2 labs epic, T3 legendary,
-- and the biggest experimentals mythic. Each tier's colour is the theme's (ClientShared's stylesheets/_theme.scss's $tiers), which the
-- stylesheets draw a card of its tag in.

local ReplicatedStorage = game:GetService "ReplicatedStorage"

local unit_defs = require(ReplicatedStorage.Shared.unit_defs)

export type TierTag = "common" | "uncommon" | "rare" | "epic" | "legendary" | "mythic"

export type Tier = {
	label: string,
	-- the class its cards take in the stylesheets
	tag: TierTag,
	below: number,
}

local TIERS: { Tier } = table.freeze({
	table.freeze({ label = "COMMON", tag = "common", below = 100 } :: Tier),
	table.freeze({ label = "UNCOMMON", tag = "uncommon", below = 400 } :: Tier),
	table.freeze({ label = "RARE", tag = "rare", below = 1200 } :: Tier),
	table.freeze({ label = "EPIC", tag = "epic", below = 3500 } :: Tier),
	table.freeze({ label = "LEGENDARY", tag = "legendary", below = 15000 } :: Tier),
	table.freeze({ label = "MYTHIC", tag = "mythic", below = math.huge } :: Tier),
})

local function tier_of(def_name: string): Tier
	local power = unit_defs.power(unit_defs.get(def_name))
	for _, tier in TIERS do
		if power < tier.below then
			return tier
		end
	end
	return TIERS[#TIERS]
end

return table.freeze({
	tier_of = tier_of,
})
