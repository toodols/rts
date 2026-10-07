--!strict
-- What a mission's guide is made of (see Client.tutorial, which walks the player through one), and the watches its
-- steps are built from: each looks at the field, the HUD or the controls for a card to be done.

local ReplicatedStorage = game:GetService "ReplicatedStorage"
local RunService = game:GetService "RunService"
local Workspace = game:GetService "Workspace"

local build_hotkeys = require(ReplicatedStorage.Shared.build_hotkeys)
local spots = require(ReplicatedStorage.Shared.spots)
local mission_map = require(ReplicatedStorage.Shared.mission_map)
local mission_state = require(ReplicatedStorage.Shared.mission_state)
local unit_defs = require(ReplicatedStorage.Shared.unit_defs)
local placement_rules = require(ReplicatedStorage.Shared.placement_rules)

local camera = require(ReplicatedStorage.Client.camera)
local team_state = require(ReplicatedStorage.Client.team_state)
local tutorial_marker = require(ReplicatedStorage.Client.tutorial_marker)
local world = require(ReplicatedStorage.Client.world)
local occupants = require(ReplicatedStorage.Client.occupants)

local types = require(ReplicatedStorage.Shared.types)
local entity_attrs = require(ReplicatedStorage.Shared.entity_attrs)

type EntityDef = types.EntityDef

-- What a card shows its way in (ui/tutorial.luau draws each kind): keys, the mouse, a short demonstration on a loop,
-- or what a building step asks for in its own art. `def_name` is what the demonstration or the art shows.
export type PictureKind =
	-- W, A, S and D, which flash red as they are pressed, since they do not pan
	"wasd"
	-- the keys that pan, lit as they are held: the arrow keys, or W, A, S and D when those are the keys
	| "arrows"
	-- the mouse, its middle button lit while it is held
	| "middle_mouse"
	-- a box dragged over `def_name`, which is then selected
	| "box_select"
	-- a left click on `def_name`, which is then selected
	| "click"
	-- a right click on a marker, and `def_name` walking there
	| "move"
	-- the Resurrect command being clicked
	| "resurrect_mode"
	-- a circle dragged over wrecks of `def_name`, which rise
	| "area_resurrect"
	-- `def_name` in its own art
	| "unit"

export type Picture = { kind: PictureKind, def_name: string? }

export type Card = {
	-- what a step's `watch` calls it when it is done
	id: string,
	-- a key in it is named `{key:<action>}` (Shared.keybinds), and shown as the player's own
	caption: string,
	-- a way to do it ("check"), or a way not to ("cross"), which is never done
	mark: "check" | "cross",
	picture: Picture,
	-- For a card that is done once an income reaches `goal` a second: which resource, whose colour its meter is in.
	-- Its progress is then the income itself, a number in text, which the card shows against the goal rather than as
	-- a count.
	rate: { resource: "metal" | "energy", goal: number }?,
	-- whether it is shown now, for a card that is only true of some keybinds; always, without it
	shown: (() -> boolean)?,
}

-- Something a guide keeps off the HUD until a step has taught what it is for: "economy" for the metal and energy bar
-- (and what things make and spend), "weapons" for what a unit or building fights with in the selection panel.
export type Feature = "economy" | "weapons"

-- Starts looking for a step's cards to be done, calling `complete` with a card's id when one is, and `report` with a
-- card's id and how far along it is ("2/3") for a card that counts. Returns a function that stops.
export type Watch = (complete: (card: string) -> (), report: (card: string, text: string) -> ()) -> () -> ()

-- What a step has the player select first: something of `def_name`, until the card `until_card` of the step is done
-- (the order having been given), or without one for the whole step.
export type Selecting = { def_name: string, until_card: string? }

-- What a step has the player click in the HUD, which the HUD then points at: something in the build menu, or one of
-- the commands list's modes (Client.order_modes); and what the cards say to do next once it has been clicked (the
-- building is being placed, or the mode is on).
export type Click =
	{ kind: "build", def_name: string, next: string? }
	| { kind: "command", mode: string, next: string? }

export type Step = {
	id: string,
	title: string,
	cards: { Card },
	select: Selecting?,
	click: Click?,
	-- what the HUD shows from the moment the step is done
	reveals: Feature?,
	-- said in place of the usual word while the next step is on its way
	done_note: string?,
	-- whether every one of its ways ("check" cards) has to be done before the next step, rather than any one
	every_card: boolean?,
	watch: Watch,
}

-- What is left to do once a guide's steps are done ("Survive"), and what that means, a line each.
export type Objective = {
	title: string,
	lines: { string },
}

-- A mission's guide.
export type Guide = {
	steps: { Step },
	-- What it says once every step is done: what is left to do, if anything is.
	objective: Objective?,
	-- For a guide that ends in a card of its own once every step is done, what that card says.
	finish: { title: string, status: string }?,
	-- For a guide that stops short: whether it has, the steps left being skipped for the objective.
	is_over: (() -> boolean)?,
	-- The pictures (Shared.ui_art) to build before anything else, so that the cards it teaches with are ready first;
	-- nil to build its pictures when they are first shown.
	preload: { string }?,
}

