-- The build menu for whatever is selected.
--
-- A factory (Bot Lab) lists the units it produces; clicking one appends it to the factory's
-- production queue. Factory build orders always queue, so shift only changes how many are added.
--
-- A construction_bot lists the buildings it can put down; clicking one enters placement mode and the
-- blueprint is created where the next left click lands. It opens on a first page of categories, each drawn as
-- the building its key (Z, X, C, V) places, and placing anything turns it to that building's category.
--
-- What the player has not unlocked through the campaign (Client.unlocks) is still listed, so they can see what there
-- is to earn, but drawn locked: its picture greyed, a lock over it, and nothing happens when it is clicked. Hovering
-- it says how it is unlocked.
--
-- In the tutorial, the button its step wants clicked (Client.tutorial's `build_target`) is lit and pointed at: the
-- option itself, or on the first page the category it is in. Once it is being placed, the menu stops pointing.

local ReplicatedStorage = game:GetService "ReplicatedStorage"
local UserInputService = game:GetService "UserInputService"

local React = require(ReplicatedStorage.Packages.react)

local unit_defs = require(ReplicatedStorage.Shared.unit_defs)
local unit_descriptions = require(ReplicatedStorage.Shared.unit_descriptions)

local build_mode = require(ReplicatedStorage.Client.build_mode)
local input = require(ReplicatedStorage.Client.input)
local tutorial = require(ReplicatedStorage.Client.tutorial)
local tooltip = require(ReplicatedStorage.Client.ui.tooltip)
local unlocks = require(ReplicatedStorage.Client.unlocks)
local use_entities = require(ReplicatedStorage.Client.ui.use_entities)
local tutorial_pointer = require(ReplicatedStorage.Client.ui.tutorial_pointer)
local use_tutorial = require(ReplicatedStorage.Client.ui.use_tutorial)
local use_viewport = require(ReplicatedStorage.Client.ui.use_viewport)
local unit_icon = require(ReplicatedStorage.Client.ui.unit_icon)

local TutorialPointer = tutorial_pointer.TutorialPointer
local UnitIcon = unit_icon.UnitIcon

type EntityView = use_entities.EntityView
type Content = tooltip.Content

local queue_production: RemoteEvent = ReplicatedStorage.Shared.QueueProduction

-- Holding shift when clicking a factory option adds a batch instead of a single unit.
local SHIFT_BATCH = 5

-- How much of an option's cell, at the bottom, its picture leaves to the name and cost written over it.
local OPTION_FOOT = 0.3

-- What a locked option says when it is hovered.
local function locked_tooltip(def_name: string): Content
	local def = unit_defs.get(def_name)
	return {
		kicker = "LOCKED",
		title = string.upper(def.display_name),
		tone = "danger",
		text = "Unlocked in the campaign.",
	}
end

-- What the local player has unlocked, as a number that changes whenever it does, for a component to re-render on.
local function use_unlocks(): number
	local version, set_version = React.useState(0)
	React.useEffect(function()
		return unlocks.subscribe(function()
			set_version(function(value: number)
				return value + 1
			end)
		end)
	end, {})
	return version
end

local function whole(value: number): string
	return tostring(math.floor(value + 0.5))
end

-- The card shown while a cell is hovered: what the thing is for and how to use it (unit_descriptions), then what it
-- costs and what it brings. The menu is on the right of the screen, so the card opens to its left.
local function def_tooltip(def_name: string, category: string?): tooltip.Content
	local def = unit_defs.get(def_name)
	local description = unit_descriptions[def_name]
	local rows: { tooltip.Row } = {
		{ label = "Metal cost", value = whole(def.metal_cost), tag = "metal" },
		{ label = "Energy cost", value = whole(def.energy_cost), tag = "energy" },
		{ label = "Health", value = whole(def.health) },
	}
	if def.buildpower ~= nil then
		table.insert(rows, { label = "Build power", value = whole(def.buildpower), tag = "buildpower" })
	end
	if def.metal_income ~= nil then
		table.insert(rows, { label = "Metal", value = `+{def.metal_income}/s`, tag = "gain" })
	end
	if def.energy_income ~= nil then
		table.insert(rows, { label = "Energy", value = `+{def.energy_income}/s`, tag = "gain" })
	end
	local range = unit_defs.attack_range(def)
	if range ~= nil then
		table.insert(rows, { label = "Range", value = `{whole(range)} studs`, tag = "weapon" })
	end
	if def.max_speed ~= nil and def.max_speed > 0 then
		table.insert(rows, { label = "Speed", value = `{whole(def.max_speed)} studs/s` })
	end

	local kind = if def.subtitle ~= nil then def.subtitle elseif def.kind == "building" then "Building" else "Unit"
	return {
		kicker = string.upper(if category ~= nil then `{category} · {kind}` else kind),
		title = string.upper(def.display_name),
		tone = if range ~= nil
			then "weapon"
			elseif def.buildpower ~= nil then "build"
			elseif def.energy_income ~= nil then "energy"
			elseif def.metal_income ~= nil then "metal"
			else "plain",
		text = if description ~= nil then description.text else nil,
		rows = rows,
		notes = if description ~= nil then description.tips else nil,
	}
end

-- What a building costs, metal then energy.
local function Cost(props: { def_name: string, LayoutOrder: number })
	local def = unit_defs.get(props.def_name)
	return React.createElement("Frame", {
		[React.Tag] = "build-cost",
		LayoutOrder = props.LayoutOrder,
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
	})
end

-- The lock over a locked option, and the word under its name where its cost would be.
local function LockBadge(props: { tag: string, LayoutOrder: number? })
	return React.createElement("TextLabel", {
		[React.Tag] = props.tag,
		LayoutOrder = props.LayoutOrder,
		Text = "🔒",
	})
end

-- The outside of an option: a button, or for a locked one a plain frame that does nothing when clicked. Either shows
-- `tip` while hovered, which for a locked one says why it is locked.
local function OptionShell(props: {
	tag: string,
	def_name: string,
	locked: boolean,
	LayoutOrder: number,
	on_click: (def_name: string) -> (),
	tip: tooltip.Tooltip,
	children: any?,
})
	if props.locked then
		return React.createElement("Frame", {
			[React.Tag] = `{props.tag} locked`,
			LayoutOrder = props.LayoutOrder,
			[React.Event.MouseEnter] = props.tip.on_enter,
			[React.Event.MouseLeave] = props.tip.on_leave,
		}, props.children)
	end
	return React.createElement("TextButton", {
		[React.Tag] = props.tag,
		LayoutOrder = props.LayoutOrder,
		Text = "",
		[React.Event.Activated] = function()
			props.on_click(props.def_name)
		end,
		[React.Event.MouseEnter] = props.tip.on_enter,
		[React.Event.MouseLeave] = props.tip.on_leave,
	}, props.children)
end

-- What an option costs, or LOCKED in its place.
local function CostOrLocked(props: { def_name: string, locked: boolean, LayoutOrder: number })
	if props.locked then
		return React.createElement("TextLabel", {
			[React.Tag] = "build-locked-label",
			LayoutOrder = props.LayoutOrder,
			Text = "LOCKED",
		})
	end
	return React.createElement(Cost, { def_name = props.def_name, LayoutOrder = props.LayoutOrder })
end

-- One category on the first page, as wide as the menu: a header with the category's name and the key that starts it,
-- over the building that key places, its picture beside its name and cost. The key is `hotkey`, not `key`, which
-- React keeps for itself and never passes on.
local function CategoryRow(
	props: {
		category: string,
		hotkey: string,
		def_name: string,
		team: Color3?,
		locked: boolean,
		-- what the tutorial's pointer at it says, when it is what the tutorial wants clicked
		pointer: string?,
		LayoutOrder: number,
		on_click: (def_name: string) -> (),
	}
)
	local def = unit_defs.get(props.def_name)
	local tip = tooltip.use_tooltip(function()
		return if props.locked then locked_tooltip(props.def_name) else def_tooltip(props.def_name, props.category)
	end, "left")

	return React.createElement(OptionShell, {
		tag = if props.pointer ~= nil then "build-category-row tutorial-highlight" else "build-category-row",
		def_name = props.def_name,
		locked = props.locked,
		LayoutOrder = props.LayoutOrder,
		on_click = props.on_click,
		tip = tip,
	}, {
		Tooltip = tip.card,
		Pointer = if props.pointer ~= nil
			then React.createElement(TutorialPointer, { text = props.pointer, side = "left" })
			else nil,
		Header = React.createElement("Frame", {
			[React.Tag] = "build-category-header",
			LayoutOrder = 1,
		}, {
			Name = React.createElement("TextLabel", {
				[React.Tag] = "build-category-name grow",
				LayoutOrder = 1,
				Text = props.category,
			}),
			-- a locked building's key does nothing, so it shows the lock instead
			Key = if props.locked
				then React.createElement(LockBadge, { tag = "build-category-lock", LayoutOrder = 2 })
				else React.createElement("TextLabel", {
					[React.Tag] = "build-category-key",
					LayoutOrder = 2,
					Text = props.hotkey,
				}),
		}),
		Body = React.createElement("Frame", {
			[React.Tag] = "build-category-body",
			LayoutOrder = 2,
		}, {
			Icon = React.createElement(UnitIcon, {
				def_name = props.def_name,
				team = props.team,
				locked = props.locked,
				tag = "build-category-icon",
				LayoutOrder = 1,
			}),
			Info = React.createElement("Frame", {
				[React.Tag] = "build-category-info grow",
				LayoutOrder = 2,
			}, {
				Name = React.createElement("TextLabel", {
					[React.Tag] = "build-category-building",
					LayoutOrder = 1,
					Text = def.display_name,
				}),
				Subtitle = if def.subtitle ~= nil
					then React.createElement("TextLabel", {
						[React.Tag] = "build-category-subtitle",
						LayoutOrder = 2,
						Text = def.subtitle,
					})
					else nil,
				Cost = React.createElement(CostOrLocked, {
					def_name = props.def_name,
					locked = props.locked,
					LayoutOrder = 3,
				}),
			}),
		}),
	})
end

-- One cell of the menu's grid.
local function Option(props: {
	def_name: string,
	hotkey: string?,
	team: Color3?,
	locked: boolean,
	pointer: string?,
	LayoutOrder: number,
	on_click: (def_name: string) -> (),
})
	local def = unit_defs.get(props.def_name)
	local tip = tooltip.use_tooltip(function()
		return if props.locked then locked_tooltip(props.def_name) else def_tooltip(props.def_name, nil)
	end, "left")

	return React.createElement(OptionShell, {
		tag = if props.pointer ~= nil then "build-option tutorial-highlight" else "build-option",
		def_name = props.def_name,
		locked = props.locked,
		LayoutOrder = props.LayoutOrder,
		on_click = props.on_click,
		tip = tip,
	}, {
		Tooltip = tip.card,
		Pointer = if props.pointer ~= nil
			then React.createElement(TutorialPointer, { text = props.pointer, side = "left" })
			else nil,
		-- the icon and the key sit over the cell where they like, so they are kept out of the body, whose list
		-- layout would stack them with the text
		Icon = React.createElement(UnitIcon, {
			def_name = props.def_name,
			team = props.team,
			locked = props.locked,
			foot = OPTION_FOOT,
			tag = "build-option-icon",
		}),
		-- a locked option's key does nothing, so it shows the lock where the key would be
		Key = if props.locked
			then React.createElement(LockBadge, { tag = "build-option-lock" })
			elseif props.hotkey ~= nil then React.createElement("TextLabel", {
				[React.Tag] = "build-option-key",
				Text = props.hotkey,
			})
			else nil,
		Body = React.createElement("Frame", {
			[React.Tag] = "build-option-body",
		}, {
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
			Cost = React.createElement(CostOrLocked, {
				def_name = props.def_name,
				locked = props.locked,
				LayoutOrder = 3,
			}),
		}),
	})
end

-- One category on the first page: its name, its key, and the building that key places.
type Row = {
	category: string,
	key: string,
	def_name: string,
}

type Page = {
	-- the category it shows and the key that starts it, or nil for the first page
	category: string?,
	key: string?,
	-- on the first page, one row per category
	rows: { Row },
	-- the cells of the grid, with the key that places each of them
	defs: { string },
	keys: { [string]: string },
}

-- The first page: one row for each category the builder can build from, showing the building its key places (the
-- category's main building, or else the first in it the builder can build). What the player has unlocked comes first,
-- as it does for the key (input's category_entry); a category with nothing unlocked shows its building locked.
-- Anything it can build that no category holds follows them in the grid.
local function first_page(builds: { string }): Page
	local page: Page = { category = nil, key = nil, rows = {}, defs = {}, keys = {} }
	local taken: { [string]: boolean } = {}
	for _, tab in input.build_tabs do
		-- the first choice among what is unlocked, and the first choice whatever is locked
		local entry: string? = nil
		local fallback: string? = nil
		for _, def_name in tab.primary do
			if table.find(builds, def_name) ~= nil then
				fallback = fallback or def_name
				if unlocks.is_unlocked(def_name) then
					entry = def_name
					break
				end
			end
		end
		for _, def_name in builds do
			if table.find(tab.defs, def_name) ~= nil then
				taken[def_name] = true
				fallback = fallback or def_name
				if entry == nil and unlocks.is_unlocked(def_name) then
					entry = def_name
				end
			end
		end
		entry = entry or fallback
		if entry ~= nil then
			table.insert(page.rows, { category = tab.name, key = tab.key, def_name = entry })
		end
	end
	for _, def_name in builds do
		if taken[def_name] == nil then
			table.insert(page.defs, def_name)
		end
	end
	return page
end

-- The page of the category `placing` belongs to: every building in it the builder can build, in the order the
-- builder lists them, each against the key that picks it. Nil if no category holds it.
local function category_page(builds: { string }, placing: string): Page?
	for _, tab in input.build_tabs do
		if table.find(tab.defs, placing) == nil then
			continue
		end
		local defs: { string } = {}
		for _, def_name in builds do
			if table.find(tab.defs, def_name) ~= nil then
				table.insert(defs, def_name)
			end
		end
		return { category = tab.name, key = tab.key, rows = {}, defs = defs, keys = tab.keys }
	end
	return nil
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
	-- only to re-render when unlocks change; what is locked is asked of `unlocks` as it is drawn
	use_unlocks()
	-- only to re-render when the tutorial's step changes; what it wants clicked is asked of `tutorial` below
	use_tutorial.use_tutorial()

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
		-- a locked option is not a button, but it may have been unlocked away since it was drawn
		if unlocks.is_unlocked(def_name) == false then
			return
		end
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

	-- A construction_bot's buildings are shown a category at a time, or they would fill the screen: the first page
	-- offers one building per category, and placing anything in a category turns the menu to that category's page
	-- until placing ends. What a factory makes is one short list.
	local buildings_only = true
	for _, def_name in builds do
		if unit_defs.get(def_name).kind ~= "building" then
			buildings_only = false
			break
		end
	end
	local page: Page = { category = nil, key = nil, rows = {}, defs = builds, keys = {} }
	if buildings_only then
		page = (if placing ~= nil then category_page(builds, placing) else nil) or first_page(builds)
	end

	-- what the tutorial wants clicked, if this builder can build it and it is not being placed already
	local target = tutorial.build_target()
	if target ~= nil and (table.find(builds, target) == nil or placing == target) then
		target = nil
	end
	local function row_pointer(row: Row): string?
		if target == nil then
			return nil
		end
		for _, tab in input.build_tabs do
			if tab.name == row.category and (row.def_name == target or table.find(tab.defs, target) ~= nil) then
				return "CLICK"
			end
		end
		return nil
	end
	local function option_pointer(def_name: string): string?
		if def_name ~= target then
			return nil
		end
		return "CLICK"
	end

	local rows = {}
	for index, row in page.rows do
		rows[row.category] = React.createElement(CategoryRow, {
			category = row.category,
			hotkey = row.key,
			def_name = row.def_name,
			team = builder.team_color,
			locked = unlocks.is_unlocked(row.def_name) == false,
			pointer = row_pointer(row),
			LayoutOrder = index,
			on_click = on_click,
		})
	end

	local options = {}
	for index, def_name in page.defs do
		options[`Option{index}`] = React.createElement(Option, {
			def_name = def_name,
			hotkey = page.keys[def_name],
			team = builder.team_color,
			locked = unlocks.is_unlocked(def_name) == false,
			pointer = option_pointer(def_name),
			LayoutOrder = index,
			on_click = on_click,
		})
	end

	-- inside a category, a banner under the title says which, and how to get back out of it
	local banner = if page.category ~= nil
		then React.createElement("Frame", {
			[React.Tag] = "build-page-header",
			LayoutOrder = 2,
		}, {
			Key = if page.key ~= nil
				then React.createElement("TextLabel", {
					[React.Tag] = "build-page-key",
					LayoutOrder = 1,
					Text = page.key,
				})
				else nil,
			Name = React.createElement("TextLabel", {
				[React.Tag] = "build-page-name grow",
				LayoutOrder = 2,
				Text = page.category,
			}),
			Back = React.createElement("TextLabel", {
				[React.Tag] = "build-page-back",
				LayoutOrder = 3,
				Text = "Right click: back",
			}),
		})
		else nil

	-- placing has its own hint by the cursor
	local hint = if placing == nil and builder_def.kind == "building" then "Shift: ×5" else nil

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
		Banner = banner,
		Rows = if #page.rows > 0
			then React.createElement("Frame", {
				[React.Tag] = "build-category-list",
				LayoutOrder = 3,
			}, rows)
			else nil,
		Grid = if #page.defs > 0
			then React.createElement("Frame", {
				[React.Tag] = "build-grid",
				LayoutOrder = 4,
			}, options)
			else nil,
		Hint = if hint ~= nil
			then React.createElement("TextLabel", {
				[React.Tag] = "build-hint",
				LayoutOrder = 5,
				Text = hint,
			})
			else nil,
	})
end

return table.freeze({
	BuildMenu = BuildMenu,
})
