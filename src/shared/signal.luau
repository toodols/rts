--!strict
-- A list of listeners told about something, for any module that lets others subscribe to what it knows. A signal is a
-- pair of closures over its own listener list, not an object: the owner keeps `fire` to itself and exports `subscribe`.
-- Listeners are told in the order they subscribed, from a copy of the list, so one may unsubscribe (itself or another)
-- while being told.

export type Signal<T...> = {
	-- Tells `listener` every time the signal fires, until the returned function is called.
	subscribe: (listener: (T...) -> ()) -> () -> (),
	fire: (T...) -> (),
}

local function new<T...>(): Signal<T...>
	local listeners: { (T...) -> () } = {}

	local function subscribe(listener: (T...) -> ()): () -> ()
		table.insert(listeners, listener)
		return function()
			local index = table.find(listeners, listener)
			if index ~= nil then
				table.remove(listeners, index)
			end
		end
	end

	local function fire(...: T...)
		for _, listener in table.clone(listeners) do
			listener(...)
		end
	end

	return table.freeze({
		subscribe = subscribe,
		fire = fire,
	})
end

return table.freeze({
	new = new,
})
