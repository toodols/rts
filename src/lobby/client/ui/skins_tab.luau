--!strict
-- The lobby's Skins tab: every skin this player may wear (shared/skins), one card each, the one they have equipped lit.
-- Equipping one asks the lobby server (its `equip_skin` action, see protocol.ACTIONS), which keeps it for all their
-- games; a skin cannot be changed once a game has started. A developer's skin is only listed to a developer (shared/developers).

local Players = game:GetService "Players"
local ReplicatedStorage = game:GetService "ReplicatedStorage"

local React = require(ReplicatedStorage.Packages.react)

local developers = require(ReplicatedStorage.Shared.developers)
local skins = require(ReplicatedStorage.Shared.skins)

local protocol = require(ReplicatedStorage.Lobby.protocol)

local use_store = require(ReplicatedStorage.ClientShared.use_store)

local controls = require(script.Parent.controls)

local local_player = Players.LocalPlayer

-- What each of the pool skin's floats is called on its card, by art name.
local FLOAT_NAMES: { [string]: string } = {
	pool_donut = "Striped ring",
	pool_donut_iced = "Iced donut",
	pool_lifebuoy = "Lifebuoy",
	rubber_ducky = "Rubber ducky",
}

-- The skin the local player has equipped and whether they are a developer, kept up to date.
local function use_wearer(): (string, boolean)
	use_store.use_changes(function(redraw: () -> ()): () -> ()
		local stop_skin = skins.equipped_changed(local_player, redraw)
		local stop_developer = developers.changed(local_player, redraw)
		return function()
			stop_skin()
			stop_developer()
		end
	end)
	return skins.equipped_by(local_player), developers.is_developer(local_player)
end

-- A line on what a skin puts on the units, if it puts on something with kinds of its own: its floats, with how often
-- each turns up.
local function extras_of(skin_name: string): string?
	local donut = skins.get(skin_name).donut
	if donut == nil then
		return nil
	end
	local total = 0
	for _, variant in donut.variants do
		total += variant.weight
	end
	local names = {}
	for _, variant in donut.variants do
		local share = math.round(variant.weight / total * 100)
		table.insert(names, `{FLOAT_NAMES[variant.art] or variant.art} {share}%`)
	end
	return `Floats: {table.concat(names, " · ")}`
end

local function Card(props: {
	name: string,
	equipped: boolean,
	act: (action: protocol.Action, argument: any?) -> (),
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
			Default = if props.name == skins.DEFAULT_SKIN
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
				props.act("equip_skin", props.name)
			end,
			LayoutOrder = 4,
		}),
	})
end

local function SkinsTab(props: { act: (action: protocol.Action, argument: any?) -> () })
	local equipped_name, developer = use_wearer()

	local cards: { [string]: any } = {
		Grid = React.createElement("UIGridLayout", {
			CellSize = UDim2.new(0.5, -6, 0, 168),
			CellPadding = UDim2.fromOffset(12, 12),
			SortOrder = Enum.SortOrder.LayoutOrder,
		}),
	}
	-- the default first, then the rest by name
	local order = 1
	cards[`Skin_{skins.DEFAULT_SKIN}`] = React.createElement(Card, {
		name = skins.DEFAULT_SKIN,
		equipped = equipped_name == skins.DEFAULT_SKIN,
		act = props.act,
		LayoutOrder = order,
	})
	for _, name in skins.names() do
		if name == skins.DEFAULT_SKIN or skins.may_wear(name, developer) == false then
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
