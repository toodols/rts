--!strict
-- How a reclaimable, a rock, a tree or a shrub, is drawn (server/instances.luau builds and places it): a map can hold
-- thousands, so each is one or two MeshParts of its feature's low-poly art (Shared.reclaimable_art, `Feature.art`),
-- stretched to fill its collider, cloned from pieces made once for each def. Art whose meshes did not load is drawn
-- from Parts instead, filling the same collider: a rock of a couple of stones, a fir of three tiers on a trunk, or a
-- shrub of a couple of clumps of leaves. Nothing in either is named "Team", so nobody's colour ever goes on it. It is
-- only a look: nothing here feeds back into the simulation.

local ReplicatedStorage = game:GetService "ReplicatedStorage"

local types = require(ReplicatedStorage.Shared.types)
local unit_defs = require(ReplicatedStorage.Shared.unit_defs)
local art = require(ReplicatedStorage.Shared.art)
local art_build = require(ReplicatedStorage.Shared.art_build)

type EntityDef = types.EntityDef

-- How long the server waits at start for the reclaimables' meshes before it gives up on any still loading.
local PRELOAD_TIMEOUT = 20

-- Each reclaimable art's meshes, as loaded once from their assets: a MeshPart at the art's own size, and where its
-- middle is from the art's origin, the middle of its footprint on the ground.
type ReclaimableMesh = { mesh: MeshPart, offset: Vector3 }
local reclaimable_meshes: { [string]: { ReclaimableMesh } } = {}
-- Each reclaimable def's pieces, those meshes stretched to fill its collider and placed about its middle, which
-- every one of it is cloned from.
type ReclaimablePiece = { mesh: MeshPart, frame: CFrame }
local reclaimable_pieces: { [string]: { ReclaimablePiece } } = {}

-- Loads every reclaimable art's meshes, all at once, and returns once they are loaded, or have failed to, or
-- PRELOAD_TIMEOUT seconds have gone by. It yields, so it is called as the server starts, before any is built; one
-- whose meshes are not there is built from Parts instead.
local function preload()
	local folder = ReplicatedStorage.Shared:FindFirstChild "reclaimable_art"
	if folder == nil then
		return
	end
	local loading = 0
	for _, module in folder:GetChildren() do
		if module:IsA "ModuleScript" == false then
			continue
		end
		local data = (require :: any)(module) :: art.Art
		loading += 1
		task.spawn(function()
			local ok, result = pcall(art_build.build_all, data.parts, function(part: art.Part): ReclaimableMesh
				local mesh = art_build.fetch(part)
				-- picked by the mouse, as a reclaimable's parts are
				mesh.CanQuery = true
				local group = data.groups[part.group]
				local pivot = if group ~= nil then art_build.vector(group.pivot) else Vector3.zero
				return { mesh = mesh, offset = pivot + art_build.vector(part.offset) }
			end)
			if ok then
				reclaimable_meshes[module.Name] = result
			else
				warn(`reclaimable art {module.Name} did not load, so it is built from Parts: {result}`)
			end
			loading -= 1
		end)
	end
	local deadline = os.clock() + PRELOAD_TIMEOUT
	while loading > 0 and os.clock() < deadline do
		task.wait()
	end
end

-- The pieces something of `def` is built from, or nil if its art has no meshes loaded.
local function pieces_of(def: EntityDef): { ReclaimablePiece }?
	local cached = reclaimable_pieces[def.name]
	if cached ~= nil then
		return cached
	end
	-- each reclaimable is drawn in its feature's art (Shared.reclaimable_art), stretched to its own collider
	local feature = def.feature
	local meshes = if feature ~= nil then reclaimable_meshes[feature.art] else nil
	if feature == nil or meshes == nil then
		return nil
	end
	local radius = unit_defs.collider_radius(def)
	local height = unit_defs.collider_height(def)
	-- how far the art reaches either way across the ground, and how high, which is stretched to fill the collider
	local reach = Vector3.zero
	for _, loaded in meshes do
		local far = loaded.offset:Abs() + loaded.mesh.Size / 2
		reach = reach:Max(Vector3.new(far.X, loaded.offset.Y + loaded.mesh.Size.Y / 2, far.Z))
	end
	local scale = Vector3.new(radius / reach.X, height / reach.Y, radius / reach.Z)
	local pieces = {}
	for _, loaded in meshes do
		local mesh = loaded.mesh:Clone()
		mesh.CastShadow = feature.shadowless ~= true
		mesh.Size = loaded.mesh.Size * scale
		local offset = loaded.offset * scale
		table.insert(pieces, {
			mesh = mesh,
			frame = CFrame.new(offset.X, offset.Y - height / 2, offset.Z) * art_build.UPLOADED_TURN,
		})
	end
	reclaimable_pieces[def.name] = pieces
	return pieces
