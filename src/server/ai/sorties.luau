--!strict
-- What a brain's army and groups tell whoever is watching (inspect.luau): each wave and group it sends out, how each
-- wave ended, each fight it asked the fight predictor about, and on how many fronts it fights, each time it thinks.
-- The brains keep none of it themselves, but for a group's own sortie, which it counts its kills and how it ended on.

local ReplicatedStorage = game:GetService "ReplicatedStorage"

local signal = require(ReplicatedStorage.Shared.signal)

local brains = require(script.Parent.brains)

type Brain = brains.Brain

export type Sortie = brains.Sortie
export type WaveEnd = brains.WaveEnd

export type Kind = "wave" | brains.GroupKind

local sent = signal.new() :: signal.Signal<Brain, Kind, Sortie>
local ended = signal.new() :: signal.Signal<Brain, WaveEnd>
local predicted = signal.new() :: signal.Signal<Brain, number>
local fronts = signal.new() :: signal.Signal<Brain, number>

return table.freeze({
	-- `brain` sent a wave or a group out.
	on_sent = sent.subscribe,
	sent = sent.fire,
	-- `brain`'s wave out has ended.
	on_ended = ended.subscribe,
	ended = ended.fire,
	-- `brain` asked the fight predictor about a fight, which took this many seconds.
	on_predicted = predicted.subscribe,
	predicted = predicted.fire,
	-- `brain` has thought, and is attacking this many places at once: the wave's target, and each raid's and strike's.
	on_fronts = fronts.subscribe,
	fronts = fronts.fire,
})
