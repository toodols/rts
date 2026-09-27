--!strict
-- The server's start, as one function: everything set up, in order, for the session `session_config` says is played.
-- The live server starts this way (init.server.luau), and so does every session a test runs in, in Studio and headless,
-- and every arena match (tools/lib/session.luau), so that what they play is the game as a live server plays
-- it. What only the live server does, stepping the simulation on the engine's clock, is init.server.luau's.
--
-- Nothing subscribes to anything as it is required: everything a module listens to, it listens to from here, and in
-- the order given here. The lists, each in the order it runs in:
--
-- - FORGETTERS: what everything that remembers entities forgets as one is gone (state.on_forget);
-- - the simulation's slots: what a game mode, a mission and a skin do every step (simulation.luau);
-- - MAP_STAGES: what starts over on every map loaded, the first included (maps.luau);
-- - PLAYER_STAGES: what is done as each player joins and leaves (server_shared/lifecycle.luau).

local Players = game:GetService "Players"
local ReplicatedStorage = game:GetService "ReplicatedStorage"
local ServerScriptService = game:GetService "ServerScriptService"

local switches = require(ReplicatedStorage.Shared.switches)
local seating = require(ReplicatedStorage.Shared.seating)
local types = require(ReplicatedStorage.Shared.types)

local lifecycle = require(ServerScriptService.ServerShared.lifecycle)
local campaign_session = require(ServerScriptService.ServerShared.campaign_session)
local skin_session = require(ServerScriptService.ServerShared.skin_session)
local developer_list = require(ServerScriptService.ServerShared.developer_list)
local remotes = require(ServerScriptService.ServerShared.remotes)
local teleports = require(ServerScriptService.ServerShared.teleports)

local session_config = require(script.Parent.session_config)
local state = require(script.Parent.state)
local simulation = require(script.Parent.simulation)
local lighting = require(script.Parent.lighting)
local wind = require(script.Parent.wind)
local deformation = require(script.Parent.deformation)
local obstacles = require(script.Parent.obstacles)
local instances = require(script.Parent.instances)
local deaths = require(script.Parent.deaths)
local damage = require(script.Parent.damage)
local movement = require(script.Parent.movement)
local attack_orders = require(script.Parent.attack_orders)
local shields = require(script.Parent.shields)
local orbits = require(script.Parent.orbits)
local orders = require(script.Parent.orders)
local work = require(script.Parent.work)
local production = require(script.Parent.production)
local control = require(script.Parent.control)
local emp = require(script.Parent.emp)
local drones = require(script.Parent.drones)
local turrets = require(script.Parent.turrets)
local weapons = require(script.Parent.weapons)
local self_destruct = require(script.Parent.self_destruct)
local projectiles = require(script.Parent.projectiles)
local interceptors = require(script.Parent.interceptors)
local donuts = require(script.Parent.donuts)
local commands = require(script.Parent.commands)
local possession = require(script.Parent.possession)
local pings = require(script.Parent.pings)
local players = require(script.Parent.players)
local scavengers = require(script.Parent.scavengers)
local scenery = require(script.Parent.scenery)
local ai = require(script.Parent.ai)
local maps = require(script.Parent.maps)
local match = require(script.Parent.match)
local pregame = require(script.Parent.pregame)
local sharing = require(script.Parent.sharing)
local notifications = require(script.Parent.notifications)
local skins = require(script.Parent.skins)
local missions = require(script.Parent.missions)
local campaign_exit = require(script.Parent.campaign_exit)
local match_stats = require(script.Parent.match_stats)
local conquest = require(script.Parent.conquest)
local ratings = require(script.Parent.ratings)
local rng = require(script.Parent.rng)
local team_updates = require(script.Parent.team_updates)
local build_rules = require(script.Parent.build_rules)
local unlocks = require(script.Parent.unlocks)
local snapshot = require(script.Parent.snapshot)

-- The switches are kept with the game (server/snapshot): godmode, nocost, a pause and the scavengers change how it plays.
-- Each is turned as it was kept, if it is not already.
snapshot.keep("switches", function()
	local on: { [string]: boolean } = {}
	for _, name: switches.Name in switches.NAMES do
		on[name] = switches.is_on(name)
	end
	return on
end, function(saved)
	for _, name: switches.Name in switches.NAMES do
		if switches.is_on(name) ~= (saved[name] == true) then
			switches.set(name, saved[name] == true)
		end
	end
end)

type Session = session_config.Session
type EntityId = number
type Entity = types.Entity

