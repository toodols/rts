-- The build menu's tooltip text for what a builder or factory can make. `text` is only what its stats and subtitle
-- do not already say; `tips` are the only place for how to use it. Anything missing here still gets a tooltip.

export type Description = {
	text: string?,
	tips: { string }?,
}

local descriptions: { [string]: Description } = {
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

	metal_extractor = {
		text = "Metal spots only.",
	},
	advanced_metal_extractor = {
		text = "Metal spots only.",
		tips = { "Build over a Metal Extractor to upgrade it." },
	},
	wind_turbine = {
		text = "Output varies with the wind.",
	},
	tidal_generator = {
		text = "Water only.",
	},
	geothermal_powerplant = {
		text = "Vents only. Explodes when destroyed.",
	},
	advanced_geothermal_powerplant = {
		text = "Vents only. Explodes when destroyed.",
		tips = { "Build over a Geothermal Powerplant to upgrade it." },
	},
	rampart = {
		text = "Vents only. Anti-nuke and drones.",
		tips = { "Build over a Geothermal Powerplant to upgrade it." },
	},
	fusion_reactor = {
		text = "Explodes when destroyed.",
	},
	advanced_fusion_reactor = {
		text = "Huge explosion when destroyed.",
	},
	epic_fusion_reactor = {
		text = "Huge explosion when destroyed.",
	},
	energy_converter = {
		text = "70 energy/s into 1 metal/s.",
	},
	advanced_energy_converter = {
		text = "600 energy/s into 10 metal/s. Explodes when destroyed.",
	},
	epic_energy_converter = {
		text = "6000 energy/s into 120 metal/s. Explodes when destroyed.",
	},
	hardened_energy_storage = {
		text = "Explodes when destroyed.",
	},

	-- Defenses

	warden = {
		text = "Costs energy per shot.",
	},
	pulsar = {
		text = "Costs energy per shot.",
	},
	thistle = {
		text = "Air only.",
	},
	eradicator = {
		text = "Air only.",
	},
	screamer = {
		text = "Air only. Stockpiles 5 missiles.",
	},
	catalyst = {
		text = "Manual fire. Cannot be blocked.",
	},
	apocalypse = {
		text = "Manual fire. Stockpiled.",
	},
	prevailer = {
		text = "Nuclear missiles only.",
	},
	calamity = {
		text = "18000 energy per shot.",
	},
	overseer = {
		text = "Blocks shells only.",
	},
	wall = {
		tips = { "Shift-drag lays a line." },
	},

	-- Factories

	shipyard = {
		text = "Water only.",
	},

	-- Bots

	trasher = {
		text = "Air only.",
	},
	arbiter = {
		text = "Rockets arc over obstacles.",
	},
	sharpshooter = {
		text = "Costs energy per shot.",
	},
	gunslinger = {
		text = "Self-repairs.",
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
	negotiator = {
		text = "Rockets arc over obstacles.",
	},
	mantis = {
		text = "Unarmed. Launches drones.",
	},

	-- Hovercraft

	birdeater = {
		text = "Air only.",
	},
	halberd = {
		text = "Costs energy per shot.",
	},

	-- Ships

	riptide = {
		text = "Blocked by friendly units.",
	},
	syracusia = {
		text = "Costs energy per shot.",
	},
	orca = {
		text = "Only torpedoes can hit it.",
	},

	-- Aircraft

	valiant = {
		text = "Air only.",
	},
	whirlwind = {
		text = "Ground only.",
	},
	hercules = {
		text = "Carries 2 light units.",
		tips = { "J to load, U to unload." },
	},
	hephaestus = {
		text = "Carries heavy units. Unarmed.",
		tips = { "J to load, U to unload." },
	},
	advanced_construction_aircraft = {
		text = "Builds tier 2.",
	},
	nighthawk = {
		text = "Air only. Stealth.",
	},
	hailstorm = {
		text = "Ground only.",
	},
	liche = {
		text = "Ground only. Nuclear blast.",
	},
	stronghold = {
		text = "Carries heavy units.",
		tips = { "J to load, U to unload." },
	},

	-- Experimental

	juggernaut = {
		text = "Walks on the sea floor.",
	},
	vanguard = {
		text = "Climbs any slope.",
	},
}

return table.freeze(descriptions)
