-- The steps a campaign mission guides its player through, and which of them the player is on (the cards that show them
-- are ui/tutorial.luau).
--
-- The tutorial is the first campaign mission (Shared.campaign), played on a map of its own. While this game is it,
-- the player is walked through TUTORIAL_STEPS one at a time, and the HUD is pared down to what they have been shown so
-- far (`shown`). Other missions guide more lightly: the overlook suggests a few things to do (OVERLOOK_STEPS), on the
-- full HUD. STEPS_BY_MISSION says which missions guide at all. Each step offers a few ways of doing one thing, a card each; doing
-- it any of those ways marks that card done, and `TUTORIAL.advance_seconds` later the next step begins. A card can be
-- the wrong way (`mark` "cross"): shown so the player knows not to, and never done. Past the last step the tutorial
-- is finished, and says so.
--
-- A step is data: its cards, and a `watch` that starts looking for them to be done. Adding a step is adding an entry
-- to a mission's steps (and, for a card that looks like none before it, how the card is drawn, in ui/tutorial.luau).

local ReplicatedStorage = game:GetService "ReplicatedStorage"
local RunService = game:GetService "RunService"
local Workspace = game:GetService "Workspace"

local campaign = require(ReplicatedStorage.Shared.campaign)
local metal_spots = require(ReplicatedStorage.Shared.metal_spots)
local types = require(ReplicatedStorage.Shared.types)
local unit_defs = require(ReplicatedStorage.Shared.unit_defs)

local camera = require(ReplicatedStorage.Client.camera)
local input = require(ReplicatedStorage.Client.input)
local mission = require(ReplicatedStorage.Client.mission)
local selection = require(ReplicatedStorage.Client.selection)
local tutorial_marker = require(ReplicatedStorage.Client.tutorial_marker)
local world = require(ReplicatedStorage.Client.world)

type EntityId = types.EntityId

export type Card = {
	-- what ui/tutorial.luau draws it as, and what `watch` calls it when it is done
	id: string,
	caption: string,
	-- a way to do it ("check"), or a way not to ("cross"), which is never done
	mark: "check" | "cross",
}

-- Something the tutorial keeps off the HUD until a step has taught what it is for.
export type Feature = "economy" | "weapons"

export type Step = {
	id: string,
	title: string,
	cards: { Card },
	-- For a step that builds something: what has to be selected to build it (a def name), and what to click in the
	-- build menu, which the menu then points out.
	builder: string?,
	build: string?,
	-- what the card says instead of pointing at the build menu, once what it asks for is being placed
	placing_hint: string?,
	-- For a step that uses a command: which of the commands list's modes (input.commands) to click, which the list
	-- then points out, and what the card says instead once that mode is on.
	command: string?,
	command_hint: string?,
	-- what the HUD shows from the moment the step is done: "economy" for the metal and energy bar, "weapons" for what
	-- a unit or building fights with in the selection panel
	reveals: Feature?,
	-- said in place of the usual word while the next step is on its way
	done_note: string?,
	-- whether every one of its ways ("check" cards) has to be done before the next step, rather than any one
	every_card: boolean?,
	-- Starts looking for the step's cards to be done, calling `complete` with a card's id when one is, and `report`
	-- with a card's id and how far along it is ("2/3") for a card that counts. Returns a function that stops.
	watch: (complete: (card: string) -> (), report: (card: string, text: string) -> ()) -> () -> (),
}

-- Starts looking for a step's cards to be done (see Step's `watch`).
type Watch = (complete: (card: string) -> (), report: (card: string, text: string) -> ()) -> () -> ()

export type State = {
	-- whether this game is a mission that guides its player at all
	active: boolean,
	-- the mission being guided through, while one is
	mission: string?,
	-- the step being shown, an index into the mission's steps; past the last one once every step is done
	step: number,
	-- the step's cards that are done
	completed: { [string]: boolean },
	-- whether a card of the step is done, so the next step is on its way
	advancing: boolean,
	-- how far along each counting card of the step is, by card id
	progress: { [string]: string },
}