-- How often the watches that wait on something on the field look again, in seconds.
local CHECK_SECONDS = 0.25
-- How far round a metal spot's middle the marker on it reaches.
local SPOT_MARKER_RADIUS = 6
-- How far down the screen, as a fraction of its height, what a step looks over at is put when the guide's cards would
-- cover the middle.
local GUIDE_CLEAR_AT = 0.74

-- The field -------------------------------------------------------------------------------------------------------

-- Your commander, if it is on the field.
local function my_commander(): Model?
	return world.my_commanders()[1]
end

local function commander_id(): types.EntityId?
	local model = my_commander()
	return if model ~= nil then world.id_of(model) else nil
end

-- Your things of which `wanted` says yes of their def: finished ones only, or with `blueprints` those still going up
-- as well.
local function mine(wanted: (def: EntityDef) -> boolean, blueprints: boolean): { Model }
	local found: { Model } = {}
	for _, model in world.all() do
		if world.is_mine(model) == false or (blueprints == false and entity_attrs.state(model) ~= "active") then
			continue
		end
		local def = world.def_of(model)
		if def ~= nil and wanted(def) then
			table.insert(found, model)
		end
	end
	return found
end

-- How many finished `def_name` are yours.
local function count_mine(def_name: string): number
	return #mine(function(def: EntityDef): boolean
		return def.name == def_name
	end, false)
end

-- The metal spots on your side of the map: those `is_mine` says are.
local function my_metal_spots(is_mine: (spot: Vector3) -> boolean): { Vector3 }
	local result: { Vector3 } = {}
	for _, spot in spots.all "metal" do
		if is_mine(spot.position) then
			table.insert(result, spot.position)
		end
	end
	return result
end

-- Your finished things, as the placement rules see them: a blueprint does not count yet.
local MY_FINISHED = occupants.only(function(model: Model): boolean
	return world.is_mine(model) and entity_attrs.state(model) == "active"
end)

-- Whether one of your finished extractors stands on `spot`.
local function extractor_on(spot: Vector3): boolean
	return placement_rules.spot_built_on(MY_FINISHED, spot, nil)
end

-- How many things the mission's enemy has left standing, finished or not; nil until the server has said which team it
-- is. Wrecks belong to nobody, so what has died is not counted.
local function enemy_left(): number?
	local enemy = mission_state.enemy_team()
	if enemy == nil then
		return nil
	end
	local count = 0
	for _, model in world.all() do
		if entity_attrs.team(model) == enemy then
			count += 1
		end
	end
	return count
end

-- The view ------------------------------------------------------------------------------------------------------

-- A step that looks over at something moves the view there (`look_at`), and once the steps stop doing so it goes back
-- to where it looked before the first of them did (`look_back`, which Client.tutorial calls as each step starts).
local look_back_to: Vector3? = nil
-- whether the step being started has moved the view
local moved_view = false

-- Glides the view to look at `position` for a step, remembering where it looked before, to go back to.
local function look_at(position: Vector3)
	if look_back_to == nil then
		look_back_to = camera.get_focus()
	end
	moved_view = true
	camera.glide_to(position)
end

-- A step is starting: until it looks at something, it has not moved the view.
local function begin_step_view()
	moved_view = false
end

-- Glides the view back to where it looked before the steps moved it, if they have, unless the step being started has
-- just moved it itself.
local function look_back()
	local back = look_back_to
	if back == nil or moved_view then
		return
	end
	look_back_to = nil
	camera.glide_to(back)
end

-- Forgets where the view was, as the map it was on goes: there is nothing to go back to.
local function forget_view()
	look_back_to = nil
	moved_view = false
end

-- Where the ray through `screen` (a fraction of the viewport) meets the flat ground at `height`, or nil if it does not.
local function ground_under(view: Camera, screen: Vector2, height: number): Vector3?
	local size = view.ViewportSize
	local ray = view:ViewportPointToRay(size.X * screen.X, size.Y * screen.Y)
	if math.abs(ray.Direction.Y) < 1e-3 then
		return nil
	end
	local along = (height - ray.Origin.Y) / ray.Direction.Y
	return if along > 0 then ray.Origin + ray.Direction * along else nil
end

-- Glides the view so that `position` ends up in the lower part of the screen (GUIDE_CLEAR_AT down it) rather than in
-- the middle, where the guide's cards would hide it: the view is as far and turned as it is now, so how far the ground
-- at that point is from the ground in the middle now is how far past `position` to look.
local function glide_below_guide(position: Vector3)
	local view = Workspace.CurrentCamera
	local middle = if view ~= nil then ground_under(view, Vector2.new(0.5, 0.5), position.Y) else nil
	local lower = if view ~= nil then ground_under(view, Vector2.new(0.5, GUIDE_CLEAR_AT), position.Y) else nil
	if middle == nil or lower == nil then
		look_at(position)
		return
	end
	look_at(position + (middle - lower))
end

