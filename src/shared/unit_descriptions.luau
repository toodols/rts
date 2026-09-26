--!strict
-- What there is to say about a def beyond its numbers: the build menu's tooltip text for what a builder or factory can
-- make, an unlock's card, and its entry in the lobby's encyclopedia. A def's text is first what its def says outright
-- that its figures do not make plain (`unit_facts.notes`: "Metal spots only.", "Air only.", "Manual fire."), then what
-- is written for it here, which is only what no field of its def says; `tips` are the only place for how to use it.
-- Anything missing here still gets a tooltip and an entry.

local ReplicatedStorage = game:GetService "ReplicatedStorage"

local types = require(ReplicatedStorage.Shared.types)
local unit_defs = require(ReplicatedStorage.Shared.unit_defs)
local unit_facts = require(ReplicatedStorage.Shared.unit_facts)

type EntityDef = types.EntityDef

export type Description = {
	text: string?,
	tips: { string }?,
}

local DESCRIPTIONS: { [string]: Description } = {
	-- Builders

	construction_bot = {
		tips = { "Shift-click queues several buildings." },
	},
	construction_hovercraft = {
		text = "Builds on water.",
	},
	construction_ship = {
		text = "Builds on water.",
	},
	advanced_construction_bot = {
		text = "Builds tier 2.",
	},
	advanced_construction_vehicle = {
		text = "Builds tier 2.",
	},
	graverobber = {
		text = "Repairs and reclaims. Cannot build.",
	},
	construction_turret = {
		text = "Immobile. Assists nearby blueprints on its own.",
	},

	-- Economy

	advanced_metal_extractor = {
		tips = { "Build over a Metal Extractor to upgrade it." },
	},
	wind_turbine = {
		text = "Output varies with the wind.",
	},
	advanced_geothermal_powerplant = {
		tips = { "Build over a Geothermal Powerplant to upgrade it." },
	},
	rampart = {
		text = "Anti-nuke.",
		tips = { "Build over a Geothermal Powerplant to upgrade it." },
	},

	-- Defenses

	catalyst = {
		text = "Cannot be blocked.",
	},
	prevailer = {
		text = "Stops nukes aimed within range.",
	},
	overseer = {
		text = "Blocks shells only.",
	},
	wall = {
		tips = { "Shift-drag lays a line." },
	},

	-- Bots

	arbiter = {
		text = "Rockets arc over obstacles.",
	},
	gunslinger = {
		tips = {
			"repairs itself in the heat of battle",
			"doesn't need energy to fight",
			"requires actual micro and attention to utilize it's [sic] fullest potential",
			"has an appropriate power spike for 5-10 minutes into the game. fair and balanced",
			'fun to fight against, promotes "brawl" gameplay',
			"hero of the frontline",
			'basically if "solo leveling" was a unit',
		},
	},
	recluse = {
		text = "Climbs any slope.",
	},

	-- Vehicles

	lasher = {
		text = "Ground and air missiles; one fires at a time.",
	},
	janus = {
		text = "Two guided rockets a volley.",
	},
	negotiator = {
		text = "Rockets arc over obstacles.",
	},
	mantis = {
		text = "Unarmed.",
	},
	starlight = {
		text = "Fires only ahead.",
	},

	-- Ships

	riptide = {
		text = "Blocked by friendly units.",
	},
	orca = {
		text = "Only torpedoes can hit it.",
	},
	sea_dragon = {
		text = "Only torpedoes can hit it.",
	},

	-- Aircraft

	hercules = {
		tips = { "J to load, U to unload." },
	},
	hephaestus = {
		text = "Unarmed.",
		tips = { "J to load, U to unload." },
	},
	advanced_construction_aircraft = {
		text = "Builds tier 2.",
	},
	stiletto = {
		text = "EMP.",
	},
	liche = {
		text = "Nuclear blast.",
	},
	stronghold = {
		tips = { "J to load, U to unload." },
	},

	-- Experimental

	juggernaut = {
		text = "Walks on the sea floor.",
	},
	vanguard = {
		text = "Climbs any slope.",
	},
	thor = {
		text = "Lightning arcs to nearby units. EMP lasers.",
		tips = { "Attack a target to fire its stockpiled EMP missile." },
	},
	behemoth = {
		text = "Gauss shots pass through everything.",
	},
}

for name in DESCRIPTIONS do
	assert(unit_defs.defs[name] ~= nil, `unit_descriptions has "{name}", which is not a def`)
end

-- What to say about `def` under its name: what its def says outright, then what is written for it; nil for nothing.
local function text_of(def: EntityDef): string?
	local parts = unit_facts.notes(def)
	local description = DESCRIPTIONS[def.name]
	if description ~= nil and description.text ~= nil then
		table.insert(parts, description.text)
	end
	return if #parts > 0 then table.concat(parts, " ") else nil
end

-- How to use something of `def_name`, if anything is written for it.
local function tips_of(def_name: string): { string }?
	local description = DESCRIPTIONS[def_name]
	return if description ~= nil then description.tips else nil
end

return table.freeze({
	text_of = text_of,
	tips_of = tips_of,
})