local TUTORIAL = campaign.TUTORIAL
local OVERLOOK = campaign.OVERLOOK
-- How often the steps that wait on something on the field look again, in seconds.
local CHECK_SECONDS = 0.25
-- How near a metal spot's middle an extractor has to stand to be on it.
local SPOT_REACH = 4
-- How wide the ring round the boulder is.
local BOULDER_RING = 26
-- How wide the ring on the overlook's cliff edge is.
local EDGE_RING = 18
-- The Workspace attribute the server names the mission's enemy team in (server/missions.luau).
local ENEMY_TEAM_ATTRIBUTE = "campaign_enemy_team"

local team_updated: RemoteEvent = ReplicatedStorage.Shared.TeamUpdated

-- Your team's energy revenue, a second's worth, as the server last sent it (as the resource bar shows it). Listened for
-- from the moment this is required, as the resource bar does, so that no update goes unheard.
local energy_revenue = 0
team_updated.OnClientEvent:Connect(function(team: any)
	if typeof(team) == "table" and typeof(team.energy_revenue) == "number" then
		energy_revenue = team.energy_revenue
	end
end)

-- Your commander, if it is on the field.
local function my_commander(): Model?
	for _, model in world.all() do
		if world.is_mine(model) and model:GetAttribute "def_name" == "commander" then
			return model
		end
	end
	return nil
end

local function commander_id(): EntityId?
	local model = my_commander()
	return if model ~= nil then world.id_of(model) else nil
end

-- How many of `def_name` are yours: finished ones only, or with `blueprints` those still going up as well.
local function count_mine(def_name: string, blueprints: boolean): number
	local count = 0
	for _, model in world.all() do
		if
			world.is_mine(model)
			and model:GetAttribute "def_name" == def_name
			and (blueprints or model:GetAttribute "state" == "active")
		then
			count += 1
		end
	end
	return count
end

-- The metal spots on your side: west of `x`.
local function my_metal_spots(x: number): { Vector3 }
	local result: { Vector3 } = {}
	for _, spot in metal_spots.all() do
		if spot.center.X < x then
			table.insert(result, spot.center)
		end
	end
	return result
end

-- Whether one of your finished metal extractors stands on `spot`; a blueprint does not count yet.
local function extractor_on(spot: Vector3): boolean
	for _, model in world.all() do
		if
			world.is_mine(model)
			and model:GetAttribute "def_name" == "metal_extractor"
			and model:GetAttribute "state" == "active"
		then
			local at = world.position_of(model)
			if Vector2.new(at.X - spot.X, at.Z - spot.Z).Magnitude <= SPOT_REACH then
				return true
			end
		end
	end
	return false
end

-- How many things the mission's enemy has left standing, finished or not; nil until the server has said which team it
-- is. Wrecks belong to nobody, so what has died is not counted.
local function enemy_left(): number?
	local enemy = Workspace:GetAttribute(ENEMY_TEAM_ATTRIBUTE)
	if typeof(enemy) ~= "number" then
		return nil
	end
	local count = 0
	for _, model in world.all() do
		if model:GetAttribute "team" == enemy then
			count += 1
		end
	end
	return count
end

-- Whether the boulder still blocks the pass.
local function boulder_standing(): boolean
	for _, model in world.all() do
		if model:GetAttribute "def_name" == "tutorial_boulder" then
			return true
		end
	end
	return false
end

-- Calls `check` now and every CHECK_SECONDS until stopped: how the steps that wait on the field keep an eye on it.
local function every_check(check: () -> ()): () -> ()
	local waited = 0
	local connection = RunService.Heartbeat:Connect(function(delta: number)
		waited += delta
		if waited >= CHECK_SECONDS then
			waited = 0
			check()
		end
	end)
	check()
	return function()
		connection:Disconnect()
	end
end

-- A step's `watch` that counts: `card` is done once `count` reaches `goal`, and reports how far it has got meanwhile.
local function watch_count(
	card: string,
	goal: number,
	count: () -> number
): (complete: (card: string) -> (), report: (card: string, text: string) -> ()) -> () -> ()
	return function(complete: (card: string) -> (), report: (card: string, text: string) -> ()): () -> ()
		return every_check(function()
			local have = math.min(count(), goal)
			report(card, `{have}/{goal}`)
			if have >= goal then
				complete(card)
			end
		end)
	end
