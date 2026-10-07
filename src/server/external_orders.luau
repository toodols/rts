--!strict
-- Orders from a computer player that runs outside the game: the Rust AI of tools/rust_ai, which the AI arena plays
-- through tools/rust_ai/bridge.luau, and the neural network of tools/nn_ai (tools/nn_ai/bridge.luau). Each second it
-- sends a list of commands for its team (a unit and what it is to do: walk or fight along a path, build, reclaim,
-- produce, ...), and `apply_all` carries them out here, on the game's own orders, production and placement. "order" and
-- "place" are given as a player gives them, through server/commands.luau, with the way found as a player's client
-- finds it.
--
-- A replay of such a game (server/replay.luau) cannot run that player again, so the arena keeps every second's commands
-- with the replay (orders.json), and `player` gives them to `apply_all` again at the same moments: after the step that
-- ends each second, as the arena did. From the same game, the same commands do the same things.

local ReplicatedStorage = game:GetService "ReplicatedStorage"

local unit_defs = require(ReplicatedStorage.Shared.unit_defs)
local surface = require(ReplicatedStorage.Shared.surface)
local geometry = require(ReplicatedStorage.Shared.geometry)
local spots = require(ReplicatedStorage.Shared.spots)
local heightmap = require(ReplicatedStorage.Shared.heightmap)

local state = require(script.Parent.state)
local orders = require(script.Parent.orders)
local production = require(script.Parent.production)
local placement = require(script.Parent.placement)
local census = require(script.Parent.ai.census)
local order_routes = require(ReplicatedStorage.Shared.order_routes)
local order_kinds = require(ReplicatedStorage.Shared.order_kinds)

-- studs between the places tried on each ring round where a building was asked for
local SEARCH_SPACING = 6
-- As the Luau AI sites its buildings (server/ai/siting.luau): nothing but an extractor within SPOT_CLEARANCE of a metal
-- spot, nothing in the lane before a lab's doorway (ai/census.luau's lane_of), and, so that blocks of buildings keep
-- ways through them, nothing within GAP studs of another building.
local SPOT_CLEARANCE = 3
local GAP = 2

export type Command = { [string]: any }
export type Outcome = { [string]: any }
-- one second's commands for a team, as the arena keeps them
export type Entry = { t: number, team: number, cmds: { Command } }

-- (x, z) moved to at least a stud inside the map's edge: a goal on the edge itself is off the grid for the pathfinder
local function inside(x: number, z: number): (number, number)
	local half_x, half_z = heightmap.half_extents()
	local left, top = heightmap.grid_to_world(0, 0)
	return math.clamp(x, left + 1, left + 2 * half_x - 1), math.clamp(z, top + 1, top + 2 * half_z - 1)
end

local function round(value: number, places: number): number
	local scale = 10 ^ places
	return math.round(value * scale) / scale
end

-- A path the player gives, as orders of `kind`, ending before its last point unless `with_last`.
local function chain_of(def: any, path: { { number } }?, kind: string, with_last: boolean): { any }
	local chain = {}
	if path == nil then
		return chain
	end
	local count = if with_last then #path else #path - 1
	for index = 1, count do
		local point = path[index]
		local x, z = inside(point[1], point[2])
		table.insert(chain, { kind = kind, position = surface.position(def, x, z) })
	end
	return chain
end

-- Where something of `def_name` goes for `builder` of `team` near (x, z): there if it can, and otherwise, out to
-- `search` studs, the nearest place on rings round it that can.
local function site_for(
	team: number,
	builder: any,
	def_name: string,
	x: number,
	z: number,
	facing: number,
	search: number
): Vector3?
	local rings = math.floor(search / SEARCH_SPACING)
	local def = unit_defs.get(def_name)
	local is_extractor = def.spot ~= nil
	-- the buildings that could be in the way, and the lanes before its labs' doorways
	local reach = search + 40
	local around = Vector3.new(x, 0, z)
	local near: { any } = {}
	local lanes: { any } = {}
	for _, other: any in state.all() do
		if other.kind ~= "building" or other.alive == false then
			continue
		end
		if geometry.distance_2d(other.position, around) > reach then
			continue
		end
		table.insert(near, { position = other.position, half = placement.half_extents_for(other) })
		if other.team == team and unit_defs.is_factory(other.def) then
			table.insert(lanes, census.lane_of(other.def_name, other.position, other.facing or 0))
		end
	end
	local function clear(center: Vector3): boolean
		local half = geometry.rotated_half_extents(unit_defs.footprint_half_extents(def), facing)
		if not is_extractor then
			if spots.nearest("metal", center.X, center.Z, math.max(half.X, half.Y) + SPOT_CLEARANCE, nil) ~= nil then
				return false
			end
			for _, other in near do
				if geometry.aabb_overlap(center, half, other.position, other.half, GAP) then
					return false
				end
			end
		end
		for _, lane in lanes do
			if geometry.aabb_overlap(center, half, lane.center, lane.half, 0) then
				return false
			end
		end
		return true
	end
	for ring = 0, rings do
		local count = math.max(1, ring * 6)
		for index = 0, count - 1 do
			local angle = index * (math.pi * 2 / count)
			local center = placement.resolve_center(
				def_name,
				x + math.cos(angle) * ring * SEARCH_SPACING,
				z + math.sin(angle) * ring * SEARCH_SPACING,
				facing,
				builder
			)
			if center ~= nil and clear(center) and placement.can_place(def_name, center, facing, nil, team) then
				return center
			end
		end
	end
	return nil
