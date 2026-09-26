--!strict
-- Where every key press, mouse button and turn of the mouse wheel the game handles goes: to exactly one handler. Each
-- part of the game that takes input puts up a layer (`push`), and the layers stand in a stack, the latest on top. An
-- input that begins goes down the stack until a layer takes it, and when it ends it goes to that same layer, whatever
-- has come or gone since; a turn of the wheel goes down the stack the same way. A layer that is `exclusive` takes
-- everything that reaches it (piloting a unit, whose keys mean other things), so nothing beneath it hears anything, and
-- those beneath are told they are covered while it is up, to drop whatever they were in the middle of.
--
-- What only shows the input, rather than acting on it (a guide's pictures of the keys, a drag on a HUD bar, a reveal
-- that a click hurries along), watches it all (`watch`) as it comes in, before any layer, whichever layer takes it.
--
-- Tab and O are taken through ContextActionService, above Roblox's own uses of them (Tab opens its player list, and O
-- zooms the default camera, which marks the key processed before anything here could see it), and come down the same
-- stack from there, never from the plain input events.

local ContextActionService = game:GetService "ContextActionService"
local ReplicatedStorage = game:GetService "ReplicatedStorage"
local UserInputService = game:GetService "UserInputService"

local signal = require(ReplicatedStorage.Shared.signal)

export type Layer = {
	-- Takes an input that began, or leaves it for the layers beneath, saying which. `processed` is whether the
	-- interface or a text box has already used it.
	began: (input: InputObject, processed: boolean) -> boolean,
	-- An input it took has ended.
	ended: (input: InputObject) -> (),
	-- Takes a turn of the mouse wheel, `delta` notches (positive away from the player), or leaves it, saying which;
	-- a layer without it leaves every turn.
	wheel: ((delta: number) -> boolean)?,
	exclusive: boolean,
	-- Told as an exclusive layer comes up above it (true) and once none is (false).
	covered: ((covered: boolean) -> ())?,
}

-- Where an input watched (`watch`) is: just pressed, moved or turned, or let go.
export type Phase = "began" | "changed" | "ended"

local CLAIM_ACTION = "rts_claimed_keys"
local CLAIMED_KEYS: { Enum.KeyCode } = { Enum.KeyCode.Tab, Enum.KeyCode.O }

-- bottom first
local stack: { Layer } = {}
-- whether each layer is covered, as it was last told
local covered_now: { [Layer]: boolean } = {}
-- the layer that took each input still held, by its key or button
local holders: { [EnumItem]: Layer } = {}
local watched = signal.new() :: signal.Signal<InputObject, Phase, boolean>

local function held_as(input: InputObject): EnumItem
	return if input.UserInputType == Enum.UserInputType.Keyboard then input.KeyCode else input.UserInputType
end

-- Tells each layer whether it is covered now, if that has changed.
local function recover()
	local above = false
	for index = #stack, 1, -1 do
		local layer = stack[index]
		if (covered_now[layer] == true) ~= above then
			covered_now[layer] = above
			if layer.covered ~= nil then
				layer.covered(above)
			end
		end
		above = above or layer.exclusive
	end
end

-- Puts `layer` on top of the stack, until the returned function takes it off.
local function push(layer: Layer): () -> ()
	table.insert(stack, layer)
	recover()
	return function()
		local index = table.find(stack, layer)
		if index == nil then
			return
		end
		table.remove(stack, index)
		covered_now[layer] = nil
		recover()
	end
end

local function began(input: InputObject, processed: boolean)
	watched.fire(input, "began", processed)
	for index = #stack, 1, -1 do
		local layer = stack[index]
		if layer.began(input, processed) or layer.exclusive then
			holders[held_as(input)] = layer
			return
		end
	end
end

local function ended(input: InputObject, processed: boolean)
	watched.fire(input, "ended", processed)
	local key = held_as(input)
	local layer = holders[key]
	holders[key] = nil
	-- a layer taken off since hears no more
	if layer ~= nil and table.find(stack, layer) ~= nil then
		layer.ended(input)
	end
end

local function wheel(delta: number)
	for index = #stack, 1, -1 do
		local layer = stack[index]
		local takes = layer.wheel
		if (takes ~= nil and takes(delta)) or layer.exclusive then
			return
		end
	end
end

local function on_input_began(input: InputObject, processed: boolean)
	if table.find(CLAIMED_KEYS, input.KeyCode) == nil then
		began(input, processed)
	end
end

local function on_input_ended(input: InputObject, processed: boolean)
	if table.find(CLAIMED_KEYS, input.KeyCode) == nil then
		ended(input, processed)
	end
end

local function on_input_changed(input: InputObject, processed: boolean)
	watched.fire(input, "changed", processed)
	-- a wheel turned over the interface scrolls it instead
	if input.UserInputType == Enum.UserInputType.MouseWheel and processed == false then
		wheel(input.Position.Z)
	end
end

local function on_claimed(_, input_state: Enum.UserInputState, input: InputObject): Enum.ContextActionResult
	local processed = UserInputService:GetFocusedTextBox() ~= nil
	if input_state == Enum.UserInputState.Begin then
		began(input, processed)
		return Enum.ContextActionResult.Sink
	end
	ended(input, processed)
	return Enum.ContextActionResult.Pass
end

local function init()
	UserInputService.InputBegan:Connect(on_input_began)
	UserInputService.InputEnded:Connect(on_input_ended)
	UserInputService.InputChanged:Connect(on_input_changed)
	ContextActionService:BindActionAtPriority(
		CLAIM_ACTION,
		on_claimed,
		false,
		Enum.ContextActionPriority.High.Value,
		table.unpack(CLAIMED_KEYS)
	)
end

return table.freeze({
	init = init,
	push = push,
	-- Tells a listener of every input that comes in, with its phase and whether the interface has used it already,
	-- until the returned function is called.
	watch = watched.subscribe,
})