end

-- Which buttons of the build menu get to `def_name`, in words: its category's, and then its own if the category's
-- button does not place it already. The categories are input's, so they are always the menu's own.
local function build_path(def_name: string): string
	local name = unit_defs.get(def_name).display_name
	for _, tab in input.build_tabs do
		if tab.keys[def_name] == nil then
			continue
		end
		if table.find(tab.primary, def_name) ~= nil then
			return `click {tab.name} in the build menu`
		end
		return `click {tab.name} and then {name} in the build menu`
	end
	return `click {name} in the build menu`
end

local function within_reach(position: Vector3): boolean
	local target = TUTORIAL.move_target
	return Vector2.new(position.X - target.X, position.Z - target.Y).Magnitude <= TUTORIAL.move_tolerance
end

-- A step's `watch` that is done once a finished extractor stands on every metal spot west of `x`, your side. Each spot is
-- marked until one does.
local function watch_extractors(x: number): Watch
	return function(complete: (card: string) -> (), report: (card: string, text: string) -> ()): () -> ()
		local spots = my_metal_spots(x)
		local hide_markers: { [number]: () -> () } = {}
		local middle = Vector3.zero
		for index, spot in spots do
			hide_markers[index] = tutorial_marker.show(Vector2.new(spot.X, spot.Z), SPOT_REACH + 2)
			middle += spot / #spots
		end
		if #spots > 0 then
			camera.glide_to(middle)
		end
		local stop = every_check(function()
			local taken = 0
			for index, spot in spots do
				if extractor_on(spot) then
					taken += 1
					local hide = hide_markers[index]
					if hide ~= nil then
						hide()
						hide_markers[index] = nil
					end
				end
			end
			report("extractors", `{taken}/{#spots}`)
			if taken >= #spots then
				complete "extractors"
			end
		end)
		return function()
			stop()
			for _, hide in hide_markers do
				hide()
			end
		end
	end
end

-- A step's `watch` that counts what has been destroyed of the most the enemy has been seen to have, and is done once it
-- has nothing left; the server ends the game in victory then. It looks over at the enemy, at `enemy_at`, first.
local function watch_destroy(enemy_at: Vector2): Watch
	return function(complete: (card: string) -> (), report: (card: string, text: string) -> ()): () -> ()
		camera.glide_to(Vector3.new(enemy_at.X, 0, enemy_at.Y))
		local most = 0
		return every_check(function()
			local left = enemy_left()
			if left == nil then
				return
			end
			most = math.max(most, left)
			if most == 0 then
				return
			end
			report("destroy", `{most - left}/{most}`)
			if left == 0 then
				complete "destroy"
			end
		end)
	end
end

-- A step's `watch` for its "energy" card: done once your energy revenue reaches `goal` a second.
local function watch_energy(goal: number): Watch
	return function(complete: (card: string) -> (), report: (card: string, text: string) -> ()): () -> ()
		return every_check(function()
			local have = math.min(math.floor(energy_revenue), goal)
			report("energy", `{have}/{goal}`)
			if have >= goal then
				complete "energy"
			end
		end)
	end
end

-- A step's `watch` that runs every one of `watches` at once.
local function watch_all(watches: { Watch }): Watch
	return function(complete: (card: string) -> (), report: (card: string, text: string) -> ()): () -> ()
		local stops: { () -> () } = {}
		for _, watch in watches do
			table.insert(stops, watch(complete, report))
		end
		return function()
			for _, stop in stops do
				stop()
			end
		end
	end
end

-- How many of your finished thugs stand at the overlook's cliff edge, on the plateau.
local function thugs_at_edge(): number
	local count = 0
	for _, model in world.all() do
		if
			world.is_mine(model)
			and model:GetAttribute "def_name" == "thug"
			and model:GetAttribute "state" == "active"
		then
			local at = world.position_of(model)
			local edge = campaign.overlook_edge_at(at.Z)
			if at.X <= edge + 1 and at.X >= edge - OVERLOOK.edge_depth then
				count += 1
			end
		end
	end
	return count
end

