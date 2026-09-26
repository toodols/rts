--!strict
-- Tests of the economy: what the wind and the tide give, a lobby's resource bonus, sharing between allies, and the
-- notices a team is sent.

local ReplicatedStorage = game:GetService "ReplicatedStorage"
local ServerScriptService = game:GetService "ServerScriptService"

local types = require(ReplicatedStorage.Shared.types)
local tick_rate = require(ReplicatedStorage.Shared.tick_rate)
local heightmap = require(ReplicatedStorage.Shared.heightmap)
local unit_defs = require(ReplicatedStorage.Shared.unit_defs)
local spots = require(ReplicatedStorage.Shared.spots)
local map_presets = require(ReplicatedStorage.Shared.map_presets)
local environment = require(ReplicatedStorage.Shared.environment)
local game_modes = require(ReplicatedStorage.Shared.game_modes)

local state = require(ServerScriptService.Server.state)
local damage = require(ServerScriptService.Server.damage)
local wind = require(ServerScriptService.Server.wind)
local economy = require(ServerScriptService.Server.economy)
local match = require(ServerScriptService.Server.match)
local alliances = require(ServerScriptService.Server.alliances)
local sharing = require(ServerScriptService.Server.sharing)
local notifications = require(ServerScriptService.Server.notifications)

local harness = require(script.Parent.harness)

local OWN = harness.OWN
local ENEMY = harness.ENEMY
local ALLY = harness.ALLY
local advance = harness.advance
local round = harness.round
local spawn = harness.spawn
local unkillable = harness.unkillable
local clear_world = harness.clear_world
local ensure_team = harness.ensure_team
local flow_of = harness.flow_of

type Entity = types.Entity
type TeamId = types.TeamId
type Args = harness.Args
type Findings = harness.Findings
type Test = harness.Test

-- A duel handed in the way a lobby would hand one over, its first player with a resource bonus.
local BONUS_MATCH = table.freeze({
	mode = "1v1",
	preset = "highlands",
	seed = 7,
	seats = {
		{ user_id = 101, name = "Bonus", side = 1 },
		{ user_id = 102, name = "Plain", side = 2 },
	},
	bonuses = { ["101"] = 50 },
})

-- The wind and the tide (`environment`): every map's own are ones that can be, a tidal generator makes as much as the
-- tidal strength however it is set, and the wind keeps to a range set while the game runs. Puts the defaults back.
local function conditions(_args: Args): Findings
	local maps: Findings = {}
	local every_map_ok = true
	for name, preset in map_presets.presets do
		local ok, reason = environment.apply(preset.conditions or {})
		every_map_ok = every_map_ok and ok
		maps[name] = if ok
			then `{environment.min_wind()}-{environment.max_wind()} tide {environment.tidal_strength()}`
			else reason
	end

	environment.apply({})
	environment.set_tidal(40)
	local generator = spawn("tidal_generator", OWN, 0, 0)
	advance(tick_rate.TICK_DELTA * 2)
	local flow = flow_of(generator.id)
	local made_at_40 = if flow ~= nil then flow.energy else nil

	environment.set_wind(5, 6)
	wind.refit()
	local slowest, fastest = math.huge, 0
	advance(20, function()
		slowest = math.min(slowest, wind.speed())
		fastest = math.max(fastest, wind.speed())
	end)

	clear_world()
	environment.apply({})
	wind.refit()
	return {
		maps = maps,
		tidal_generator_at_40 = made_at_40,
		wind_5_to_6 = { round(slowest, 2), round(fastest, 2) },
		pass = every_map_ok
			and made_at_40 ~= nil
			and math.abs(made_at_40 - 40) < 1e-6
			and slowest >= 5 - 1e-6
			and fastest <= 6 + 1e-6,
	}
end

