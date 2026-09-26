--!strict
-- Posing a def's art piece by piece, wherever it is drawn: a copy of its meshes grouped as its art groups them (a
-- `Rig`), each group turned about its pivot (Shared.art_build.turn_of_group) and its meshes put where that says, and
-- how the pieces that move on their own move: a leg swings as the unit walks, a wheel rolls by the ground it covers, a
-- rotor spins. A match's entities (client/art.luau) and the lobby's scene both pose their art through this, each
-- deciding for itself how far a unit has walked and where its turrets point. And where on a def's art its body is
-- (`body_of`), which what a skin hangs on it is worn round.

local ReplicatedStorage = game:GetService "ReplicatedStorage"

local art = require(ReplicatedStorage.Shared.art)
local art_build = require(ReplicatedStorage.Shared.art_build)

local art_models = require(script.Parent.art_models)

type ArtGroup = art.Group

-- One group of a rig: the art's group, where it turns about, its meshes and where each sits on it, and how far it is
-- turned, in radians.
export type RigGroup = {
	def: ArtGroup,
	pivot: CFrame,
	pieces: { { part: MeshPart, offset: CFrame } },
	angle: number,
}

-- A copy of a def's art to pose: every mesh in `model`, grouped.
export type Rig = {
	model: Model,
	groups: { RigGroup },
}

-- The body of a def's art, which what a skin hangs on it is worn round: the piece it belongs to, the middle of its
-- bulk across the ground in that piece's own frame, the heights of its bottom and its top there, the box round all
-- of it, and its fuselage, if it has one.
export type Body = {
	group: string,
	middle: Vector3,
	bottom: number,
	top: number,
	low: Vector3,
	high: Vector3,
	fuselage: Fuselage?,
}

-- The long, thin run of a body from tail to nose (+Z), which on a plane is its fuselage: the middle of it, how long it
-- is, and how far it reaches out from its middle across, at the most.
export type Fuselage = {
	middle: Vector3,
	length: number,
	radius: number,
}

local TAU = 2 * math.pi
-- A leg whose art does not say: how far it swings either way, in radians, and how many studs of ground one step cycle
-- covers; and a wheel whose art does not give its radius, in studs.
local DEFAULT_SWING = math.rad(25)
local DEFAULT_STRIDE = 3
local DEFAULT_WHEEL_RADIUS = 0.5

-- Each art's body (`body_of`), by art name, once worked out, and the art there is none in.
local bodies: { [string]: Body } = {}
local bodiless: { [string]: boolean } = {}

-- A copy of the art called `name`, its meshes grouped as the art groups them, each at rest, or nil while there is none
-- (art_models.status). Given a `team`, `name` is a def's art and its team parts take the team's colour, as
-- art_models.copy paints them.
local function rig(name: string, team: Color3?): Rig?
	local template = art_models.template(name)
	local parts = art_models.copy_parts(name, team)
	if template == nil or parts == nil then
		return nil
	end
	local model = Instance.new "Model"
	model.Name = name
	local by_name: { [string]: RigGroup } = {}
	local groups: { RigGroup } = {}
	for group_name, group_def in template.art.groups do
		local group: RigGroup = {
			def = group_def,
			pivot = CFrame.new(art_build.vector(group_def.pivot)),
			pieces = {},
			angle = 0,
		}
		by_name[group_name] = group
		table.insert(groups, group)
	end
	for index, source in template.parts do
		local part = parts[index]
		part.Parent = model
		table.insert(by_name[source.group].pieces, { part = part, offset = source.offset })
	end
	return { model = model, groups = groups }
end

-- Puts every piece of `groups` where its group's pivot and angle say, relative to `origin`, the art's origin in the
-- world.
local function place(groups: { RigGroup }, origin: CFrame)
	for _, group in groups do
		local frame = origin * group.pivot * art_build.turn_of_group(group.def, group.angle)
		for _, piece in group.pieces do
			piece.part.CFrame = frame * piece.offset
		end
	end
end

