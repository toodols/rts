-- The build menu for whatever is selected.
--
-- A factory (Bot Lab) lists the units it produces; clicking one appends it to the factory's
-- production queue. Factory build orders always queue, so shift only changes how many are added.
--
-- A constructor lists the buildings it can put down; clicking one enters placement mode and the
-- blueprint is created where the next left click lands.

local ReplicatedStorage = game:GetService "ReplicatedStorage"
local UserInputService = game:GetService "UserInputService"

local React = require(ReplicatedStorage.Packages.react)

local unit_defs = require(ReplicatedStorage.Shared.unit_defs)

local build_mode = require(ReplicatedStorage.Client.build_mode)
local input = require(ReplicatedStorage.Client.input)
local use_entities = require(ReplicatedStorage.Client.ui.use_entities)
local use_viewport = require(ReplicatedStorage.Client.ui.use_viewport)

type EntityView = use_entities.EntityView

local queue_production: RemoteEvent = ReplicatedStorage.Shared.QueueProduction

-- Holding shift when clicking a factory option adds a batch instead of a single unit.
local SHIFT_BATCH = 5

local function Option(props: {
	def_name: string,
	hotkey: string?,
	LayoutOrder: number,
	on_click: (def_name: string) -> (),
})
	local def = unit_defs.get(props.def_name)

	return React.createElement("TextButton", {
		[React.Tag] = "build-option",
		LayoutOrder = props.LayoutOrder,
		Text = "",
		[React.Event.Activated] = function()
			props.on_click(props.def_name)
		end,
	}, {
		Key = if props.hotkey ~= nil
			then React.createElement("TextLabel", {
				[React.Tag] = "build-option-key",
				Text = props.hotkey,
			})
			else nil,
		Name = React.createElement("TextLabel", {
			[React.Tag] = "build-option-name",
			LayoutOrder = 1,
			Text = def.display_name,
		}),
		Subtitle = if def.subtitle ~= nil
			then React.createElement("TextLabel", {
				[React.Tag] = "build-option-subtitle",
				LayoutOrder = 2,
				Text = def.subtitle,
			})
			else nil,
		Cost = React.createElement("Frame", {
			[React.Tag] = "build-cost",
			LayoutOrder = 3,
		}, {
			Metal = React.createElement("TextLabel", {
				[React.Tag] = "cost cost-metal",
				LayoutOrder = 1,
				Text = tostring(def.metal_cost),
			}),
			Energy = React.createElement("TextLabel", {
				[React.Tag] = "cost cost-energy",
				LayoutOrder = 2,
				Text = tostring(def.energy_cost),
			}),
		}),
	})
end

local OTHER_TAB = "Other"
local MAIN_TAB = "Main"

type Tab = {
	name: string,
	key: string?,
	defs: { string },
	-- what the category's key places, best first
	primary: { string },
	-- the key that places each of the defs
	keys: { [string]: string },
}

-- Splits a constructor's buildings into the categories the build hotkeys use, keeping the order it lists
-- them in and leaving out the empty ones. Anything no category holds goes in a last tab of its own.
local function tabs_for(builds: { string }): { Tab }
	local tabs: { Tab } = {}
	local taken: { [string]: boolean } = {}
	for _, category in input.build_tabs do
		local defs: { string } = {}
		for _, def_name in builds do
			if table.find(category.defs, def_name) ~= nil then
				table.insert(defs, def_name)
				taken[def_name] = true
			end
		end
		if #defs > 0 then
			table.insert(
				tabs,
				{ name = category.name, key = category.key, defs = defs, primary = category.primary, keys = category.keys }
			)
		end
	end
	local rest: { string } = {}
	for _, def_name in builds do
		if taken[def_name] == nil then
			table.insert(rest, def_name)
		end
	end
	if #rest > 0 then
		table.insert(tabs, { name = OTHER_TAB, key = nil, defs = rest, primary = {}, keys = {} })
	end

	-- The menu opens on a first page of its own, holding the main building of each category it can build from,
	-- and the category pages come after it.
	if #tabs > 1 then
		local main: { string } = {}
		local main_keys: { [string]: string } = {}
		for _, tab in tabs do
			for _, def_name in tab.primary do
				if table.find(tab.defs, def_name) ~= nil then
					table.insert(main, def_name)
					if tab.key ~= nil then
						main_keys[def_name] = tab.key
					end
					break
				end
			end
		end
		if #main > 0 then
			table.insert(tabs, 1, { name = MAIN_TAB, key = nil, defs = main, primary = {}, keys = main_keys })
		end
	end
	return tabs
end

-- The menu follows the first selected entity that can build anything.
local function first_builder(views: { EntityView }): EntityView?
	for _, view in views do
		local def = unit_defs.defs[view.def_name]
		if def ~= nil and def.build_options ~= nil then
			return view
		end
	end
	return nil
end