-- What each seated team's own extractor, solar collector, wind turbine and commander make under the resource bonus its
-- player was given in the match handed in (`args.match`; a duel with a bonus of 50 for one side unless another is
-- given), against what their defs say they make. The extractor and the generators should make 1 + bonus / 100 times
-- that and the commander what its def says whatever the bonus, and a converter should convert at its def's rate either
-- way. Every team's things stand together on one metal spot, so they all see the same spot, wind and tide.
local function resource_bonus(_args: Args): Findings
	local handed = match.get()
	assert(handed ~= nil, "no match was handed in: pass one as `match`")
	local spot = spots.all("metal")[1].position

	local teams: { [string]: Findings } = {}
	local ok = true
	for _, seat in handed.seats do
		local team = match.team_of(seat.user_id)
		if team == nil then
			continue
		end
		ensure_team(team)
		local extractor = spawn("metal_extractor", team, spot.X, spot.Z)
		local solar = spawn("solar_collector", team, spot.X + 40, spot.Z)
		local turbine = spawn("wind_turbine", team, spot.X, spot.Z + 40)
		local commander = unkillable(spawn("commander", team, spot.X - 40, spot.Z))
		local converter = spawn("energy_converter", team, spot.X, spot.Z - 40)
		-- enough energy over the converters' threshold, and room for their metal, that they run flat out
		advance(tick_rate.TICK_DELTA)
		local team_state = state.get_team(team) :: types.Team
		harness.set_bank(team, { metal = 0, energy = team_state.energy_capacity })
		advance(tick_rate.TICK_DELTA)

		local scale = 1 + game_modes.bonus_of(handed, seat.user_id) / 100
		local function made(entity: Entity): (number, number)
			local flow = flow_of(entity.id)
			if flow == nil then
				return 0, 0
			end
			return flow.metal, flow.energy
		end
		local extractor_metal = made(extractor)
		local _, solar_energy = made(solar)
		local _, turbine_energy = made(turbine)
		local commander_metal, commander_energy = made(commander)
		local converter_metal = made(converter)
		local commander_def = unit_defs.get "commander"
		local expected: { [string]: number } = {
			extractor_metal = unit_defs.get("metal_extractor").metal_income :: number * spots.multiplier_at(
				extractor.position
			) * scale,
			solar_energy = unit_defs.get("solar_collector").energy_income :: number * scale,
			turbine_energy = wind.speed() * unit_defs.get("wind_turbine").wind_multiplier :: number * scale,
			commander_metal = commander_def.metal_income :: number,
			commander_energy = commander_def.energy_income :: number,
			converter_metal = (unit_defs.get("energy_converter").energy_conversion :: types.EnergyConversion).metal_per_second,
		}
		local got: { [string]: number } = {
			extractor_metal = extractor_metal,
			solar_energy = solar_energy,
			turbine_energy = turbine_energy,
			commander_metal = commander_metal,
			commander_energy = commander_energy,
			converter_metal = converter_metal,
		}
		local wrong = {}
		for key, want in expected do
			if math.abs(got[key] - want) > 1e-6 then
				table.insert(wrong, `{key}: {round(got[key], 3)}, not {round(want, 3)}`)
			end
		end
		ok = ok and #wrong == 0
		teams[tostring(team)] = {
			side = seat.side,
			bonus = economy.bonus_of(team),
			made = got,
			wrong = wrong,
		}
		clear_world()
	end
	return { teams = teams, pass = ok and next(teams) ~= nil }
end

-- Giving resources from the player list (sharing.luau): only to an ally, never more than the giver has or the taker
-- has room for, and nothing for a request that makes no sense, whether it is asked for on the server or sent by a
-- player's client (ShareResources), which is only heard with a real amount of a real resource.
local function resource_sharing(_args: Args): Findings
	local giver = ensure_team(OWN)
	local ally = ensure_team(ALLY)
	local enemy = ensure_team(ENEMY)
	alliances.ally(giver.id, ally.id)
	local function reset()
		harness.set_bank(giver.id, { metal = 300, metal_capacity = 1000, energy = 500, energy_capacity = 1000 })
		harness.set_bank(ally.id, { metal = 0, metal_capacity = 5000, energy = 900, energy_capacity = 1000 })
		harness.set_bank(enemy.id, { metal = 0, metal_capacity = 1000, energy = 0, energy_capacity = 1000 })
	end

	reset()
	local capped_by_room = sharing.share(giver.id, ally.id, "energy", 400)
	local room_banks = { giver = giver.energy, ally = ally.energy }
	reset()
	local capped_by_stock = sharing.share(giver.id, ally.id, "metal", 1000)
	local stock_banks = { giver = giver.metal, ally = ally.metal }
	reset()
	local to_enemy = sharing.share(giver.id, enemy.id, "metal", 100)
	local to_self = sharing.share(giver.id, giver.id, "metal", 100)
	local nan = sharing.share(giver.id, ally.id, "metal", 0 / 0)
	local negative = sharing.share(giver.id, ally.id, "metal", -50)
	local rejected_left_banks = giver.metal == 300 and ally.metal == 0 and enemy.metal == 0
	-- what a client sends: a player on the giving team, sending what no client should, and then 100 metal
	local player = harness.join(giver.id)
	harness.send("ShareResources", player, ally.id, "metal", 0 / 0)
	harness.send("ShareResources", player, ally.id, "metal", math.huge)
	harness.send("ShareResources", player, ally.id, "gold", 100)
	harness.send("ShareResources", player, tostring(ally.id), "metal", 100)
	local unsendable = giver.metal == 300 and ally.metal == 0
	harness.send("ShareResources", player, ally.id, "metal", 100)
	local sent = ally.metal

	return {
		-- 400 asked, the ally has room for 100
		capped_by_room = capped_by_room,
		room_banks = room_banks,
		-- 1000 asked, the giver has 300
		capped_by_stock = capped_by_stock,
		stock_banks = stock_banks,
		rejected = {
			to_enemy = to_enemy,
			to_self = to_self,
			nan = nan,
			negative = negative,
		},
		unsendable = unsendable,
		sent = sent,
		rejected_left_banks = rejected_left_banks,
		pass = capped_by_room == 100
			and room_banks.giver == 400
			and room_banks.ally == 1000
			and capped_by_stock == 300
			and stock_banks.giver == 0
			and stock_banks.ally == 300
			and to_enemy + to_self + nan + negative == 0
			and unsendable
			and sent == 100
			and rejected_left_banks,
	}