end

-- server/commands.luau, required when first wanted: it takes its remotes as it is loaded, and this is loaded before they
-- are made
local commands_module: any = nil
local function commands(): any
	if commands_module == nil then
		commands_module = require(script.Parent.commands) :: any
	end
	return commands_module
end

-- The way `entity` goes to `destination` on an order of `kind`, found as a player's client finds it
-- (order_routes.waypoints), for the commands given as a player gives them ("order", "place").
local function route_for(entity: any, kind: string, launch: boolean, destination: Vector3?, radius: number?): { Vector3 }?
	if destination == nil then
		return nil
	end
	return order_routes.waypoints(entity.def, entity.position, kind :: any, launch, destination, radius)
end

-- Carries out one command for `team`; returns what became of it.
local function apply(team: number, command: Command): Outcome
	local kind = command.c
	local id = command.u
	local entity: any = if id ~= nil then state.get(id) else nil
	if entity == nil or entity.alive == false or entity.team ~= team then
		return { ok = false, why = "no unit" }
	end
	local def = entity.def
	local queue = command.queue == true
	if kind == "stop" then
		orders.issue(entity, {}, false, false)
		return { ok = true }
	elseif kind == "move" or kind == "fight" or kind == "patrol" then
		local path = command.path
		if path == nil or #path == 0 then
			return { ok = false, why = "no path" }
		end
		local along = if kind == "fight" then "fight" else "move"
		orders.issue(entity, chain_of(def, path, along, true) :: any, queue, false)
		return { ok = true }
	elseif kind == "build" then
		local def_name = command.def
		if table.find(unit_defs.build_options(def), def_name) == nil then
			return { ok = false, why = "cannot build" }
		end
		local facing = command.facing or 0
		local site_x, site_z = inside(command.x, command.z)
		local center = site_for(team, entity, def_name, site_x, site_z, facing, command.search or 0)
		if center == nil then
			return { ok = false, why = "no site" }
		end
		local chain = chain_of(def, command.path, "move", false)
		table.insert(chain, {
			kind = "build",
			position = center,
			target_id = nil,
			def_name = def_name,
			facing = facing,
		})
		orders.issue(entity, chain :: any, queue, false)
		return { ok = true, x = round(center.X, 2), z = round(center.Z, 2) }
	elseif
		kind == "reclaim"
		or kind == "repair"
		or kind == "assist"
		or kind == "guard"
		or kind == "resurrect"
		or kind == "attack"
	then
		local target: any = state.get(command.target)
		if target == nil or target.alive == false then
			return { ok = false, why = "no target" }
		end
		local chain = chain_of(def, command.path, "move", false)
		table.insert(chain, { kind = kind, position = nil, target_id = target.id })
		orders.issue(entity, chain :: any, queue, false)
		return { ok = true }
	elseif kind == "area_reclaim" or kind == "area_repair" or kind == "area_attack" or kind == "area_resurrect" then
		local chain = chain_of(def, command.path, "move", false)
		table.insert(chain, {
			kind = kind,
			position = surface.position(def, inside(command.x, command.z)),
			radius = command.radius or 30,
		})
		orders.issue(entity, chain :: any, queue, false)
		return { ok = true }
	elseif kind == "dgun" then
		if def.manual_weapon == nil then
			return { ok = false, why = "no manual weapon" }
		end
		orders.issue(
			entity,
			{ { kind = "dgun", position = surface.position(def, inside(command.x, command.z)) } } :: any,
			false,
			true
		)
		return { ok = true }
	elseif kind == "order" then
		-- any order a player can give, `o` its kind, given as a player gives it (server/commands.luau's `issue`), with
		-- the way there found as the client finds it
		local order_kind = command.o
		local info = order_kinds.get(order_kind)
		if info.issued == false then
			return { ok = false, why = "not an order" }
		end
		local launch = command.launch == true
		local spot: Vector3? = nil
		if command.x ~= nil and command.z ~= nil then
			local x, z = inside(command.x, command.z)
			spot = surface.position(def, x, z)
		end
		local target: any = if command.target ~= nil then state.get(command.target) else nil
		if info.aim == "entity" and (target == nil or target.alive == false) then
			return { ok = false, why = "no target" }
		end
		if (info.aim == "spot" or info.aim == "area" or info.aim == "formation") and spot == nil then
			return { ok = false, why = "no spot" }
		end
		local destination = if target ~= nil then target.position else spot
		local route = route_for(entity, order_kind, launch, destination, command.radius)
		commands().issue(team, {
			kind = order_kind,
			ids = { entity.id },
			positions = if spot ~= nil then { spot } else nil,
			routes = if route ~= nil then { route } else nil,
			target_id = if target ~= nil then target.id else nil,
			position = spot,
			radius = command.radius,
			queue = queue,
			front = command.front == true,
			launch = launch,
		} :: any)
		return { ok = true }
	elseif kind == "place" then
		-- a building put down as a player puts one down (server/commands.luau's `place`), where it can go
		-- within `search` studs of (x, z)
		local def_name = command.def
		if table.find(unit_defs.build_options(def), def_name) == nil then
			return { ok = false, why = "cannot build" }
		end
		local facing = geometry.snap_facing(command.facing or 0)
		local site_x, site_z = inside(command.x, command.z)
		local center = site_for(team, entity, def_name, site_x, site_z, facing, command.search or 0)
		if center == nil then
			return { ok = false, why = "no site" }
		end
		local route = route_for(entity, "build", false, center, nil)
		commands().place(team, {
			def_name = def_name,
			position = center,
			facing = facing,
			ids = { entity.id },
			routes = if route ~= nil then { route } else nil,
			queue = queue,
			front = command.front == true,
		})
		return { ok = true, x = round(center.X, 2), z = round(center.Z, 2) }
	elseif kind == "shield" or kind == "self_destruct" then
		commands().issue(team, {
			kind = kind,
			ids = { entity.id },
			queue = false,
			front = false,
			launch = false,
		} :: any)
		return { ok = true }
	elseif kind == "cancel" then
		-- one entry off a lab's queue: the one at `index`, or the last
		return { ok = production.cancel(entity, command.index or #entity.queue) }
	elseif kind == "produce" then
		local made = 0
		for _ = 1, command.n or 1 do
			if production.enqueue(entity, command.def, command.front == true) then
				made += 1
			end
		end
		return { ok = made > 0, made = made }
	elseif kind == "dequeue" then
		-- takes off the back of the queue, leaving what is being made
		local taken = 0
		for _ = 1, command.n or 1 do
			if #entity.queue > 1 and production.cancel(entity, -1) then
				taken += 1
			end
		end
		return { ok = true, taken = taken }
	end
	return { ok = false, why = `unknown command {kind}` }
end

-- Carries out a second's commands for `team`, in order; each one's outcome, by its place in the list.
local function apply_all(team: number, commands: { Command }): { Outcome }
	local outcomes = {}
	for index, command in commands do
		local ok, outcome = pcall(apply, team, command)
		outcomes[index] = if ok then outcome else { ok = false, why = tostring(outcome) }
	end
	return outcomes
end

export type Player = {
	-- after a step: the commands of the second it has got to, if there are any and they have not been given yet
	at: (now: number, half_step: number) -> (),
	-- after the game is put back to a moment: from there on (what was given at that moment is in what was put back)
	rewind: (now: number, half_step: number) -> (),
}

-- Gives recorded `entries` (in order of time) again as the game gets to their moments.
local function player(entries: { Entry }): Player
	-- the index of the next entry to give
	local next_index = 1

	local function rewind(now: number, half_step: number)
		next_index = #entries + 1
		for index, entry in entries do
			if entry.t > now + half_step then
				next_index = index
				break
			end
		end
	end

	local function at(now: number, half_step: number)
		while next_index <= #entries do
			local entry = entries[next_index]
			if entry.t > now + half_step then
				return
			end
			next_index += 1
			-- one that was passed without being given (the game was put back after it) is not given late
			if math.abs(entry.t - now) < half_step then
				apply_all(entry.team, entry.cmds)
			end
		end
	end

	return { at = at, rewind = rewind }
end

return {
	apply = apply,
	apply_all = apply_all,
	player = player,
}
