--!strict
-- The game's switches: what a developer turns on and off with pow (the `godmode`, `nocost`, `pause` and `scavengers`
-- commands), and what a match sets for the scavengers. Each is a replicated field (shared/replicated.luau), set by the
-- server, so that a client sees it too: whose units it may select (godmode), whether to dim the screen (paused).
--
-- - godmode: every player commands every real team's units and buildings.
-- - nocost: everything builds for free and at once.
-- - paused: the simulation does not step at all.
-- - scavengers: the scavengers play (see server/scavengers.luau): opt in, off unless a game asks for them (a lobby's
--   scavengers mode, or the scavengers command). Off, no new beacon comes and those standing make nothing, but what is
--   already out there carries on, and the game's progress keeps rising, so turning it on again picks up where it has
--   got to.
--
-- The debugging ones are off unless a developer turns them on, so nothing about a normal game depends on them.

local ReplicatedStorage = game:GetService "ReplicatedStorage"

local replicated = require(ReplicatedStorage.Shared.replicated)

export type Name = "godmode" | "nocost" | "paused" | "scavengers"

-- Every switch, in the order they are listed.
local NAMES: { Name } = { "godmode", "nocost", "paused", "scavengers" }

-- What a switch is before anything has set it.
local DEFAULTS: { [Name]: boolean } = {
	godmode = false,
	nocost = false,
	paused = false,
	scavengers = false,
}

local FIELDS: { [Name]: replicated.WorldField<boolean> } = {}
for _, name: Name in NAMES do
	FIELDS[name] = replicated.world("switch", name, replicated.BOOLEAN)
end

local function is_on(name: Name): boolean
	local value = FIELDS[name].get()
	if value ~= nil then
		return value
	end
	return DEFAULTS[name]
end

-- What switch `name` is before anything has set it.
local function default(name: Name): boolean
	return DEFAULTS[name]
end

-- Calls `listener` whenever switch `name` is turned, until the returned function is called.
local function changed(name: Name, listener: () -> ()): () -> ()
	return FIELDS[name].changed(listener)
end

-- The server's side.
local function set(name: Name, on: boolean)
	FIELDS[name].set(on)
end

-- The switches that are on, in order.
local function active(): { Name }
	local on: { Name } = {}
	for _, name: Name in NAMES do
		if is_on(name) then
			table.insert(on, name)
		end
	end
	return on
end

return table.freeze({
	NAMES = NAMES,
	is_on = is_on,
	default = default,
	changed = changed,
	set = set,
	active = active,
})
