--!strict
-- What a def's numbers come to, in words and figures, for whatever shows them: the HUD's selection panel (its loadout
-- rows and their tooltips) and the lobby's encyclopedia, which lays the same facts out in full. Only the facts are
-- here, as rows of a label and a value; how each is drawn is its screen's business. Every figure is read off the def,
-- whose numbers are BAR's (see shared/unit_defs), and nothing here makes one up.

local ReplicatedStorage = game:GetService "ReplicatedStorage"

local types = require(ReplicatedStorage.Shared.types)
local unit_defs = require(ReplicatedStorage.Shared.unit_defs)
local weapon_kinds = require(ReplicatedStorage.Shared.weapon_kinds)

type EntityDef = types.EntityDef
type Weapon = types.Weapon
type ManualWeapon = types.ManualWeapon

-- One fact: what it is and how much. `tag` is a tone class for the value ("metal", "energy", "weapon", ...), and
-- `divider` sets a row off from those above it, as a total is from what it adds up. A tooltip's rows are these.
-- `headline` marks a weapon's damage a second and its range, which a screen that shows them large, as the
-- encyclopedia's weapon cards do, leaves out of its rows.
export type Row = { label: string, value: string, tag: string?, divider: boolean?, headline: boolean? }

-- A number as a readout: whole when it is big enough that the fraction would be noise, one place otherwise.
local function figure(value: number): string
	if math.abs(value) >= 100 or value == math.floor(value) then
		return tostring(math.round(value))
	end
	return string.format("%.1f", value)
end

-- A time in seconds, to two places while it is short.
local function seconds(value: number): string
	if value >= 10 then
		return `{math.round(value)}s`
	end
	return `{string.format("%.2f", value)}s`
end

-- A distance in studs, the world's unit.
local function studs(value: number): string
	return `{figure(value)} studs`
end

-- A weapon's name, the short code on its slot, and its icon (Shared.ui_art), all its kind's.
local function weapon_kind(weapon: Weapon): (string, string, string)
	local kind = weapon_kinds.get(weapon.kind)
	return kind.name, kind.slot, kind.icon
end

-- A weapon's damage a second while it keeps firing: a whole burst, the gaps within it and the reload after it. One
-- that fires from a stockpile keeps firing only as fast as the stockpile refills, one missile every `build_time`,
-- however short its reload: the Thor's EMP missile reloads in 3 seconds but is built in 65.
local function weapon_dps(weapon: Weapon): number
	local shots = math.max(1, weapon.burst_count or 1)
	local cycle = weapon.reload + (shots - 1) * unit_defs.burst_interval(weapon)
	if weapon.stockpile ~= nil then
		cycle = math.max(cycle, weapon.stockpile.build_time)
	end
	return weapon.damage * shots / math.max(cycle, 1e-3)
end

-- The damage a second of all of `def`'s weapons together, or nil if it has none that does damage. An EMP weapon's
-- damage only stuns and an anti-nuke only shoots down missiles, so neither counts.
local function damage_dps(def: EntityDef): number?
	local total: number? = nil
	for _, weapon in def.weapons or {} :: { Weapon } do
		if weapon.paralyze_time == nil and unit_defs.is_anti_nuke(weapon) == false then
			total = (total or 0) + weapon_dps(weapon)
		end
	end
	return total
end

-- What a weapon can shoot at, in a word or two.
local function targets_text(weapon: Weapon): string
	if unit_defs.is_anti_nuke(weapon) then
		return "Nuclear missiles"
	elseif weapon.target_layer == "air" then
		return "Air"
	elseif weapon.target_layer == "ground" then
		return "Ground"
	end
	return "Ground and air"
end

