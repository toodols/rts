--!strict
-- What the HUD shows in the game being played, as a hook: everything, but in a campaign mission what its `hud` pares
-- away (Shared.campaign) and what its guide has not yet taught (Client.tutorial's `shown`). No component asks which
-- mission it is; each asks this.

local ReplicatedStorage = game:GetService "ReplicatedStorage"

local missions = require(ReplicatedStorage.Client.missions)
local tutorial = require(ReplicatedStorage.Client.tutorial)

local use_store = require(ReplicatedStorage.ClientShared.use_store)

export type HudFeatures = {
	-- the selection panel pared down to a name, a team and a health bar
	simple: boolean,
	-- the metal and energy bar, and what things make and spend
	economy: boolean,
	-- what a unit or building fights with, in the selection panel
	weapons: boolean,
}

local function same(a: HudFeatures, b: HudFeatures): boolean
	return a.simple == b.simple and a.economy == b.economy and a.weapons == b.weapons
end

-- the features last read, handed out again for as long as they are the same, so that nothing renders again for them
local last: HudFeatures? = nil

local function read(): HudFeatures
	local mission = missions.current_mission()
	local features: HudFeatures = table.freeze({
		simple = mission ~= nil and mission.hud == "simple",
		economy = tutorial.shown "economy",
		weapons = tutorial.shown "weapons",
	})
	if last ~= nil and same(last, features) then
		return last
	end
	last = features
	return features
end

-- Tells `listener` whenever the mission or its guide changes, until the returned function is called.
local function subscribe(listener: () -> ()): () -> ()
	local stop_mission = missions.subscribe(listener)
	local stop_guide = tutorial.subscribe(listener)
	return function()
		stop_mission()
		stop_guide()
	end
end

local function use_hud_features(): HudFeatures
	return use_store.use_store(read, subscribe)
end

return table.freeze({
	use_hud_features = use_hud_features,
})