local TUTORIAL_STEPS: { Step } = table.freeze({
	{
		id = "camera",
		title = "Move the camera",
		cards = {
			{ id = "wasd", caption = "WASD does not move the camera", mark = "cross" },
			{ id = "arrows", caption = "Use the arrow keys", mark = "check" },
			{ id = "middle_drag", caption = "Or hold the middle mouse button and drag", mark = "check" },
		},
		watch = function(complete: (card: string) -> ()): () -> ()
			-- W, A, S and D only show that they do not pan here, rather than starting the commands they are bound to
			input.suppress_keys({ Enum.KeyCode.W, Enum.KeyCode.A, Enum.KeyCode.S, Enum.KeyCode.D })
			local stop = camera.subscribe_pan(function(method: camera.PanMethod)
				complete(if method == "keys" then "arrows" else "middle_drag")
			end)
			return function()
				stop()
				input.suppress_keys({})
			end
		end,
	},
	{
		id = "select",
		title = "Select your commander",
		cards = {
			{ id = "box_select", caption = "Drag a box over it with the left mouse button", mark = "check" },
			{ id = "click_select", caption = "Or left click it", mark = "check" },
		},
		watch = function(complete: (card: string) -> ()): () -> ()
			-- it may have been panned out of sight in the step before
			local commander = my_commander()
			if commander ~= nil then
				camera.glide_to(world.position_of(commander))
			end
			return input.subscribe_select(function(method: input.SelectMethod, ids: { EntityId })
				local id = commander_id()
				if id ~= nil and table.find(ids, id) ~= nil and selection.contains(id) then
					complete(if method == "box" then "box_select" else "click_select")
				end
			end)
		end,
	},
	{
		id = "move",
		title = "Move your commander",
		cards = {
			{ id = "right_click", caption = "Right click the marker to send your commander there", mark = "check" },
		},
		-- Done once the commander stands at the marker, however it got there. Sending it there says it is on its way.
		watch = function(complete: (card: string) -> (), report: (card: string, text: string) -> ()): () -> ()
			local target = TUTORIAL.move_target
			local hide_marker = tutorial_marker.show(target, TUTORIAL.move_tolerance)
			-- look between the commander and the marker, so both are in view
			local commander = my_commander()
			local target_point = Vector3.new(target.X, 0, target.Y)
			if commander ~= nil then
				camera.glide_to((world.position_of(commander) + target_point) / 2)
			else
				camera.glide_to(target_point)
			end
			local stop_watching_moves = input.subscribe_move(function(ids: { EntityId }, positions: { Vector3 })
				local id = commander_id()
				local index = if id ~= nil then table.find(ids, id) else nil
				if index ~= nil and within_reach(positions[index]) then
					report("right_click", "On its way...")
				end
			end)
			local arrival = RunService.Heartbeat:Connect(function()
				local model = my_commander()
				if model ~= nil and within_reach(world.position_of(model)) then
					complete "right_click"
				end
			end)
			return function()
				hide_marker()
				stop_watching_moves()
				arrival:Disconnect()
			end
		end,
	},
	{
		id = "extractors",
		title = "Build metal extractors",
		cards = {
			{
				id = "extractors",
				caption = `Metal Extractors mine metal. With your commander selected, {build_path "metal_extractor"}, then click each marked metal spot`,
				mark = "check",
			},
		},
		builder = "commander",
		build = "metal_extractor",
		placing_hint = "Now click a marked metal spot",
		watch = watch_extractors(TUTORIAL.chokepoint.X),
	},
	{
		id = "solars",
		title = "Build solar collectors",
		cards = {
			{
				id = "solars",
				caption = `Solar Collectors make energy. With your commander selected, {build_path "solar_collector"}, then place {TUTORIAL.solars} of them`,
				mark = "check",
			},
		},
		builder = "commander",
		build = "solar_collector",
		placing_hint = "Now click on open ground to place it",
		reveals = "economy",
		done_note = "Your metal and energy are now shown at the top of the screen",
		watch = watch_count("solars", TUTORIAL.solars, function(): number
			return count_mine("solar_collector", false)
		end),
	},
	{
		id = "bot_lab",
		title = "Build a Bot Lab",
		cards = {
			{
				id = "bot_lab",
				caption = `A Bot Lab makes your army. With your commander selected, {build_path "bot_lab"}, then place it`,
				mark = "check",
			},
		},
		builder = "commander",
		build = "bot_lab",
		placing_hint = "Now click on open ground to place it",
		watch = watch_count("bot_lab", 1, function(): number
			return count_mine("bot_lab", false)
		end),
	},
	{
		id = "grunts",
		title = "Make Grunts",
		cards = {
			{
				id = "grunts",
				caption = `Select your Bot Lab and click Grunt in its build menu {TUTORIAL.grunts} times`,
				mark = "check",
			},
		},
		builder = "bot_lab",
		build = "grunt",
		reveals = "weapons",
		done_note = "Select a unit to see its weapons in the panel at the bottom left",
		watch = watch_count("grunts", TUTORIAL.grunts, function(): number
			return count_mine("grunt", false)
		end),
	},
	{
		id = "dgun",
		title = "Clear the pass",
		builder = "commander",
		command = "disintegrator",
		command_hint = "Now click the boulder",
		cards = {
			{
				id = "dgun",
				caption = "Move your commander towards the boulder, then press D to use your Disintegrator Gun on the boulder.",
				mark = "check",
			},
		},
		-- Done once the boulder is gone, however that came about.
		watch = function(complete: (card: string) -> (), _report: (card: string, text: string) -> ()): () -> ()
			local pass = TUTORIAL.chokepoint
			local hide_marker = tutorial_marker.show(pass, BOULDER_RING)
			camera.glide_to(Vector3.new(pass.X, 0, pass.Y))
			local stop = every_check(function()
				if boulder_standing() == false then
					complete "dgun"
				end
			end)
			return function()
				stop()
				hide_marker()
			end
		end,
	},
	{
		id = "destroy",
		title = "Destroy the enemy",
		cards = {
			{
				id = "destroy",
				caption = "Take your Grunts and commander through the pass and destroy everything the enemy has",
				mark = "check",
			},
		},
		watch = watch_destroy(TUTORIAL.enemy_start),
	},
})