-- Everything about a weapon, as rows, and the notes on what it does that no number says.
local function weapon_rows(weapon: Weapon): ({ Row }, { string })
	-- an EMP weapon's damage is EMP, which stuns and does not hurt
	local dealt = if weapon.paralyze_time ~= nil then "EMP" else "Damage"
	local rows: { Row } = {
		{ label = `{dealt} a second`, value = figure(weapon_dps(weapon)), tag = "weapon", headline = true },
		{ label = `{dealt} a shot`, value = figure(weapon.damage) },
	}
	if weapon.paralyze_time ~= nil then
		table.insert(rows, { label = "Longest stun", value = seconds(weapon.paralyze_time) })
	end
	local burst = weapon.burst_count
	if burst ~= nil and burst > 1 then
		table.insert(rows, {
			label = "Burst",
			value = `{burst} shots, {seconds(unit_defs.burst_interval(weapon))} apart`,
		})
	end
	table.insert(rows, { label = "Reload", value = seconds(weapon.reload) })
	table.insert(rows, { label = "Range", value = studs(weapon.range), headline = true })
	local projectile = unit_defs.projectile_of(weapon)
	if projectile ~= nil and projectile.aoe_radius > 0 then
		table.insert(rows, { label = "Blast radius", value = studs(projectile.aoe_radius) })
	end
	if projectile ~= nil and projectile.speed > 0 then
		table.insert(rows, { label = "Shot speed", value = `{studs(projectile.speed)}/s` })
	end
	if weapon.energy_per_shot > 0 then
		-- a burst is paid for once, as it starts
		local per = if burst ~= nil and burst > 1 then "burst" else "shot"
		table.insert(rows, { label = `Energy a {per}`, value = figure(weapon.energy_per_shot), tag = "energy" })
	end
	local lightning = if weapon.delivery.kind == "beam" then weapon.delivery.lightning else nil
	if lightning ~= nil then
		table.insert(rows, {
			label = "Sparks",
			value = `{lightning.forks} within {studs(lightning.range)}, {math.round(lightning.fork_damage * 100)}%`,
		})
	end
	table.insert(rows, { label = "Targets", value = targets_text(weapon) })
	local kind = weapon_kinds.get(weapon.kind)
	if kind.anti_air ~= true and kind.anti_nuke ~= true and weapon.target_layer ~= "ground" then
		table.insert(rows, { label = "Vs air", value = `{math.round(weapon_kinds.NON_AA_AIR_DAMAGE_FRACTION * 100)}%` })
	end
	local stockpile = weapon.stockpile
	if stockpile ~= nil then
		table.insert(rows, { label = "Holds", value = `{stockpile.limit}, one every {seconds(stockpile.build_time)}` })
		table.insert(rows, { label = "Each costs", value = `{stockpile.metal} M · {stockpile.energy} E` })
	end

	local notes: { string } = {}
	if weapon.manual_fire then
		table.insert(notes, "Manual fire")
	end
	if weapon.weapon_group ~= nil then
		table.insert(notes, "Shared reload")
	end
	if kind.pierces == true then
		table.insert(notes, "Passes through")
	end
	return rows, notes
end

-- The commander's disintegrator, the one manual weapon: what it is called, its slot's code and icon, and what it does.
local MANUAL_WEAPON = table.freeze({
	name = "DISINTEGRATOR",
	slot = "DGN",
	icon = "icon_disintegrator",
	text = "Destroys everything in its strip, allies too.",
})

local function manual_weapon_rows(manual: ManualWeapon): { Row }
	return {
		{ label = "Range", value = studs(manual.range), headline = true },
		{ label = "Strip width", value = studs(manual.radius * 2) },
		{ label = "Reload", value = seconds(manual.reload) },
		{ label = "Energy a shot", value = figure(manual.energy_per_shot), tag = "energy" },
	}
end

-- Which of a builder's jobs `def` does, in words.
local function build_jobs(def: EntityDef): { string }
	local jobs: { string } = {}
	if #unit_defs.build_options(def) > 0 then
		table.insert(jobs, "Build")
	end
	if unit_defs.does(def, "assist") then
		table.insert(jobs, "Assist")
	end
	if unit_defs.does(def, "repair") then
		table.insert(jobs, "Repair")
	end
	if unit_defs.does(def, "reclaim") then
		table.insert(jobs, "Reclaim")
	end
	if unit_defs.does(def, "resurrect") then
		table.insert(jobs, "Resurrect")
	end
	return jobs
