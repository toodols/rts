-- The commands a player gives their units and labs (IssueOrder, QueueProduction, CancelProduction, PlaceBlueprint).
-- Everything arriving here is untrusted: its shape is read as it arrives (the decoders here, through
-- server_shared/remotes.luau, which also holds each player to a rate), and ownership, what each kind of order may
-- be aimed at and who may carry it out (shared/order_kinds.luau) are checked against the simulation before anything is
-- applied (`issue`).

local ReplicatedStorage = game:GetService "ReplicatedStorage"
local ServerScriptService = game:GetService "ServerScriptService"

local types = require(ReplicatedStorage.Shared.types)
local unit_defs = require(ReplicatedStorage.Shared.unit_defs)
local surface = require(ReplicatedStorage.Shared.surface)
local heightmap = require(ReplicatedStorage.Shared.heightmap)
local geometry = require(ReplicatedStorage.Shared.geometry)
local order_kinds = require(ReplicatedStorage.Shared.order_kinds)
local order_routes = require(ReplicatedStorage.Shared.order_routes)
local switches = require(ReplicatedStorage.Shared.switches)
local teams = require(ReplicatedStorage.Shared.teams)
local decode = require(ReplicatedStorage.Shared.decode)
local command_payloads = require(ReplicatedStorage.Shared.command_payloads)

local remotes = require(ServerScriptService.ServerShared.remotes)

local state = require(script.Parent.state)
local orders = require(script.Parent.orders)
local players = require(script.Parent.players)
local placement = require(script.Parent.placement)
local production = require(script.Parent.production)
local build_rules = require(script.Parent.build_rules)
local self_destruct = require(script.Parent.self_destruct)
local shields = require(script.Parent.shields)
local alliances = require(script.Parent.alliances)

type Entity = types.Entity
type EntityId = types.EntityId
type Order = types.Order
type OrderKind = types.OrderKind
type TeamId = types.TeamId
type Command = order_kinds.Command

-- An order as a player sent it, as it is read: what the ids name, and whether they may be ordered so, are for `issue`
-- to see to.
type Sent = command_payloads.IssuedOrder

local issue_order: RemoteEvent = ReplicatedStorage.Shared.IssueOrder
local queue_production: RemoteEvent = ReplicatedStorage.Shared.QueueProduction
local cancel_production: RemoteEvent = ReplicatedStorage.Shared.CancelProduction
local place_blueprint: RemoteEvent = ReplicatedStorage.Shared.PlaceBlueprint

-- How many of what a player orders at once are given it; the rest of a bigger selection are left be.
local MAX_SELECTION = 250
local MAX_QUEUE_COUNT = 50

