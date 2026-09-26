--!strict
-- Tests of the maps: what one is made of, replacing it while the game runs, loading every one, and where each kind of
-- unit can go on them.

local ReplicatedStorage = game:GetService "ReplicatedStorage"
local ServerScriptService = game:GetService "ServerScriptService"
local Workspace = game:GetService "Workspace"

local types = require(ReplicatedStorage.Shared.types)
local ground_levels = require(ReplicatedStorage.Shared.ground_levels)
local tick_rate = require(ReplicatedStorage.Shared.tick_rate)
local world_scale = require(ReplicatedStorage.Shared.world_scale)
local heightmap = require(ReplicatedStorage.Shared.heightmap)
local unit_defs = require(ReplicatedStorage.Shared.unit_defs)
local surface = require(ReplicatedStorage.Shared.surface)
local pathfinder = require(ReplicatedStorage.Shared.pathfinder)
local passability = require(ReplicatedStorage.Shared.passability)
local starts = require(ReplicatedStorage.Shared.starts)
local spots = require(ReplicatedStorage.Shared.spots)
local map_state = require(ReplicatedStorage.Shared.map_state)
local map_presets = require(ReplicatedStorage.Shared.map_presets)
local map_designs = require(ReplicatedStorage.Shared.map_designs)

local state = require(ServerScriptService.Server.state)
local maps = require(ServerScriptService.Server.maps)
local deformation = require(ServerScriptService.Server.deformation)
local placement = require(ServerScriptService.Server.placement)

local harness = require(script.Parent.harness)

local OWN = harness.OWN
local advance = harness.advance
local round = harness.round
local spawn = harness.spawn

type Entity = types.Entity
type Args = harness.Args
type Findings = harness.Findings
type Test = harness.Test

-- The places each of the maps drawn to show off one part of the game (shared/map_designs) is about, in world (x, z).
local DESIGN_PLACES: { [string]: { [string]: Vector2 } } = {
	switchbacks = { plateau = Vector2.new(0, 0) },
	tidal_flats = { sandbar = Vector2.new(-130, -70), island = Vector2.new(0, 0) },
	caldera = { crater = Vector2.new(0, 0), rim = Vector2.new(-134, 0) },
	mesas = { middle_mesa = Vector2.new(0, 0), mesa = Vector2.new(-150, -190) },
	trenches = { no_mans_land = Vector2.new(0, 0), crest = Vector2.new(-104, 0) },
	canyons = {
		plaza = Vector2.new(-60, 26),
		cut_off = Vector2.new(-164, -198),
		tableland = Vector2.new(-200, -320),
	},
	last_stand = { far_corner = Vector2.new(300, 300) },
	pinwheel = { hub = Vector2.new(0, 0) },
	prairie = { middle = Vector2.new(0, 0), far_edge = Vector2.new(400, 0) },
}
-- Something of each way of getting about, for where each can go.
local WALKERS: { [string]: string } = { bot = "grunt", tank = "incisor", hover = "goon", amphibious = "commander" }
-- The prairie is open ground: no more than this share of its dry ground is too steep for a tank.
local PRAIRIE_MOST_BLOCKED = 0.01

-- `args.maps`, or every map's name, in order.
local function map_names(args: Args): { string }
	if args.maps ~= nil then
		return args.maps
	end
	local names = {}
	for name in map_presets.presets do
		table.insert(names, name)
	end
	table.sort(names)
	return names
end

-- How far a pathfinder's route from `from` to `to` for something of `def` runs, in studs, or false if it does not get
-- there.
local function route_length(def: types.EntityDef, from: Vector3, to: Vector3): number | boolean
	local path = pathfinder.find_path(def, from, to, 400000)
	local total, last = 0, from
	for _, order in path.orders do
		local position = order.position :: Vector3
		total += Vector2.new(position.X - last.X, position.Z - last.Z).Magnitude
		last = position
	end
	return if path.complete then math.round(total) else false
end

