-- What a def's numbers come to, in words and figures, for whatever shows them: the HUD's selection panel (its loadout
-- rows and their tooltips) and the lobby's encyclopedia, which lays the same facts out in full. Only the facts are
-- here, as rows of a label and a value; how each is drawn is its screen's business. Every figure is read off the def,
-- whose numbers are BAR's (see shared/unit_defs), and nothing here makes one up.

local ReplicatedStorage = game:GetService "ReplicatedStorage"

local config = require(ReplicatedStorage.Shared.config)
local types = require(ReplicatedStorage.Shared.types)

type EntityDef = types.EntityDef
type Weapon = types.Weapon
type ManualWeapon = types.ManualWeapon

-- One fact: what it is and how much. `tag` is a tone class for the value ("metal", "energy", "weapon", ...), and
-- `divider` sets a row off from those above it, as a total is from what it adds up. The same shape as tooltip.Row.
export type Row = { label: string, value: string, tag: string?, divider: boolean? }

-- The gap between the shots of a burst for a weapon that does not give its own, as combat has it.
local DEFAULT_BURST_INTERVAL = 0.1

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

-- What each WeaponKind is called, the short code on its slot, and its icon.
local KINDS: { [types.WeaponKind]: { name: string, slot: string, icon: string } } = {
	heat_ray = { name = "HEAT RAY", slot = "HRY", icon = "icon_heat_ray" },
	flamethrower = { name = "FLAMETHROWER", slot = "FLM", icon = "icon_flamethrower" },
	shotgun = { name = "SHOTGUN", slot = "SHG", icon = "icon_shotgun" },
	sniper = { name = "SNIPER RIFLE", slot = "SNP", icon = "icon_sniper" },
	machine_gun = { name = "MACHINE GUN", slot = "MG", icon = "icon_machine_gun" },
	depth_charge = { name = "DEPTH CHARGES", slot = "DPC", icon = "icon_depth_charge" },
	flak = { name = "FLAK", slot = "FLK", icon = "icon_flak" },
}

-- A weapon's name, from what it is, since a def's weapons have none of their own, the short code on its slot, and
-- its icon (Shared.ui_art).
local function weapon_kind(weapon: Weapon): (string, string, string)
	local projectile = weapon.projectile
	local name, slot, icon
	local kind = if weapon.kind ~= nil then KINDS[weapon.kind] else nil
	if kind ~= nil then
		name, slot, icon = kind.name, kind.slot, kind.icon
	elseif weapon.anti_nuke then
		name, slot, icon = "ANTI-NUKE", "ABM", "icon_anti_nuke"
	elseif weapon.lightning ~= nil then
		name, slot, icon = "LIGHTNING GUN", "LTN", "icon_lightning"
	elseif weapon.paralyze_time ~= nil and projectile ~= nil and projectile.dropped then
		name, slot, icon = "EMP BOMBS", "EMP", "icon_emp"
	elseif weapon.paralyze_time ~= nil and projectile ~= nil and projectile.missile ~= nil then
		name, slot, icon = "EMP MISSILE", "EMP", "icon_emp"
	elseif weapon.paralyze_time ~= nil and weapon.beam_time ~= nil then
		name, slot, icon = "EMP LASER", "EMP", "icon_emp"
	elseif projectile ~= nil and projectile.pierce then
		name, slot, icon = "GAUSS CANNON", "GSS", "icon_gauss"
	elseif projectile ~= nil and projectile.nuclear then
		name, slot, icon = "NUCLEAR MISSILE", "NUK", "icon_nuke"
	elseif projectile ~= nil and projectile.torpedo then
		name, slot, icon = "TORPEDO", "TRP", "icon_torpedo"
	elseif projectile ~= nil and projectile.dropped then
		name, slot, icon = "BOMBS", "BMB", "icon_bombs"
	elseif weapon.beam_time ~= nil then
		name, slot, icon = "LASER", "LSR", "icon_laser"
	elseif projectile ~= nil and projectile.plasma then
		name, slot, icon = "PLASMA CANNON", "PLS", "icon_plasma_cannon"
	elseif projectile ~= nil and (projectile.missile ~= nil or projectile.homing) then
		name, slot, icon = "MISSILES", "MSL", "icon_missile"
	elseif projectile ~= nil and projectile.thrust_time <= 0 and projectile.acceleration <= 0 then
		-- a shell: nothing drives it once it leaves the barrel
		name, slot, icon = "CANNON", "CNN", "icon_cannon"
	elseif projectile ~= nil then
		name, slot, icon = "ROCKETS", "RKT", "icon_rocket"
	else
		name, slot, icon = "GUN", "GUN", "icon_machine_gun"
	end
	if weapon.anti_air and not weapon.anti_nuke then
		return `AA {name}`, "AA", "icon_anti_air"
	end
	return name, slot, icon
