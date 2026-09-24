-- Mirrors the simulation into Workspace.
--
-- The sim is the truth; these parts exist so that Roblox replicates positions for free and so the
-- client has something to raycast against when picking units. Every part is anchored and
-- non-collidable - nothing here ever feeds back into the simulation.
--
-- A def with a hand-made model in ReplicatedStorage.Models is drawn with it. A def with procedural art
-- (ReplicatedStorage.Shared.art) gets only an invisible hitbox the size of its collider, which the client dresses
-- in meshes it builds itself, since those cannot replicate. Anything else is a box the size of its collider if it
-- is a building, and a procedural stand-in that fits inside its collider if it is a unit (see unit_placeholder.luau).
-- A reclaimable is a rock or a tree, never painted for anything: a map can hold thousands, so each is one or two
-- MeshParts of its low-poly art (Shared.reclaimable_art), built here rather than on the client, since it never moves.
--
-- Art and placeholder alike are moved with :PivotTo and measured with :GetPivot, so nothing here
-- depends on a model having a PrimaryPart. A model with one pivots about it; a model without one
-- pivots about its WorldPivot, which is set when the model is built.

local AssetService = game:GetService "AssetService"
local ReplicatedStorage = game:GetService "ReplicatedStorage"
local Workspace = game:GetService "Workspace"

local types = require(ReplicatedStorage.Shared.types)
local model_fit = require(ReplicatedStorage.Shared.model_fit)
local config = require(ReplicatedStorage.Shared.config)
local unit_defs = require(ReplicatedStorage.Shared.unit_defs)
local appearance = require(ReplicatedStorage.Shared.appearance)
local art = require(ReplicatedStorage.Shared.art)

local state = require(script.Parent.state)
local construction = require(script.Parent.construction)
local reclaim = require(script.Parent.reclaim)
local resurrection = require(script.Parent.resurrection)
local alliances = require(script.Parent.alliances)
local combat = require(script.Parent.combat)
local flows = require(script.Parent.flows)
local shields = require(script.Parent.shields)
local transport = require(script.Parent.transport)
local production = require(script.Parent.production)
local unit_placeholder = require(script.Parent.unit_placeholder)
local donuts = require(script.Parent.donuts)

type Entity = types.Entity
type EntityId = types.EntityId

-- The invisible part a def with procedural art is given in place of a placeholder: it is what the client picks
-- by raycast and hangs the art on, and it is never painted.
local HITBOX_NAME = "Hitbox"

type Original = {
	color: Color3,
	material: Enum.Material,
	transparency: number,
}

local models: { [EntityId]: Model } = {}
-- How every part of every model looked as authored. Blueprints and wrecks paint over their whole model,
-- and a model that is finished has to go back to exactly what its art said: materials as well as
-- colour, and parts that were meant to be see-through, like a rig's root part, staying that way.
local originals: { [BasePart]: Original } = {}
-- What kind, state and team each model was last painted for. Repainting means walking every part of
-- the model (GetDescendants included), which is real cost to pay every sync for every entity when
-- what it looks like has, almost always, not changed since the tick before.
local appearance_keys: { [EntityId]: string } = {}
-- How much buildpower was left in each reclaimable when its model was last written. A map can have thousands of them and
-- almost none is ever touched, so one whose store has not moved is passed over without so much as reading an attribute.
local reclaimables_synced: { [EntityId]: number } = {}
-- Where each model was last pivoted to, so a building or a unit standing still is not handed the
-- same PivotTo it already has every single sync.
local transforms: { [EntityId]: { position: Vector3, facing: number } } = {}
local container: Folder? = nil

local function get_container(): Folder
	if container ~= nil then
		return container
	end
	local existing = Workspace:FindFirstChild "Entities" :: Folder?
	if existing ~= nil then
		container = existing
		return existing
	end
	local folder = Instance.new "Folder"
	folder.Name = "Entities"
	folder.Parent = Workspace
	container = folder
	return folder
end

local team_color = appearance.team_color

