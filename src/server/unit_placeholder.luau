-- Procedural stand-in art for units that have no model file yet, laid out around the model's origin.
--
-- Every shape is worked out from the def's collider, and stays inside the cylinder that collider stands
-- for: no further from the centre than its radius, and between the bottom and the top of its height.
-- What it looks like comes from what the unit is:
--   * a vehicle is a car: a low rectangular hull on tracks with a cab or turret on top, and a barrel if
--     it is armed. A ship is the same without the tracks and longer and thinner.
--   * a bot is a stack of cylinders: legs, a torso and a head with a visor. How the two are proportioned
--     comes from a hash of its name, so bots differ from each other but a given bot always looks the same.
--   * an aircraft is a flat isosceles triangle with a canopy on it.
-- A unit that can build, repair, reclaim or assist has one high visibility yellow part. The front of a
-- unit is +Z.
--
-- Parts named "Team" are tinted with the team colour, as they are on a real model; the rest keep the
-- colour they are given here.

local ReplicatedStorage = game:GetService "ReplicatedStorage"

local types = require(ReplicatedStorage.Shared.types)
local unit_defs = require(ReplicatedStorage.Shared.unit_defs)

type EntityDef = types.EntityDef

local TEAM_PART = "Team"
local HIGH_VIS = Color3.fromRGB(255, 214, 0)
local DARK = Color3.fromRGB(48, 50, 56)
local BARREL = Color3.fromRGB(28, 28, 30)
local LIGHT_GREY = Color3.fromRGB(170, 174, 182)

-- Width over length of each footprint.
local VEHICLE_ASPECT = 0.6
local SHIP_ASPECT = 0.38
local AIR_ASPECT = 0.85

local function is_builder(def: EntityDef): boolean
	return def.build_options ~= nil or def.repairing or def.reclaiming or def.assisting
end

-- The width and length of the biggest rectangle of this proportion that fits inside a circle of `radius`,
-- so that its corners land on the collider's edge.
local function fit_rect(radius: number, aspect: number): (number, number)
	local length = 2 * radius / math.sqrt(1 + aspect * aspect)
	return length * aspect, length
end

-- A number in [0, 1] taken from five bits of `seed`; each slot reads different bits.
local function unit_interval(seed: number, slot: number): number
	return bit32.extract(seed, slot * 5, 5) / 31
end

local function hash_name(name: string): number
	local hash = 5381
	for index = 1, #name do
		hash = (hash * 33 + string.byte(name, index)) % 4294967296
	end
	return hash
end

-- Anchored, out of the simulation's way, but pickable: the client raycasts against these.
local function finish(
	part: BasePart,
	model: Model,
	name: string,
	size: Vector3,
	cframe: CFrame,
	color: Color3?
): BasePart
	part.Name = name
	part.Anchored = true
	part.CanCollide = false
	part.CanQuery = true
	part.CanTouch = false
	part.Material = Enum.Material.Metal
	part.TopSurface = Enum.SurfaceType.Smooth
	part.BottomSurface = Enum.SurfaceType.Smooth
	part.Size = size
	part.CFrame = cframe
	if color ~= nil then
		part.Color = color
	end
	part.Parent = model
	return part
end

local function add_block(model: Model, name: string, size: Vector3, center: Vector3, color: Color3?): BasePart
	local part = Instance.new "Part"
	part.Shape = Enum.PartType.Block
	return finish(part, model, name, size, CFrame.new(center), color)
end

-- A Cylinder part's flat faces point along X, so it is rolled to stand upright.
local function add_cylinder(
	model: Model,
	name: string,
	radius: number,
	height: number,
	center: Vector3,
	color: Color3?
): BasePart
	local part = Instance.new "Part"
	part.Shape = Enum.PartType.Cylinder
	return finish(
		part,
		model,
		name,
		Vector3.new(height, radius * 2, radius * 2),
		CFrame.new(center) * CFrame.Angles(0, 0, math.pi / 2),
		color
	)
end