end

-- A weapon's damage a second while it keeps firing: a whole burst, the gaps within it and the reload after it. One
-- that fires from a stockpile keeps firing only as fast as the stockpile refills, one missile every `build_time`,
-- however short its reload: the Thor's EMP missile reloads in 3 seconds but is built in 65.
local function weapon_dps(weapon: Weapon): number
	local shots = math.max(1, weapon.burst_count or 1)
	local cycle = weapon.reload + (shots - 1) * (weapon.burst_interval or DEFAULT_BURST_INTERVAL)
	if weapon.stockpile ~= nil then
		cycle = math.max(cycle, weapon.stockpile.build_time)
	end
	return weapon.damage * shots / math.max(cycle, 1e-3)
end

-- What a weapon can shoot at, in a word or two.
local function targets_text(weapon: Weapon): string
	if weapon.anti_nuke then
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
		{ label = `{dealt} a second`, value = figure(weapon_dps(weapon)), tag = "weapon" },
		{ label = `{dealt} a shot`, value = figure(weapon.damage) },
	}
	if weapon.paralyze_time ~= nil then
		table.insert(rows, { label = "Longest stun", value = seconds(weapon.paralyze_time) })
	end
	local burst = weapon.burst_count
	if burst ~= nil and burst > 1 then
		table.insert(rows, {
			label = "Burst",
			value = `{burst} shots, {seconds(weapon.burst_interval or DEFAULT_BURST_INTERVAL)} apart`,
		})
	end
	table.insert(rows, { label = "Reload", value = seconds(weapon.reload) })
	table.insert(rows, { label = "Range", value = studs(weapon.range) })
	local projectile = weapon.projectile
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
	local lightning = weapon.lightning
	if lightning ~= nil then
		table.insert(rows, {
			label = "Sparks",
			value = `{lightning.forks} within {studs(lightning.range)}, {math.round(lightning.fork_damage * 100)}%`,
		})
	end
	table.insert(rows, { label = "Targets", value = targets_text(weapon) })
	if not weapon.anti_air and not weapon.anti_nuke and weapon.target_layer ~= "ground" then
		table.insert(rows, { label = "Vs air", value = `{math.round(config.NON_AA_AIR_DAMAGE_FRACTION * 100)}%` })
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
	if projectile ~= nil and projectile.pierce then
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
		{ label = "Range", value = studs(manual.range) },
		{ label = "Strip width", value = studs(manual.radius * 2) },
		{ label = "Reload", value = seconds(manual.reload) },
		{ label = "Energy a shot", value = figure(manual.energy_per_shot), tag = "energy" },
	}
end

-- Which of a builder's jobs `def` does, in words.
local function build_jobs(def: EntityDef): { string }
	local jobs: { string } = {}
	if def.build_options ~= nil and #def.build_options > 0 then
		table.insert(jobs, "Build")
	end
	if def.assisting then
		table.insert(jobs, "Assist")
	end
	if def.repairing then
		table.insert(jobs, "Repair")
	end
	if def.reclaiming then
		table.insert(jobs, "Reclaim")
	end
	if def.resurrecting then
		table.insert(jobs, "Resurrect")
	end
	return jobs
end

-- What building takes and what it reaches, and which of a builder's jobs it does.
local function build_rows(def: EntityDef): { Row }
	local rows: { Row } = {
		{ label = "Buildpower", value = `{def.buildpower}/s`, tag = "buildpower" },
	}
	if def.build_range ~= nil then
		table.insert(rows, { label = "Build range", value = studs(def.build_range) })
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
		{ label = "Health", value = figure(def.health) },
		{ label = "Metal cost", value = figure(def.metal_cost), tag = "metal" },
		{ label = "Energy cost", value = figure(def.energy_cost), tag = "energy" },
		{ label = "Buildpower cost", value = figure(def.buildpower_cost), tag = "buildpower" },
	}
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
	if def.buildpower ~= nil then
		for _, row in build_rows(def) do
			table.insert(rows, row)
		end
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

return table.freeze({
	DEFAULT_BURST_INTERVAL = DEFAULT_BURST_INTERVAL,
	MANUAL_WEAPON = MANUAL_WEAPON,
	figure = figure,
	seconds = seconds,
	studs = studs,
	weapon_kind = weapon_kind,
	weapon_dps = weapon_dps,
	targets_text = targets_text,
	weapon_rows = weapon_rows,
	manual_weapon_rows = manual_weapon_rows,
	build_jobs = build_jobs,
	build_rows = build_rows,
	def_rows = def_rows,
})
