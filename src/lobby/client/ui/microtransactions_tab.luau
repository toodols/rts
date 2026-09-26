--!strict
-- The lobby's Microtransactions tab. Nothing is for sale yet, so for now it only says so; it is where purchases will go.

local ReplicatedStorage = game:GetService "ReplicatedStorage"

local React = require(ReplicatedStorage.Packages.react)

local function MicrotransactionsTab()
	return React.createElement("Frame", {
		[React.Tag] = "microtransactions-tab panel",
	}, {
		Title = React.createElement("TextLabel", {
			[React.Tag] = "microtransactions-title",
			LayoutOrder = 1,
			Text = "NOTHING FOR SALE YET",
		}),
	})
end

return table.freeze({
	MicrotransactionsTab = MicrotransactionsTab,
})