-- What the remotes take. Only the first MAX_SELECTION of what is ordered are read, and with them their own spots and
-- routes.
local IDS = decode.first(decode.number, MAX_SELECTION)
local ROUTES = decode.optional(decode.first(decode.list(decode.on_map, order_routes.MAX_WAYPOINTS), MAX_SELECTION))
local ORDER = decode.record({
	kind = order_kinds.issued,
	ids = IDS,
	positions = decode.optional(decode.first(decode.vector, MAX_SELECTION)),
	routes = ROUTES,
	target_id = decode.optional(decode.number),
	position = decode.optional(decode.vector),
	radius = decode.optional(decode.number),
	queue = decode.flag,
	front = decode.flag,
	launch = decode.flag,
})
local PRODUCTION = decode.record({
	factory_id = decode.number,
	def_name = decode.key_of(unit_defs.defs),
	count = decode.optional(decode.whole),
})
local CANCEL = decode.record({
	factory_id = decode.number,
	index = decode.optional(decode.whole),
})
local BLUEPRINT = decode.record({
	def_name = decode.key_of(unit_defs.defs),
	position = decode.on_map,
	facing = decode.optional(decode.number),
	ids = IDS,
	routes = ROUTES,
	queue = decode.flag,
	front = decode.flag,
})
-- A player may send this many commands at once, and so many a second after that: a line of buildings laid out at once
-- is one PlaceBlueprint each (client/build_mode.luau's MAX_LAYOUT).
local COMMAND_RATE: remotes.Rate = { per_second = 20, burst = 40 }
local BLUEPRINT_RATE: remotes.Rate = { per_second = 50, burst = 100 }

-- Whether `entity` is `team`'s to command: its own, or in godmode any real team's.
local function commands_it(team: TeamId, entity: Entity): boolean
	return entity.team == team or (switches.is_on "godmode" and entity.team ~= teams.NEUTRAL)
end

-- The entity `id` names, if `team` may command it.
local function owned_entity(team: TeamId, id: EntityId): Entity?
	local entity = state.get(id)
	if entity == nil or commands_it(team, entity) == false then
		return nil
	end
	return entity
end

-- Whether `team` may give an order of `kind` aimed at `target`. An order only aimed at friends (`friendly_only`) may be
-- aimed at one's own things and an ally's, or in godmode any real team's; never at an enemy's or at nobody's.
local function may_aim_at(team: TeamId, kind: order_kinds.Kind, target: Entity): boolean
	if kind.friendly_only == false then
		return true
	end
	if target.team == teams.NEUTRAL then
		return false
	end
	return switches.is_on "godmode" or alliances.are_allied(team, target.team)
end

-- `point` as a spot on the map's ground, if it is on the map.
local function ground_spot(point: Vector3?): Vector3?
	if point == nil or heightmap.in_bounds(point.X, point.Z) == false then
		return nil
	end
	return heightmap.ground_position(point.X, point.Z)
end

-- Where the unit at `index` of `sent` is sent for an order of `kind`: the one spot, its own spot, or nothing. The first
-- result is false when it is to be left out, its own spot not being one.
local function spot_for(
	sent: Sent,
	kind: order_kinds.Kind,
	def: types.EntityDef,
	index: number,
	shared: Vector3?
): (boolean, Vector3?)
	local own = if sent.positions ~= nil then sent.positions[index] else nil
	if kind.aim == "formation" then
		-- a ship's waypoints are on the water's surface, and the rest are on the ground
		if own == nil or heightmap.in_bounds(own.X, own.Z) == false then
			return false, nil
		end
		return true, surface.position(def, own.X, own.Z)
	end
	if kind.spread and sent.positions ~= nil then
		local spot = ground_spot(own)
		return spot ~= nil, spot
	end
	return true, shared
end

-- Carries out `sent` for team `team`: each of what it names that the team may command, and that can carry out an order
-- of its kind, is given it, or for what acts at once (stop, self-destruct), does it.
local function issue(team: TeamId, sent: Sent)
	local kind = order_kinds.get(sent.kind)
	-- only a kind that may be a launch is one
	local launch = sent.launch and kind.launches
	local target_id = sent.target_id
	local target = if target_id ~= nil then state.get(target_id) else nil
	if kind.aim == "entity" and (target == nil or may_aim_at(team, kind, target :: Entity) == false) then
		return
	end
	local radius: number? = nil
	if kind.aim == "area" then
		if sent.radius == nil or sent.radius <= 0 then
			return
		end
		radius = sent.radius
	end
	-- one spot for everyone, unless it is spread out along a line, which gives every unit a spot of its own
	local shared: Vector3? = nil
	if (kind.aim == "spot" or kind.aim == "area") and (kind.spread == false or sent.positions == nil) then
		shared = ground_spot(sent.position)
		if shared == nil then
			return
		end
	end

	for index, id in sent.ids do
		local entity = owned_entity(team, id)
		if entity == nil then
			continue
		end
		local def = entity.def
		-- a drone answers to its carrier alone
		if unit_defs.is_drone(def) then
			continue
		end
		-- anything of yours can destroy itself, a building too, and stopping it calls that off
		if sent.kind == "self_destruct" then
			self_destruct.toggle(entity)
			continue
		end
		if sent.kind == "shield" then
			shields.toggle(entity)
			continue
		end
		if sent.kind == "stop" then
			self_destruct.cancel(entity)
		end
		-- a lab cannot carry out orders, but it keeps them in its queue like anything else, and each unit it makes
		-- takes a copy (see production's rally_order); an unfinished unit takes orders too, which wait in its queue
		-- until it is built
		local factory = unit_defs.is_factory(def)
		if factory == false and unit_defs.takes_orders(def) == false then
			continue
		end
		-- stopping drops everything the unit was told to do, and leaves it standing where it is
		if sent.kind == "stop" then
			entity.orders = {}
			continue
		end
		if factory and kind.lab_ok == false then
			continue
		end
		-- nor can it be told to fire a weapon it has not got, which would only clear its queue
		if kind.needs_manual_weapon and def.manual_weapon == nil then
			continue
		end
		if launch and unit_defs.order_range(def, true) == nil then
			continue
		end

		local placed, position = spot_for(sent, kind, def, index, shared)
		if placed == false then
			continue
		end
		local order: Order = {
			kind = sent.kind :: OrderKind,
			position = position,
			target_id = target_id,
			radius = radius,
		}
		if launch then
			order.launch = true
		end
		-- captured where the target is now, so that the route stays there as it moves or goes
		local pinned = if kind.pins_target and target_id ~= nil then state.get(target_id, true) else nil
		if pinned ~= nil then
			order.position = pinned.position
		end

		-- a lab's orders are handed to each unit it makes, which finds its own way from where it is
		if factory then
			orders.issue(entity, { order }, sent.queue, sent.front)
			continue
		end
		local route = if sent.routes ~= nil then sent.routes[index] else nil
		orders.issue(entity, order_routes.along(def, order, route), sent.queue, sent.front)
	end
end

local function on_issue_order(player: Player, sent: Sent)
	local team = players.team_of(player)
	if team ~= nil then
		issue(team, sent)
	end
end

local function on_queue_production(player: Player, sent: command_payloads.QueuedProduction)
	local team = players.team_of(player)
	local factory = if team ~= nil then owned_entity(team, sent.factory_id) else nil
	if factory == nil then
		return
	end
	-- A factory's build orders always queue, whether or not shift was held.
	for _ = 1, math.clamp(sent.count or 1, 1, MAX_QUEUE_COUNT) do
		if production.enqueue(factory, sent.def_name) == false then
			return
		end
	end
end

local function on_cancel_production(player: Player, sent: command_payloads.CancelledProduction)
	local team = players.team_of(player)
	local factory = if team ~= nil then owned_entity(team, sent.factory_id) else nil
	if factory ~= nil then
		production.cancel(factory, sent.index or #factory.queue)
	end
end

local function on_place_blueprint(player: Player, sent: command_payloads.PlacedBlueprint)
	local team = players.team_of(player)
	if team == nil or unit_defs.get(sent.def_name).kind ~= "building" then
		return
	end

	-- Only a builder that lists this def may order it, and only builders can pay it off.
	local builders: { Entity } = {}
	-- each builder's way to the site, as the client sent it alongside its id
	local builder_routes: { [Entity]: { Vector3 }? } = {}
	for index, id in sent.ids do
		local entity = owned_entity(team, id)
		if entity == nil then
			continue
		end
		local builder_def = entity.def
		if table.find(unit_defs.build_options(builder_def), sent.def_name) == nil then
			continue
		end
		if unit_defs.does(builder_def, "assist") == false then
			continue
		end
		-- nor anything the builder's team has not unlocked in the campaign, whoever gives the order
		if build_rules.allows(entity.team, sent.def_name) == false then
			continue
		end
		table.insert(builders, entity)
		builder_routes[entity] = if sent.routes ~= nil then sent.routes[index] else nil
	end
	if #builders == 0 then
		return
	end

	local facing = geometry.snap_facing(sent.facing or 0)
	local center = placement.resolve_center(sent.def_name, sent.position.X, sent.position.Z, facing, builders[1])
	if center == nil then
		return
	end

	local placeable = placement.can_place(sent.def_name, center, facing, nil, builders[1].team)
	if placeable == false then
		return
	end

	-- Nothing is placed yet. Each builder is sent to the spot, and the blueprint appears when the
	-- first of them gets there.
	for _, builder in builders do
		local order: Order = {
			kind = "build",
			position = center,
			target_id = nil,
			def_name = sent.def_name,
			facing = facing,
		}
		orders.issue(builder, order_routes.along(builder.def, order, builder_routes[builder]), sent.queue, sent.front)
	end
end

local function init()
	remotes.listen(issue_order, { args = { ORDER }, rate = COMMAND_RATE }, on_issue_order)
	remotes.listen(queue_production, { args = { PRODUCTION }, rate = COMMAND_RATE }, on_queue_production)
	remotes.listen(cancel_production, { args = { CANCEL }, rate = COMMAND_RATE }, on_cancel_production)
	remotes.listen(place_blueprint, { args = { BLUEPRINT }, rate = BLUEPRINT_RATE }, on_place_blueprint)
end

return table.freeze({
	init = init,
})
