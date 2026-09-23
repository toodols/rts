-- Stockpiles: things built up ahead of time and held until they are used, one at a time. A weapon's missiles are
-- (`Weapon.stockpile`), and so are a carrier's drones (`Carrier.stockpile`), as BAR's drone carriers build theirs.
-- Every `build_time` seconds one more is finished, up to `limit`, and it is paid for as it is built, a share of its
-- `metal` and `energy` with each moment of work (`economy.try_spend`). A moment that cannot be paid for is not
-- worked, so one that cannot be afforded waits until it can. Nothing is built while the stockpile is full, and
-- building goes on whatever what uses it is doing: a weapon reloading, or drones out fighting.

local ReplicatedStorage = game:GetService "ReplicatedStorage"

local types = require(ReplicatedStorage.Shared.types)

local economy = require(script.Parent.economy)

-- Works `delta` seconds on the next of `stockpile` for `team`, which holds `held` finished and is `progress` seconds
-- into the next. Returns how many it holds and how far into the next it is after.
local function grow(
	team: types.TeamId,
	stockpile: types.Stockpile,
	held: number,
	progress: number,
	delta: number
): (number, number)
	if held >= stockpile.limit then
		return held, 0
	end
	local step = math.min(stockpile.build_time - progress, delta)
	if step > 0 then
		local share = step / stockpile.build_time
		if economy.try_spend(team, stockpile.metal * share, stockpile.energy * share) == false then
			return held, progress
		end
		progress += step
	end
	if progress >= stockpile.build_time then
		return held + 1, 0
	end
	return held, progress
end

return table.freeze({
	grow = grow,
})
