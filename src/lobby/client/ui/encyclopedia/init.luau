--!strict
-- The lobby's Encyclopedia tab: every unit and building a player can have, a card each, filed as the catalog files
-- them (Shared.def_catalog), the cards flowing across as many to a row as fit (unit_card.luau). A search box and a chip
-- per kind narrow them.
--
-- Each card wears its tier, as an unlock's card does on the end screen, and whether the campaign has it locked for this
-- player. Clicking one opens its entry (entry.luau) in a panel beside the grid, which narrows to make room.
--
-- Another screen opens an entry by handing `focus` a def name with a fresh `nonce` (the campaign's missions link to what
-- they unlock), and so does a link in an entry: the grid clears its filters, opens that entry and scrolls its card into
-- view.

local ReplicatedStorage = game:GetService "ReplicatedStorage"
local RunService = game:GetService "RunService"

local React = require(ReplicatedStorage.Packages.react)

local campaign = require(ReplicatedStorage.Shared.campaign)
local def_catalog = require(ReplicatedStorage.Shared.def_catalog)
local rarity = require(ReplicatedStorage.Shared.rarity)
local types = require(ReplicatedStorage.Shared.types)
local unit_defs = require(ReplicatedStorage.Shared.unit_defs)

local campaign_standing = require(ReplicatedStorage.ClientShared.campaign_standing)

local controls = require(script.Parent.controls)
local entry = require(script.entry)
local entry_link = require(script.entry_link)
local unit_card = require(script.unit_card)

type EntityDef = types.EntityDef

-- An element's properties: strict mode cannot type a table of them that mixes tags, properties and handlers.
type Props = { [any]: any }

-- How far under the grid's top a card jumped to is left, as a share of the grid's height.
local JUMP_MARGIN = 0.04

-- An entry to open, from another screen or from a link in an entry. `nonce` is new each time, so asking for the same
-- entry twice scrolls to it again.
export type Focus = { name: string, nonce: number }

-- What the chips along the top narrow the grid to: every section, or those of one category.
type Filter = "all" | types.Category

-- The chips along the top, in order, and what each says.
local FILTERS: { { id: Filter, label: string } } = {
	{ id = "all", label = "ALL" },
	{ id = "bots", label = "BOTS" },
	{ id = "vehicles", label = "VEHICLES" },
	{ id = "hover", label = "HOVER" },
	{ id = "ships", label = "SHIPS" },
	{ id = "aircraft", label = "AIRCRAFT" },
	{ id = "experimental", label = "EXPERIMENTAL" },
	{ id = "factories", label = "FACTORIES" },
	{ id = "economy", label = "ECONOMY" },
	{ id = "defences", label = "DEFENCES" },
}

-- What a search is matched against: the name, the def's own name spelled out, and the subtitle, all lower case.
local function search_text(def: EntityDef): string
	return string.lower(`{def.display_name} {string.gsub(def.name, "_", " ")} {def.subtitle or ""}`)
end

local SEARCH_TEXT: { [string]: string } = {}
for name, def in unit_defs.defs do
	if def_catalog.has_entry(name) then
		SEARCH_TEXT[name] = search_text(def)
	end
end

-- The open entry, in a panel beside the grid: a bar to close it, and the entry, scrolling on its own. It is keyed by
-- the def, so opening another starts it from the top.
local function Detail(props: {
	name: string,
	locked: boolean,
	unlocks: { [string]: boolean },
	on_open: (name: string) -> (),
	on_close: () -> (),
})
	local def = unit_defs.defs[props.name]
	local tier = rarity.tier_of(props.name)
	return React.createElement("Frame", {
		[React.Tag] = `encyclopedia-detail {tier.tag}`,
	}, {
		Bar = React.createElement("Frame", {
			[React.Tag] = "detail-bar",
			LayoutOrder = 1,
		}, {
			Accent = React.createElement("Frame", {
				[React.Tag] = "accent-bar",
				LayoutOrder = 1,
			}),
			Title = React.createElement("TextLabel", {
				[React.Tag] = "detail-title heading",
				LayoutOrder = 2,
				Text = "ENTRY",
			}),
			Close = React.createElement(controls.Button, {
				kind = "button",
				tag = "detail-close",
				label = "Close",
				on_press = props.on_close,
				LayoutOrder = 3,
			}),
		}),
		[`Scroll_{props.name}`] = React.createElement("ScrollingFrame", {
			[React.Tag] = "detail-scroll",
			LayoutOrder = 2,
			CanvasSize = UDim2.new(),
			AutomaticCanvasSize = Enum.AutomaticSize.Y,
			ScrollingDirection = Enum.ScrollingDirection.Y,
		}, {
			Body = React.createElement(
				entry.EntryBody,
				{ def = def, tier = tier, locked = props.locked, unlocks = props.unlocks, on_open = props.on_open }
			),
		}),
	})
end