-- The overlook's: a few suggestions, on the full HUD.
local OVERLOOK_STEPS: { Step } = table.freeze({
	{
		id = "economy",
		title = "Develop your economy",
		cards = {
			{ id = "extractors", caption = "Metal Extractors on the marked spots", mark = "check" },
			{ id = "energy", caption = "Energy per second, from Solar Collectors or Wind Turbines", mark = "check" },
		},
		every_card = true,
		builder = "commander",
		build = "metal_extractor",
		placing_hint = "Now click a marked metal spot",
		watch = watch_all({ watch_extractors(OVERLOOK.edge_x), watch_energy(OVERLOOK.energy) }),
	},
	{
		id = "high_ground",
		title = "Take the high ground",
		cards = {
			{
				id = "edge_thugs",
				caption = "Thugs at the cliff edge outrange the guards below",
				mark = "check",
			},
		},
		build = "thug",
		-- Done once enough of your thugs stand at the edge. The edge in front of the enemy is marked.
		watch = function(complete: (card: string) -> (), report: (card: string, text: string) -> ()): () -> ()
			local edge = Vector2.new(campaign.overlook_edge_at(0) - OVERLOOK.edge_depth / 2, 0)
			local hide_marker = tutorial_marker.show(edge, EDGE_RING)
			camera.glide_to(Vector3.new(edge.X, 0, edge.Y))
			local stop = watch_count("edge_thugs", OVERLOOK.edge_thugs, thugs_at_edge)(complete, report)
			return function()
				stop()
				hide_marker()
			end
		end,
	},
	{
		id = "destroy",
		title = "Destroy the enemy",
		cards = {
			{ id = "destroy", caption = "Every enemy unit and building", mark = "check" },
		},
		watch = watch_destroy(OVERLOOK.enemy_start),
	},
})

-- The missions that guide their player, and through what.
local STEPS_BY_MISSION: { [string]: { Step } } = table.freeze({
	tutorial = TUTORIAL_STEPS,
	overlook = OVERLOOK_STEPS,
})