local function BuildMenu()
	local ids = use_entities.use_selection()
	local views = use_entities.use_views(ids)
	local placing, set_placing = React.useState(build_mode.active())
	local ui_scale = use_viewport.use_ui_scale()
	local chosen_tab, set_chosen_tab = React.useState(nil :: string?)

	-- Tapping shift goes back to the first page. Shift is also held to queue a batch or place several, so it only
	-- counts as a tap if nothing else was pressed or clicked while it was down.
	React.useEffect(function()
		local tapped = false
		local began = UserInputService.InputBegan:Connect(function(input_object: InputObject, processed: boolean)
			local key = input_object.KeyCode
			if key == Enum.KeyCode.LeftShift or key == Enum.KeyCode.RightShift then
				tapped = processed == false
			else
				tapped = false
			end
		end)
		local ended = UserInputService.InputEnded:Connect(function(input_object: InputObject)
			local key = input_object.KeyCode
			if (key == Enum.KeyCode.LeftShift or key == Enum.KeyCode.RightShift) and tapped then
				tapped = false
				set_chosen_tab(nil)
			end
		end)
		return function()
			began:Disconnect()
			ended:Disconnect()
		end
	end, {})

	React.useEffect(function()
		return build_mode.subscribe(function(def_name: string?)
			set_placing(def_name)
		end)
	end, {})

	local builder = first_builder(views)
	-- leaving placement mode when the builder is deselected keeps the ghost from outliving it
	React.useEffect(function()
		if builder == nil and build_mode.active() ~= nil then
			build_mode.exit()
		end
	end, { builder })

	if builder == nil then
		return nil
	end

	local builder_def = unit_defs.get(builder.def_name)
	local builds = builder_def.build_options
	if builds == nil then
		return nil
	end

	local function on_click(def_name: string)
		local def = unit_defs.get(def_name)
		if def.kind == "building" then
			build_mode.enter(def_name)
			return
		end
		local shift = UserInputService:IsKeyDown(Enum.KeyCode.LeftShift)
		queue_production:FireServer({
			factory_id = builder.id,
			def_name = def_name,
			count = if shift then SHIFT_BATCH else 1,
		})
	end

	-- a constructor's buildings are shown a category at a time, or they would fill the screen; what a factory
	-- makes is one short list
	local buildings_only = true
	for _, def_name in builds do
		if unit_defs.get(def_name).kind ~= "building" then
			buildings_only = false
			break
		end
	end
	local tabs = if buildings_only then tabs_for(builds) else {}
	local shown = builds
	local shown_keys: { [string]: string } = {}
	local tab_row = nil
	if #tabs > 0 then
		-- the tab of what is being placed, so a hotkey into another category takes the menu there
		local active = tabs[1]
		for _, tab in tabs do
			if tab.name == chosen_tab then
				active = tab
			end
		end
		if placing ~= nil then
			for _, tab in tabs do
				if table.find(tab.defs, placing) ~= nil then
					active = tab
				end
			end
		end
		shown = active.defs
		shown_keys = active.keys

		local buttons = {}
		for index, tab in tabs do
			-- the first page has no button of its own: the menu opens on it, and shift goes back to it
			if tab.name == MAIN_TAB then
				continue
			end
			buttons[tab.name] = React.createElement("TextButton", {
				[React.Tag] = if tab == active then "build-tab active" else "build-tab",
				LayoutOrder = index,
				Text = "",
				[React.Event.Activated] = function()
					set_chosen_tab(tab.name)
				end,
			}, {
				Name = React.createElement("TextLabel", {
					[React.Tag] = "build-tab-name",
					LayoutOrder = 1,
					Text = tab.name,
				}),
				Key = if tab.key ~= nil
					then React.createElement("TextLabel", {
						[React.Tag] = "build-tab-key",
						LayoutOrder = 2,
						Text = tab.key,
					})
					else nil,
			})
		end
		tab_row = React.createElement("Frame", {
			[React.Tag] = "build-tabs",
			LayoutOrder = 2,
		}, buttons)
	end

	local options = {}
	for index, def_name in shown do
		options[`Option{index}`] = React.createElement(Option, {
			def_name = def_name,
			hotkey = shown_keys[def_name],
			LayoutOrder = index,
			on_click = on_click,
		})
	end

	local hint = if placing ~= nil
		then "Left click to place, [ ] to rotate, right click to cancel"
		elseif builder_def.kind == "building" then "Build orders always queue; shift adds five"
		else "Pick a building to place"

	return React.createElement("Frame", {
		[React.Tag] = "build-menu panel",
	}, {
		Scale = React.createElement("UIScale", { Scale = ui_scale }),
		Rail = React.createElement("Frame", {
			[React.Tag] = "rail",
		}),
		Title = React.createElement("Frame", {
			[React.Tag] = "build-title",
			LayoutOrder = 1,
		}, {
			Accent = React.createElement("Frame", {
				[React.Tag] = "accent-bar",
				LayoutOrder = 1,
			}),
			Name = React.createElement("TextLabel", {
				[React.Tag] = "heading grow",
				LayoutOrder = 2,
				Text = builder_def.display_name,
			}),
		}),
		Tabs = tab_row,
		Grid = React.createElement("Frame", {
			[React.Tag] = "build-grid",
			LayoutOrder = 3,
		}, options),
		Hint = React.createElement("TextLabel", {
			[React.Tag] = "build-hint",
			LayoutOrder = 4,
			Text = hint,
		}),
	})
end

return table.freeze({
	BuildMenu = BuildMenu,
})