local function build_hull(
	model: Model,
	def: EntityDef,
	radius: number,
	height: number,
	aspect: number,
	tracked: boolean
)
	local width, length = fit_rect(radius, aspect)
	local bottom = -height / 2
	local builder = is_builder(def)

	local hull_width = if tracked then width * 0.7 else width
	local hull_height = height * 0.5
	add_block(
		model,
		TEAM_PART,
		Vector3.new(hull_width, hull_height, length),
		Vector3.new(0, bottom + hull_height / 2, 0),
		nil
	)

	if tracked then
		local track_width = width * 0.2
		local track_height = height * 0.4
		for _, side in { -1, 1 } do
			add_block(
				model,
				"Track",
				Vector3.new(track_width, track_height, length),
				Vector3.new(side * (width / 2 - track_width / 2), bottom + track_height / 2, 0),
				DARK
			)
		end
	end

	-- the cab sits toward the back so the hull is longer in front
	local cab_height = height - hull_height
	local cab_length = length * 0.5
	local cab_z = -length * 0.12
	local cab_center_y = bottom + hull_height + cab_height / 2
	add_block(
		model,
		"Cab",
		Vector3.new(hull_width * 0.8, cab_height, cab_length),
		Vector3.new(0, cab_center_y, cab_z),
		if builder then HIGH_VIS else DARK
	)

	-- a barrel that ends flush with the front of the hull
	if unit_defs.attack_range(def) ~= nil then
		local barrel_length = length * 0.5
		add_block(
			model,
			"Barrel",
			Vector3.new(hull_width * 0.14, cab_height * 0.3, barrel_length),
			Vector3.new(0, cab_center_y, length / 2 - barrel_length / 2),
			BARREL
		)
	end
end

local function build_bot(model: Model, def: EntityDef, radius: number, height: number)
	local seed = hash_name(def.name)
	local torso_radius = radius * (0.7 + 0.3 * unit_interval(seed, 0))
	local leg_height = height * (0.25 + 0.15 * unit_interval(seed, 1))
	local head_height = height * (0.14 + 0.08 * unit_interval(seed, 2))
	local head_radius = torso_radius * (0.45 + 0.2 * unit_interval(seed, 3))
	local torso_height = height - leg_height - head_height
	local bottom = -height / 2

	if unit_interval(seed, 4) > 0.4 then
		local leg_radius = torso_radius * 0.32
		for _, side in { -1, 1 } do
			add_cylinder(
				model,
				"Leg",
				leg_radius,
				leg_height,
				Vector3.new(side * torso_radius * 0.55, bottom + leg_height / 2, 0),
				DARK
			)
		end
	else
		add_cylinder(model, "Leg", torso_radius * 0.65, leg_height, Vector3.new(0, bottom + leg_height / 2, 0), DARK)
	end

	add_cylinder(
		model,
		TEAM_PART,
		torso_radius,
		torso_height,
		Vector3.new(0, bottom + leg_height + torso_height / 2, 0),
		nil
	)

	local head_y = bottom + leg_height + torso_height + head_height / 2
	add_cylinder(
		model,
		"Head",
		head_radius,
		head_height,
		Vector3.new(0, head_y, 0),
		if is_builder(def) then HIGH_VIS else LIGHT_GREY
	)
	add_block(
		model,
		"Visor",
		Vector3.new(head_radius * 1.1, head_height * 0.4, head_radius * 0.3),
		Vector3.new(0, head_y, head_radius * 0.9),
		DARK
	)
end

-- The wings are two right triangles back to back along the centre line, each a WedgePart turned on its
-- side. A wedge's own triangle is drawn in its Y and Z axes with the right angle at its back bottom
-- (+Z, -Y); the half on side `side` of the centre line has that angle at the middle of the trailing
-- edge, its Z pointing to the tail, and its Y pointing out along the trailing edge.
local function build_aircraft(model: Model, def: EntityDef, radius: number, height: number)
	local width, length = fit_rect(radius, AIR_ASPECT)
	local bottom = -height / 2
	local wing_height = height * 0.3

	for _, side in { -1, 1 } do
		local wing = Instance.new "WedgePart"
		finish(
			wing,
			model,
			TEAM_PART,
			Vector3.new(wing_height, width / 2, length),
			CFrame.fromMatrix(
				Vector3.new(side * width / 4, bottom + wing_height / 2, 0),
				Vector3.yAxis * side,
				Vector3.xAxis * side,
				-Vector3.zAxis
			),
			nil
		)
	end

	local canopy_height = height - wing_height
	add_block(
		model,
		"Canopy",
		Vector3.new(width * 0.22, canopy_height, length * 0.3),
		Vector3.new(0, bottom + wing_height + canopy_height / 2, length * 0.1),
		if is_builder(def) then HIGH_VIS else DARK
	)
end

local function build(model: Model, def: EntityDef)
	local radius = unit_defs.collider_radius(def)
	local height = unit_defs.collider_height(def)
	if unit_defs.is_air(def) then
		build_aircraft(model, def, radius, height)
	elseif unit_defs.rides_surface(def) then
		build_hull(model, def, radius, height, SHIP_ASPECT, false)
	elseif def.vehicle == true then
		build_hull(model, def, radius, height, VEHICLE_ASPECT, true)
	else
		build_bot(model, def, radius, height)
	end
end

return table.freeze({
	build = build,
})
