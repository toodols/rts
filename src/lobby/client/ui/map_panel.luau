-- The lobby's map: a large picture of it with its grid, what it is, and every map to pick from. Only the host can
-- pick; everyone else sees the list but cannot change it. A co-op lobby's map is its mission's, so it has no list. BAR's
-- maps are listed only to a developer (shared/developers.luau).

local Players = game:GetService "Players"
local ReplicatedStorage = game:GetService "ReplicatedStorage"

local React = require(ReplicatedStorage.Packages.react)

local protocol = require(ReplicatedStorage.Lobby.protocol)
local developers = require(ReplicatedStorage.Shared.developers)

local map_preview = require(ReplicatedStorage.LobbyClient.map_preview)
local map_image = require(script.Parent.map_image)

type MapInfo = map_preview.MapInfo

local ACTIONS = protocol.ACTIONS

local local_player = Players.LocalPlayer

local function format_units(units: Vector2): string
	return `{math.round(units.X)} × {math.round(units.Y)}`
end

local function Fact(props: { label: string, value: string, LayoutOrder: number })
	return React.createElement("Frame", {
		[React.Tag] = "fact",
		LayoutOrder = props.LayoutOrder,
	}, {
		Label = React.createElement("TextLabel", {
			[React.Tag] = "fact-label",
			LayoutOrder = 1,
			Text = props.label,
		}),
		Value = React.createElement("TextLabel", {
			[React.Tag] = "fact-value readout",
			LayoutOrder = 2,
			Text = props.value,
		}),
	})
end

local function MapCard(props: {
	map: MapInfo,
	seed: number,
	selected: boolean,
	locked: boolean,
	players: number,
	act: (action: string, argument: any?) -> (),
	LayoutOrder: number,
})
	local tag = "map-card"
	if props.selected then
		tag ..= " active"
	end
	if props.locked then
		tag ..= " locked"
	end
	local crowded = props.players > props.map.starts

	return React.createElement("TextButton", {
		[React.Tag] = tag,
		LayoutOrder = props.LayoutOrder,
		Text = "",
		AutoButtonColor = false,
		Interactable = not props.locked,
		[React.Event.Activated] = function()
			props.act(ACTIONS.set_map, props.map.preset)
		end,
	}, {
		Thumb = React.createElement(map_image.MapImage, {
			preset = props.map.preset,
			seed = props.seed,
			grid = false,
			tag = "map-card-thumb",
			LayoutOrder = 1,
		}),
		Name = React.createElement("TextLabel", {
			[React.Tag] = "map-card-name",
			LayoutOrder = 2,
			Text = props.map.name,
		}),
		Size = React.createElement("TextLabel", {
			[React.Tag] = if crowded then "map-card-size crowded" else "map-card-size",
			LayoutOrder = 3,
			Text = `{format_units(props.map.units)} · {props.map.starts} starts`,
		}),
	})
end

local function MapPanel(
	props: {
		preset: string,
		seed: number,
		is_host: boolean,
		-- the map is a co-op mission's, and cannot be changed
		fixed: boolean,
		players: number,
		act: (action: string, argument: any?) -> (),
	}
)
	local info = map_preview.info(props.preset)

	local maps: { MapInfo } = if props.fixed then {} else map_preview.all(developers.is_developer(local_player))
	local cards: { [string]: any } = {}
	for index, map in maps do
		cards[map.preset] = React.createElement(MapCard, {
			map = map,
			seed = props.seed,
			selected = map.preset == props.preset,
			locked = not props.is_host,
			players = props.players,
			act = props.act,
			LayoutOrder = index,
		})
	end

	return React.createElement("Frame", {
		[React.Tag] = "map-panel panel",
		LayoutOrder = 1,
	}, {
		Rail = React.createElement("Frame", {
			[React.Tag] = "rail",
			LayoutOrder = 1,
		}),
		Title = React.createElement("Frame", {
			[React.Tag] = "title-row",
			LayoutOrder = 2,
		}, {
			Accent = React.createElement("Frame", {
				[React.Tag] = "accent-bar",
				LayoutOrder = 1,
			}),
			Name = React.createElement("TextLabel", {
				[React.Tag] = "heading",
				LayoutOrder = 2,
				Text = info.name,
			}),
			Source = React.createElement("TextLabel", {
				[React.Tag] = "badge",
				LayoutOrder = 3,
				Text = if info.from_bar then "BAR" else "GENERATED",
			}),
		}),
		Stage = React.createElement(map_image.MapImage, {
			preset = props.preset,
			seed = props.seed,
			grid = true,
			tag = "map-stage",
			LayoutOrder = 3,
		}),
		Facts = React.createElement("Frame", {
			[React.Tag] = "facts",
			LayoutOrder = 4,
		}, {
			Units = React.createElement(Fact, {
				label = "SIZE",
				value = format_units(info.units),
				LayoutOrder = 1,
			}),
			Studs = React.createElement(Fact, {
				label = "STUDS",
				value = `{math.round(info.size.X)} × {math.round(info.size.Y)}`,
				LayoutOrder = 2,
			}),
			Starts = React.createElement(Fact, {
				label = "STARTS",
				value = tostring(info.starts),
				LayoutOrder = 3,
			}),
			Description = React.createElement("TextLabel", {
				[React.Tag] = "map-description grow",
				LayoutOrder = 4,
				Text = info.description,
			}),
		}),
		Grid = React.createElement("TextLabel", {
			[React.Tag] = "map-grid-note faint",
			LayoutOrder = 5,
			Text = `Grid: {math.round(map_preview.UNIT_STUDS)} studs`,
		}),
		List = React.createElement("ScrollingFrame", {
			[React.Tag] = "map-list",
			LayoutOrder = 6,
		}, cards),
	})
end

return table.freeze({
	MapPanel = MapPanel,
})
