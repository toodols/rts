--!strict
-- The bridge between a headless game (tools/lib) and the Rust AI (tools/rust_ai/src), for the AI arena: a team whose
-- side is `{"engine": "rust"}` is played by a `rust_ai` process rather than by server/ai.
--
-- The process is started once per team and kept for the whole game. The two talk in lines of JSON, one each way per
-- thought: the bridge sends what the team sees (`observe`), the process answers with commands, and the bridge carries
-- them out through what a player's commands go through (orders.issue, production.enqueue, placement), so the Rust AI
-- plays by the game's rules as server/ai does: it pays for what it builds, walks where it goes, and can only build what
-- its builders can, where the game lets it. The first line the bridge sends (`hello`) is what does not change: the
-- map (every ground a unit walks on, as open and closed cells, and the metal spots) and every def's numbers.
--
-- What the Rust AI decides it decides for itself: where to walk (its own routes round danger, sent as waypoints), what
-- to build and where (the bridge only moves a site that cannot be built on to the nearest one that can), and what its
-- labs make. It sees what server/ai sees by default: everything, wherever it is.

local process = require "@lune/process"
local serde = require "@lune/serde"

local function round(value: number, places: number): number
	local scale = 10 ^ places
	return math.round(value * scale) / scale
end

export type Options = {
	-- the repository's root, where tools/rust_ai is
	root: string,
	-- the executable, if not the release build under tools/rust_ai/target
	exe: string?,
	-- the Rust AI's tunable numbers (tools/rust_ai/src/params.rs), any it is not given keeping their defaults
	params: { [string]: any }?,
	-- the line it plays, if it is told one
	line: string?,
	-- where the process writes what it thinks, a line a thought, if anywhere
	log: string?,
	-- given each thought's commands (and the game's time) before they are carried out, for a recorded game to keep
	on_commands: ((now: number, commands: { any }) -> ())?,
}