local function Encyclopedia(props: { focus: Focus? })
	local progress = campaign_standing.use_standing()
	local query, set_query = React.useState ""
	local category: Filter, set_category = React.useState("all" :: Filter)
	-- the entry open in the detail panel
	local selected: string?, set_selected = React.useState(nil :: string?)
	-- the card to bring into view once it is laid out
	local jump, set_jump = React.useState(nil :: Focus?)
	local list_ref = React.useRef(nil :: ScrollingFrame?)
	local search_ref = React.useRef(nil :: TextBox?)
	local cards = React.useRef({} :: { [string]: Instance? })

	local function card_ref(name: string, instance: Instance?)
		cards.current[name] = instance :: any
	end

	-- Opens `name` in the detail panel and brings its card into view, clearing whatever would hide it.
	local function focus(name: string)
		if def_catalog.has_entry(name) == false then
			return
		end
		set_query ""
		if search_ref.current ~= nil then
			search_ref.current.Text = ""
		end
		set_category "all"
		set_selected(name)
		set_jump({ name = name, nonce = os.clock() })
	end

	React.useEffect(function()
		if props.focus ~= nil then
			focus(props.focus.name)
		end
	end, { props.focus })

	-- Scrolls the card asked for to near the top of the grid once it has been laid out (the grid narrows as the detail
	-- panel opens, which moves it). The shell is scaled to fit the screen, and whether the canvas's offset is in the
	-- scaled pixels or the shell's own has proved hard to say, so rather than assume, it moves by what is left to go,
	-- sees how far that really moved the card, and corrects by that ratio, until the card is there or the canvas can go
	-- no further.
	React.useEffect(function(): (() -> ())?
		if jump == nil then
			return nil
		end
		local thread = task.spawn(function()
			RunService.Heartbeat:Wait()
			RunService.Heartbeat:Wait()
			-- canvas offset per screen pixel
			local ratio = 1
			for _ = 1, 4 do
				local list = list_ref.current
				local found = cards.current[jump.name]
				if list == nil or found == nil or not found:IsA "GuiObject" then
					return
				end
				local card = found :: GuiObject
				-- a little under the top, so the row above shows the card is not the first
				local left = card.AbsolutePosition.Y - list.AbsolutePosition.Y - JUMP_MARGIN * list.AbsoluteSize.Y
				if math.abs(left) < 1 then
					return
				end
				local before = list.CanvasPosition.Y
				list.CanvasPosition = Vector2.new(0, math.max(0, before + left * ratio))
				local applied = list.CanvasPosition.Y - before
				if math.abs(applied) < 0.5 then
					return
				end
				RunService.Heartbeat:Wait()
				local moved = (card.AbsolutePosition.Y - list.AbsolutePosition.Y - JUMP_MARGIN * list.AbsoluteSize.Y)
				moved = left - moved
				if math.abs(moved) >= 1 then
					ratio = applied / moved
				end
			end
		end)
		return function()
			if coroutine.status(thread) ~= "dead" then
				task.cancel(thread)
			end
		end
	end, { jump })

	-- A card clicked opens its entry, or closes it if it is the one open.
	local function choose(name: string)
		set_selected(function(current: string?): string?
			return if current == name then nil else name
		end)
	end

	local needle = string.lower(query)
	local shown = 0
	local sections: { [string]: any } = {}
	for index, section in def_catalog.SECTIONS do
		if category ~= "all" and section.category ~= category then
			continue
		end
		local names: { string } = {}
		for _, name in section.names do
			if needle == "" or string.find(SEARCH_TEXT[name], needle, 1, true) ~= nil then
				table.insert(names, name)
			end
		end
		if #names == 0 then
			continue
		end
		shown += #names
		sections[section.key] = React.createElement(unit_card.SectionView, {
			section = section,
			names = names,
			selected = selected,
			unlocks = progress.unlocks,
			on_select = choose,
			card_ref = card_ref,
			LayoutOrder = index,
		})
	end
	if shown == 0 then
		sections.Empty = React.createElement("TextLabel", {
			[React.Tag] = "empty",
			LayoutOrder = 0,
			Text = "Nothing matches.",
		})
	end

	local chips: { [string]: any } = {}
	for index, filter in FILTERS do
		chips[filter.id] = React.createElement(controls.Button, {
			kind = "chip",
			tag = if filter.id == category then "filter active" else "filter",
			label = filter.label,
			on_press = function()
				set_category(filter.id)
			end,
			LayoutOrder = index,
		})
	end

	return React.createElement("Frame", {
		[React.Tag] = "encyclopedia panel",
	}, {
		Rail = React.createElement("Frame", {
			[React.Tag] = "rail",
			LayoutOrder = 1,
		}),
		Toolbar = React.createElement("Frame", {
			[React.Tag] = "encyclopedia-toolbar",
			LayoutOrder = 2,
		}, {
			Search = React.createElement(
				"TextBox",
				{
					[React.Tag] = "encyclopedia-search",
					LayoutOrder = 1,
					Text = "",
					PlaceholderText = "Search",
					PlaceholderColor3 = Color3.fromRGB(146, 166, 188),
					ClearTextOnFocus = false,
					ref = search_ref,
					[React.Change.Text] = function(box: TextBox)
						set_query(box.Text)
					end,
				} :: Props
			),
			Filters = React.createElement("Frame", {
				[React.Tag] = "encyclopedia-filters grow",
				LayoutOrder = 2,
			}, chips),
			Count = React.createElement("TextLabel", {
				[React.Tag] = "badge",
				LayoutOrder = 3,
				Text = if shown == def_catalog.LISTED_COUNT
					then tostring(def_catalog.LISTED_COUNT)
					else `{shown}/{def_catalog.LISTED_COUNT}`,
			}),
		}),
		Content = React.createElement("Frame", {
			[React.Tag] = "encyclopedia-content",
			LayoutOrder = 3,
		}, {
			List = React.createElement("ScrollingFrame", {
				[React.Tag] = "encyclopedia-list",
				LayoutOrder = 1,
				CanvasSize = UDim2.new(),
				AutomaticCanvasSize = Enum.AutomaticSize.Y,
				ScrollingDirection = Enum.ScrollingDirection.Y,
				ref = list_ref,
			}, sections),
			Detail = if selected ~= nil
				then React.createElement(Detail, {
					name = selected,
					locked = campaign.is_unlocked(progress.unlocks, selected) == false,
					unlocks = progress.unlocks,
					on_open = focus,
					on_close = function()
						set_selected(nil)
					end,
				})
				else nil,
		}),
	})
end

return table.freeze({
	Encyclopedia = Encyclopedia,
	EntryLink = entry_link.EntryLink,
})
