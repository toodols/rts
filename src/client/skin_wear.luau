--!strict
-- What a skin hangs on what wears it, over its art: a pool skin's donut (client/donuts.luau). Each kind of thing worn
-- keeps itself on its wearer as art.luau draws it (`wear`), from where the wearer's body is, and is dropped as the
-- wearer goes (`forget`); its art is fetched with everyone else's (`preload`). Art knows nothing of what is worn.

local ReplicatedStorage = game:GetService "ReplicatedStorage"

local skins = require(ReplicatedStorage.Shared.skins)
local types = require(ReplicatedStorage.Shared.types)

local art_pose = require(ReplicatedStorage.ClientShared.art_pose)

local donuts = require(ReplicatedStorage.Client.donuts)

type Skin = skins.Skin
type EntityDef = types.EntityDef

-- A kind of thing a skin may hang on what wears it.
type Worn = {
	wear: (
		model: Model,
		def: EntityDef,
		body: art_pose.Body,
		frame: CFrame,
		skin: Skin,
		wearing: boolean,
		folder: Folder,
		dt: number
	) -> (),
	forget: (model: Model) -> (),
	preload: (timeout: number) -> (),
}

local WORN: { Worn } = { donuts }

-- Keeps on `model`, of `def`, whatever `skin` hangs on it, for this frame, round its body `body` at `frame`, in
-- `folder`, while it is `wearing` anything (finished, not a blueprint or a wreck).
local function wear(
	model: Model,
	def: EntityDef,
	body: art_pose.Body,
	frame: CFrame,
	skin: Skin,
	wearing: boolean,
	folder: Folder,
	dt: number
)
	for _, worn in WORN do
		worn.wear(model, def, body, frame, skin, wearing, folder, dt)
	end
end

-- Drops whatever `model` wore.
local function forget(model: Model)
	for _, worn in WORN do
		worn.forget(model)
	end
end

-- Fetches the art of everything any skin hangs on anything, and returns once it is all in or `timeout` seconds have
-- gone by.
local function preload(timeout: number)
	for _, worn in WORN do
		worn.preload(timeout)
	end
end

return table.freeze({
	wear = wear,
	forget = forget,
	preload = preload,
})
