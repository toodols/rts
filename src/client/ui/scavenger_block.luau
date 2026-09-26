-- The scavengers' difficulty, beside the wind in the resource bar, shown only while the gamemode is on.
--
-- The server sends it (shared/scavenger_state.luau): the difficulty the scavengers may field, which grows
-- exponentially over the game, already rounded to two significant figures, and none at all while the gamemode is
-- off. It is shown roughly, as `~1.3k`, because it is a feel for how bad it has
-- got rather than a number to plan around.

local ReplicatedStorage = game:GetService "ReplicatedStorage"

local React = require(ReplicatedStorage.Packages.react)

local scavenger_state = require(ReplicatedStorage.Shared.scavenger_state)

local format = require(ReplicatedStorage.ClientShared.format)
local use_store = require(ReplicatedStorage.ClientShared.use_store)

-- The difficulty now, or nil while the gamemode is off.
local function use_difficulty(): number?
	return use_store.use_store(scavenger_state.difficulty, scavenger_state.difficulty_changed)
end

local function ScavengerBlock(props: { LayoutOrder: number, difficulty: number })
	return React.createElement("Frame", {
		[React.Tag] = "scavenger-block",
		LayoutOrder = props.LayoutOrder,
	}, {
		Head = React.createElement("Frame", {
			[React.Tag] = "scavenger-head",
			LayoutOrder = 1,
		}, {
			Label = React.createElement("TextLabel", {
				[React.Tag] = "resource-name",
				LayoutOrder = 1,
				Text = "DIFFICULTY",
			}),
		}),
		Value = React.createElement("TextLabel", {
			[React.Tag] = "scavenger-value",
			LayoutOrder = 2,
			Text = `~{format.compact(props.difficulty)}`,
		}),
	})
end

return table.freeze({
	use_difficulty = use_difficulty,
	ScavengerBlock = ScavengerBlock,
})