local state: State = table.freeze({
	active = false,
	mission = nil,
	step = 1,
	completed = table.freeze({}),
	advancing = false,
	progress = table.freeze({}),
})
local listeners: { (state: State) -> () } = {}
-- Stops the current step's watching.
local stop_step: (() -> ())? = nil
-- Bumped whenever the step changes, so that what an old step set going does nothing once it has gone.
local generation = 0

local function set_state(next_state: State)
	state = table.freeze(next_state)
	for _, listener in table.clone(listeners) do
		listener(state)
	end
end

local function subscribe(listener: (state: State) -> ()): () -> ()
	table.insert(listeners, listener)
	return function()
		local index = table.find(listeners, listener)
		if index ~= nil then
			table.remove(listeners, index)
		end
	end
end

local function get(): State
	return state
end

-- The steps of the mission being guided through; none outside one.
local function steps(): { Step }
	return STEPS_BY_MISSION[state.mission or ""] or {}
end

-- The step being shown, while it is still to be done: nil outside the tutorial, once it is finished, and while the
-- next step is on its way.
local function current_step(): Step?
	if state.active == false or state.advancing then
		return nil
	end
	return steps()[state.step]
end

-- Which command the commands list should point out right now, if any.
local function command_target(): string?
	local step = current_step()
	return if step ~= nil then step.command else nil
end

-- What the build menu should point out right now, if anything.
local function build_target(): string?
	local step = current_step()
	return if step ~= nil then step.build else nil
end

-- Whether `feature` is shown on the HUD: always, unless a step of the mission being guided through reveals it (only the
-- tutorial's do), and then once that step has been done.
local function shown(feature: Feature): boolean
	if state.active == false then
		return true
	end
	local revealed_later = false
	for index, step in steps() do
		if step.reveals == feature then
			if index < state.step or (index == state.step and state.advancing) then
				return true
			end
			revealed_later = true
		end
	end
	return revealed_later == false
end

local function leave_step()
	generation += 1
	local stop = stop_step
	stop_step = nil
	if stop ~= nil then
		stop()
	end
end

local function go_to(mission_id: string, index: number)
	leave_step()
	local this_generation = generation
	set_state({
		active = true,
		mission = mission_id,
		step = index,
		completed = table.freeze({}),
		advancing = false,
		progress = table.freeze({}),
	})

	local step = steps()[index]
	if step == nil then
		return
	end
	local function complete(card: string)
		if generation ~= this_generation or state.completed[card] == true then
			return
		end
		local completed = table.clone(state.completed)
		completed[card] = true
		-- on a step that needs every card, the next waits for the last of them
		local done = true
		if step.every_card == true then
			for _, each in step.cards do
				if each.mark == "check" and completed[each.id] ~= true then
					done = false
				end
			end
		end
		local was_advancing = state.advancing
		set_state({
			active = true,
			mission = mission_id,
			step = index,
			completed = table.freeze(completed),
			advancing = was_advancing or done,
			progress = state.progress,
		})
		if was_advancing == false and done then
			task.delay(TUTORIAL.advance_seconds, function()
				if generation == this_generation then
					go_to(mission_id, index + 1)
				end
			end)
		end
	end
	local function report(card: string, text: string)
		if generation ~= this_generation or state.progress[card] == text then
			return
		end
		local progress = table.clone(state.progress)
		progress[card] = text
		set_state({
			active = true,
			mission = mission_id,
			step = index,
			completed = state.completed,
			advancing = state.advancing,
			progress = table.freeze(progress),
		})
	end
	stop_step = step.watch(complete, report)
end

-- Starts guiding the player from the first step when this game becomes a mission that guides, or begins it again (the
-- server's load_mission), and stops when it stops being one.
local function follow_mission(current: string?)
	if current ~= nil and STEPS_BY_MISSION[current] ~= nil then
		go_to(current, 1)
	elseif state.active then
		leave_step()
		set_state({
			active = false,
			mission = nil,
			step = 1,
			completed = table.freeze({}),
			advancing = false,
			progress = table.freeze({}),
		})
	end
end

local function init()
	mission.subscribe(follow_mission)
	follow_mission(mission.current())
end

return table.freeze({
	init = init,
	steps = steps,
	get = get,
	current_step = current_step,
	build_target = build_target,
	command_target = command_target,
	shown = shown,
	subscribe = subscribe,
})