-- Whether everyone who joins only watches (the session's `spectate`).
local spectating = false

-- A player's team: the one the match seated them on, or the next one free; none for someone who came only to watch,
-- who has nothing to command and nowhere to start.
local function seat(player: Player)
	local spectator = spectating or match.is_spectator(player.UserId)
	if spectator == false then
		players.assign(player, match.team_of(player.UserId))
	end
	seating.set_spectator(player, spectator)
end

local FORGETTERS: { (EntityId) -> () } = {
	deaths.forget,
	movement.forget,
	attack_orders.forget,
	shields.forget,
	orbits.forget,
	orders.forget,
	work.forget,
	production.forget,
	control.forget,
	emp.forget,
	drones.forget,
	turrets.forget,
	weapons.forget,
	self_destruct.forget,
	scavengers.forget,
	missions.forget,
	ai.forget,
	donuts.forget,
	-- its model goes
	instances.destroy,
	-- and the ground under a building is open again
	obstacles.forget,
}

local MAP_STAGES: { maps.Stage } = {
	-- nothing in flight over the old map comes down on the new one
	{ cleared = projectiles.clear },
	{ cleared = interceptors.clear },
	-- the new map is a new game: nothing of the last is kept
	{ built = notifications.reset },
	{ built = match_stats.reset },
	{ built = ratings.reset },
	{ built = scavengers.reset },
	{ built = conquest.start_over },
	-- every player starts over on it, and then the AI's teams, at the starts left
	{ built = pregame.start_over },
	{ built = ai.restart_on_new_map },
	-- the mission it is played with begins as the old map is cleared away, and is set up once the players' commanders
	-- are down on the new one
	{
		cleared = function(request: maps.Request)
			missions.begin(request.mission, request.hard == true)
		end,
		built = missions.setup,
	},
}

local PLAYER_STAGES: { lifecycle.Stage } = {
	-- whatever they pilot is let go of first as they leave
	{ left = possession.player_removing },
	-- whether they are a developer, which what they may wear and do waits on
	{ joined = developer_list.joined, left = developer_list.left },
	-- what they have unlocked in the campaign, the starting unlocks at once and then what is stored
	{ joined = campaign_session.joined, left = campaign_session.left },
	{ joined = seat },
	-- their team wears the skin they have equipped, before their commander is put down
	{ joined = skin_session.joined, left = skin_session.left },
	{
		joined = function(player: Player)
			match.arrived(player.UserId)
		end,
		left = function(player: Player)
			match.left(player.UserId)
		end,
	},
	{ left = campaign_exit.player_removing },
	-- their commander goes down once they have chosen a start and the game has begun, or now if it already has
	{ joined = pregame.player_added, left = pregame.player_removing },
	{ left = conquest.player_removing },
	{ left = players.forget },
	{ joined = team_updates.send },
	{ left = teleports.forget },
	{ left = remotes.forget },
	{ left = deformation.forget_player },
}

local function start(session: Session)
	spectating = session.spectate
	-- This is an RTS: players command units from a camera and never have an avatar.
	Players.CharacterAutoLoads = false

	if session.match ~= nil then
		match.load(session.match)
	end
	players.reserve(match.seated_count())
	switches.set("scavengers", session.scavengers)
	-- nothing a team has not unlocked in the campaign is built or made by it
	unlocks.init()
	build_rules.add(unlocks.can_build)
	-- everything the game leaves to chance is rolled from the seed a session is given, if it is given one
	if session.random_seed ~= nil then
		rng.seed(session.random_seed)
	end
	for _, forget in FORGETTERS do
		state.on_forget(forget)
	end
	simulation.init({
		scavengers = scavengers.tick,
		missions = missions.tick,
		conquest = conquest.tick,
		skins = donuts.tick,
	})
	damage.init()
	-- a unit or building hurt by an enemy may be news to its side
	damage.on_hurt(function(target: Entity, _amount: number, attacker_team: number?)
		notifications.damaged(target, attacker_team)
	end)
	projectiles.on_nuke_launched(notifications.nuke_launched)
	donuts.init()
	lighting.init()
	deformation.init()
	-- every building is a wall from the moment it goes down, the map's own included
	obstacles.init()
	-- the meshes every rock and tree on the map is cloned from, before the map lays any out
	instances.preload()
	maps.init(MAP_STAGES)
	assert(maps.load(session.map))
	-- the wind starts somewhere in the range the map gives it
	wind.init()

	teleports.init()
	commands.init()
	possession.init()
	pings.init()
	sharing.init()
	notifications.init()
	skins.init()
	campaign_exit.init()
	match_stats.init()
	ratings.init()
	scavengers.init()

	if session.scenery == false then
		scenery.clear()
	end
	ai.init(session.ai_opponents, session.ai_opponent_orders)
	pregame.init(session.played == false)

	lifecycle.run(PLAYER_STAGES)
end

return table.freeze({
	start = start,
})
