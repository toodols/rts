-- The lobby's Skins tab: every skin this player may wear (shared/skins), one card each, the one they have equipped lit.
-- Equipping one asks the lobby server (protocol.ACTIONS.equip_skin), which keeps it for all their games; a skin cannot
-- be changed once a game has started. A developer's skin is only listed to a developer (shared/developers).

local Players = game:GetService "Players"
local ReplicatedStorage = game:GetService "ReplicatedStorage"

local React = require(ReplicatedStorage.Packages.react)

local config = require(ReplicatedStorage.Shared.config)
local developers = require(ReplicatedStorage.Shared.developers)
local skins = require(ReplicatedStorage.Shared.skins)

local protocol = require(ReplicatedStorage.Lobby.protocol)

local controls = require(script.Parent.controls)

local ACTIONS = protocol.ACTIONS

local local_player = Players.LocalPlayer

-- What each of the pool skin's floats is called on its card, by art name.
local FLOAT_NAMES: { [string]: string } = {
	pool_donut = "Striped ring",
	pool_donut_iced = "Iced donut",
	pool_lifebuoy = "Lifebuoy",
	rubber_ducky = "Rubber ducky",
}

-- `attribute` of the local player, kept up to date.
local function use_attribute(attribute: string): unknown
	local value, set_value = React.useState(local_player:GetAttribute(attribute))
	React.useEffect(function()
		set_value(local_player:GetAttribute(attribute))
		local connection = local_player:GetAttributeChangedSignal(attribute):Connect(function()
			set_value(local_player:GetAttribute(attribute))
		end)
		return function()
			connection:Disconnect()
		end
	end, { attribute })
	return value
end

-- A line on what a skin puts on the units, if it puts on something with kinds of its own: its floats, with how often
-- each turns up.
local function extras_of(skin_name: string): string?
	for _, attachment in skins.get(skin_name).attachments do
		if attachment.kind == "donut" then
			local total = 0
			for _, variant in attachment.donut.variants do
				total += variant.weight
			end
			local names = {}
			for _, variant in attachment.donut.variants do
				local share = math.round(variant.weight / total * 100)
				table.insert(names, `{FLOAT_NAMES[variant.art] or variant.art} {share}%`)
			end
			return `Floats: {table.concat(names, " · ")}`
		end
	end
	return nil
end

local function Card(props: {
	name: string,
	equipped: boolean,
	act: (action: string, argument: any?) -> (),
	LayoutOrder: number,
})
	local skin = skins.get(props.name)
	local extras = extras_of(props.name)
	return React.createElement("Frame", {
		[React.Tag] = if props.equipped then "skin-card equipped" else "skin-card",
		LayoutOrder = props.LayoutOrder,
	}, {
		Head = React.createElement("Frame", {
			[React.Tag] = "skin-head",
			LayoutOrder = 1,
		}, {
			Name = React.createElement("TextLabel", {
				[React.Tag] = "skin-name",
				LayoutOrder = 1,
				Text = string.upper(skin.display_name),
			}),
			Developer = if skin.developer_only
				then React.createElement("TextLabel", {
					[React.Tag] = "tag developer",
					LayoutOrder = 2,
					Text = "DEV",
				})
				else nil,
			Default = if props.name == config.DEFAULT_SKIN
				then React.createElement("TextLabel", {
					[React.Tag] = "tag",
					LayoutOrder = 3,
					Text = "DEFAULT",
				})
				else nil,
		}),
		Description = React.createElement("TextLabel", {
			[React.Tag] = "skin-description",
			LayoutOrder = 2,
			Text = skin.description,
		}),
		Extras = if extras ~= nil
			then React.createElement("TextLabel", {
				[React.Tag] = "skin-extras",
				LayoutOrder = 3,
				Text = extras,
			})
			else nil,
		Equip = React.createElement(controls.Button, {
			kind = "button",
			tag = if props.equipped then "equip" else "equip primary",
			label = if props.equipped then "EQUIPPED" else "EQUIP",
			locked = props.equipped,
			on_press = function()
				props.act(ACTIONS.equip_skin, props.name)
			end,
			LayoutOrder = 4,
		}),
	})
end

local function SkinsTab(props: { act: (action: string, argument: any?) -> () })
	local equipped = use_attribute "skin"
	-- read to re-render when it changes; `developers.is_developer` is what decides
	local _developer = use_attribute(developers.ATTRIBUTE)
	local equipped_name = if typeof(equipped) == "string" then equipped else config.DEFAULT_SKIN
	local developer = developers.is_developer(local_player)

	local cards: { [string]: any } = {
		Grid = React.createElement("UIGridLayout", {
			CellSize = UDim2.new(0.5, -6, 0, 168),
			CellPadding = UDim2.fromOffset(12, 12),
			SortOrder = Enum.SortOrder.LayoutOrder,
		}),
	}
	-- the default first, then the rest by name
	local order = 1
	cards[`Skin_{config.DEFAULT_SKIN}`] = React.createElement(Card, {
		name = config.DEFAULT_SKIN,
		equipped = equipped_name == config.DEFAULT_SKIN,
		act = props.act,
		LayoutOrder = order,
	})
	for _, name in skins.names() do
		if name == config.DEFAULT_SKIN or skins.may_wear(name, developer) == false then
			continue
		end
		order += 1
		cards[`Skin_{name}`] = React.createElement(Card, {
			name = name,
			equipped = name == equipped_name,
			act = props.act,
			LayoutOrder = order,
		})
	end

	return React.createElement("Frame", {
		[React.Tag] = "skins-tab panel",
	}, {
		Hint = React.createElement("TextLabel", {
			[React.Tag] = "skins-hint",
			LayoutOrder = 1,
			Text = "Locked once a game starts.",
		}),
		Cards = React.createElement("ScrollingFrame", {
			[React.Tag] = "skins-cards",
			LayoutOrder = 2,
			CanvasSize = UDim2.new(),
			AutomaticCanvasSize = Enum.AutomaticSize.Y,
			ScrollingDirection = Enum.ScrollingDirection.Y,
		}, cards),
	})
end

return table.freeze({
	SkinsTab = SkinsTab,
})
