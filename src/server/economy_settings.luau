--!strict
-- What a team's economy starts from (server/state.luau) and is built up on every tick (server/economy.luau).

local STARTING_METAL = 1000
local STARTING_ENERGY = 1000
-- What a team has with nothing built: no income, and room for only 500 of each. Its commander and
-- its generators, extractors and stores add to these.
local METAL_INCOME = 0
local ENERGY_INCOME = 0
local METAL_CAPACITY = 500
local ENERGY_CAPACITY = 500
-- Converters only run while a team's energy is above this fraction of its storage, so that turning
-- energy into metal never leaves it with none to build with.
local CONVERTER_THRESHOLD = 0.5

return table.freeze({
	STARTING_METAL = STARTING_METAL,
	STARTING_ENERGY = STARTING_ENERGY,
	METAL_INCOME = METAL_INCOME,
	ENERGY_INCOME = ENERGY_INCOME,
	METAL_CAPACITY = METAL_CAPACITY,
	ENERGY_CAPACITY = ENERGY_CAPACITY,
	CONVERTER_THRESHOLD = CONVERTER_THRESHOLD,
})
