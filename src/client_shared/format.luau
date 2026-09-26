--!strict
-- How the HUD and the lobby put numbers, times and text into words, so each is said one way everywhere.
--
-- Rich text is on for every label the stylesheets style, so text anyone can choose (a player's or a team's name, a
-- lobby's host) goes through `escape` before it goes in, or a name like "<b>" would be read as markup.

-- How hurt something looks: its health bar is "healthy" above 60%, "worn" above 30%, and "low" at or below that.
export type HealthLevel = "healthy" | "worn" | "low"

local WORN_BELOW = 0.6
local LOW_BELOW = 0.3

local function escape(text: string): string
	return (
		string.gsub(text, "[<>&\"']", {
			["<"] = "&lt;",
			[">"] = "&gt;",
			["&"] = "&amp;",
			['"'] = "&quot;",
			["'"] = "&apos;",
		})
	)
end

-- A stored or flowing amount of a resource: whole up to 9999, then in thousands to one place (`12.4k`).
local function amount(value: number): string
	if value >= 10000 then
		return string.format("%.1fk", value / 1000)
	end
	return string.format("%d", math.floor(value))
end

-- A number that runs from tens to millions, in little space: `840`, `1.3k`, `83k`, `4.2M`.
local function compact(value: number): string
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

-- A total short enough for a table's column, grouped in thousands up to 99,999: `950`, `12,400`, `125k`, `1.2M`.
local function tally(value: number): string
	if value >= 1e6 then
		return `{string.format("%.1f", value / 1e6)}M`
	elseif value >= 1e5 then
		return `{math.floor(value / 1e3 + 0.5)}k`
	end
	local digits = tostring(math.floor(value + 0.5))
	return (string.reverse((string.gsub(string.reverse(digits), "(%d%d%d)(%d)", "%1,%2"))))
end

-- A clock's reading of `seconds`: minutes and seconds, `4:05`.
local function clock(seconds: number): string
	return string.format("%d:%02d", seconds // 60, seconds % 60)
end

-- Seconds left, counted up to the next whole one: `45s` under a minute, a clock's `1:05` from there.
local function countdown(seconds: number): string
	local whole = math.ceil(seconds)
	if whole >= 60 then
		return clock(whole)
	end
	return `{whole}s`
end

-- How hurt something is that has `fraction` of its health left.
local function health_level(fraction: number): HealthLevel
	if fraction <= LOW_BELOW then
		return "low"
	elseif fraction <= WORN_BELOW then
		return "worn"
	end
	return "healthy"
end

return table.freeze({
	escape = escape,
	amount = amount,
	compact = compact,
	tally = tally,
	clock = clock,
	countdown = countdown,
	health_level = health_level,
})
