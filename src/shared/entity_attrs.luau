--!strict
-- The attributes an entity's model carries: every name the server writes (server/instances.luau) and the client reads,
-- by what kind of value it holds, and a typed reader for each kind. A name is a type here, so a misspelt one does not
-- check, and a reader never hands back a value of the wrong type: whatever is missing, or not what the name holds,
-- reads as nil. What piloting publishes has its own names, next to the rest of piloting (shared/piloting.luau).

local ReplicatedStorage = game:GetService "ReplicatedStorage"

local types = require(ReplicatedStorage.Shared.types)

type EntityId = types.EntityId
type TeamId = types.TeamId
type EntityKind = types.EntityKind
type EntityState = types.EntityState

-- The attributes that hold a number.
export type NumberName =
	"entity_id"
	-- the user id of whoever pilots it, and how long its manual weapon has left to reload while it is piloted
	-- (shared/piloting.luau)
	| "pilot"
	| "manual_cooldown"
	| "team"
	-- the same for every team in an alliance, so two things are allied exactly when it matches
	| "ally_group"
	| "health"
	| "max_health"
	-- EMP in whole percent of its max health, and while it stuns, whole seconds left
	| "emp"
	| "stun"
	| "build_progress"
	| "buildpower_cost"
	| "order_count"
	-- whole seconds until it destroys itself, while it is counting down
	| "self_destruct"
	| "kills"
	| "experience"
	-- what it makes or spends this second
	| "metal_rate"
	| "energy_rate"
	| "shield_power"
	| "shield_max"
	| "stockpile"
	| "stockpile_limit"
	| "stockpile_progress"
	| "reload_progress"
	| "cargo_used"
	| "cargo_capacity"
	-- the entity it is putting its buildpower into
	| "work_target"
	-- what is left in a wreck or a reclaimable, and how far along raising a wreck is
	| "metal_left"
	| "energy_left"
	| "reclaim_left"
	| "reclaim_total"
	| "resurrect_progress"
	| "donut_shake"

-- The attributes that hold a string.
export type TextName =
	"def_name"
	| "skin"
	-- an EntityKind and an EntityState: read them with `kind` and `state`
	| "kind"
	| "state"
	| "team_name"
	-- what is holding its flow back, and what its flow is made of (`encode_flow_sources`, read with `flow_sources`)
	| "stalled"
	| "flow_sources"
	-- its orders, as server/instances.luau's encode_path writes them
	| "path"
	-- "build", "reclaim", "resurrect" or "repair": what it does to `work_target`
	| "work_kind"
	-- a lab's queue (`encode_queue`, read with `queue`)
	| "queue"
	| "donut_event"
	-- for a piloted unit that has called a transport, "coming" or "lost" (shared/piloting.luau)
	| "pilot_call"

-- The attributes that hold a boolean.
export type FlagName =
	-- a blueprint losing progress for nobody building it
	"decaying"
	| "need_energy"
	| "exit_blocked"
	| "manual_ready"
	| "carried"
	-- the pool skin's donut, on unless it is false
	| "donut"
	-- what a piloted unit's pilot may do now (shared/piloting.luau)
	| "pilot_can_load"
	| "pilot_can_unload"
	| "pilot_can_call"

-- The attributes that hold a colour.
export type ColorName = "team_color"

-- The number attributes each weapon has of its own, by the weapon's index (`aim_name`, `fired_name`, `charge_name`):
-- where its turret points, in radians from the way the entity faces; how many shots it has fired, to the nearest
-- thousand, for art that plays something as it fires; and while its unit is piloted, how far through its reload it is,
-- from 0 to 1. No def has more than MAX_WEAPONS weapons.
export type WeaponName =
	"aim_1"
	| "aim_2"
	| "aim_3"
	| "aim_4"
	| "aim_5"
	| "aim_6"
	| "aim_7"
	| "aim_8"
	| "fired_1"
	| "fired_2"
	| "fired_3"
	| "fired_4"
	| "fired_5"
	| "fired_6"
	| "fired_7"
	| "fired_8"
	| "charge_1"
	| "charge_2"
	| "charge_3"
	| "charge_4"
	| "charge_5"
	| "charge_6"
	| "charge_7"
	| "charge_8"

export type Name = NumberName | TextName | FlagName | ColorName | WeaponName

-- One source of what an entity makes (positive) or spends (negative) each second, as the server names it:
-- "Generating", "Building Grunt".
export type FlowSource = { label: string, metal: number, energy: number }

-- Writes one of the attributes the server publishes on an entity's model for the clients to read
-- (server/instances.luau): what each part of the simulation knows about it, under the attribute's name. Nil clears it.
export type Publish = (name: Name, value: any) -> ()

local KINDS: { [string]: EntityKind } = {
	unit = "unit",
	building = "building",
	wreck = "wreck",
	reclaimable = "reclaimable",
}
table.freeze(KINDS)

local STATES: { [string]: EntityState } = {
	blueprint = "blueprint",
	active = "active",
}
table.freeze(STATES)

