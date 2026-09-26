--!strict
-- A record kept for each player in a server, read from a store as they join and saved back as it changes: what the
-- skin and campaign sessions are built on (skin_session.luau, campaign_session.luau), in the lobby and in the game alike.
--
-- As a player joins (`joined`) they are given a fresh record, which is published on them at once, so that nothing ever
-- sees them without one, and what is stored for them is read without holding anything up, and published once it is.
-- Until then nothing can be changed (`change` refuses it), so that nothing is saved over a record not yet read; if it
-- cannot be read at all, as in Studio, where records are not kept (record_store.enabled), they keep what they have for
-- the session, and a change is kept but never saved.

local record_store = require(script.Parent.record_store)

-- How far a player's record has got: being read, read (and so saved as it changes), or not readable, and so only kept
-- for the session.
export type Status = "loading" | "loaded" | "unread"

-- What became of a change: stored as well, kept only for the session (never read, not asked to be saved, or the save
-- failed), or refused (still being read).
export type Outcome = "saved" | "kept" | "refused"

export type Spec<T> = {
	-- what it is, as a player is told of it: "skin", "campaign progress"
	label: string,
	store: record_store.Store<T>,
	key: (user_id: number) -> string,
	-- a player's record before theirs has been read
	fresh: () -> T,
	-- tells the player, and anything that reads it from them, their record as it is now
	publish: (Player, T) -> (),
	-- anything to wait for before what is stored is read, such as whether they are a developer
	prepare: ((Player) -> ())?,
	-- what of a record read from the store is theirs to keep, if not all of it
	admit: ((Player, T) -> T)?,
}

export type Session<T> = {
	-- lifecycle stages (lifecycle.luau)
	joined: (Player) -> (),
	left: (Player) -> (),
	-- `player`'s record as it stands, and how far it has got
	get: (Player) -> T,
	status: (Player) -> Status,
	-- Waits for `player`'s record to be read, and returns whether it was, and why not.
	wait_loaded: (Player) -> (boolean, string?),
	-- Applies `change` to `player`'s record and publishes it, and with `save`, applies it to what is stored too. Yields
	-- while it saves. Returns what became of it, and why it was not saved or was refused.
	change: (Player, change: (T) -> T, save: boolean) -> (Outcome, string?),
}

type Entry<T> = {
	record: T,
	status: Status,
	-- why it could not be read, once it could not
	reason: string?,
	-- threads waiting in `wait_loaded`
	waiting: { thread },
}

local function new<T>(spec: Spec<T>): Session<T>
	local entries: { [Player]: Entry<T> } = {}

	local function entry_of(player: Player): Entry<T>
		local entry = entries[player]
		if entry == nil then
			entry = { record = spec.fresh(), status = "loading", reason = nil, waiting = {} }
			entries[player] = entry
		end
		return entry
	end

	local function settle(entry: Entry<T>, status: Status, reason: string?)
		entry.status = status
		entry.reason = reason
		local waiting = entry.waiting
		entry.waiting = {}
		for _, thread in waiting do
			task.spawn(thread, status == "loaded", reason)
		end
	end

	local function joined(player: Player)
		local entry = entry_of(player)
		spec.publish(player, entry.record)
		task.spawn(function()
			if spec.prepare ~= nil then
				spec.prepare(player)
			end
			local stored, reason = spec.store.load(spec.key(player.UserId))
			if entries[player] ~= entry then
				-- they left while it was being read
				return
			end
			if stored == nil then
				-- where records are not kept at all, as in Studio, that is how it should be
				if record_store.enabled() then
					warn(`could not read {player.Name}'s {spec.label}, so it is kept for this session only: {reason}`)
				end
				settle(entry, "unread", reason)
				return
			end
			entry.record = if spec.admit ~= nil then spec.admit(player, stored) else stored
			spec.publish(player, entry.record)
			settle(entry, "loaded", nil)
		end)
	end

	local function left(player: Player)
		local entry = entries[player]
		entries[player] = nil
		if entry ~= nil then
			settle(entry, "unread", "they left")
		end
	end

	local function get(player: Player): T
		return entry_of(player).record
	end

	local function status(player: Player): Status
		return entry_of(player).status
	end

	local function wait_loaded(player: Player): (boolean, string?)
		local entry = entry_of(player)
		if entry.status ~= "loading" then
			return entry.status == "loaded", entry.reason
		end
		table.insert(entry.waiting, coroutine.running())
		return coroutine.yield()
	end

	local function change(player: Player, apply: (T) -> T, save: boolean): (Outcome, string?)
		local entry = entry_of(player)
		if entry.status == "loading" then
			return "refused", `Your {spec.label} hasn't loaded yet`
		end
		entry.record = apply(entry.record)
		spec.publish(player, entry.record)
		if save == false then
			return "kept", nil
		end
		if entry.status ~= "loaded" then
			return "kept", `Your {spec.label} couldn't be read, so it isn't saved`
		end
		local _, problem = spec.store.update(spec.key(player.UserId), apply)
		if problem ~= nil then
			warn(`could not save {player.Name}'s {spec.label}: {problem}`)
			return "kept", `Couldn't save your {spec.label}; try again`
		end
		return "saved", nil
	end

	return table.freeze({
		joined = joined,
		left = left,
		get = get,
		status = status,
		wait_loaded = wait_loaded,
		change = change,
	})
end

return table.freeze({
	new = new,
})
