--!strict
-- Tells every client about a shot (shared/shot_events), through the WeaponFired remote: the one way the server does.

local ReplicatedStorage = game:GetService "ReplicatedStorage"

local shot_events = require(ReplicatedStorage.Shared.shot_events)

local weapon_fired: RemoteEvent = ReplicatedStorage.Shared.WeaponFired

local function send(event: shot_events.Event)
	weapon_fired:FireAllClients(event)
end

return table.freeze({
	send = send,
})