end

-- What building takes and what it reaches, and which of a builder's jobs it does; nothing for what does not build.
local function build_rows(def: EntityDef): { Row }
	local builder = def.builder
	if builder == nil then
		return {}
	end
	local rows: { Row } = {
		{ label = "Buildpower", value = `{builder.buildpower}/s`, tag = "buildpower" },
	}
	if builder.range ~= nil then
		table.insert(rows, { label = "Build range", value = studs(builder.range) })
	end
	local jobs = build_jobs(def)
	if #jobs > 0 then
		table.insert(rows, { label = "Can", value = table.concat(jobs, ", ") })
	end
	return rows
end

-- Everything about `def` itself that does not belong to one of its weapons: what it costs, how tough and how quick
-- it is, what it makes, holds and carries. Only what the def has: a building has no speed, and most things make
-- nothing.
local function def_rows(def: EntityDef): { Row }
	local rows: { Row } = {
		{ label = "Metal cost", value = figure(def.metal_cost), tag = "metal" },
		{ label = "Energy cost", value = figure(def.energy_cost), tag = "energy" },
		{ label = "Buildpower cost", value = figure(def.buildpower_cost), tag = "buildpower" },
	}
	if def.health ~= nil then
		table.insert(rows, 1, { label = "Health", value = figure(def.health) })
	end
	local function add(label: string, value: string, tag: string?)
		table.insert(rows, { label = label, value = value, tag = tag })
	end
	if def.max_speed ~= nil and def.max_speed > 0 then
		add("Speed", `{studs(def.max_speed)}/s`)
	end
	if def.acceleration ~= nil and def.acceleration > 0 then
		add("Acceleration", `{studs(def.acceleration)}/s²`)
	end
	local air = def.air
	if air ~= nil then
		add("Flies at", studs(air.altitude))
		if air.wings ~= nil then
			add("Turn rate", `{figure(math.deg(air.wings.turn_rate))}°/s`)
		end
	end
	for _, row in build_rows(def) do
		table.insert(rows, row)
	end
	if def.metal_income ~= nil then
		add("Makes metal", `+{figure(def.metal_income)}/s`, "metal")
	end
	if def.energy_income ~= nil then
		add("Makes energy", `+{figure(def.energy_income)}/s`, "energy")
	end
	if def.wind_multiplier ~= nil then
		add("Energy from wind", `{figure(def.wind_multiplier)}× wind speed`, "energy")
	end
	if def.tidal_multiplier ~= nil then
		add("Energy from tide", `{figure(def.tidal_multiplier)}× tidal strength`, "energy")
	end
	local conversion = def.energy_conversion
	if conversion ~= nil then
		add(
			"Converts",
			`{figure(conversion.energy_per_second)} E into {figure(conversion.metal_per_second)} M /s`,
			"metal"
		)
	end
	if def.metal_storage ~= nil then
		add("Metal storage", figure(def.metal_storage), "metal")
	end
	if def.energy_storage ~= nil then
		add("Energy storage", figure(def.energy_storage), "energy")
	end
	local transport = def.transport
	if transport ~= nil then
		add("Carries", `{transport.capacity} {transport.carries}`)
	end
	if def.weight_class ~= nil then
		add("Carried as", def.weight_class)
	end
	local carrier = def.carrier
	if carrier ~= nil then
		add("Drones", `{carrier.count} out, {carrier.starting} free`)
		add("Drone range", studs(carrier.engage_range))
		add("Drone stock", `{carrier.stockpile.limit}, one every {seconds(carrier.stockpile.build_time)}`)
		add("Each drone costs", `{carrier.stockpile.metal} M · {carrier.stockpile.energy} E`)
	end
	local shield = def.shield
	if shield ~= nil then
		add("Shield radius", studs(shield.radius))
		add("Shield power", figure(shield.power))
		add("Shield regen", `{figure(shield.regen)}/s for {figure(shield.regen_energy)} E/s`)
		local upkeep = shield.upkeep
		if upkeep ~= nil then
			add("Shield upkeep", `{figure(upkeep.moving)} E/s moving, {figure(upkeep.standing)} E/s still`)
		end
	end
	if def.autoheal ~= nil then
		add("Self-repair", `{figure(def.autoheal)}/s`)
	end
	if def.emp_resistance ~= nil then
		add("EMP resistance", `{math.round(def.emp_resistance * 100)}%`)
	end
	local explosion = def.death_explosion
	if explosion ~= nil then
		add("Death blast", `{figure(explosion.damage)} within {studs(explosion.radius)}`)
	end
	return rows
