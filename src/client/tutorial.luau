--!strict
-- The guide of the campaign mission being played, and which of its steps the player is on (the cards that show them are
-- ui/tutorial.luau). Each mission's guide is data in Client.missions: its steps, and what it says once they are done.
--
-- While this game is a mission with a guide, the player is walked through its steps one at a time. Each step offers a
-- few ways of doing one thing, a card each; doing it any of those ways (or every one, for a step that says so) marks
-- it done, and ADVANCE_SECONDS later the next step begins. A card can be the wrong way (`mark` "cross"): shown so the
-- player knows not to, and never done. A guide that stops short (its `is_over`) skips the steps left. Past the last
-- step the guide says what is left to do, if anything. A step that looks over at something moves the view there, and
-- once the steps stop doing so it goes back to where it was before (Client.missions' `look_back`). A mission's hard
-- mode (mission_state.hard) guides not at all.
--
-- What a guide keeps off the HUD until one of its steps has taught it (a step's `reveals`) is `shown`. What the HUD
-- points at for the step is `build_target` and `command_target`, and what its cards say to do first or next, with
-- what is selected and what the cursor is doing, is `hint`.

local ReplicatedStorage = game:GetService "ReplicatedStorage"

local campaign = require(ReplicatedStorage.Shared.campaign)
local unit_defs = require(ReplicatedStorage.Shared.unit_defs)
local map_state = require(ReplicatedStorage.Shared.map_state)
local mission_state = require(ReplicatedStorage.Shared.mission_state)
local signal = require(ReplicatedStorage.Shared.signal)

local missions = require(ReplicatedStorage.Client.missions)
local map_events = require(ReplicatedStorage.Client.map_events)
local world = require(ReplicatedStorage.Client.world)
local selection = require(ReplicatedStorage.Client.selection)
local command_state = require(ReplicatedStorage.Client.command_state)

type Step = missions.Step
type Feature = missions.Feature

-- What the cards of the step say to do before what they ask can be done (select something first), or with `next`,
-- what to do now that it has been started (where to click, once a building is being placed).
export type Hint = { text: string, next: boolean }

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

-- How long a step waits, once it is done, before the next begins.
local ADVANCE_SECONDS = 3

local INACTIVE: State = table.freeze({
	active = false,
	mission = nil,
	step = 1,
	completed = table.freeze({}),
	advancing = false,
	progress = table.freeze({}),
})

local state: State = INACTIVE
local changed = signal.new() :: signal.Signal<State>
-- Stops the current step's watching.
local stop_step: (() -> ())? = nil
-- Bumped whenever the step changes, so that what an old step set going does nothing once it has gone.
local generation = 0

local function set_state(next_state: State)
	state = table.freeze(next_state)
	changed.fire(state)
end

local function get(): State
	return state
end

-- The guide of the mission being guided through; none outside one.
local function guide(): missions.Guide?
	return if state.mission ~= nil then missions.guide_of(state.mission) else nil
end

-- The steps of the mission being guided through; none outside one.
local function steps(): { Step }
	local current = guide()
	return if current ~= nil then current.steps else {}
end

-- The step being shown, while it is still to be done: nil outside a guided mission, once it is finished, and while the
-- next step is on its way.
local function current_step(): Step?
	if state.active == false or state.advancing then
		return nil
	end
	return steps()[state.step]
end

-- What is left to do once every step of the mission being guided through is done, if it says: nil before then.
local function objective(): missions.Objective?
	local current = guide()
	if state.active == false or current == nil or current.steps[state.step] ~= nil then
		return nil
	end
	return current.objective
end

-- Which command the commands list should point out right now, if any.
local function command_target(): string?
	local step = current_step()
	local click = if step ~= nil then step.click else nil
	return if click ~= nil and click.kind == "command" then click.mode else nil
end

-- What the build menu should point out right now, if anything.
local function build_target(): string?
	local step = current_step()
	local click = if step ~= nil then step.click else nil
	return if click ~= nil and click.kind == "build" then click.def_name else nil
end

-- Whether something of `def_name` is selected.
local function is_selected(def_name: string): boolean
	for _, id in selection.get() do
		local def = world.def_of_id(id)
		if def ~= nil and def.name == def_name then
			return true
		end
	end
	return false
end

-- the hint last handed out, handed out again for as long as it says the same, so that nothing renders again for it
local last_hint: Hint? = nil

-- What the cards of the step being shown say to do first or next right now, if anything: select what the step needs
-- selected while it does and it is not, or, once what it asks to be clicked has been, what to do next.
local function hint(): Hint?
	local step = current_step()
	if step == nil then
		return nil
	end
	local found: Hint? = nil
	local selecting = step.select
	local click = step.click
	if
		selecting ~= nil
		and (selecting.until_card == nil or state.completed[selecting.until_card] ~= true)
		and is_selected(selecting.def_name) == false
	then
		local def = unit_defs.get(selecting.def_name)
		local name = if unit_defs.is_commander(def) then "commander" else def.display_name
		found = { text = `First select your {name}`, next = false }
	elseif click ~= nil and click.next ~= nil then
		local clicked = if click.kind == "build"
			then command_state.placing() == click.def_name
			else command_state.mode() == click.mode
		found = if clicked then { text = click.next, next = true } else nil
	end
	if found ~= nil and last_hint ~= nil and found.text == last_hint.text and found.next == last_hint.next then
		return last_hint
	end
	last_hint = found
	return found
end

-- Calls `listener` whenever what `hint` says could have changed, until the returned function is called.
local function subscribe_hint(listener: () -> ()): () -> ()
	local stops = {
		changed.subscribe(listener),
		selection.subscribe(listener),
		command_state.subscribe(listener),
	}
	return function()
		for _, stop in stops do
			stop()
		end
	end
end

-- Whether `feature` is shown on the HUD: always, unless the guide of the mission being played has a step that reveals
-- it, and then only once the player is being guided past that step. A hard mode, which does not guide, shows it all.
local function shown(feature: Feature): boolean
	local playing = missions.current()
	local playing_guide = if playing ~= nil and mission_state.hard() == false then missions.guide_of(playing) else nil
	if playing_guide == nil then
		return true
	end
	for index, step in playing_guide.steps do
		if step.reveals ~= feature then
			continue
		end
		local guided_here = state.active and state.mission == playing
		return guided_here and (index < state.step or (index == state.step and state.advancing))
	end
	return true
end

local function leave_step()
	generation += 1
	local stop = stop_step
	stop_step = nil
	if stop ~= nil then
		stop()
	end
end

-- Goes on to step `index` of `mission_id`'s. The view, if a step before moved it, goes back to where it was unless this
-- one moves it at once.
local function go_to(mission_id: string, index: number)
	leave_step()
	missions.begin_step_view()
	local this_generation = generation
	set_state({
		active = true,
		mission = mission_id,
		step = index,
		completed = table.freeze({}),
		advancing = false,
		progress = table.freeze({}),
	})

	local current = missions.guide_of(mission_id) :: missions.Guide
	local step = current.steps[index]
	if step == nil then
		missions.look_back()
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
			task.delay(ADVANCE_SECONDS, function()
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
	local stop_watch = step.watch(complete, report)
	missions.look_back()
	local is_over = current.is_over
	if is_over == nil then
		stop_step = stop_watch
		return
	end
	local stop_over = missions.every_check(function()
		if is_over() then
			-- deferred, as this may be running inside go_to itself
			task.defer(function()
				if generation == this_generation then
					go_to(mission_id, #current.steps + 1)
				end
			end)
		end
	end)
	stop_step = function()
		stop_watch()
		stop_over()
	end
end

-- Whether this side has built `mission_id`'s map yet. The server names the mission before it loads the map, and a
-- step reads the map (its metal spots) as it starts, so none starts on the map before.
local function map_built(mission_id: string): boolean
	local built = map_state.get()
	local wanted = campaign.get(mission_id)
	return built ~= nil and wanted ~= nil and built.preset == wanted.preset
end

-- Starts guiding the player from the first step when this game becomes a mission that guides, or begins it again (the
-- server's mission_load), once its map is built, and stops when it stops being one. Its hard mode does not guide.
local function follow_mission(current: string?)
	-- where the view was on the map before is nothing to go back to
	missions.forget_view()
	if current ~= nil and missions.guide_of(current) ~= nil and mission_state.hard() == false then
		if map_built(current) then
			go_to(current, 1)
		else
			leave_step()
		end
	elseif state.active then
		leave_step()
		set_state(INACTIVE)
	end
end

-- The map was replaced: the mission being guided through, if any, begins again on the new one.
local function rebuild()
	follow_mission(missions.current())
end

local function init()
	missions.subscribe(follow_mission)
	map_events.on_rebuilt(rebuild)
	follow_mission(missions.current())
end

return table.freeze({
	init = init,
	guide = guide,
	steps = steps,
	get = get,
	current_step = current_step,
	objective = objective,
	build_target = build_target,
	command_target = command_target,
	hint = hint,
	subscribe_hint = subscribe_hint,
	shown = shown,
	subscribe = changed.subscribe,
})
