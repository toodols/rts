-- Mirrors the simulation into Workspace.
--
-- The sim is the truth; these parts exist so that Roblox replicates positions for free and so the
-- client has something to raycast against when picking units. Every part is anchored and
-- non-collidable - nothing here ever feeds back into the simulation.
--
-- Real models do not exist yet, so a building is a box the size of its collider and a unit is a
-- procedural stand-in that fits inside its collider (see unit_placeholder.luau).
--
-- Art and placeholder alike are moved with :PivotTo and measured with :GetPivot, so nothing here
-- depends on a model having a PrimaryPart. A model with one pivots about it; a model without one
-- pivots about its WorldPivot, which is set when the model is built.

local ReplicatedStorage = game:GetService "ReplicatedStorage"
local Workspace = game:GetService "Workspace"

local types = require(ReplicatedStorage.Shared.types)
local model_fit = require(ReplicatedStorage.Shared.model_fit)
local config = require(ReplicatedStorage.Shared.config)
local unit_defs = require(ReplicatedStorage.Shared.unit_defs)

local state = require(script.Parent.state)
local construction = require(script.Parent.construction)
local reclaim = require(script.Parent.reclaim)
local resurrection = require(script.Parent.resurrection)
local combat = require(script.Parent.combat)
local flows = require(script.Parent.flows)
local shields = require(script.Parent.shields)
local transport = require(script.Parent.transport)
local unit_placeholder = require(script.Parent.unit_placeholder)

type Entity = types.Entity
type EntityId = types.EntityId

local BLUEPRINT_TRANSPARENCY = 0.6
local WRECK_COLOR = Color3.fromRGB(96, 88, 80)

local TEAM_COLORS: { [number]: Color3 } = {
	[0] = Color3.fromRGB(140, 140, 140),
	[1] = Color3.fromRGB(86, 148, 224),
	[2] = Color3.fromRGB(214, 92, 84),
	[config.SCAVENGER_TEAM] = Color3.fromRGB(160, 84, 214),
}

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

local function team_color(team: types.TeamId): Color3
	local color = TEAM_COLORS[team]
	if color == nil then
		return TEAM_COLORS[0]
	end
	return color
end

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
	local def = unit_defs.get(entity.def_name)
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
	local def = unit_defs.get(entity.def_name)
	local model = Instance.new "Model"
	model.Name = `{entity.def_name}_{entity.id}`

	if def.kind == "unit" then
		unit_placeholder.build(model, def)
	else
		local body = make_part("Team", model)
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

local function build_model(entity: Entity): Model
	local template = find_template(entity.def_name)
	if template ~= nil then
		return build_from_template(entity, template)
	end
	return build_placeholder(entity)
end

-- Every model is moved whole: art and placeholder are both built around their pivot, so placing an
-- entity is one :PivotTo and nothing here has to know which part is which.
local function apply_transform(entity: Entity, model: Model)
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

-- Blueprints and wrecks read as such across the whole model, not just its team-coloured parts.
local function all_parts(model: Model): { BasePart }
	local parts = {}
	for _, descendant in model:GetDescendants() do
		if descendant:IsA "BasePart" then
			table.insert(parts, descendant)
		end
	end
	return parts
end

local function apply_appearance(entity: Entity, model: Model)
	local def = unit_defs.get(entity.def_name)

	if entity.kind == "wreck" then
		for _, part in all_parts(model) do
			part.Color = WRECK_COLOR
			part.Transparency = 0.25
			part.Material = Enum.Material.CorrodedMetal
		end
	elseif entity.state == "blueprint" then
		local tint = team_color(entity.team):Lerp(def.color, 0.35)
		for _, part in all_parts(model) do
			part.Color = tint
			part.Transparency = BLUEPRINT_TRANSPARENCY
			part.Material = Enum.Material.ForceField
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
			part.Color = def.color:Lerp(team_color(entity.team), 0.45)
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

-- The whole order queue as `kind,x,z,target,facing;...` (target and facing empty where they do not
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
			table.insert(steps, `{order.kind},{math.round(position.X)},{math.round(position.Z)},{target},{facing}`)
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
-- to reload. A unit with several turrets shows its first slow one.
local function reload_progress(entity: Entity, def: types.EntityDef): number?
	local remaining = entity.reload_remaining
	local weapon = def.weapon
	if weapon == nil or weapon.reload <= config.RELOAD_BAR_MIN_SECONDS then
		weapon = nil
		local turrets = def.turrets
		if turrets ~= nil then
			for index, turret in turrets do
				if turret.weapon.reload > config.RELOAD_BAR_MIN_SECONDS then
					weapon = turret.weapon
					remaining = entity.turret_reloads[index] or 0
					break
				end
			end
		end
	end
	if weapon == nil then
		return nil
	end
	return math.floor(math.clamp(1 - remaining / weapon.reload, 0, 1) * 100) / 100
end

-- Everything the client needs to know about an entity that is not its transform.
local function apply_attributes(entity: Entity, model: Model)
	local def = unit_defs.get(entity.def_name)
	set_attribute(model, "entity_id", entity.id)
	set_attribute(model, "team", entity.team)
	set_attribute(model, "def_name", entity.def_name)
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
	-- a weapon with an energy cost and no energy to fire it with
	set_attribute(model, "need_energy", combat.short_of_energy(entity.id))
	-- what it is making or spending this second, in metal and energy, and what is holding it back if it is
	local flow = flows.get(entity.id)
	set_attribute(model, "metal_rate", if flow ~= nil then math.round(flow.metal * 10) / 10 else nil)
	set_attribute(model, "energy_rate", if flow ~= nil then math.round(flow.energy * 10) / 10 else nil)
	set_attribute(model, "stalled", if flow ~= nil then flow.stall else nil)
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
	-- how many missiles a launcher holds ready, the most it can hold, and how far along its next one is
	if def.weapon ~= nil and def.weapon.stockpile ~= nil then
		local stockpile = def.weapon.stockpile
		set_attribute(model, "stockpile", entity.stockpile)
		set_attribute(model, "stockpile_limit", stockpile.limit)
		set_attribute(
			model,
			"stockpile_progress",
			if entity.stockpile >= stockpile.limit
				then 1
				else math.floor(entity.stockpile_progress / stockpile.build_time * 100) / 100
		)
	end
	-- how far along a slow weapon is to its next shot, which is shown as a bar
	set_attribute(model, "reload_progress", reload_progress(entity, def))
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
end

local function sync_entity(entity: Entity, carried: boolean)
	local model = models[entity.id]
	if model == nil then
		model = build_model(entity)
		models[entity.id] = model
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
	team_color = team_color,
})
