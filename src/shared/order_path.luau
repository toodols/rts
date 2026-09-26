--!strict
-- A unit's order queue as the server publishes it on its model (the `path` attribute, server/instances.luau), for the
-- client to draw the way it will go and to plan from where its queue leaves it: one step per order that goes
-- somewhere, front of the queue first, `kind,x,z,target,facing,radius,launch` each and `;` between them. `target` is
-- what a build order builds, or the id of what any other order is aimed at; `facing`, `radius` and `launch` are empty
-- where they do not apply. Whole studs are plenty for something that is only drawn, and every write is a replication.

local ReplicatedStorage = game:GetService "ReplicatedStorage"

local types = require(ReplicatedStorage.Shared.types)
local order_kinds = require(ReplicatedStorage.Shared.order_kinds)

type Order = types.Order
type OrderKind = types.OrderKind

-- One order of a published queue, where it goes on the ground (with no height: the reader drops it onto whatever it
-- rests on), and what else the order says.
export type Step = {
	kind: OrderKind,
	x: number,
	z: number,
	-- what an order aimed at something is aimed at, and what a build order builds, turned how
	target_id: types.EntityId?,
	def_name: string?,
	facing: number?,
	-- the circle an area order covers
	radius: number?,
	-- an attack that fires the manual-fire weapons (`Order.launch`)
	launch: boolean,
}

-- `orders` as published, each where `position_of` says it goes, and left out where that is nowhere.
local function encode(orders: { Order }, position_of: (Order) -> Vector3?): string
	local steps = table.create(#orders)
	for _, order in orders do
		local position = position_of(order)
		if position == nil then
			continue
		end
		local target = if order.kind == "build"
			then order.def_name or ""
			elseif order.target_id ~= nil then tostring(order.target_id)
			else ""
		local facing = if order.facing ~= nil then string.format("%.2f", order.facing) else ""
		local radius = if order.radius ~= nil then tostring(math.round(order.radius)) else ""
		local launch = if order.launch == true then "1" else ""
		table.insert(
			steps,
			`{order.kind},{math.round(position.X)},{math.round(position.Z)},{target},{facing},{radius},{launch}`
		)
	end
	return table.concat(steps, ";")
end

-- One step of a published queue, or nil for one that is not a step at all.
local function decode_step(text: string): Step?
	local fields = string.split(text, ",")
	local kind: OrderKind = fields[1] :: any
	local known: order_kinds.Kind? = order_kinds.get(kind)
	local x, z = tonumber(fields[2]), tonumber(fields[3])
	if x == nil or z == nil or known == nil then
		return nil
	end
	local build = kind == "build"
	local target = fields[4]
	local step: Step = {
		kind = kind,
		x = x,
		z = z,
		target_id = if build then nil else tonumber(target),
		def_name = if build and target ~= nil and target ~= "" then target else nil,
		facing = tonumber(fields[5]),
		radius = tonumber(fields[6]),
		launch = fields[7] == "1",
	}
	return step
end

-- Every step of a published queue. Queues are few and the same text is read every frame, so each is decoded once,
-- and a long session does not keep them all.
local MAX_DECODED = 256
local decoded: { [string]: { Step } } = {}
local decoded_count = 0
local function decode(text: string): { Step }
	local cached = decoded[text]
	if cached ~= nil then
		return cached
	end
	local steps: { Step } = {}
	if text ~= "" then
		for _, part in string.split(text, ";") do
			local step = decode_step(part)
			if step ~= nil then
				table.insert(steps, step)
			end
		end
	end
	table.freeze(steps)
	if decoded_count >= MAX_DECODED then
		table.clear(decoded)
		decoded_count = 0
	end
	decoded[text] = steps
	decoded_count += 1
	return steps
end

-- The last step of a published queue, where the unit is once it has carried out all of it, if it has any.
local function last(text: string): Step?
	local steps = decode(text)
	return steps[#steps]
end

return table.freeze({
	encode = encode,
	decode = decode,
	last = last,
})
