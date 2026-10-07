--!strict
-- A player's level (campaign.level) worn as a rank: a diamond in the colour of its tier with the level on it. The tiers
-- are the theme's rarity colours, a fifth of the way to 100 each, and 100 itself the last of them.

local ReplicatedStorage = game:GetService "ReplicatedStorage"

local React = require(ReplicatedStorage.Packages.react)

local TIERS = { "common", "uncommon", "rare", "epic", "legendary" }
local TOP_TIER = "mythic"
local TIER_SPAN = 20

-- The tier `level` is in.
local function tier_of(level: number): string
	if level >= 100 then
		return TOP_TIER
	end
	return TIERS[math.clamp(math.floor(level / TIER_SPAN) + 1, 1, #TIERS)]
end

-- `small` is the browser's size; the seats' otherwise.
local function Insignia(props: { level: number, small: boolean?, LayoutOrder: number? })
	local tag = `rank {tier_of(props.level)}`
	if props.small then
		tag ..= " small"
	end
	return React.createElement("Frame", {
		[React.Tag] = tag,
		LayoutOrder = props.LayoutOrder,
	}, {
		Diamond = React.createElement("Frame", {
			[React.Tag] = "rank-diamond",
		}, {
			Core = React.createElement("Frame", {
				[React.Tag] = "rank-core",
			}),
		}),
		Number = React.createElement("TextLabel", {
			[React.Tag] = "rank-number",
			Text = tostring(props.level),
		}),
	})
end

return table.freeze({
	TIERS = TIERS,
	TIER_SPAN = TIER_SPAN,
	tier_of = tier_of,
	Insignia = Insignia,
})
