-- The tidal strength, beside the wind in the resource bar: the energy a tidal generator makes a second. It is set
-- by the map and only changes when a command sets it, so it is a plain readout with nothing drifting behind it.

local ReplicatedStorage = game:GetService "ReplicatedStorage"

local React = require(ReplicatedStorage.Packages.react)

local environment = require(ReplicatedStorage.Shared.environment)

local function TideBlock(props: { LayoutOrder: number })
	local strength, set_strength = React.useState(environment.tidal_strength())

	React.useEffect(function()
		local connection = environment.tidal_strength_changed():Connect(function()
			set_strength(environment.tidal_strength())
		end)
		return function()
			connection:Disconnect()
		end
	end, {})

	return React.createElement("Frame", {
		[React.Tag] = "tide-block",
		LayoutOrder = props.LayoutOrder,
	}, {
		Label = React.createElement("TextLabel", {
			[React.Tag] = "resource-name",
			LayoutOrder = 1,
			Text = "TIDAL",
		}),
		Value = React.createElement("TextLabel", {
			[React.Tag] = "tide-value",
			LayoutOrder = 2,
			Text = string.format("%g", strength),
		}),
	})
end

return table.freeze({
	TideBlock = TideBlock,
})