-- How many studs of ground one step cycle of the leg `group` covers.
local function stride(group: ArtGroup): number
	return group.stride or DEFAULT_STRIDE
end

-- The angle of the leg `group` at `cycle` step cycles walked, its swing scaled by `gait`: 1 walking, easing to 0 as
-- it stops.
local function leg_swing(group: ArtGroup, cycle: number, gait: number): number
	return gait * (group.swing or DEFAULT_SWING) * math.sin(TAU * (cycle + (group.phase or 0)))
end

-- How far the wheel `group` turns rolling `distance` studs of ground, in radians, backwards for a negative distance.
local function wheel_turn(group: ArtGroup, distance: number): number
	return distance / (group.radius or DEFAULT_WHEEL_RADIUS)
end

-- The angle of the spinning piece `group` at `angle` once `dt` seconds more have gone by.
local function spin(group: ArtGroup, angle: number, dt: number): number
	return (angle + (group.speed or 0) * dt) % TAU
end

-- Where on `data` its body is: the bulkiest piece that holds still, or turns as a turret or a builder's head does
-- (never a leg, a wheel, a hatch or a spinning piece), which on a bot is its torso, on a tank its hull and on a plane
-- its fuselage. Its middle is the middle of its bulk, which a long thin gun barrel or a wing barely moves. Nil for art
-- with no such piece.
local function find_body(data: art.Art): Body?
	type Box = { low: Vector3, high: Vector3, bulk: Vector3, volume: number }
	local boxes: { [string]: Box } = {}
	for _, part in data.parts do
		local group = data.groups[part.group]
		if group == nil or (group.kind ~= nil and group.kind ~= "turret" and group.kind ~= "work") then
			continue
		end
		local middle, size = art_build.vector(part.offset), art_build.vector(part.size)
		local volume = size.X * size.Y * size.Z
		local box = boxes[part.group]
		if box == nil then
			boxes[part.group] =
				{ low = middle - size / 2, high = middle + size / 2, bulk = middle * volume, volume = volume }
		else
			box.low = box.low:Min(middle - size / 2)
			box.high = box.high:Max(middle + size / 2)
			box.bulk += middle * volume
			box.volume += volume
		end
	end
	local found: string? = nil
	local most = -1
	for name, box in boxes do
		if box.volume > most then
			found, most = name, box.volume
		end
	end
	if found == nil then
		return nil
	end
	local box = boxes[found]
	local middle = if box.volume > 0 then box.bulk / box.volume else (box.low + box.high) / 2
	-- its fuselage: the piece of it longest from tail to nose against how thick it is across, and long for that too.
	-- Pieces are merged by colour, so a wing may share one with the fuselage's paint; it is wide for how long it is.
	-- A flat panel has no thickness and is no fuselage.
	local fuselage: Fuselage? = nil
	local best = 0
	for _, part in data.parts do
		local size = art_build.vector(part.size)
		local across = math.max(size.X, size.Y)
		if part.group ~= found or math.min(size.X, size.Y) <= 0 then
			continue
		end
		local score = size.Z * size.Z / across
		if score > best then
			best = score
			fuselage = { middle = art_build.vector(part.offset), length = size.Z, radius = across / 2 }
		end
	end
	return {
		group = found,
		middle = Vector3.new(middle.X, 0, middle.Z),
		bottom = box.low.Y,
		top = box.high.Y,
		low = box.low,
		high = box.high,
		fuselage = fuselage,
	}
end

-- The body of the art `template` was built from, worked out once.
local function body_of(template: art_models.Template): Body?
	local name = template.name
	if bodies[name] == nil and bodiless[name] == nil then
		local found = find_body(template.art)
		if found == nil then
			bodiless[name] = true
		else
			bodies[name] = found
		end
	end
	return bodies[name]
end

return table.freeze({
	rig = rig,
	body_of = body_of,
	place = place,
	stride = stride,
	leg_swing = leg_swing,
	wheel_turn = wheel_turn,
	spin = spin,
})
