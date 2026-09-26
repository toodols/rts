--!strict
-- The campaign mission this game is, if it is one (Shared.campaign), as the client plays it: the server says which
-- (Shared.mission_state), and the HUD puts itself in that mission's state. Each mission's guide, the steps it walks its
-- player through (Client.tutorial runs them), is its own module here, one to a mission id in GUIDES; a mission with
-- none guides nobody.

local ReplicatedStorage = game:GetService "ReplicatedStorage"

local campaign = require(ReplicatedStorage.Shared.campaign)
local mission_map = require(ReplicatedStorage.Shared.mission_map)
local mission_state = require(ReplicatedStorage.Shared.mission_state)

local world = require(ReplicatedStorage.Client.world)

local kit = require(script.kit)
local tutorial = require(script.tutorial)
local overlook = require(script.overlook)
local counterattack = require(script.counterattack)
local channel = require(script.channel)
local blockade = require(script.blockade)

type Mission = campaign.Mission

export type Guide = kit.Guide
export type Step = kit.Step
export type Card = kit.Card
export type Picture = kit.Picture
export type PictureKind = kit.PictureKind
export type Feature = kit.Feature
export type Objective = kit.Objective

local GUIDES: { [string]: Guide } = table.freeze({
	tutorial = tutorial,
	overlook = overlook,
	counterattack = counterattack,
	channel = channel,
	blockade = blockade,
})

-- The id of the mission being played, if one is.
local function current(): string?
	return mission_state.mission()
end

-- The mission being played, if one is.
local function current_mission(): Mission?
	local id = current()
	return if id ~= nil then campaign.get(id) else nil
end

-- Calls `listener` with the mission's id whenever it changes, and when it begins again. Returns a function that stops.
local function subscribe(listener: (mission_id: string?) -> ()): () -> ()
	return mission_state.subscribe_mission(listener)
end

-- The guide of the mission `mission_id`, if it has one.
local function guide_of(mission_id: string): Guide?
	return GUIDES[mission_id]
end

-- Where the view opens in the mission being played: over your commander, or until it is down, over the mission's
-- start, where it goes down. Nil outside a mission, or in one whose players choose their starts, where the view opens
-- over the start the player chooses.
local function start_view(): Vector3?
	local mission = current_mission()
	local start = if mission ~= nil then mission_map.player_start(mission.preset) else nil
	if start == nil then
		return nil
	end
	local commanders = world.my_commanders()
	if #commanders > 0 then
		return world.position_of(commanders[1])
	end
	return Vector3.new(start.X, 0, start.Y)
end

return table.freeze({
	current = current,
	current_mission = current_mission,
	subscribe = subscribe,
	guide_of = guide_of,
	start_view = start_view,
	every_check = kit.every_check,
	begin_step_view = kit.begin_step_view,
	look_back = kit.look_back,
	forget_view = kit.forget_view,
})