local function make_part(name: string, parent: Instance): Part
	local part = Instance.new "Part"
	part.Name = name
	part.Anchored = true
	part.CanCollide = false
	part.CanQuery = true
	part.CanTouch = false
	part.CastShadow = true
	part.Material = Enum.Material.Metal
	part.TopSurface = Enum.SurfaceType.Smooth
	part.BottomSurface = Enum.SurfaceType.Smooth
	part.Parent = parent
	return part
end

-- Every def already complained about, so a missing model costs one warning rather than one per
-- entity built from it.
local warned: { [string]: boolean } = {}

local function warn_missing(def_name: string, reason: string)
	if warned[def_name] == true then
		return
	end
	warned[def_name] = true
	warn(`{reason}; {def_name} renders as a placeholder`)
end

-- Art, if any, lives in ReplicatedStorage.Models named after the def. See src/models/README.md.
-- Whatever the model's pivot is - a PrimaryPart if it has one, its WorldPivot if it does not - is
-- taken as the entity's origin, so there is nothing here for an artist to remember to set.
local function find_template(def_name: string): Model?
	local folder = ReplicatedStorage:FindFirstChild "Models"
	if folder == nil then
		warn_missing(def_name, "there is no ReplicatedStorage.Models folder")
		return nil
	end
	local template = folder:FindFirstChild(def_name)
	if template == nil then
		warn_missing(def_name, `ReplicatedStorage.Models has no "{def_name}"`)
		return nil
	end
	if template:IsA "Model" == false then
		warn_missing(def_name, `Models.{def_name} is a {template.ClassName}, not a Model`)
		return nil
	end
	return template :: Model
end

local function remember_appearance(model: Model)
	for _, descendant in model:GetDescendants() do
		if descendant:IsA "BasePart" then
			originals[descendant] = {
				color = descendant.Color,
				material = descendant.Material,
				transparency = descendant.Transparency,
			}
		end
	end
end

local function build_from_template(entity: Entity, template: Model): Model
	local def = unit_defs.of(entity)
	local model = template:Clone()
	model.Name = `{entity.def_name}_{entity.id}`

	for _, descendant in model:GetDescendants() do
		if descendant:IsA "BasePart" then
			descendant.Anchored = true
			descendant.CanCollide = false
			descendant.CanTouch = false
		end
	end

	remember_appearance(model)

	model_fit.align_to_collider_bottom(model, unit_defs.collider_height(def))

	model.Parent = get_container()
	return model
end

