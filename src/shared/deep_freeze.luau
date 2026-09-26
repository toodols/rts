--!strict
-- Freezing a table and every table in it, for data that is built once and then read by everything, like the unit defs
-- and the map presets, so that nothing that reads it can change it for everyone else.

-- Freezes `value` and every table in it, keys included, and returns it. A table that is already frozen is walked all
-- the same, since one frozen at the top may hold ones that are not; one met twice is walked once.
local function deep_freeze<T>(value: T): T
	local seen: { [any]: boolean } = {}
	local function walk(item: any)
		if type(item) ~= "table" or seen[item] == true then
			return
		end
		seen[item] = true
		for key, child in item do
			walk(key)
			walk(child)
		end
		if table.isfrozen(item) == false then
			table.freeze(item)
		end
	end
	walk(value)
	return value
end

return table.freeze({
	deep_freeze = deep_freeze,
})
