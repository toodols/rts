-- The build menu for whatever is selected.
--
-- A factory (Bot Lab) lists the units it produces; clicking one appends it to the factory's
-- production queue. Factory build orders always queue, so shift only changes how many are added.
--
-- A construction_bot lists the buildings it can put down; clicking one enters placement mode and the
-- blueprint is created where the next left click lands. It opens on a first page of categories, each drawn as
-- the building its key (Z, X, C, V) places, and placing anything turns it to that building's category.
--
-- What the player has not unlocked through the campaign (ClientShared.campaign_standing) is still listed, so they can see what there
-- is to earn, but drawn locked: its picture greyed, a lock over it, and nothing happens when it is clicked. Hovering
-- it says how it is unlocked.
--
-- In the tutorial, the button its step wants clicked (Client.tutorial's `build_target`) is lit and pointed at: the
-- option itself, or on the first page the category it is in. Once it is being placed, the menu stops pointing.

local ReplicatedStorage = game:GetService "ReplicatedStorage"

local React = require(ReplicatedStorage.Packages.react)

local campaign = require(ReplicatedStorage.Shared.campaign)
local build_hotkeys = require(ReplicatedStorage.Shared.build_hotkeys)
local unit_defs = require(ReplicatedStorage.Shared.unit_defs)
local unit_descriptions = require(ReplicatedStorage.Shared.unit_descriptions)
local unit_facts = require(ReplicatedStorage.Shared.unit_facts)
local entity_attrs = require(ReplicatedStorage.Shared.entity_attrs)

local command_state = require(ReplicatedStorage.Client.command_state)
local modifiers = require(ReplicatedStorage.Client.modifiers)
local orders = require(ReplicatedStorage.Client.orders)
local selected = require(ReplicatedStorage.Client.selected)
local tooltip = require(ReplicatedStorage.Client.ui.tooltip)
local use_entities = require(ReplicatedStorage.Client.ui.use_entities)
local tutorial_pointer = require(ReplicatedStorage.Client.ui.tutorial_pointer)
local use_tutorial = require(ReplicatedStorage.Client.ui.use_tutorial)
local use_viewport = require(ReplicatedStorage.Client.ui.use_viewport)

local unit_picture = require(ReplicatedStorage.ClientShared.unit_picture)
local campaign_standing = require(ReplicatedStorage.ClientShared.campaign_standing)
local use_store = require(ReplicatedStorage.ClientShared.use_store)

local TutorialPointer = tutorial_pointer.TutorialPointer
local UnitPicture = unit_picture.UnitPicture

type Content = tooltip.Content

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

-- What the local player has unlocked, kept up to date: whether they may build a def, by its name.
local function use_unlocked(): (def_name: string) -> boolean
	local unlocked = campaign_standing.use_standing().unlocks
	return function(def_name: string): boolean
		return campaign.is_unlocked(unlocked, def_name)
	end
end

-- The card shown while a cell is hovered: what the thing is for and how to use it (unit_descriptions), then what it
-- costs and what it brings (unit_facts). The menu is on the right of the screen, so the card opens to its left.
local function def_tooltip(def_name: string, category: string?): tooltip.Content
	local def = unit_defs.get(def_name)
	local kind = if def.subtitle ~= nil then def.subtitle elseif def.kind == "building" then "Building" else "Unit"
	return {
		kicker = string.upper(if category ~= nil then `{category} · {kind}` else kind),
		title = string.upper(def.display_name),
		tone = unit_facts.tone(def),
		text = unit_descriptions.text_of(def),
		rows = unit_facts.summary_rows(def),
		notes = unit_descriptions.tips_of(def_name),
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
		-- whether the tutorial points at it, as what leads to what it wants clicked
		pointed: boolean,
		LayoutOrder: number,
		on_click: (def_name: string) -> (),
	}
)
	local def = unit_defs.get(props.def_name)
	local tip = tooltip.use_tooltip(function()
		return if props.locked then locked_tooltip(props.def_name) else def_tooltip(props.def_name, props.category)
	end, "left")

	return React.createElement(OptionShell, {
		tag = tutorial_pointer.lit("build-category-row", props.pointed),
		def_name = props.def_name,
		locked = props.locked,
		LayoutOrder = props.LayoutOrder,
		on_click = props.on_click,
		tip = tip,
	}, {
		Tooltip = tip.card,
		Pointer = if props.pointed then React.createElement(TutorialPointer, { side = "left" }) else nil,
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
			Icon = React.createElement(UnitPicture, {
				framing = "card",
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
	pointed: boolean,
	LayoutOrder: number,
	on_click: (def_name: string) -> (),
})
	local def = unit_defs.get(props.def_name)
	local tip = tooltip.use_tooltip(function()
		return if props.locked then locked_tooltip(props.def_name) else def_tooltip(props.def_name, nil)
	end, "left")

	return React.createElement(OptionShell, {
		tag = tutorial_pointer.lit("build-option", props.pointed),
		def_name = props.def_name,
		locked = props.locked,
		LayoutOrder = props.LayoutOrder,
		on_click = props.on_click,
		tip = tip,
	}, {
		Tooltip = tip.card,
		Pointer = if props.pointed then React.createElement(TutorialPointer, { side = "left" }) else nil,
		-- the icon and the key sit over the cell where they like, so they are kept out of the body, whose list
		-- layout would stack them with the text
		Icon = React.createElement(UnitPicture, {
			framing = "card",
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

-- The first page: one row for each category the builder can build from, showing the building its key places, which
-- is what the key itself would place (build_hotkeys.entry); a category with nothing unlocked shows its building
-- locked. Anything it can build that no category holds follows them in the grid.
local function first_page(builds: { string }, is_unlocked: (def_name: string) -> boolean): Page
	local page: Page = { category = nil, key = nil, rows = {}, defs = {}, keys = {} }
	for _, category in build_hotkeys.categories do
		local entry, shown = build_hotkeys.entry(category, builds, is_unlocked)
		local def_name = entry or shown
		if def_name ~= nil then
			table.insert(page.rows, { category = category.name, key = category.key, def_name = def_name })
		end
	end
	for _, def_name in builds do
		if build_hotkeys.category_of(def_name) == nil then
			table.insert(page.defs, def_name)
		end
	end
	return page
end

-- The page of the category `placing` belongs to: every building in it the builder can build, in the order the
-- builder lists them, each against the key that picks it. Nil if no category holds it.
local function category_page(builds: { string }, placing: string): Page?
	local category = build_hotkeys.category_of(placing)
	if category == nil then
		return nil
	end
	local defs: { string } = {}
	for _, def_name in builds do
		if category.key_of[def_name] ~= nil then
			table.insert(defs, def_name)
		end
	end
	return { category = category.name, key = category.key, rows = {}, defs = defs, keys = category.key_of }
end

local function BuildMenu()
	-- the menu follows the selection's builder, rendering again as the selection changes
	use_entities.use_selection()
	local placing = use_store.use_store(command_state.placing, command_state.subscribe_placing)
	local ui_scale = use_viewport.use_ui_scale()
	local is_unlocked = use_unlocked()
	-- what the guide wants clicked, if anything
	local wanted = use_tutorial.use_build_target()

	local builder = selected.builder()
	if builder == nil then
		return nil
	end
	local builder_def = builder.def
	local builds = unit_defs.build_options(builder_def)
	local team_color = entity_attrs.color(builder.model, "team_color")

	local function on_click(def_name: string)
		-- a locked option is not a button, but it may have been unlocked away since it was drawn
		if campaign_standing.is_unlocked(def_name) == false then
			return
		end
		local def = unit_defs.get(def_name)
		if def.kind == "building" then
			-- whatever the cursor was doing ends, a mode waiting for its click among it
			command_state.place(def_name)
			return
		end
		orders.queue(builder.id, def_name, if modifiers.shift_held() then SHIFT_BATCH else 1, modifiers.alt_held())
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
		page = (if placing ~= nil then category_page(builds, placing) else nil) or first_page(builds, is_unlocked)
	end

	-- what the tutorial wants clicked, if this builder can build it and it is not being placed already, and so what
	-- leads to it: its own cell, or on the first page the row of its category
	local target = if wanted ~= nil and table.find(builds, wanted) ~= nil and placing ~= wanted then wanted else nil
	local target_category = if target ~= nil then build_hotkeys.category_of(target) else nil
	local function leads_to_target(def_name: string, category: string?): boolean
		return target ~= nil and (def_name == target or (target_category ~= nil and target_category.name == category))
	end

	local rows = {}
	for index, row in page.rows do
		rows[row.category] = React.createElement(CategoryRow, {
			category = row.category,
			hotkey = row.key,
			def_name = row.def_name,
			team = team_color,
			locked = is_unlocked(row.def_name) == false,
			pointed = leads_to_target(row.def_name, row.category),
			LayoutOrder = index,
			on_click = on_click,
		})
	end

	local options = {}
	for index, def_name in page.defs do
		options[`Option{index}`] = React.createElement(Option, {
			def_name = def_name,
			hotkey = page.keys[def_name],
			team = team_color,
			locked = is_unlocked(def_name) == false,
			pointed = leads_to_target(def_name, nil),
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
