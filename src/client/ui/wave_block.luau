-- The counterattack's waves (server/counterattack.luau), at the end of the resource bar while that mission is played:
-- the time left to prepare, then which wave has arrived of how many and the time to the next, and once the final wave
-- has arrived, how many of the enemy's are left. It is drawn as the scavengers' difficulty is, which is never shown
-- in a campaign mission, so it wears that block's tags.
--
-- The server publishes it all as Workspace attributes (campaign.COUNTERATTACK_ATTRIBUTES); `waves` is there only while
-- the mission is played.

local ReplicatedStorage = game:GetService "ReplicatedStorage"
local Workspace = game:GetService "Workspace"

local React = require(ReplicatedStorage.Packages.react)

local campaign = require(ReplicatedStorage.Shared.campaign)

local ATTRIBUTES = campaign.COUNTERATTACK_ATTRIBUTES

export type Waves = {
	-- how many have arrived, 0 while preparing, and how many there are
	wave: number,
	waves: number,
	-- whole seconds to the next, none once the last has arrived
	wave_in: number?,
	-- how many of the enemy's are left standing
	left: number,
}

local function number_attribute(name: string): number?
	local value = Workspace:GetAttribute(name)
	return if typeof(value) == "number" then value else nil
end

local function read_waves(): Waves?
	local waves = number_attribute(ATTRIBUTES.waves)
	if waves == nil then
		return nil
	end
	return {
		wave = number_attribute(ATTRIBUTES.wave) or 0,
		waves = waves,
		wave_in = number_attribute(ATTRIBUTES.wave_in),
		left = number_attribute(ATTRIBUTES.enemies_left) or 0,
	}
end

-- The waves as they stand, or nil outside the counterattack.
local function use_waves(): Waves?
	local waves, set_waves = React.useState(read_waves)

	React.useEffect(function()
		local connections: { RBXScriptConnection } = {}
		for _, name in ATTRIBUTES do
			table.insert(
				connections,
				Workspace:GetAttributeChangedSignal(name):Connect(function()
					set_waves(read_waves())
				end)
			)
		end
		set_waves(read_waves())
		return function()
			for _, connection in connections do
				connection:Disconnect()
			end
		end
	end, {})

	return waves
end

-- Seconds as minutes and seconds: `4:05`.
local function format_time(seconds: number): string
	return string.format("%d:%02d", seconds // 60, seconds % 60)
end

local function WaveBlock(props: { LayoutOrder: number, waves: Waves })
	local waves = props.waves
	local label: string
	local value: string
	if waves.wave == 0 then
		label = "ENEMY IN"
		value = format_time(waves.wave_in or 0)
	elseif waves.wave_in ~= nil then
		label = `WAVE {waves.wave}/{waves.waves}`
		value = format_time(waves.wave_in)
	else
		label = "FINAL WAVE"
		value = `{waves.left} left`
	end
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
				Text = label,
			}),
		}),
		Value = React.createElement("TextLabel", {
			[React.Tag] = "scavenger-value",
			LayoutOrder = 2,
			Text = value,
		}),
	})
end

return table.freeze({
	use_waves = use_waves,
	WaveBlock = WaveBlock,
})