end

-- The few facts about `def` that a glance wants, for a card over something in the HUD: what it costs, how tough it is,
-- and whichever of these it has: how fast it goes, how hard it builds, what it makes, how far it shoots, what it carries.
local function summary_rows(def: EntityDef): { Row }
	local rows: { Row } = {
		{ label = "Metal cost", value = figure(def.metal_cost), tag = "metal" },
		{ label = "Energy cost", value = figure(def.energy_cost), tag = "energy" },
	}
	if def.health ~= nil then
		table.insert(rows, 1, { label = "Health", value = figure(def.health) })
	end
	local function add(label: string, value: string, tag: string?)
		table.insert(rows, { label = label, value = value, tag = tag })
	end
	if def.max_speed ~= nil and def.max_speed > 0 then
		add("Speed", `{studs(def.max_speed)}/s`)
	end
	if def.builder ~= nil then
		add("Buildpower", `{def.builder.buildpower}/s`, "buildpower")
	end
	if def.metal_income ~= nil then
		add("Makes metal", `+{figure(def.metal_income)}/s`, "metal")
	end
	if def.energy_income ~= nil then
		add("Makes energy", `+{figure(def.energy_income)}/s`, "energy")
	end
	local range = unit_defs.attack_range(def)
	if range ~= nil then
		add("Range", studs(range), "weapon")
	end
	local transport = def.transport
	if transport ~= nil then
		add("Carries", `{transport.capacity} {transport.carries}`)
	end
	return rows
end

-- What `def` is mostly for, as a tone class for a card over it: fighting, building, or making energy or metal.
local function tone(def: EntityDef): string
	if unit_defs.attack_range(def) ~= nil then
		return "weapon"
	elseif def.builder ~= nil then
		return "build"
	elseif def.energy_income ~= nil then
		return "energy"
	elseif def.metal_income ~= nil then
		return "metal"
	end
	return "plain"
end

-- What sort of thing `def` is, in a word or two each, as the encyclopedia's chips under a name show it. Only what the
-- def says outright.
local function kinds(def: EntityDef): { string }
	local found: { string } = {}
	local function add(kind: string)
		table.insert(found, kind)
	end
	if unit_defs.is_commander(def) then
		add "COMMANDER"
	end
	if unit_defs.is_drone(def) then
		add "DRONE"
	end
	if def.air ~= nil then
		add "AIRCRAFT"
	elseif unit_defs.is_submarine(def) then
		add "SUBMARINE"
	elseif unit_defs.floats(def) then
		add(if def.kind == "building" then "ON WATER" else "SHIP")
	elseif def.footing.water == "hover" then
		add "HOVER"
	elseif def.kind == "building" then
		add "BUILDING"
	end
	if unit_defs.is_factory(def) then
		add "FACTORY"
	elseif def.builder ~= nil then
		add "BUILDER"
	end
	local anti_air, anti_nuke, emp = false, false, false
	for _, weapon in def.weapons or {} :: { Weapon } do
		anti_air = anti_air or unit_defs.is_anti_air(weapon)
		anti_nuke = anti_nuke or unit_defs.is_anti_nuke(weapon)
		emp = emp or weapon.paralyze_time ~= nil
	end
	if anti_nuke then
		add "ANTI-NUKE"
	elseif anti_air then
		add "ANTI-AIR"
	end
	if emp then
		add "EMP"
	end
	if def.transport ~= nil then
		add "TRANSPORT"
	end
	if def.carrier ~= nil then
		add "CARRIER"
	end
	if def.shield ~= nil then
		add "SHIELD"
	end
	if def.stealth == true then
		add "STEALTH"
	end
	return found
