-- Tooltips: a card of detail that appears beside a panel while the cursor is over one of its rows.
--
-- The card is portalled into the HUD's ScreenGui (`Layer`, provided by ui/init.luau) rather than drawn inside the
-- row, so the panel it came from neither clips it nor has to make room for it. It stands just past the right edge of
-- the panel it belongs to (or before its left edge, for a panel on the right of the screen), level with the bottom of
-- the row, and goes when the cursor leaves the row.

local CollectionService = game:GetService "CollectionService"
local ReplicatedStorage = game:GetService "ReplicatedStorage"

local React = require(ReplicatedStorage.Packages.react)
local ReactRoblox = require(ReplicatedStorage.Packages["react-roblox"])

local unit_facts = require(ReplicatedStorage.Shared.unit_facts)

local use_viewport = require(ReplicatedStorage.Client.ui.use_viewport)

-- How far from the panel's edge the card stands.
local GAP = 10

-- Where tooltips go: the HUD's ScreenGui.
local Layer = React.createContext(nil :: Instance?)

-- `divider` draws a rule above the row, to set off a total from what it adds up; `headline` is unit_facts.Row's.
export type Row = unit_facts.Row

export type Content = {
	title: string,
	-- a word or two over the title, saying what kind of thing this is
	kicker: string?,
	-- a tone class for the title and the card's edge: "weapon", "build", "metal", "energy", "danger"
	tone: string?,
	text: string?,
	rows: { Row }?,
	notes: { string }?,
}

-- The panel a row sits in, which the card stands beside: its nearest ancestor tagged `panel`, or the row itself.
local function panel_of(instance: GuiObject): GuiObject
	local at: Instance? = instance
	while at ~= nil do
		if at:IsA "GuiObject" and CollectionService:HasTag(at, "panel") then
			return at
		end
		at = at.Parent
	end
	return instance
end

local function Card(props: { content: Content })
	local content = props.content
	local tone = content.tone or "plain"

	local rows = {}
	for index, row in content.rows or {} do
		if row.divider then
			rows[`Divider{index}`] = React.createElement("Frame", {
				[React.Tag] = "tooltip-divider",
				LayoutOrder = index * 2 - 1,
			})
		end
		rows[`Row{index}`] = React.createElement("Frame", {
			[React.Tag] = "tooltip-row",
			LayoutOrder = index * 2,
		}, {
			Label = React.createElement("TextLabel", {
				[React.Tag] = "tooltip-label",
				LayoutOrder = 1,
				Text = row.label,
			}),
			Value = React.createElement("TextLabel", {
				[React.Tag] = if row.tag ~= nil then `tooltip-value {row.tag}` else "tooltip-value",
				LayoutOrder = 2,
				Text = row.value,
			}),
		})
	end

	local notes = {}
	for index, note in content.notes or {} do
		notes[`Note{index}`] = React.createElement("TextLabel", {
			[React.Tag] = "tooltip-note",
			LayoutOrder = index,
			Text = `· {note}`,
		})
	end

	return React.createElement(React.Fragment, {}, {
		Rail = React.createElement("Frame", {
			[React.Tag] = `tooltip-rail tooltip-{tone}`,
			LayoutOrder = 0,
		}),
		Kicker = if content.kicker ~= nil
			then React.createElement("TextLabel", {
				[React.Tag] = "tooltip-kicker",
				LayoutOrder = 1,
				Text = content.kicker,
			})
			else nil,
		Title = React.createElement("TextLabel", {
			[React.Tag] = `tooltip-title tooltip-{tone}`,
			LayoutOrder = 2,
			Text = content.title,
		}),
		Text = if content.text ~= nil
			then React.createElement("TextLabel", {
				[React.Tag] = "tooltip-text",
				LayoutOrder = 3,
				Text = content.text,
			})
			else nil,
		Rows = if next(rows) ~= nil
			then React.createElement("Frame", {
				[React.Tag] = "tooltip-rows",
				LayoutOrder = 4,
			}, rows)
			else nil,
		Notes = if next(notes) ~= nil
			then React.createElement("Frame", {
				[React.Tag] = "tooltip-notes",
				LayoutOrder = 5,
			}, notes)
			else nil,
	})
end

-- Which side of its panel a card stands: "right" past its right edge, or "left" before its left edge, for a panel
-- docked on the right of the screen.
export type Side = "left" | "right"

export type Tooltip = {
	-- call with the hovered frame when the cursor comes onto it, and when it leaves
	on_enter: (frame: GuiObject) -> (),
	on_leave: () -> (),
	-- the card, portalled into the HUD, while it is shown; render it anywhere among the frame's children
	card: any?,
}

-- Shows `content` in a card beside the panel of whatever frame `on_enter` is called with, until `on_leave` is. For a
-- frame that is already something else, a button say, rather than one WithTooltip makes. `content` is a function so
-- that what goes in the card is only worked out while it is shown.
local function use_tooltip(content: () -> Content, side: Side?): Tooltip
	local layer = React.useContext(Layer)
	local ui_scale = use_viewport.use_ui_scale()
	-- where the card's bottom corner nearest the panel goes, while it is shown
	local at, set_at = React.useState(nil :: Vector2?)
	local left = side == "left"

	local card = nil
	if at ~= nil and layer ~= nil then
		card = ReactRoblox.createPortal(
			React.createElement("Frame", {
				[React.Tag] = "tooltip",
				AnchorPoint = Vector2.new(if left then 1 else 0, 1),
				Position = UDim2.fromOffset(at.X, at.Y),
			}, {
				Scale = React.createElement("UIScale", { Scale = ui_scale }),
				Card = React.createElement(Card, { content = content() }),
			}),
			layer
		)
	end

	return {
		on_enter = function(frame: GuiObject)
			local panel = panel_of(frame)
			local x = if left
				then panel.AbsolutePosition.X - GAP
				else panel.AbsolutePosition.X + panel.AbsoluteSize.X + GAP
			set_at(Vector2.new(x, frame.AbsolutePosition.Y + frame.AbsoluteSize.Y))
		end,
		on_leave = function()
			set_at(nil)
		end,
		card = card,
	}
end

-- A frame that shows `content` in a card beside its panel while the cursor is over it. `content` is a function so
-- that what goes in the card is only worked out while it is shown.
local function WithTooltip(props: {
	tag: string,
	LayoutOrder: number?,
	content: () -> Content,
	side: Side?,
	children: any?,
})
	local tip = use_tooltip(props.content, props.side)

	return React.createElement("Frame", {
		[React.Tag] = props.tag,
		LayoutOrder = props.LayoutOrder,
		[React.Event.MouseEnter] = tip.on_enter,
		[React.Event.MouseLeave] = tip.on_leave,
	}, {
		Children = React.createElement(React.Fragment, {}, props.children),
		Card = tip.card,
	})
end

return table.freeze({
	Layer = Layer,
	WithTooltip = WithTooltip,
	use_tooltip = use_tooltip,
})