-- The placeholder: a box the size of the collider for buildings, and for units, whatever
-- `unit_placeholder` makes of them (also for a unit's wreck). It is laid out around the origin and then
-- pivoted into place like any other model. Its parts named "Team" take the team colour, as a real model's do.
local function build_placeholder(entity: Entity): Model
	local def = unit_defs.of(entity)
	local model = Instance.new "Model"
	model.Name = `{entity.def_name}_{entity.id}`

	local has_art = art.has(entity.def_name)
	if def.kind == "unit" and has_art == false then
		unit_placeholder.build(model, def)
	else
		-- with art, the box is only something to pick and to hang the client's meshes on, and is never seen
		local body = make_part(if has_art then HITBOX_NAME else "Team", model)
		if has_art then
			body.Transparency = 1
			body.CastShadow = false
		end
		local collider = def.collider
		body.Shape = Enum.PartType.Block
		if collider.shape == "box" then
			body.Size = Vector3.new(collider.width, collider.height, collider.length)
		else
			body.Size = Vector3.new(collider.radius * 2, collider.height, collider.radius * 2)
		end
		body.CFrame = CFrame.identity
	end

	-- the parts above are laid out around the origin, so that is the pivot the model carries
	model.WorldPivot = CFrame.identity
	remember_appearance(model)

	model.Parent = get_container()
	return model
end

-- The art each reclaimable is drawn in (Shared.reclaimable_art). Every rock is the same one, stretched to its own
-- collider, so that the thousands on a map are all one mesh.
local RECLAIMABLE_ART: { [string]: string } = {
	tree = "tree",
	shrub = "shrub",
	small_rock = "rock",
	rock = "rock",
	large_rock = "rock",
}
-- Art that casts no shadow: rocks and shrubs lie low, and thousands of shadows cost far more than they show.
local SHADOWLESS: { [string]: boolean } = { rock = true, shrub = true }
-- Roblox's importer turns an uploaded mesh half a turn about its vertical axis; see client/art.luau.
local UPLOADED_TURN = CFrame.Angles(0, math.pi, 0)
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

local function vector(values: { number }): Vector3
	return Vector3.new(values[1], values[2], values[3])
end

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
			local ok, result = pcall(function(): { ReclaimableMesh }
				local meshes = {}
				for _, part in data.parts do
					if part.mesh == nil then
						error "not uploaded (tools/model_pipeline/roblox/upload_art.py)"
					end
					local mesh = AssetService:CreateMeshPartAsync(
						Content.fromUri(part.mesh),
						{ CollisionFidelity = Enum.CollisionFidelity.Box }
					)
					mesh.Anchored = true
					mesh.CanCollide = false
					mesh.CanQuery = true
					mesh.CanTouch = false
					mesh.CastShadow = SHADOWLESS[module.Name] ~= true
					mesh.Material = Enum.Material.SmoothPlastic
					mesh.Color = Color3.new(part.color[1], part.color[2], part.color[3])
					mesh.Size = vector(part.size)
					local group = data.groups[part.group]
					local pivot = if group ~= nil then vector(group.pivot) else Vector3.zero
					table.insert(meshes, { mesh = mesh, offset = pivot + vector(part.offset) })
				end
				return meshes
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

-- The pieces `entity`'s def is built from, or nil if its art has no meshes loaded.
local function reclaimable_pieces_of(entity: Entity): { ReclaimablePiece }?
	local cached = reclaimable_pieces[entity.def_name]
	if cached ~= nil then
		return cached
	end
	local art_name = RECLAIMABLE_ART[entity.def_name]
	local meshes = if art_name ~= nil then reclaimable_meshes[art_name] else nil
	if meshes == nil then
		return nil
	end
	local def = unit_defs.of(entity)
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
		mesh.Size = loaded.mesh.Size * scale
		local offset = loaded.offset * scale
		table.insert(pieces, {
			mesh = mesh,
			frame = CFrame.new(offset.X, offset.Y - height / 2, offset.Z) * UPLOADED_TURN,
		})
	end
	reclaimable_pieces[entity.def_name] = pieces
	return pieces
end

-- Where `entity` stands, facing its way; kept as its last transform, so the sync after it is built has nothing to move.
local function place_once(entity: Entity, model: Model)
	transforms[entity.id] = { position = entity.position, facing = entity.facing }
	model:PivotTo(CFrame.new(entity.position) * CFrame.Angles(0, entity.facing, 0))
end

-- A reclaimable whose art did not load: a rock, a couple of stones filling its collider, a tree, a fir of three tiers
-- on a trunk, or a shrub, a couple of clumps of leaves. Nothing in it is named "Team", so nobody's colour ever goes on
-- it. It is laid out around the origin, like a placeholder.
local TRUNK_COLOR = Color3.fromRGB(92, 66, 44)

local function build_reclaimable_parts(entity: Entity): Model
	local def = unit_defs.of(entity)
	local model = Instance.new "Model"
	model.Name = `{entity.def_name}_{entity.id}`
	local radius = unit_defs.collider_radius(def)
	local height = unit_defs.collider_height(def)
	local bottom = -height / 2

	if entity.def_name == "tree" then
		local trunk_height = height * 0.3
		local trunk = make_part("Trunk", model)
		trunk.Material = Enum.Material.Wood
		trunk.Color = TRUNK_COLOR
		trunk.Size = Vector3.new(radius * 0.35, trunk_height, radius * 0.35)
		trunk.CFrame = CFrame.new(0, bottom + trunk_height / 2, 0)
		local tier_height = (height - trunk_height) / 2
		for tier = 0, 2 do
			local width = radius * 2 * (1 - tier * 0.28)
			local part = make_part("Leaves", model)
			part.Material = Enum.Material.LeafyGrass
			part.Color = def.color
			part.Size = Vector3.new(width, tier_height, width)
			part.CFrame = CFrame.new(0, bottom + trunk_height + tier_height * (tier * 0.75 + 0.5), 0)
				* CFrame.Angles(0, tier * math.pi / 4, 0)
		end
	elseif entity.def_name == "shrub" then
		for clump = 0, 1 do
			local part = make_part("Leaves", model)
			part.Material = Enum.Material.LeafyGrass
			part.Color = def.color:Lerp(Color3.new(0, 0, 0), clump * 0.12)
			part.Size =
				Vector3.new(radius * (1.8 - clump * 0.6), height * (1 - clump * 0.3), radius * (1.5 - clump * 0.5))
			part.CFrame = CFrame.new(
				clump * radius * 0.4,
				bottom + height * (1 - clump * 0.3) / 2,
				clump * radius * 0.3
			) * CFrame.Angles(0, clump * 0.9, 0)
		end
	else
		local stone = make_part("Stone", model)
		stone.Material = Enum.Material.Slate
		stone.Color = def.color
		stone.Size = Vector3.new(radius * 1.7, height, radius * 1.4)
		stone.CFrame = CFrame.new(0, 0, 0) * CFrame.Angles(0.12, 0.3, -0.1)
		local chip = make_part("Stone", model)
		chip.Material = Enum.Material.Slate
		chip.Color = def.color:Lerp(Color3.new(0, 0, 0), 0.15)
		chip.Size = Vector3.new(radius * 0.9, height * 0.7, radius * 0.8)
		chip.CFrame = CFrame.new(radius * 0.55, bottom + height * 0.35, radius * 0.4) * CFrame.Angles(-0.2, 1.1, 0.15)
	end

	model.WorldPivot = CFrame.identity
	remember_appearance(model)
	model.Parent = get_container()
	return model
end

-- A reclaimable: a clone of each of its def's pieces, put where it stands before it is parented, so it replicates
-- once, whole and in place.
local function build_reclaimable(entity: Entity): Model
	local pieces = reclaimable_pieces_of(entity)
	if pieces == nil then
		return build_reclaimable_parts(entity)
	end
	local model = Instance.new "Model"
	model.Name = `{entity.def_name}_{entity.id}`
	for _, piece in pieces do
		local mesh = piece.mesh:Clone()
		mesh.CFrame = piece.frame
		mesh.Parent = model
	end
	model.WorldPivot = CFrame.identity
	place_once(entity, model)
	model.Parent = get_container()
	return model
end

local function build_model(entity: Entity): Model
	if entity.kind == "reclaimable" then
		return build_reclaimable(entity)
	end
	local template = find_template(entity.def_name)
	if template ~= nil then
		return build_from_template(entity, template)
	end
	return build_placeholder(entity)
end

-- Every model is moved whole: art and placeholder are both built around their pivot, so placing an
-- entity is one :PivotTo and nothing here has to know which part is which.
local function apply_transform(entity: Entity, model: Model)
	local last = transforms[entity.id]
	if last ~= nil and last.position == entity.position and last.facing == entity.facing then
		return
	end
	transforms[entity.id] = { position = entity.position, facing = entity.facing }
	model:PivotTo(CFrame.new(entity.position) * CFrame.Angles(0, entity.facing, 0))
end

-- Which parts of a model take the entity's colour: the parts named "Team", so the rest of the art keeps
-- the colours it was given.
local function tinted_parts(model: Model): { BasePart }
	local parts = {}
	for _, descendant in model:GetDescendants() do
		if descendant:IsA "BasePart" and descendant.Name == "Team" then
			table.insert(parts, descendant)
		end
	end
	return parts
end

-- Blueprints and wrecks read as such across the whole model, not just its team-coloured parts. A hitbox is
-- left out: it stays invisible, and the client paints the art hung on it.
local function all_parts(model: Model): { BasePart }
	local parts = {}
	for _, descendant in model:GetDescendants() do
		if descendant:IsA "BasePart" and descendant.Name ~= HITBOX_NAME then
			table.insert(parts, descendant)
		end
	end
	return parts
end

local function apply_appearance(entity: Entity, model: Model)
	local key = `{entity.kind}|{entity.state}|{entity.team}`
	if appearance_keys[entity.id] == key then
		return
	end
	appearance_keys[entity.id] = key

	local def = unit_defs.of(entity)

	if entity.kind == "wreck" then
		for _, part in all_parts(model) do
			part.Color = appearance.WRECK_COLOR
			part.Transparency = appearance.WRECK_TRANSPARENCY
			part.Material = appearance.WRECK_MATERIAL
		end
	elseif entity.state == "blueprint" then
		local tint = appearance.blueprint_tint(def.color, team_color(entity.team))
		for _, part in all_parts(model) do
			part.Color = tint
			part.Transparency = appearance.BLUEPRINT_TRANSPARENCY
			part.Material = appearance.BLUEPRINT_MATERIAL
		end
	else
		for _, part in all_parts(model) do
			local original = originals[part]
			if original ~= nil then
				part.Color = original.color
				part.Material = original.material
				part.Transparency = original.transparency
			end
		end
		for _, part in tinted_parts(model) do
			part.Color = appearance.team_tint(def.color, team_color(entity.team))
		end
	end
end

-- Attributes replicate on every write, so only write when the value has actually moved. Numbers
-- are rounded first so a health bar creeping by a hundredth does not cost a replication.
local function set_attribute(model: Model, name: string, value: any)
	if model:GetAttribute(name) ~= value then
		model:SetAttribute(name, value)
	end
end

-- Where an order sends its unit. A move order carries a point outright; an order aimed at another
-- entity inherits wherever that entity is now.
local function order_position(order: types.Order): Vector3?
	if order.position ~= nil then
		return order.position
	end
	local target_id = order.target_id
	if target_id == nil then
		return nil
	end
	local target = state.get(target_id)
	if target == nil then
		return nil
	end
	return target.position
end

-- The whole order queue as `kind,x,z,target,facing,radius;...` (target, facing and radius empty where they do not
-- apply), front of the queue first, so the client can draw a
-- path through every waypoint of a selected unit. Whole studs are plenty for something that is only
-- drawn, and every attribute write is a replication.
local function encode_path(entity: Entity): string
	local steps = {}
	for _, order in entity.orders do
		local position = order_position(order)
		if position ~= nil then
			-- a build order names what it will build in place of a target, and how it is turned
			local target = if order.def_name ~= nil
				then order.def_name
				elseif order.target_id ~= nil then tostring(order.target_id)
				else ""
			local facing = if order.facing ~= nil then string.format("%.2f", order.facing) else ""
			-- an area order's circle, in whole studs
			local radius = if order.radius ~= nil then tostring(math.round(order.radius)) else ""
			table.insert(
				steps,
				`{order.kind},{math.round(position.X)},{math.round(position.Z)},{target},{facing},{radius}`
			)
		end
	end
	return table.concat(steps, ";")
end

-- The bubble round a plasma deflector: a translucent ball the size of its shield, which fades out as the shield's
-- power runs down and is gone altogether while it is down or the building is not finished.
local BUBBLE_COLOR = Color3.fromRGB(120, 200, 255)
local function apply_shield_bubble(entity: Entity, model: Model, shield: types.Shield, held: number)
	local bubble = model:FindFirstChild "Shield"
	if bubble == nil then
		local part = Instance.new "Part"
		part.Name = "Shield"
		part.Shape = Enum.PartType.Ball
		part.Anchored = true
		part.CanCollide = false
		part.CanQuery = false
		part.CanTouch = false
		part.CastShadow = false
		part.Material = Enum.Material.ForceField
		part.Color = BUBBLE_COLOR
		part.Size = Vector3.one * shield.radius * 2
		part.CFrame = CFrame.new(entity.position)
		part.Parent = model
		bubble = part
	end
	local ball = bubble :: Part
	ball.CFrame = CFrame.new(entity.position)
	-- the model's own colouring passes over every part, this one too, so it is put back
	ball.Color = BUBBLE_COLOR
	ball.Material = Enum.Material.ForceField
	if entity.state ~= "active" or held <= 0 then
		ball.Transparency = 1
	else
		ball.Transparency = 0.6 + 0.35 * (1 - math.clamp(held / shield.power, 0, 1))
	end
end

-- How far along a slow weapon is to its next shot, from 0 to 1, rounded to a hundredth so that it is not
-- rewritten every step; nil for something with no weapon that takes longer than `config.RELOAD_BAR_MIN_SECONDS`
-- to reload. A unit with several weapons shows its first slow one.
local function reload_progress(entity: Entity, def: types.EntityDef): number?
	local weapons = def.weapons
	if weapons == nil then
		return nil
	end
	for index, weapon in weapons do
		if weapon.reload > config.RELOAD_BAR_MIN_SECONDS then
			local remaining = entity.weapon_reloads[index] or 0
			return math.floor(math.clamp(1 - remaining / weapon.reload, 0, 1) * 100) / 100
		end
	end
	return nil
end

-- The attribute weapon `index`'s aim is written to, "aim_1" and so on, made once rather than every sync.
local aim_attributes: { string } = {}
local function aim_attribute(index: number): string
	local name = aim_attributes[index]
	if name == nil then
		name = `aim_{index}`
		aim_attributes[index] = name
	end
	return name
end

-- The weapons of a def whose art plays something when they fire (a "hatch" piece naming them), worked out once.
local fired_by_def: { [string]: { number } } = {}
local function fired_weapons(def_name: string): { number }
	local found = fired_by_def[def_name]
	if found ~= nil then
		return found
	end
	found = {}
	local data = if art.has(def_name) then art.get(def_name) else nil
	if data ~= nil then
		for _, group in data.groups do
			if group.kind == "hatch" and group.weapon ~= nil and table.find(found, group.weapon) == nil then
				table.insert(found, group.weapon)
			end
		end
	end
	fired_by_def[def_name] = found
	return found
end

local fired_attributes: { string } = {}
local function fired_attribute(index: number): string
	local name = fired_attributes[index]
	if name == nil then
		name = `fired_{index}`
		fired_attributes[index] = name
	end
	return name
end

-- Everything the client needs to know about an entity that is not its transform.
local function apply_attributes(entity: Entity, model: Model)
	local def = unit_defs.of(entity)
	set_attribute(model, "entity_id", entity.id)
	set_attribute(model, "team", entity.team)
	-- the same for every team in its alliance, so the client can tell an ally from an enemy without
	-- knowing the alliance graph itself: two things are allied exactly when this matches
	set_attribute(model, "ally_group", alliances.root_of(entity.team))
	set_attribute(model, "def_name", entity.def_name)
	-- the skin it wears, which the client dresses it in (client/art.luau, client/donuts.luau)
	set_attribute(model, "skin", entity.skin)
	-- the pool skin's donut, as the server keeps it (donuts.luau): on or off, how hard it shakes, and how it last came
	-- off, which every client draws alike
	local donut = donuts.published(entity)
	set_attribute(model, "donut", if donut ~= nil then donut.on else nil)
	set_attribute(model, "donut_shake", if donut ~= nil and donut.shake > 0 then donut.shake else nil)
	set_attribute(model, "donut_event", if donut ~= nil then donut.event else nil)
	set_attribute(model, "kind", entity.kind)
	-- every entity carries its team's name and the colour to show it in, for the selection panel and a
	-- commander's own nametag alike
	do
		local team = state.get_team(entity.team)
		if team ~= nil then
			set_attribute(model, "team_name", team.name)
		end
		set_attribute(model, "team_color", team_color(entity.team))
	end
	set_attribute(model, "state", entity.state)
	set_attribute(model, "health", math.round(entity.health))
	set_attribute(model, "max_health", math.round(entity.max_health))
	set_attribute(model, "build_progress", math.round(entity.build_progress))
	-- a blueprint nobody has built on for long enough is losing progress, which the client shows
	set_attribute(
		model,
		"decaying",
		entity.state == "blueprint" and entity.build_progress > 0 and entity.unfed_time >= config.BLUEPRINT_DECAY_DELAY
	)
	set_attribute(model, "buildpower_cost", def.buildpower_cost)
	set_attribute(model, "order_count", #entity.orders)
	-- what it has earned in battle (`combat.credit`); experience to the hundredth, which is all that is shown of it
	set_attribute(model, "kills", entity.kills)
	set_attribute(model, "experience", math.floor(entity.experience * 100) / 100)
	-- a weapon with an energy cost and no energy to fire it with
	set_attribute(model, "need_energy", combat.short_of_energy(entity.id))
	-- a lab whose next unit cannot be started for something standing where it goes
	set_attribute(model, "exit_blocked", production.is_blocked(entity.id))
	-- what it is making or spending this second, in metal and energy, and what is holding it back if it is
	local flow = flows.get(entity.id)
	set_attribute(model, "metal_rate", if flow ~= nil then math.round(flow.metal * 10) / 10 else nil)
	set_attribute(model, "energy_rate", if flow ~= nil then math.round(flow.energy * 10) / 10 else nil)
	set_attribute(model, "stalled", if flow ~= nil then flow.stall else nil)
	set_attribute(model, "flow_sources", flows.encode_sources(entity.id))
	-- a plasma deflector's power, and the bubble drawn round it
	if def.shield ~= nil then
		local held, most = shields.level_of(entity)
		set_attribute(model, "shield_power", if held ~= nil then math.round(held) else nil)
		set_attribute(model, "shield_max", most)
		apply_shield_bubble(entity, model, def.shield, held or 0)
	end
	if def.manual_weapon ~= nil then
		set_attribute(model, "manual_ready", entity.manual_reload_remaining <= 0)
	end
	-- how many missiles a launcher holds ready, the most it can hold, and how far along its next one is;
	-- a unit with several stockpiling weapons shows its first. A carrier shows its drones in reserve the same way.
	local carrier = def.carrier
	if carrier ~= nil then
		local stockpile = carrier.stockpile
		set_attribute(model, "stockpile", entity.drone_stockpile)
		set_attribute(model, "stockpile_limit", stockpile.limit)
		set_attribute(
			model,
			"stockpile_progress",
			if entity.drone_stockpile >= stockpile.limit
				then 1
				else math.floor(entity.drone_stockpile_progress / stockpile.build_time * 100) / 100
		)
	elseif def.weapons ~= nil then
		for index, weapon in def.weapons do
			local stockpile = weapon.stockpile
			if stockpile == nil then
				continue
			end
			local held = entity.weapon_stockpiles[index] or 0
			set_attribute(model, "stockpile", held)
			set_attribute(model, "stockpile_limit", stockpile.limit)
			set_attribute(
				model,
				"stockpile_progress",
				if held >= stockpile.limit
					then 1
					else math.floor((entity.weapon_stockpile_progress[index] or 0) / stockpile.build_time * 100) / 100
			)
			break
		end
	end
	-- how far along a slow weapon is to its next shot, which is shown as a bar
	set_attribute(model, "reload_progress", reload_progress(entity, def))
	-- where each turret points, in radians from the way the entity faces, which the client turns its art to; to a
	-- hundredth, so that a turret holding still is not rewritten every step
	if def.weapons ~= nil then
		for index, weapon in def.weapons do
			if weapon.turret ~= nil then
				set_attribute(model, aim_attribute(index), math.round((entity.weapon_aims[index] or 0) * 100) / 100)
			end
		end
	end
	-- how many shots each weapon whose art plays something when it fires (a silo's hatch) has taken, for the client
	-- to play it on each one; to the nearest thousand, which is plenty to see a new one by
	for _, index in fired_weapons(entity.def_name) do
		set_attribute(model, fired_attribute(index), combat.shots_of(entity.id, index) % 1000)
	end
	-- where a pop-up is in unfolding (see types.Animation); nothing else ever leaves "open"
	if def.popup ~= nil then
		set_attribute(model, "animation", entity.animation.state)
	end
	-- how full a transport is, in slots
	if def.transport ~= nil then
		set_attribute(model, "cargo_used", transport.slots_used(entity.id))
		set_attribute(model, "cargo_capacity", def.transport.capacity)
	end

	set_attribute(model, "path", encode_path(entity))

	-- What it is putting its buildpower into right now, so the client can show it working.
	local build_target = construction.target_of(entity.id)
	local reclaim_target = reclaim.target_of(entity.id)
	local repair_target = construction.repair_target_of(entity.id)
	local resurrect_target = resurrection.target_of(entity.id)
	set_attribute(
		model,
		"work_target",
		if build_target ~= nil
			then build_target
			elseif reclaim_target ~= nil then reclaim_target
			elseif resurrect_target ~= nil then resurrect_target
			else repair_target
	)
	set_attribute(
		model,
		"work_kind",
		if build_target ~= nil
			then "build"
			elseif reclaim_target ~= nil then "reclaim"
			elseif resurrect_target ~= nil then "resurrect"
			elseif repair_target ~= nil then "repair"
			else nil
	)
	set_attribute(model, "queue", table.concat(entity.queue, ","))

	local wreck = entity.wreck
	if wreck ~= nil then
		set_attribute(model, "metal_left", math.round(wreck.metal_left))
		set_attribute(model, "reclaim_left", math.round(wreck.buildpower_left))
		set_attribute(model, "reclaim_total", math.round(wreck.buildpower_total))
		-- how far along raising it is, as a fraction
		set_attribute(
			model,
			"resurrect_progress",
			math.floor(math.clamp(wreck.resurrect_progress / math.max(1, def.buildpower_cost), 0, 1) * 1000) / 1000
		)
	end
end

local function destroy(id: EntityId)
	local model = models[id]
	if model == nil then
		return
	end
	for _, descendant in model:GetDescendants() do
		if descendant:IsA "BasePart" then
			originals[descendant] = nil
		end
	end
	model:Destroy()
	models[id] = nil
	appearance_keys[id] = nil
	transforms[id] = nil
	reclaimables_synced[id] = nil
end

-- What the client needs to know about a reclaimable, which is much less than about anything else: what it is, and
-- what is left in it. It never moves, is never anyone's, and never does anything.
local function apply_reclaimable_attributes(entity: Entity, model: Model)
	set_attribute(model, "entity_id", entity.id)
	set_attribute(model, "team", entity.team)
	set_attribute(model, "ally_group", alliances.root_of(entity.team))
	set_attribute(model, "def_name", entity.def_name)
	set_attribute(model, "kind", entity.kind)
	set_attribute(model, "state", entity.state)
	local yield = entity.yield
	if yield ~= nil then
		set_attribute(model, "metal_left", math.round(yield.metal_left))
		set_attribute(model, "energy_left", math.round(yield.energy_left))
		set_attribute(model, "reclaim_left", math.round(yield.buildpower_left))
		set_attribute(model, "reclaim_total", math.round(yield.buildpower_total))
	end
end

local function sync_entity(entity: Entity, carried: boolean)
	local model = models[entity.id]
	if model == nil then
		model = build_model(entity)
		models[entity.id] = model
	end
	if entity.kind == "reclaimable" then
		-- it never moves and only ever changes by being reclaimed
		local left = if entity.yield ~= nil then entity.yield.buildpower_left else 0
		if reclaimables_synced[entity.id] == left then
			return
		end
		reclaimables_synced[entity.id] = left
		apply_transform(entity, model)
		apply_reclaimable_attributes(entity, model)
		return
	end
	apply_transform(entity, model)
	apply_appearance(entity, model)
	apply_attributes(entity, model)
	-- something being carried is inactive, and hangs from its transport
	set_attribute(model, "carried", carried)
end

local function sync()
	local world = state.all()
	local carried = state.carried()

	-- a model whose entity is in neither the world nor a transport's hold is gone, like the cargo of a transport that
	-- was destroyed
	local present: { [EntityId]: boolean } = {}
	for _, cargo in carried do
		present[cargo.id] = true
	end
	for id in models do
		if world[id] == nil and present[id] ~= true then
			destroy(id)
		end
	end

	for _, entity in world do
		if entity.alive then
			sync_entity(entity, false)
		end
	end
	for _, cargo in carried do
		sync_entity(cargo, true)
	end
end

local function get_model(id: EntityId): Model?
	return models[id]
end

return table.freeze({
	sync = sync,
	destroy = destroy,
	get_model = get_model,
	preload = preload,
	team_color = team_color,
})