-- What a weapon is to the Rust AI: its sustained fire and what it can be turned on, and the few things about its
-- shots that decide how often they land (as server/ai/combat_sim.luau's `gun_of` reads them).
local function weapon_info(game: any, weapon: any): { [string]: any }
	local unit_defs = game.shared "unit_defs"
	local damage = game.server "damage"
	local weapons = game.server "weapons"
	local delivery = weapon.delivery
	local splash, edge, flight, scatter = 0, 0, 0, 0
	local homes = false
	if delivery.kind == "beam" then
		local lightning = delivery.lightning
		if lightning ~= nil then
			splash, edge = lightning.range, lightning.fork_damage
		end
	else
		local params = delivery.projectile
		splash, edge = params.aoe_radius, damage.edge_of(params.edge_effectiveness)
		-- as server/ai/combat_sim.luau's ARC_FLIGHT has it: a low arc flies near flat, and is taken as a direct shot
		local arc = if delivery.kind == "missile"
			then 2
			elseif delivery.kind == "lobbed" and delivery.arc == "medium" then 1 / math.cos(math.rad(45))
			elseif delivery.kind == "lobbed" and (delivery.arc == "high" or delivery.arc == "auto") then 2
			else nil
		if arc ~= nil and params.speed > 0 then
			flight = arc / params.speed
		end
		homes = (delivery.kind == "straight" or delivery.kind == "torpedo") and delivery.guidance == "homes"
		if homes == false then
			scatter = params.inaccuracy or 0
		end
	end
	return {
		dps = weapons.damage_per_second(weapon),
		shot = weapon.damage,
		reload = weapon.reload,
		range = weapon.range,
		splash = splash,
		edge = edge,
		flight = flight,
		scatter = scatter,
		ground = unit_defs.reaches_layer(weapon, "ground"),
		water = unit_defs.reaches_layer(weapon, "water"),
		air = unit_defs.reaches_layer(weapon, "air"),
		under = unit_defs.reaches_layer(weapon, "under"),
		anti_air = unit_defs.is_anti_air(weapon),
		manual = weapon.manual_fire == true,
		anti_nuke = unit_defs.is_anti_nuke(weapon),
		paralyze = weapon.paralyze_time ~= nil,
		group = weapon.weapon_group,
		energy_per_shot = weapon.energy_per_shot,
		stockpile = weapon.stockpile ~= nil,
	}
end

-- The key of the ground something of `def` walks on, as shared/pathfinder keys it, or nil for what does not walk.
local function ground_key(unit_defs: any, def: any): string?
	if unit_defs.walks(def) == false then
		return nil
	end
	local footing = def.footing
	return `{footing.class or ""}|{footing.min_depth}|{footing.max_depth}`
end

-- What a def is to the Rust AI.
local function def_info(game: any, def: any): { [string]: any }
	local unit_defs = game.shared "unit_defs"
	local builder = def.builder
	local weapon_list = {}
	for _, weapon in def.weapons or {} do
		table.insert(weapon_list, weapon_info(game, weapon))
	end
	local half = unit_defs.footprint_half_extents(def)
	local conversion = def.energy_conversion
	local death = def.death_explosion
	return {
		name = def.name,
		kind = def.kind,
		category = def.category,
		tech = def.tech_level or 0,
		metal = def.metal_cost,
		energy = def.energy_cost,
		buildtime = def.buildpower_cost,
		health = unit_defs.max_health(def),
		speed = if unit_defs.moves(def) then def.max_speed else 0,
		air = unit_defs.is_air(def),
		bomber = def.air ~= nil and def.air.bombing_runs == true,
		radius = unit_defs.collider_radius(def),
		half_x = half.X,
		half_z = half.Y,
		ground = ground_key(unit_defs, def),
		buildpower = if builder ~= nil then builder.buildpower else 0,
		build_range = unit_defs.build_range(def) or 0,
		options = unit_defs.build_options(def),
		assists = unit_defs.does(def, "assist"),
		repairs = unit_defs.does(def, "repair"),
		reclaims = unit_defs.does(def, "reclaim"),
		resurrects = unit_defs.does(def, "resurrect"),
		factory = unit_defs.is_factory(def),
		commander = unit_defs.is_commander(def),
		metal_income = def.metal_income or 0,
		energy_income = def.energy_income or 0,
		wind = def.wind_multiplier or 0,
		tidal = def.tidal_multiplier or 0,
		metal_storage = def.metal_storage or 0,
		energy_storage = def.energy_storage or 0,
		convert_energy = if conversion ~= nil then conversion.energy_per_second else 0,
		convert_metal = if conversion ~= nil then conversion.metal_per_second else 0,
		spot = def.spot,
		upgrades = def.upgrades or {},
		stealth = def.stealth == true,
		autoheal = def.autoheal or 0,
		death_radius = if death ~= nil then death.radius else 0,
		death_damage = if death ~= nil then death.damage else 0,
		weapons = weapon_list,
		dgun_range = if def.manual_weapon ~= nil then def.manual_weapon.range else 0,
		dgun_reload = if def.manual_weapon ~= nil then def.manual_weapon.reload else 0,
		dgun_energy = if def.manual_weapon ~= nil then def.manual_weapon.energy_per_shot else 0,
		carrier_range = if def.carrier ~= nil then def.carrier.engage_range else 0,
		carrier_drone = if def.carrier ~= nil then def.carrier.drone else nil,
		carrier_count = if def.carrier ~= nil then def.carrier.count else 0,
		immune = def.damage_immunity ~= nil,
		objectify = def.objectify == true,
		power = unit_defs.power(def),
	}
end

-- What does not change over a game: the map, and every def.
local function hello(game: any, team: number, enemies: { number }, options: Options): { [string]: any }
	local unit_defs = game.shared "unit_defs"
	local heightmap = game.shared "heightmap"
	local pathfinder = game.shared "pathfinder"
	local spots = game.shared "spots"
	local world_scale = game.shared "world_scale"
	local cells_x, cells_z = heightmap.cells()
	local origin_x, origin_z = heightmap.grid_to_world(0, 0)
	local cell = world_scale.CELL_STUDS

	local defs = {}
	local grounds: { [string]: string } = {}
	local names = {}
	for name in unit_defs.defs do
		table.insert(names, name)
	end
	table.sort(names)
	for _, name in names do
		local def = unit_defs.get(name)
		if def.kind ~= "unit" and def.kind ~= "building" then
			continue
		end
		table.insert(defs, def_info(game, def))
		-- one open-and-closed map for each ground something walks on
		local key = ground_key(unit_defs, def)
		if key ~= nil and grounds[key] == nil then
			local row = table.create(cells_x * cells_z)
			for cz = 0, cells_z - 1 do
				for cx = 0, cells_x - 1 do
					local x, z = heightmap.grid_to_world(cx + 0.5, cz + 0.5)
					row[cz * cells_x + cx + 1] = if pathfinder.open_at(def, x, z) then "1" else "0"
				end
			end
			grounds[key] = table.concat(row)
		end
	end

	-- the height of each cell's middle, to the nearest tenth of a stud, for what shoots over hills
	local heights = table.create(cells_x * cells_z)
	for cz = 0, cells_z - 1 do
		for cx = 0, cells_x - 1 do
			local x, z = heightmap.grid_to_world(cx + 0.5, cz + 0.5)
			heights[cz * cells_x + cx + 1] = round(heightmap.height_at(x, z), 1)
		end
	end

	local metal = {}
	for _, spot in spots.all "metal" do
		table.insert(metal, { x = spot.position.X, z = spot.position.Z, m = spot.multiplier })
	end
	local geo = {}
	for _, spot in spots.all "geo" do
		table.insert(geo, { x = spot.position.X, z = spot.position.Z })
	end
	local state = game.server "state"
	local starts = {}
	for _, entity in state.all() do
		if entity.alive and unit_defs.is_commander(entity.def) then
			starts[tostring(entity.team)] = { x = entity.position.X, z = entity.position.Z }
		end
	end
	local weapon_kinds = game.shared "weapon_kinds"
	local order_kinds = game.shared "order_kinds"
	return {
		type = "hello",
		team = team,
		enemies = enemies,
		line = options.line,
		constants = {
			non_aa_air_fraction = weapon_kinds.NON_AA_AIR_DAMAGE_FRACTION,
			aa_non_air_damage = weapon_kinds.AA_NON_AIR_DAMAGE,
			range_margin = order_kinds.RANGE_MARGIN,
		},
		params = options.params or {},
		log = options.log,
		map = {
			cells_x = cells_x,
			cells_z = cells_z,
			cell = cell,
			origin_x = origin_x,
			origin_z = origin_z,
			grounds = grounds,
			heights = heights,
			metal = metal,
			geo = geo,
			starts = starts,
		},
		defs = defs,
	}
end

-- What the team sees in a thought: every team's bank, and everything on the map.
local function observe(game: any, now: number, results: { any }): { [string]: any }
	local state = game.server "state"
	local wind = game.server "wind"
	local teams = {}
	for id, team in state.all_teams() do
		teams[tostring(id)] = {
			metal = round(team.metal, 2),
			energy = round(team.energy, 2),
			metal_income = round(team.metal_income, 3),
			energy_income = round(team.energy_income, 3),
			metal_capacity = team.metal_capacity,
			energy_capacity = team.energy_capacity,
			metal_revenue = round(team.metal_revenue, 3),
			metal_expense = round(team.metal_expense, 3),
			energy_revenue = round(team.energy_revenue, 3),
			energy_expense = round(team.energy_expense, 3),
		}
	end
	local entities = {}
	for _, entity in state.all() do
		if entity.alive == false then
			continue
		end
		local kind = entity.kind
		local item: { [string]: any } = {
			id = entity.id,
			t = entity.team,
			d = if kind == "wreck" or kind == "reclaimable" then entity.def.name else entity.def_name,
			k = kind,
			x = round(entity.position.X, 2),
			y = round(entity.position.Y, 2),
			z = round(entity.position.Z, 2),
		}
		if kind == "unit" or kind == "building" then
			item.vx = round(entity.velocity.X, 2)
			item.vz = round(entity.velocity.Z, 2)
			item.hp = round(entity.health, 1)
			item.mhp = entity.max_health
			if entity.state == "blueprint" then
				item.bp = round(entity.build_progress / math.max(1, entity.def.buildpower_cost), 4)
			end
			local first = entity.orders[1]
			if first ~= nil then
				item.o = first.kind
				item.ot = first.target_id
				if first.position ~= nil then
					item.ox = round(first.position.X, 1)
					item.oz = round(first.position.Z, 1)
				end
				item.on = #entity.orders
				-- a build order's def, which the Rust AI counts as spoken for
				local last = entity.orders[#entity.orders]
				if last.kind == "build" then
					item.od = last.def_name
					if last.position ~= nil then
						item.bx = round(last.position.X, 1)
						item.bz = round(last.position.Z, 1)
					end
				end
			end
			if #entity.queue > 0 then
				item.q = entity.queue
			end
			if entity.emp > 0 then
				item.emp = round(entity.emp / math.max(1, entity.max_health), 3)
			end
			if entity.manual_reload_remaining > 0 then
				item.dr = round(entity.manual_reload_remaining, 2)
			end
		else
			local yield = entity.yield
			if yield ~= nil then
				item.ml = round(yield.metal_left, 1)
				item.el = round(yield.energy_left, 1)
				item.bl = round(yield.buildpower_left, 1)
			end
			if entity.wreck ~= nil then
				item.src = entity.wreck.source_def_name
			end
		end
		table.insert(entities, item)
	end
	return {
		type = "observe",
		time = round(now, 3),
		wind = round(wind.speed(), 3),
		teams = teams,
		entities = entities,
		results = results,
	}
end

export type Side = {
	think: (now: number) -> (),
	report: () -> { [string]: any },
	close: () -> (),
}

-- Starts the Rust AI for team `team`, which already has its commander, against `enemies`.
local function start(game: any, team: number, enemies: { number }, options: Options): Side
	local external_orders = game.server "external_orders"

	local exe = options.exe or `{options.root}/tools/rust_ai/target/release/rust_ai.exe`
	local child = process.create(exe, {})
	local buffer_left = ""
	local last_report: { [string]: any } = {}
	local think_seconds = 0
	local thoughts = 0
	local commands_applied = 0
	local commands_failed = 0

	local function send(message: { [string]: any })
		child.stdin:write(serde.encode("json", message) .. "\n")
	end

	-- The next line the process writes; an error with what it wrote to stderr if it wrote none, having ended.
	local function receive(): { [string]: any }
		while true do
			local newline = string.find(buffer_left, "\n", 1, true)
			if newline ~= nil then
				local line = string.sub(buffer_left, 1, newline - 1)
				buffer_left = string.sub(buffer_left, newline + 1)
				if string.sub(line, 1, 1) == "{" then
					return serde.decode("json", line)
				end
				-- anything else it prints is a note, passed on
				print(`[rust_ai {team}] {line}`)
				continue
			end
			local chunk = child.stdout:read()
			if chunk == nil or chunk == "" then
				local status = child:status()
				local stderr = child.stderr:readToEnd()
				error(`rust_ai for team {team} ended (code {status.code}): {stderr}`)
			end
			buffer_left ..= chunk
		end
	end

	local results: { any } = {}

	local function think(now: number)
		local started = os.clock()
		send(observe(game, now, results))
		local answer = receive()
		results = {}
		local commands = answer.cmds or {}
		-- a recorded game keeps them, for its replay to give again (server/external_orders.luau)
		if options.on_commands ~= nil and #commands > 0 then
			options.on_commands(now, commands)
		end
		local outcomes = external_orders.apply_all(team, commands)
		for index, command in commands do
			local outcome = outcomes[index]
			if outcome.ok then
				commands_applied += 1
			else
				commands_failed += 1
			end
			-- what came of each command that is asked after (`tag`), and every failure
			if command.tag ~= nil or outcome.ok == false then
				outcome.i = index
				outcome.tag = command.tag
				table.insert(results, outcome)
			end
		end
		if answer.report ~= nil then
			last_report = answer.report
		end
		think_seconds += os.clock() - started
		thoughts += 1
	end

	local function report(): { [string]: any }
		local result = table.clone(last_report)
		result.thoughts = thoughts
		result.think_ms = round(think_seconds * 1000 / math.max(1, thoughts), 2)
		result.commands = commands_applied
		result.failed = commands_failed
		return result
	end

	local function close()
		pcall(function()
			send({ type = "bye" })
			child.stdin:close()
		end)
		pcall(function()
			child:kill()
		end)
	end

	local started = os.clock()
	send(hello(game, team, enemies, options))
	local ready = receive()
	assert(ready.type == "ready", "rust_ai did not say it was ready")
	think_seconds += os.clock() - started
	return {
		think = think,
		report = report,
		close = close,
	}
end

return {
	start = start,
	hello = hello,
}
