-- What covers the screen while the game is paused (the `paused` switch, see shared/switches.luau): the whole screen dimmed, with PAUSED across
-- the middle. It only dims: clicks go through to the world, so what is on the field can still be selected and looked at.

local ReplicatedStorage = game:GetService "ReplicatedStorage"

local React = require(ReplicatedStorage.Packages.react)

local switches = require(ReplicatedStorage.Shared.switches)

local use_store = require(ReplicatedStorage.ClientShared.use_store)

local function paused(): boolean
	return switches.is_on "paused"
end

local function paused_changed(listener: () -> ()): () -> ()
	return switches.changed("paused", listener)
end

local function PauseOverlay()
	if use_store.use_store(paused, paused_changed) == false then
		return nil
	end
	return React.createElement("Frame", {
		[React.Tag] = "pause-overlay",
	}, {
		Plate = React.createElement("Frame", {
			[React.Tag] = "pause-plate",
		}, {
			Title = React.createElement("TextLabel", {
				[React.Tag] = "pause-title",
				LayoutOrder = 1,
				Text = "PAUSED",
			}),
		}),
	})
end

return table.freeze({
	PauseOverlay = PauseOverlay,
})
