-- The tutorial's state (Client.tutorial) as a hook: re-renders whenever the step, or what is done in it, changes.

local ReplicatedStorage = game:GetService "ReplicatedStorage"

local React = require(ReplicatedStorage.Packages.react)

local tutorial = require(ReplicatedStorage.Client.tutorial)

type State = tutorial.State

local function use_tutorial(): State
	local state, set_state = React.useState(tutorial.get)
	React.useEffect(function()
		set_state(tutorial.get())
		return tutorial.subscribe(set_state)
	end, {})
	return state
end

return table.freeze({
	use_tutorial = use_tutorial,
})