-- The map as it was made, run on whatever `args.preset` is: its size and heights, how much of it is under water, where
-- the starts are, how many metal spots it has, what the ground is made of (from the terrain as it was written, read at
-- `args.samples` by `args.samples` points, 48 by default), and whether a bot and a tank can each find their way from
-- the first start to the second. The session then stays up for `args.hold` seconds (none by default), to be looked at.
local function map(args: Args): Findings
	local lowest, highest = heightmap.height_bounds()

	local start_list = {}
	for slot = 1, starts.count() do
		local at = starts.center(slot)
		table.insert(start_list, {
			x = round(at.X, 1),
			z = round(at.Y, 1),
			height = round(heightmap.height_at(at.X, at.Y), 1),
		})
	end

	local rich = 0
	for _, spot in spots.all "metal" do
		if spot.multiplier > 2 then
			rich += 1
		end
	end

	-- the material of the voxel just under the surface, over an even spread of the map
	local samples = args.samples or 48
	local materials: { [string]: number } = {}
	local half_x, half_z = heightmap.half_extents()
	for ix = 1, samples do
		for iz = 1, samples do
			local x = -half_x + (ix - 0.5) / samples * half_x * 2
			local z = -half_z + (iz - 0.5) / samples * half_z * 2
			local y = heightmap.height_at(x, z) - world_scale.CELL_STUDS
			local region = Region3.new(Vector3.new(x - 1, y - 1, z - 1), Vector3.new(x + 1, y + 1, z + 1))
				:ExpandToGrid(world_scale.CELL_STUDS)
			local voxels = Workspace.Terrain:ReadVoxels(region, world_scale.CELL_STUDS)
			local name = voxels[1][1][1].Name
			materials[name] = (materials[name] or 0) + 1
		end
	end

	local from = starts.center(1)
	local to = starts.center(2)
	local function crossing(def_name: string): Findings
		local def = unit_defs.get(def_name)
		local path = pathfinder.find_path(
			def,
			heightmap.ground_position(from.X, from.Y),
			heightmap.ground_position(to.X, to.Y),
			200000
		)
		return { complete = path.complete, waypoints = #path.orders }
	end

	local wet = 0
	local total = 0
	local cells_x, cells_z = heightmap.cells()
	for cz = 0, cells_z, 4 do
		for cx = 0, cells_x, 4 do
			local x, z = heightmap.grid_to_world(cx, cz)
			total += 1
			if heightmap.water_depth(x, z) > 0 then
				wet += 1
			end
		end
	end

	if typeof(args.hold) == "number" then
		task.wait(args.hold)
	end
	return {
		preset = map_state.preset().name,
		lowest = round(lowest, 1),
		highest = round(highest, 1),
		percent_under_water = round(wet / total * 100, 1),
		starts = start_list,
		metal_spots = #spots.all "metal",
		rich_metal_spots = rich,
		materials = materials,
		bot_crossing = crossing "grunt",
		tank_crossing = crossing "incisor",
	}
end

-- Replacing the map while the game runs: units on it and a crater in it, then `maps.load` to `args.to` (altair_crossing by
-- default). Afterwards the load should have gone through, with nothing left of the old world's units, the map and
-- generation built and published the new one's, no edit to the old ground come across, and the voxels drawn from the
-- new heightmap, to within a cell.
local function load_map(args: Args): Findings
	local units: { Entity } = {}
	for index = 1, 5 do
		table.insert(units, spawn("grunt", OWN, index * 8, 0))
	end
	advance(tick_rate.TICK_DELTA)
	deformation.crater(heightmap.ground_position(0, 40), 12, 5000)
	advance(tick_rate.TICK_DELTA)
	local before = map_state.get() :: map_state.MapState
	local edited_before = #heightmap.edited_heights() // 2

	local to = args.to or "altair_crossing"
	local ok, err = maps.load({ preset = to })

	local units_left = 0
	for _, unit in units do
		if state.get(unit.id) ~= nil then
			units_left += 1
		end
	end
	local built = map_state.get() :: map_state.MapState
	local published = map_state.published()

	-- the voxels under a few points, against the heightmap they should have been drawn from
	local params = RaycastParams.new()
	params.FilterType = Enum.RaycastFilterType.Include
	params.FilterDescendantsInstances = { Workspace.Terrain }
	params.IgnoreWater = true
	local worst = 0
	for _, at in { Vector2.new(-200, -200), Vector2.new(0, 0), Vector2.new(150, -60), Vector2.new(-90, 210) } do
		local expected = heightmap.height_at(at.X, at.Y)
		local hit = Workspace:Raycast(Vector3.new(at.X, 200, at.Y), Vector3.new(0, -400, 0), params)
		worst = math.max(worst, if hit ~= nil then math.abs(hit.Position.Y - expected) else math.huge)
	end

	local published_matches = published ~= nil
		and published.generation == built.generation
		and published.preset == built.preset
		and published.seed == built.seed
	local edited_after = #heightmap.edited_heights() // 2
	return {
		loaded = ok,
		error = err,
		generation_before = before.generation,
		generation_after = built.generation,
		preset_after = map_state.preset().name,
		published_matches = published_matches,
		units_left = units_left,
		edited_samples_before = edited_before,
		edited_samples_after = edited_after,
		metal_spots = #spots.all "metal",
		worst_surface_error = round(worst, 2),
		pass = ok
			and built.generation ~= before.generation
			and map_state.preset().name == to
			and published_matches
			and units_left == 0
			and edited_before > 0
			and edited_after == 0
			and worst <= world_scale.CELL_STUDS,
	}
end

-- Every map, loaded one after another with `maps.load`: for each, whether it loaded or the error it gave, how long it
-- took, how big it is, and how many metal spots and starts it has. Every one should load, and in every start box, where
-- a player who has not chosen starts should be in it and somewhere they can be started on.
local function load_every_map(_args: Args): Findings
	local results = {}
	local failed: { string } = {}
	for _, name in map_names({}) do
		local began = os.clock()
		local ok, err = maps.load({ preset = name })
		local half_x, half_z = heightmap.half_extents()
		-- each start box: whether where a player who has not chosen starts is in it and can be started on, and how much
		-- of it can be started on at all, sampled on a grid
		local boxes = {}
		local boxes_ok = true
		for index = 1, starts.box_count() do
			local box = starts.box(index)
			local spot = starts.default_spot(index)
			local startable, samples = 0, 0
			for row = 0, 15 do
				for column = 0, 15 do
					local x = box.min.X + (box.max.X - box.min.X) * (column + 0.5) / 16
					local z = box.min.Y + (box.max.Y - box.min.Y) * (row + 0.5) / 16
					samples += 1
					if starts.can_start_at(x, z) then
						startable += 1
					end
				end
			end
			local default_ok = starts.in_box(index, spot.X, spot.Y) and starts.can_start_at(spot.X, spot.Y)
			boxes_ok = boxes_ok and default_ok
			boxes[index] = {
				size = `{math.round(box.max.X - box.min.X)}x{math.round(box.max.Y - box.min.Y)}`,
				default_ok = default_ok,
				startable = round(startable / samples, 2),
			}
		end
		if ok == false or boxes_ok == false then
			table.insert(failed, name)
		end
		results[name] = {
			loaded = ok,
			error = err,
			seconds = round(os.clock() - began, 2),
			size = `{half_x * 2}x{half_z * 2}`,
			metal_spots = #spots.all "metal",
			start_boxes = boxes,
		}
		harness.settle()
	end
	return { maps = results, failed = failed, pass = #failed == 0 }
end

-- Where hovercraft can go on each map, `args.maps` or every one: loaded in turn, and flood filled over the cells a
-- hovercraft's slope class can stand on from every start. For each start, how much of the map it can reach, and whether
-- that takes in the sea; whether every start can reach every other; how much of the shore, dry ground beside the
-- water, a hovercraft can climb.
local function hover_reach(args: Args): Findings
	local function is_water(cx: number, cz: number): boolean
		return heightmap.sample(cx, cz) < ground_levels.WATER_LEVEL
			and heightmap.sample(cx + 1, cz) < ground_levels.WATER_LEVEL
			and heightmap.sample(cx, cz + 1) < ground_levels.WATER_LEVEL
			and heightmap.sample(cx + 1, cz + 1) < ground_levels.WATER_LEVEL
	end
	local results = {}
	for _, name in map_names(args) do
		local ok, err = maps.load({ preset = name })
		if ok == false then
			results[name] = { error = err }
			continue
		end
		local width, depth = heightmap.cells()
		local water_cells, open_cells = 0, 0
		local shore, climbable_shore = 0, 0
		for cz = 0, depth - 1 do
			for cx = 0, width - 1 do
				local water = is_water(cx, cz)
				if water then
					water_cells += 1
				end
				if passability.passable_cell("HOVER2", cx, cz) then
					open_cells += 1
				end
				if water == false then
					local by_water = (cx > 0 and is_water(cx - 1, cz))
						or (cx < width - 1 and is_water(cx + 1, cz))
						or (cz > 0 and is_water(cx, cz - 1))
						or (cz < depth - 1 and is_water(cx, cz + 1))
					if by_water then
						shore += 1
						if passability.passable_cell("HOVER2", cx, cz) then
							climbable_shore += 1
						end
					end
				end
			end
			if cz % 64 == 0 then
				harness.settle()
			end
		end
		-- the region each start is in, for a slope class: a number for each cell, the same across a region
		local function regions(slope_class: types.MoveClassName): buffer
			local region = buffer.create(width * depth * 4)
			local next_region = 0
			local stack: { number } = {}
			for cz = 0, depth - 1 do
				for cx = 0, width - 1 do
					local at = cz * width + cx
					if buffer.readu32(region, at * 4) == 0 and passability.passable_cell(slope_class, cx, cz) then
						next_region += 1
						buffer.writeu32(region, at * 4, next_region)
						table.insert(stack, at)
						while #stack > 0 do
							local here = table.remove(stack) :: number
							local hx, hz = here % width, here // width
							for _, step in { { 1, 0 }, { -1, 0 }, { 0, 1 }, { 0, -1 } } do
								local nx, nz = hx + step[1], hz + step[2]
								if nx >= 0 and nx < width and nz >= 0 and nz < depth then
									local there = nz * width + nx
									if
										buffer.readu32(region, there * 4) == 0
										and passability.passable_cell(slope_class, nx, nz)
									then
										buffer.writeu32(region, there * 4, next_region)
										table.insert(stack, there)
									end
								end
							end
						end
					end
				end
				if cz % 32 == 0 then
					harness.settle()
				end
			end
			return region
		end
		local function reach(slope_class: types.MoveClassName): Findings
			local region = regions(slope_class)
			local sizes: { [number]: number } = {}
			local has_water: { [number]: boolean } = {}
			for cz = 0, depth - 1 do
				for cx = 0, width - 1 do
					local id = buffer.readu32(region, (cz * width + cx) * 4)
					if id ~= 0 then
						sizes[id] = (sizes[id] or 0) + 1
						if is_water(cx, cz) then
							has_water[id] = true
						end
					end
				end
			end
			local per_start = {}
			local first: number? = nil
			local all_together = true
			for index = 1, starts.box_count() do
				local spot = starts.default_spot(index)
				local gx, gz = heightmap.world_to_grid(spot.X, spot.Y)
				local id = buffer.readu32(region, (math.floor(gz) * width + math.floor(gx)) * 4)
				if first == nil then
					first = id
				elseif id ~= first then
					all_together = false
				end
				per_start[index] = {
					reaches = round((sizes[id] or 0) / (width * depth), 3),
					sea = has_water[id] == true,
				}
			end
			return { starts = per_start, starts_connected = all_together }
		end
		results[name] = {
			water = round(water_cells / (width * depth), 3),
			hover_open = round(open_cells / (width * depth), 3),
			shore_climbable = if shore > 0 then round(climbable_shore / shore, 3) else "no shore",
			hover = reach "HOVER2",
		}
	end
	return { maps = results }
end

-- The maps drawn to show off one part of the game each (shared/map_designs), `args.maps` or every one: loaded in turn,
-- and for each what it holds (metal spots, rich ones, vents, wrecks) and where a bot (a Grunt), a tank (an Incisor), a
-- hovercraft (a Goon) and an amphibious unit (the Commander) can go, by the pathfinder's own routes: from the first start
-- box to the second, and to the places each map is about. For every trip, how far the route runs in studs, or false if it
-- does not get there.
local function map_designs_test(args: Args): Findings
	local names: { string } = args.maps
	if names == nil then
		names = {}
		for _, design in map_designs.ALL do
			if design.source == "design" then
				table.insert(names, design.name)
			end
		end
	end

	local results = {}
	for _, name in names do
		local ok, err = maps.load({ preset = name })
		if ok == false then
			results[name] = { error = err }
			continue
		end
		local wrecks = 0
		for _, entity in state.all() do
			if entity.kind == "wreck" then
				wrecks += 1
			end
		end
		local rich = 0
		for _, spot in spots.all "metal" do
			if spot.multiplier > 2 then
				rich += 1
			end
		end
		local targets: { [string]: Vector2 } = { across = starts.default_spot(2) }
		local own = DESIGN_PLACES[name]
		if own ~= nil then
			for place, at in own do
				targets[place] = at
			end
		end
		local home = starts.default_spot(1)
		local routes = {}
		for kind, def_name in WALKERS do
			local def = unit_defs.get(def_name)
			local from = surface.position(def, home.X, home.Y)
			local found = {}
			for place, at in targets do
				found[place] = route_length(def, from, surface.position(def, at.X, at.Y))
				harness.settle()
			end
			routes[kind] = found
		end
		results[name] = {
			spots = #spots.all "metal",
			rich = rich,
			vents = #spots.all "geo",
			wrecks = wrecks,
			boxes = starts.box_count(),
			routes = routes,
		}
	end
	return { maps = results }
end

-- The prairie (shared/map_designs/prairie.luau), loaded with `args.seed` or the default: whether it is the open map for
-- vehicles it is meant to be. For every start box, whether where a player who has not chosen starts is in it and can be
-- started on, how far it is from the middle of the box, and how far a tank (an Incisor) drives to it from the first box
-- by the pathfinder's own route, or false if it cannot; the steepest dry cell against a tank's limit, and how much of
-- the dry ground a tank cannot drive over; how much of the map is under water; and how many metal spots and vents
-- there are, and which of them an extractor or a geothermal plant cannot be put on. Every start should be good and
-- reachable by a tank, next to none of the dry ground too steep for one, and every spot and vent usable.
local function prairie_test(args: Args): Findings
	local ok, err = maps.load({ preset = "prairie", seed = args.seed })
	assert(ok, err)

	local tank = unit_defs.get "incisor"
	local home = starts.default_spot(1)
	local from = surface.position(tank, home.X, home.Y)
	local boxes = {}
	local boxes_ok = true
	for index = 1, starts.box_count() do
		local box = starts.box(index)
		local spot = starts.default_spot(index)
		local drive: number | boolean = 0
		if index > 1 then
			drive = route_length(tank, from, surface.position(tank, spot.X, spot.Y))
			harness.settle()
		end
		local default_ok = starts.in_box(index, spot.X, spot.Y) and starts.can_start_at(spot.X, spot.Y)
		boxes_ok = boxes_ok and default_ok and drive ~= false
		boxes[index] = {
			at = `{math.round(spot.X)}, {math.round(spot.Y)}`,
			default_ok = default_ok,
			off_middle = round((spot - (box.min + box.max) / 2).Magnitude, 1),
			tank_drive = drive,
		}
	end

	local tank_limit = passability.steepness_limit(passability.max_slope "TANK2" :: number)
	local width, depth = heightmap.cells()
	local steepest, dry, blocked, wet = 0, 0, 0, 0
	for cz = 0, depth - 1 do
		for cx = 0, width - 1 do
			local x, z = heightmap.grid_to_world(cx + 0.5, cz + 0.5)
			if heightmap.water_depth(x, z) > 0 then
				wet += 1
				continue
			end
			dry += 1
			steepest = math.max(steepest, passability.cell_steepness(cx, cz))
			if passability.passable_cell("TANK2", cx, cz) == false then
				blocked += 1
			end
		end
	end

	local unplaceable_spots = {}
	for _, spot in spots.all "metal" do
		local center = placement.ground_center("metal_extractor", spot.position.X, spot.position.Z)
		local placeable, reason = placement.can_place("metal_extractor", center, 0, nil, nil)
		if placeable == false then
			table.insert(unplaceable_spots, `{math.round(spot.position.X)}, {math.round(spot.position.Z)}: {reason}`)
		end
	end
	local unplaceable_vents = {}
	for _, vent in spots.all "geo" do
		local center = placement.ground_center("geothermal_powerplant", vent.position.X, vent.position.Z)
		local placeable, reason = placement.can_place("geothermal_powerplant", center, 0, nil, nil)
		if placeable == false then
			table.insert(unplaceable_vents, `{math.round(vent.position.X)}, {math.round(vent.position.Z)}: {reason}`)
		end
	end
	local reclaimables = 0
	for _, entity in state.all() do
		if entity.kind == "reclaimable" then
			reclaimables += 1
		end
	end

	local blocked_share = blocked / math.max(dry, 1)
	return {
		boxes = boxes,
		steepest_degrees = round(math.deg(math.atan(steepest)), 1),
		tank_limit_degrees = round(math.deg(math.atan(tank_limit)), 1),
		dry_tank_blocked = round(blocked_share, 4),
		under_water = round(wet / (width * depth), 3),
		metal_spots = #spots.all "metal",
		unplaceable_spots = unplaceable_spots,
		vents = #spots.all "geo",
		unplaceable_vents = unplaceable_vents,
		reclaimables = reclaimables,
		pass = boxes_ok
			and blocked_share <= PRAIRIE_MOST_BLOCKED
			and #spots.all "metal" > 0
			and #unplaceable_spots == 0
			and #unplaceable_vents == 0,
	}
end

-- Every map preset as shared/map_presets makes them, and what a lobby is offered of them: each one frozen all the way
-- down, an even number of cells across, with starts and start boxes, and the ones made for the game not taken for BAR's;
-- a lobby offered no campaign mission's map, BAR's only for a developer, and in the order it lists them; and a map
-- loaded with as many starts as its preset has, each its own place, which pinwheel's eight are.
local function presets_test(_args: Args): Findings
	local problems: { string } = {}
	local function thawed(value: any, path: string, seen: { [any]: boolean })
		if type(value) ~= "table" or seen[value] == true then
			return
		end
		seen[value] = true
		if table.isfrozen(value) == false then
			table.insert(problems, `{path} is not frozen`)
			return
		end
		for key, item in value do
			thawed(item, `{path}.{tostring(key)}`, seen)
		end
	end
	local seen: { [any]: boolean } = {}
	for name, preset in map_presets.presets do
		if preset.name ~= name then
			table.insert(problems, `{name} is listed under another name`)
		end
		thawed(preset, name, seen)
		if (preset.size.X / world_scale.CELL_STUDS) % 2 ~= 0 or (preset.size.Y / world_scale.CELL_STUDS) % 2 ~= 0 then
			table.insert(problems, `{name} is not an even number of cells across`)
		end
		if #preset.starts == 0 or #preset.start_boxes == 0 then
			table.insert(problems, `{name} has nowhere to start`)
		end
	end

	local offered = map_presets.lobby_choices(false)
	local to_developer = map_presets.lobby_choices(true)
	local order_ok = true
	for index = 2, #to_developer do
		if to_developer[index - 1].source == "bar" and to_developer[index].source ~= "bar" then
			order_ok = false
		end
	end
	local offered_names: { string } = {}
	for _, preset in offered do
		table.insert(offered_names, preset.name)
		if preset.source == "bar" or preset.campaign_only == true then
			table.insert(problems, `{preset.name} is offered to everyone`)
		end
	end

	local ok, err = maps.load({ preset = "pinwheel" })
	local distinct: { Vector2 } = {}
	for slot = 1, starts.count() do
		if table.find(distinct, starts.center(slot)) == nil then
			table.insert(distinct, starts.center(slot))
		end
	end
	return {
		problems = problems,
		offered = offered_names,
		bar_offered_to_developer = #to_developer - #offered,
		developer_order_ok = order_ok,
		pinwheel_loaded = if ok then true else err,
		pinwheel_starts = starts.count(),
		pinwheel_distinct_starts = #distinct,
		pass = #problems == 0 and order_ok and #to_developer > #offered and map_presets.lobby_may_choose(
			"tutorial",
			true
		) == false and ok and starts.count() == #map_presets.presets.pinwheel.starts and #distinct == starts.count(),
	}
end

local TESTS: { [string]: Test } = {
	presets = { run = presets_test },
	map = { run = map, diagnostic = true, studio_only = "reads the terrain's voxels" },
	load_map = { run = load_map, studio_only = "raycasts against the terrain" },
	load_every_map = { run = load_every_map },
	hover_reach = { run = hover_reach, diagnostic = true },
	map_designs = { run = map_designs_test, diagnostic = true },
	prairie = { run = prairie_test },
}

return table.freeze(TESTS)