end

-- The fallback's proportions, as shares of the collider's radius and height: a tree's trunk and how its three tiers of
-- leaves narrow and overlap; a shrub's two clumps; a rock's stone and the chip beside it, each turned a little off true.
local TRUNK_COLOR = Color3.fromRGB(92, 66, 44)
local TRUNK_HEIGHT = 0.3
local TRUNK_WIDTH = 0.35
local TIERS = 3
local TIER_NARROWING = 0.28
local TIER_OVERLAP = 0.75
local LEAF_SHADE = 0.12
local STONE = { width = 1.7, length = 1.4, tilt = Vector3.new(0.12, 0.3, -0.1) }
local CHIP = {
	width = 0.9,
	height = 0.7,
	length = 0.8,
	at = Vector2.new(0.55, 0.4),
	tilt = Vector3.new(-0.2, 1.1, 0.15),
	shade = 0.15,
}

local function make_part(name: string, material: Enum.Material, color: Color3, parent: Instance): Part
	local part = Instance.new "Part"
	part.Name = name
	part.Anchored = true
	part.CanCollide = false
	part.CanQuery = true
	part.CanTouch = false
	part.Material = material
	part.Color = color
	part.TopSurface = Enum.SurfaceType.Smooth
	part.BottomSurface = Enum.SurfaceType.Smooth
	part.Parent = parent
	return part
end

-- Something of `def` drawn from Parts, filling its collider, laid out around the origin.
local function build_parts(def: EntityDef, model: Model)
	local radius = unit_defs.collider_radius(def)
	local height = unit_defs.collider_height(def)
	local bottom = -height / 2
	local look = if def.feature ~= nil then def.feature.art else "rock"

	if look == "tree" then
		local trunk_height = height * TRUNK_HEIGHT
		local trunk = make_part("Trunk", Enum.Material.Wood, TRUNK_COLOR, model)
		trunk.Size = Vector3.new(radius * TRUNK_WIDTH, trunk_height, radius * TRUNK_WIDTH)
		trunk.CFrame = CFrame.new(0, bottom + trunk_height / 2, 0)
		local tier_height = (height - trunk_height) / 2
		for tier = 0, TIERS - 1 do
			local width = radius * 2 * (1 - tier * TIER_NARROWING)
			local part = make_part("Leaves", Enum.Material.LeafyGrass, def.color, model)
			part.Size = Vector3.new(width, tier_height, width)
			part.CFrame = CFrame.new(0, bottom + trunk_height + tier_height * (tier * TIER_OVERLAP + 0.5), 0)
				* CFrame.Angles(0, tier * math.pi / 4, 0)
		end
	elseif look == "shrub" then
		for clump = 0, 1 do
			local color = def.color:Lerp(Color3.new(0, 0, 0), clump * LEAF_SHADE)
			local part = make_part("Leaves", Enum.Material.LeafyGrass, color, model)
			part.Size =
				Vector3.new(radius * (1.8 - clump * 0.6), height * (1 - clump * 0.3), radius * (1.5 - clump * 0.5))
			part.CFrame = CFrame.new(
				clump * radius * 0.4,
				bottom + height * (1 - clump * 0.3) / 2,
				clump * radius * 0.3
			) * CFrame.Angles(0, clump * 0.9, 0)
		end
	else
		local stone = make_part("Stone", Enum.Material.Slate, def.color, model)
		stone.Size = Vector3.new(radius * STONE.width, height, radius * STONE.length)
		stone.CFrame = CFrame.Angles(STONE.tilt.X, STONE.tilt.Y, STONE.tilt.Z)
		local chip_color = def.color:Lerp(Color3.new(0, 0, 0), CHIP.shade)
		local chip = make_part("Stone", Enum.Material.Slate, chip_color, model)
		chip.Size = Vector3.new(radius * CHIP.width, height * CHIP.height, radius * CHIP.length)
		chip.CFrame = CFrame.new(radius * CHIP.at.X, bottom + height * CHIP.height / 2, radius * CHIP.at.Y)
			* CFrame.Angles(CHIP.tilt.X, CHIP.tilt.Y, CHIP.tilt.Z)
	end
end

-- Something of `def`, a reclaimable, laid out around the origin and not yet parented: from its art's pieces if they
-- loaded, and from Parts if not.
local function build(def: EntityDef): Model
	local model = Instance.new "Model"
	local pieces = pieces_of(def)
	if pieces == nil then
		build_parts(def, model)
	else
		for _, piece in pieces do
			local mesh = piece.mesh:Clone()
			mesh.CFrame = piece.frame
			mesh.Parent = model
		end
	end
	model.WorldPivot = CFrame.identity
	return model
end

return table.freeze({
	preload = preload,
	build = build,
})