local function number(model: Instance, name: NumberName): number?
	local value = model:GetAttribute(name)
	return if typeof(value) == "number" then value else nil
end

local function text(model: Instance, name: TextName): string?
	local value = model:GetAttribute(name)
	return if typeof(value) == "string" then value else nil
end

local function flag(model: Instance, name: FlagName): boolean?
	local value = model:GetAttribute(name)
	return if typeof(value) == "boolean" then value else nil
end

local function color(model: Instance, name: ColorName): Color3?
	local value = model:GetAttribute(name)
	return if typeof(value) == "Color3" then value else nil
end

local function id(model: Instance): EntityId?
	return number(model, "entity_id")
end

local function team(model: Instance): TeamId?
	return number(model, "team")
end

local function def_name(model: Instance): string?
	return text(model, "def_name")
end

local function kind(model: Instance): EntityKind?
	local value = text(model, "kind")
	return if value ~= nil then KINDS[value] else nil
end

local function state(model: Instance): EntityState?
	local value = text(model, "state")
	return if value ~= nil then STATES[value] else nil
end

-- A lab's queue, the def names of what it is to make in turn, as the `queue` attribute holds it: joined by commas.
local function encode_queue(def_names: { string }): string
	return table.concat(def_names, ",")
end

-- The queue of the lab `model` (`encode_queue`), empty for one that has none.
local function queue(model: Instance): { string }
	local raw = text(model, "queue")
	local found: { string } = {}
	if raw ~= nil then
		for name in string.gmatch(raw, "[^,]+") do
			table.insert(found, name)
		end
	end
	return found
end

-- What an entity's flow is made of, as the `flow_sources` attribute holds it: "label|metal|energy" for each source,
-- joined by ";". Nil for none.
local function encode_flow_sources(sources: { FlowSource }): string?
	if #sources == 0 then
		return nil
	end
	local parts = table.create(#sources)
	for index, source in sources do
		parts[index] = `{source.label}|{source.metal}|{source.energy}`
	end
	return table.concat(parts, ";")
end

-- What the flow of `model` is made of (`encode_flow_sources`), empty when it neither makes nor spends.
local function flow_sources(model: Instance): { FlowSource }
	local raw = text(model, "flow_sources")
	local found: { FlowSource } = {}
	if raw ~= nil then
		for part in string.gmatch(raw, "[^;]+") do
			local label, metal, energy = string.match(part, "^(.*)|([^|]*)|([^|]*)$")
			if label ~= nil then
				table.insert(found, { label = label, metal = tonumber(metal) or 0, energy = tonumber(energy) or 0 })
			end
		end
	end
	return found
end

-- Fires as attribute `name` of `model` changes.
local function changed(model: Instance, name: Name): RBXScriptSignal
	return model:GetAttributeChangedSignal(name)
end

-- The most weapons any def has, which is as many as there are names for.
local MAX_WEAPONS = 8
local AIM_NAMES: { WeaponName } = { "aim_1", "aim_2", "aim_3", "aim_4", "aim_5", "aim_6", "aim_7", "aim_8" }
local FIRED_NAMES: { WeaponName } =
	{ "fired_1", "fired_2", "fired_3", "fired_4", "fired_5", "fired_6", "fired_7", "fired_8" }
local CHARGE_NAMES: { WeaponName } =
	{ "charge_1", "charge_2", "charge_3", "charge_4", "charge_5", "charge_6", "charge_7", "charge_8" }
table.freeze(AIM_NAMES)
table.freeze(FIRED_NAMES)
table.freeze(CHARGE_NAMES)

local function weapon_name(names: { WeaponName }, index: number): WeaponName
	local name: WeaponName? = names[index]
	if name == nil then
		error(`no attribute names for weapon {index}: no def has more than {MAX_WEAPONS} weapons`)
	end
	return name
end

-- Where weapon `index`'s turret points ("aim_1"...).
local function aim_name(index: number): WeaponName
	return weapon_name(AIM_NAMES, index)
end

-- How many shots weapon `index` has fired ("fired_1"...).
local function fired_name(index: number): WeaponName
	return weapon_name(FIRED_NAMES, index)
end

-- How far through its reload weapon `index` of a piloted unit is ("charge_1"...).
local function charge_name(index: number): WeaponName
	return weapon_name(CHARGE_NAMES, index)
end

-- A weapon's own number attribute (`WeaponName`).
local function weapon_number(model: Instance, name: WeaponName): number?
	local value = model:GetAttribute(name)
	return if typeof(value) == "number" then value else nil
end

return table.freeze({
	number = number,
	text = text,
	flag = flag,
	color = color,
	id = id,
	team = team,
	def_name = def_name,
	kind = kind,
	state = state,
	encode_queue = encode_queue,
	queue = queue,
	encode_flow_sources = encode_flow_sources,
	flow_sources = flow_sources,
	changed = changed,
	MAX_WEAPONS = MAX_WEAPONS,
	aim_name = aim_name,
	fired_name = fired_name,
	charge_name = charge_name,
	weapon_number = weapon_number,
})
