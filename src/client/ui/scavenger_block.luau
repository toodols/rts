-- The scavengers' difficulty, beside the wind in the resource bar, shown only while the gamemode is on.
--
-- The server sends it as the `scavenger_difficulty` attribute of Workspace: the difficulty the scavengers may
-- field, which grows exponentially over the game, already rounded to two significant figures, and no attribute
-- at all while the gamemode is off. It is shown roughly, as `~1.3k`, because it is a feel for how bad it has
-- got rather than a number to plan around.

local ReplicatedStorage = game:GetService "ReplicatedStorage"
local Workspace = game:GetService "Workspace"

local React = require(ReplicatedStorage.Packages.react)

local ATTRIBUTE = "scavenger_difficulty"
-- What the state holds while there is no difficulty to show: a state that could be nil would have nothing to
-- tell "not read yet" from "off".
local NONE = -1

local function read_difficulty(): number
	local value = Workspace:GetAttribute(ATTRIBUTE)
	if typeof(value) == "number" then
		return value
	end
	return NONE
end

-- The difficulty now, or nil while the gamemode is off.
local function use_difficulty(): number?
	local difficulty, set_difficulty = React.useState(read_difficulty())

	React.useEffect(function()
		local connection = Workspace:GetAttributeChangedSignal(ATTRIBUTE):Connect(function()
			set_difficulty(read_difficulty())
		end)
		return function()
			connection:Disconnect()
		end
	end, {})

	if difficulty == NONE then
		return nil
	end
	return difficulty
end

-- A number that runs from tens to millions, in the space of the block: `840`, `1.3k`, `83k`, `4.2M`.
local function format_difficulty(value: number): string
	if value < 1000 then
		return string.format("%d", math.floor(value))
	end
	if value >= 1000000 then
		local millions = value / 1000000
		if millions < 10 then
			return string.format("%.1fM", millions)
		end
		return string.format("%dM", math.floor(millions))
	end
	local thousands = value / 1000
	if thousands < 10 then
		return string.format("%.1fk", thousands)
	end
	return string.format("%dk", math.floor(thousands))
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
			Text = `~{format_difficulty(props.difficulty)}`,
		}),
	})
end

return table.freeze({
	use_difficulty = use_difficulty,
	ScavengerBlock = ScavengerBlock,
})