end

-- The layer every one of `def`'s weapons is held to, if they all are to the same one.
local function only_layer(def: EntityDef): types.TargetLayer?
	local weapons = def.weapons
	if weapons == nil or #weapons == 0 then
		return nil
	end
	local layer: types.TargetLayer? = weapons[1].target_layer
	for _, weapon in weapons do
		if weapon.target_layer ~= layer then
			return nil
		end
	end
	return layer
end

-- What is worth knowing about `def` at a glance that its figures alone do not make plain, each a short sentence: where
-- it can be built, what its weapons can be turned on and how they are fired, what it makes, carries and resists, and
-- that it goes off when destroyed. The build menu, an unlock's card and the encyclopedia show these before anything
-- written for it (shared/unit_descriptions).
local function notes(def: EntityDef): { string }
	local found: { string } = {}
	local function add(note: string)
		table.insert(found, note)
	end
	if def.spot == "metal" then
		add "Metal spots only."
	elseif def.spot == "geo" then
		add "Vents only."
	elseif def.kind == "building" and unit_defs.floats(def) then
		add "Water only."
	end
	local layer = only_layer(def)
	if layer == "air" then
		add "Air only."
	elseif layer == "ground" then
		add "Ground only."
	end
	-- what the weapons that cost energy to fire cost, each
	local manual, stockpile, energy = false, nil :: number?, {} :: { number }
	for _, weapon in def.weapons or {} :: { Weapon } do
		manual = manual or weapon.manual_fire == true
		if weapon.stockpile ~= nil then
			stockpile = math.max(stockpile or 0, weapon.stockpile.limit)
		end
		if weapon.energy_per_shot > 0 then
			table.insert(energy, weapon.energy_per_shot)
		end
	end
	if manual then
		add "Manual fire."
	end
	if stockpile ~= nil then
		add(`Stockpiles {stockpile}.`)
	end
	if #energy == 1 then
		add(`{figure(energy[1])} energy per shot.`)
	elseif #energy > 1 then
		add "Costs energy per shot."
	end
	local conversion = def.energy_conversion
	if conversion ~= nil then
		add(`{figure(conversion.energy_per_second)} energy/s into {figure(conversion.metal_per_second)} metal/s.`)
	end
	local transport = def.transport
	if transport ~= nil then
		add(`Carries {transport.capacity} {transport.carries} {if transport.capacity == 1 then "unit" else "units"}.`)
	end
	if def.carrier ~= nil then
		add "Launches drones."
	end
	if def.stealth == true then
		add "Stealth."
	end
	if def.autoheal ~= nil then
		add "Self-repairs."
	end
	if def.emp_resistance == 1 then
		add "Immune to EMP."
	end
	if def.death_explosion ~= nil then
		add "Explodes when destroyed."
	end
	return found
end

return table.freeze({
	MANUAL_WEAPON = MANUAL_WEAPON,
	figure = figure,
	seconds = seconds,
	studs = studs,
	weapon_kind = weapon_kind,
	weapon_dps = weapon_dps,
	damage_dps = damage_dps,
	kinds = kinds,
	notes = notes,
	targets_text = targets_text,
	weapon_rows = weapon_rows,
	manual_weapon_rows = manual_weapon_rows,
	build_jobs = build_jobs,
	build_rows = build_rows,
	def_rows = def_rows,
	summary_rows = summary_rows,
	tone = tone,
})
