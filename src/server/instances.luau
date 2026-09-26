-- Mirrors the simulation into Workspace.
--
-- The sim is the truth; these parts exist so that Roblox replicates positions for free and so the
-- client has something to raycast against when picking units. Every part is anchored and
-- non-collidable - nothing here ever feeds back into the simulation.
--
-- A def with art (ReplicatedStorage.Shared.art) gets only an invisible hitbox the size of its collider, which the
-- client dresses in meshes it builds itself, since those cannot replicate. Anything else is a box the size of its
-- collider if it is a building, and a procedural stand-in that fits inside its collider if it is a unit (see
-- unit_placeholder.luau). A reclaimable is a rock or a tree, never painted for anything, drawn as
-- server/reclaimable_models.luau has it: a map can hold thousands, so each is built here rather than on the client,
-- since it never moves.
--
-- Every model is built around its pivot, its WorldPivot, and moved with :PivotTo, so nothing here depends on a
-- PrimaryPart.

local ReplicatedStorage = game:GetService "ReplicatedStorage"
local Workspace = game:GetService "Workspace"

local types = require(ReplicatedStorage.Shared.types)
local entity_attrs = require(ReplicatedStorage.Shared.entity_attrs)
local blueprint_decay = require(ReplicatedStorage.Shared.blueprint_decay)
local unit_defs = require(ReplicatedStorage.Shared.unit_defs)
local appearance = require(ReplicatedStorage.Shared.appearance)
local art = require(ReplicatedStorage.Shared.art)
local order_path = require(ReplicatedStorage.Shared.order_path)

local state = require(script.Parent.state)
local alliances = require(script.Parent.alliances)
local weapons = require(script.Parent.weapons)
local flows = require(script.Parent.flows)
local shields = require(script.Parent.shields)
local transport = require(script.Parent.transport)
local production = require(script.Parent.production)
local unit_placeholder = require(script.Parent.unit_placeholder)
local reclaimable_models = require(script.Parent.reclaimable_models)
local donuts = require(script.Parent.donuts)
local pilots = require(script.Parent.pilots)
local self_destruct = require(script.Parent.self_destruct)
local emp = require(script.Parent.emp)
local stockpiles = require(script.Parent.stockpiles)
local work = require(script.Parent.work)

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

-- The placeholder: a box the size of the collider for buildings, and for units, whatever
-- `unit_placeholder` makes of them (also for a unit's wreck). It is laid out around the origin and then
-- pivoted into place like any other model. Its parts named "Team" take the team colour.
local function build_placeholder(entity: Entity): Model
	-- what it is drawn as, which for a wreck is what died
	local def = unit_defs.get(entity.def_name)
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

-- Where `entity` stands, facing its way; kept as its last transform, so the sync after it is built has nothing to move.
local function place_once(entity: Entity, model: Model)
	transforms[entity.id] = { position = entity.position, facing = entity.facing }
	model:PivotTo(CFrame.new(entity.position) * CFrame.Angles(0, entity.facing, 0))
end

-- A reclaimable, drawn as reclaimable_models has it, put where it stands before it is parented, so it replicates once,
-- whole and in place.
local function build_reclaimable(entity: Entity): Model
	local model = reclaimable_models.build(entity.def)
	model.Name = `{entity.def_name}_{entity.id}`
	place_once(entity, model)
	model.Parent = get_container()
	return model
end

local function build_model(entity: Entity): Model
	if entity.kind == "reclaimable" then
		return build_reclaimable(entity)
	end
	return build_placeholder(entity)
end

-- Every model is moved whole: each is built around its pivot, so placing an
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

	local def = entity.def

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
local function set_attribute(model: Model, name: entity_attrs.Name, value: any)
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
	local target = state.get(target_id, true)
	if target == nil then
		return nil
	end
	return target.position
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

-- Where what each part of the simulation publishes about an entity is being written, while it is (`publish`).
local writing: Model? = nil
local function write(name: entity_attrs.Name, value: any)
	set_attribute(writing :: Model, name, value)
end

-- Everything that publishes something about an entity, each what it alone knows (see `entity_attrs.Publish`).
local PUBLISHERS: { (Entity, types.EntityDef, entity_attrs.Publish) -> () } = {
	donuts.publish,
	emp.publish,
	self_destruct.publish,
	weapons.publish,
	stockpiles.publish,
	pilots.publish,
	production.publish,
	flows.publish,
	shields.publish,
	transport.publish,
	work.publish,
}

-- What is left in remains, a wreck or a reclaimable, for the client to show; nothing for anything else.
local function apply_yield_attributes(entity: Entity, model: Model)
	local yield = entity.yield
	if yield ~= nil then
		set_attribute(model, "metal_left", math.round(yield.metal_left))
		set_attribute(model, "energy_left", math.round(yield.energy_left))
		set_attribute(model, "reclaim_left", math.round(yield.buildpower_left))
		set_attribute(model, "reclaim_total", math.round(yield.buildpower_total))
	end
end

-- Everything the client needs to know about an entity that is not its transform: what the entity itself holds, and
-- what every part of the simulation publishes about it.
local function apply_attributes(entity: Entity, model: Model)
	local def = entity.def
	set_attribute(model, "entity_id", entity.id)
	set_attribute(model, "team", entity.team)
	-- the same for every team in its alliance, so the client can tell an ally from an enemy without
	-- knowing the alliance graph itself: two things are allied exactly when this matches
	set_attribute(model, "ally_group", alliances.root_of(entity.team))
	set_attribute(model, "def_name", entity.def_name)
	-- the skin it wears, which the client dresses it in (client/art.luau, client/donuts.luau)
	set_attribute(model, "skin", entity.skin)
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
		entity.state == "blueprint"
			and entity.build_progress > 0
			and entity.unfed_time >= blueprint_decay.BLUEPRINT_DECAY_DELAY
	)
	set_attribute(model, "buildpower_cost", def.buildpower_cost)
	set_attribute(model, "order_count", #entity.orders)
	-- what it has earned in battle (server/credit.luau); experience to the hundredth, which is all that is shown of it
	set_attribute(model, "kills", entity.kills)
	set_attribute(model, "experience", math.floor(entity.experience * 100) / 100)
	set_attribute(model, "path", order_path.encode(entity.orders, order_position))
	set_attribute(model, "queue", entity_attrs.encode_queue(entity.queue))

	local wreck = entity.wreck
	if wreck ~= nil then
		-- how far along raising it is, as a fraction of what raising what it was takes
		local raise_cost = unit_defs.get(wreck.source_def_name).buildpower_cost
		set_attribute(
			model,
			"resurrect_progress",
			math.floor(math.clamp(wreck.resurrect_progress / math.max(1, raise_cost), 0, 1) * 1000) / 1000
		)
	end
	apply_yield_attributes(entity, model)

	writing = model
	for _, publish in PUBLISHERS do
		publish(entity, def, write)
	end
	writing = nil

	-- a plasma deflector's bubble, drawn as its power has it
	if def.shield ~= nil then
		apply_shield_bubble(entity, model, def.shield, shields.power_of(entity))
	end
end

-- A model goes the moment its entity is cleared out of the world, even while the game is paused and nothing syncs.
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
	apply_yield_attributes(entity, model)
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
	preload = reclaimable_models.preload,
	team_color = team_color,
})