-- Which buttons of the build menu get to `def_name`, in words: its category's, and then its own if the category's
-- button does not place it already. The categories are the menu's own (Shared.build_hotkeys).
local function build_path(def_name: string): string
	local name = unit_defs.get(def_name).display_name
	local category = build_hotkeys.category_of(def_name)
	if category == nil then
		return `click {name} in the build menu`
	elseif build_hotkeys.is_main(category, def_name) then
		return `click {category.name} in the build menu`
	end
	return `click {category.name} and then {name} in the build menu`
end

-- Watches ---------------------------------------------------------------------------------------------------------

-- Calls `check` now and every CHECK_SECONDS until stopped: how the watches that wait on the field keep an eye on it.
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

-- A watch that counts: `card` is done once `count` reaches `goal`, and reports how far it has got meanwhile.
local function watch_count(card: string, goal: number, count: () -> number): Watch
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

-- Marks each metal spot on your side until a finished extractor stands on it, and looks over at them; calls `check`
-- with how many have one and how many there are, now and every CHECK_SECONDS. Returns a function that stops.
local function mark_spots(is_mine: (spot: Vector3) -> boolean, check: (taken: number, total: number) -> ()): () -> ()
	local my_spots = my_metal_spots(is_mine)
	local hide_markers: { [number]: () -> () } = {}
	local middle = Vector3.zero
	for index, spot in my_spots do
		hide_markers[index] = tutorial_marker.show(Vector2.new(spot.X, spot.Z), SPOT_MARKER_RADIUS)
		middle += spot / #my_spots
	end
	if #my_spots > 0 then
		look_at(middle)
	end
	local stop = every_check(function()
		local taken = 0
		for index, spot in my_spots do
			if extractor_on(spot) then
				taken += 1
				local hide = hide_markers[index]
				if hide ~= nil then
					hide()
					hide_markers[index] = nil
				end
			end
		end
		check(taken, #my_spots)
	end)
	return function()
		stop()
		for _, hide in hide_markers do
			hide()
		end
	end
end

-- A watch that is done ("extractors") once a finished extractor stands on every metal spot on your side, the ones
-- `is_mine` picks. Each spot is marked until one does.
local function watch_extractors(is_mine: (spot: Vector3) -> boolean): Watch
	return function(complete: (card: string) -> (), report: (card: string, text: string) -> ()): () -> ()
		return mark_spots(is_mine, function(taken: number, total: number)
			report("extractors", `{taken}/{total}`)
			if taken >= total then
				complete "extractors"
			end
		end)
	end
end

-- A watch that only marks the metal spots on your side until each has an extractor, for a step whose cards ask for
-- what they bring in rather than for the extractors themselves. It is never done.
local function watch_spots(is_mine: (spot: Vector3) -> boolean): Watch
	return function(): () -> ()
		return mark_spots(is_mine, function() end)
	end
end

-- A watch that counts what has been destroyed ("destroy") of the most the enemy has been seen to have, and is done once
-- it has nothing left; the server ends the game in victory then. It looks over at the enemy's start first.
local function watch_destroy(): Watch
	return function(complete: (card: string) -> (), report: (card: string, text: string) -> ()): () -> ()
		local enemy_at = mission_map.here(mission_map.ENEMY_START)
		look_at(Vector3.new(enemy_at.X, 0, enemy_at.Y))
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

-- A watch for a card with a `rate`: reports your revenue of its resource a second, and is done once it reaches the
-- goal as the resource bar shows it, rounded to a whole number.
local function watch_rate(card: Card): Watch
	local rate = card.rate :: { resource: "metal" | "energy", goal: number }
	return function(complete: (card: string) -> (), report: (card: string, text: string) -> ()): () -> ()
		return every_check(function()
			-- your revenue of it, a second's worth, as the resource bar shows it
			local resources = team_state.get()
			local have = if rate.resource == "metal" then resources.metal_revenue else resources.energy_revenue
			report(card.id, string.format("%.1f", have))
			if math.floor(have + 0.5) >= rate.goal then
				complete(card.id)
			end
		end)
	end
end

-- A watch that runs every one of `watches` at once.
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

-- A watch that shows a marker `radius` wide at `where()` and looks at it while `inner` runs.
local function with_marker(where: () -> Vector2, radius: number, inner: Watch): Watch
	return function(complete: (card: string) -> (), report: (card: string, text: string) -> ()): () -> ()
		local at = where()
		local hide_marker = tutorial_marker.show(at, radius)
		look_at(Vector3.new(at.X, 0, at.Y))
		local stop = inner(complete, report)
		return function()
			stop()
			hide_marker()
		end
	end
end

return table.freeze({
	my_commander = my_commander,
	commander_id = commander_id,
	mine = mine,
	count_mine = count_mine,
	look_at = look_at,
	begin_step_view = begin_step_view,
	look_back = look_back,
	forget_view = forget_view,
	glide_below_guide = glide_below_guide,
	build_path = build_path,
	every_check = every_check,
	watch_count = watch_count,
	watch_extractors = watch_extractors,
	watch_spots = watch_spots,
	watch_destroy = watch_destroy,
	watch_rate = watch_rate,
	watch_all = watch_all,
	with_marker = with_marker,
})
