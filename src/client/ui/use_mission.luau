-- The campaign mission this game is (Client.mission), kept live for a component: nil in any other game.

local ReplicatedStorage = game:GetService "ReplicatedStorage"

local React = require(ReplicatedStorage.Packages.react)

local mission = require(ReplicatedStorage.Client.mission)

local function use_mission(): string?
	local current, set_current = React.useState(mission.current)
	React.useEffect(function()
		-- in case it changed between the first render and this
		set_current(mission.current())
		return mission.subscribe(function(next_mission: string?)
			set_current(next_mission)
		end)
	end, {})
	return current
end

return table.freeze({
	use_mission = use_mission,
})