end

-- Notifications (server/notifications.luau): an ally's gift of metal and a request for it reach the right team and
-- nobody else; a base is told it is under attack when an enemy hurts an unarmed building, not again while that goes on,
-- and again after BASE_QUIET_SECONDS of quiet, and never for an armed one or a harmless hit; a commander hurt by an
-- enemy is told of the same way, as a commander and not a base; and an enemy's aircraft, a blueprint as much as a
-- finished one, is told of once.
local function notifications_test(_args: Args): Findings
	local own = ensure_team(OWN)
	local ally = ensure_team(ALLY)
	local enemy = ensure_team(ENEMY)
	alliances.ally(own.id, ally.id)
	harness.set_bank(own.id, { metal = 100, metal_capacity = 1000 })
	harness.set_bank(ally.id, { metal = 500, metal_capacity = 1000, energy = 500, energy_capacity = 1000 })

	local log: { [number]: { string } } = { [own.id] = {}, [ally.id] = {}, [enemy.id] = {} }
	local amounts: { [string]: number } = {}
	local stop = notifications.on_sent(function(team_id: TeamId, notice: types.Notice)
		local list = log[team_id]
		if list ~= nil then
			table.insert(list, notice.kind)
			if notice.amount ~= nil then
				amounts[`{team_id}:{notice.kind}`] = notice.amount
			end
		end
	end)
	local function count(team_id: TeamId, kind: string): number
		local total = 0
		for _, logged in log[team_id] do
			if logged == kind then
				total += 1
			end
		end
		return total
	end

	sharing.share(ally.id, own.id, "metal", 150)
	sharing.share(ally.id, own.id, "energy", 100)
	notifications.request_metal(own.id, 5000)

	local solar = spawn("solar_collector", own.id, 0, 0)
	local guard = unkillable(spawn("guard", own.id, 30, 0))
	advance(1)
	unkillable(solar)
	damage.apply(guard, 10, nil, enemy.id)
	damage.apply(solar, 10, nil, ally.id)
	damage.apply(solar, 10, nil, nil)
	local before_attack = count(own.id, "base_attacked")
	damage.apply(solar, 10, nil, enemy.id)
	local first_attack = count(own.id, "base_attacked")
	advance(5)
	damage.apply(solar, 10, nil, enemy.id)
	local kept_up = count(own.id, "base_attacked")
	advance(11)
	damage.apply(solar, 10, nil, enemy.id)
	local after_quiet = count(own.id, "base_attacked")

	local commander = unkillable(spawn("commander", own.id, -30, 0))
	damage.apply(commander, 10, nil, ally.id)
	local commander_before = count(own.id, "commander_attacked")
	damage.apply(commander, 10, nil, enemy.id)
	local commander_first = count(own.id, "commander_attacked")
	advance(5)
	damage.apply(commander, 10, nil, enemy.id)
	local commander_kept_up = count(own.id, "commander_attacked")
	advance(11)
	damage.apply(commander, 10, nil, enemy.id)
	local commander_after_quiet = count(own.id, "commander_attacked")
	local base_after_commander = count(own.id, "base_attacked")

	local air_before = count(own.id, "air_detected")
	state.create_entity("valiant", enemy.id, heightmap.ground_position(-60, 0), 0, "blueprint")
	advance(2)
	local air_first = count(own.id, "air_detected")
	spawn("valiant", enemy.id, -80, 0)
	advance(3)
	stop()

	local findings: Findings = {
		own = log[own.id],
		ally = log[ally.id],
		enemy = log[enemy.id],
		sent_amount = amounts[`{own.id}:metal_sent`],
		requested_amount = amounts[`{ally.id}:metal_request`],
		base = { before = before_attack, first = first_attack, kept_up = kept_up, after_quiet = after_quiet },
		commander = {
			before = commander_before,
			first = commander_first,
			kept_up = commander_kept_up,
			after_quiet = commander_after_quiet,
		},
		air = { before = air_before, first = air_first, total = count(own.id, "air_detected") },
	}
	findings.pass = count(own.id, "metal_sent") == 1
		and findings.sent_amount == 150
		and count(ally.id, "metal_request") == 1
		-- it had 250 of 1000 by then, so room for 750
		and findings.requested_amount == 750
		and count(own.id, "metal_request") == 0
		and before_attack == 0
		and first_attack == 1
		and kept_up == 1
		and after_quiet == 2
		and commander_before == 0
		and commander_first == 1
		and commander_kept_up == 1
		and commander_after_quiet == 2
		and base_after_commander == 2
		and air_before == 0
		and air_first == 1
		and findings.air.total == 1
		and count(ally.id, "air_detected") == 1
		and #log[enemy.id] == 0
	return findings
end

local TESTS: { [string]: Test } = {
	conditions = { run = conditions },
	resource_bonus = { run = resource_bonus, defaults = { match = BONUS_MATCH } },
	resource_sharing = { run = resource_sharing },
	notifications = { run = notifications_test },
}

return table.freeze(TESTS)
