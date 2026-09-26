--!strict
-- The lobby's map: a large picture of it with its grid, what it is, and every map to pick from. Only the host can
-- pick; everyone else sees the list but cannot change it. A co-op lobby's map is its mission's, so it has no list. BAR's
-- maps are listed only to a developer (shared/developers.luau).

local Players = game:GetService "Players"
local ReplicatedStorage = game:GetService "ReplicatedStorage"

local React = require(ReplicatedStorage.Packages.react)

local protocol = require(ReplicatedStorage.Lobby.protocol)
local world_scale = require(ReplicatedStorage.Shared.world_scale)
local developers = require(ReplicatedStorage.Shared.developers)
local map_presets = require(ReplicatedStorage.Shared.map_presets)

local map_preview = require(ReplicatedStorage.LobbyClient.map_preview)
local map_image = require(script.Parent.map_image)

type Preset = map_presets.Preset

-- An element's properties: strict mode cannot type a table of them that mixes tags, properties and handlers.
type Props = { [any]: any }

-- What the badge by a map's name says of where it comes from.
local SOURCE_BADGES: { [map_presets.PresetSource]: string } = {
	bar = "BAR",
	design = "DESIGNED",
	generated = "GENERATED",
}

local local_player = Players.LocalPlayer

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
	map: Preset,
	seed: number,
	selected: boolean,
	locked: boolean,
	players: number,
	act: (action: protocol.Action, argument: any?) -> (),
	LayoutOrder: number,
})
	local tag = "map-card"
	if props.selected then
		tag ..= " active"
	end
	if props.locked then
		tag ..= " locked"
	end
	local starts = #props.map.starts
	local crowded = props.players > starts

	return React.createElement(
		"TextButton",
		{
			[React.Tag] = tag,
			LayoutOrder = props.LayoutOrder,
			Text = "",
			AutoButtonColor = false,
			Interactable = not props.locked,
			[React.Event.Activated] = function()
				props.act("set_map", props.map.name)
			end,
		} :: Props,
		{
			Thumb = React.createElement(map_image.MapImage, {
				preset = props.map.name,
				seed = props.seed,
				grid = false,
				tag = "map-card-thumb",
				LayoutOrder = 1,
			}),
			Name = React.createElement("TextLabel", {
				[React.Tag] = "map-card-name",
				LayoutOrder = 2,
				Text = props.map.display_name,
			}),
			Size = React.createElement("TextLabel", {
				[React.Tag] = if crowded then "map-card-size crowded" else "map-card-size",
				LayoutOrder = 3,
				Text = `{map_preview.units_text(props.map)} · {starts} starts`,
			}),
		}
	)
end

local function MapPanel(
	props: {
		preset: string,
		seed: number,
		is_host: boolean,
		-- the map is a co-op mission's, and cannot be changed
		fixed: boolean,
		players: number,
		act: (action: protocol.Action, argument: any?) -> (),
	}
)
	local preset = map_presets.presets[props.preset]

	local maps: { Preset } = if props.fixed
		then {}
		else map_presets.lobby_choices(developers.is_developer(local_player))
	local cards: { [string]: any } = {}
	for index, map in maps do
		cards[map.name] = React.createElement(MapCard, {
			map = map,
			seed = props.seed,
			selected = map.name == props.preset,
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
				Text = preset.display_name,
			}),
			Source = React.createElement("TextLabel", {
				[React.Tag] = "badge",
				LayoutOrder = 3,
				Text = SOURCE_BADGES[preset.source],
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
				value = map_preview.units_text(preset),
				LayoutOrder = 1,
			}),
			Studs = React.createElement(Fact, {
				label = "STUDS",
				value = `{math.round(preset.size.X)} × {math.round(preset.size.Y)}`,
				LayoutOrder = 2,
			}),
			Starts = React.createElement(Fact, {
				label = "STARTS",
				value = tostring(#preset.starts),
				LayoutOrder = 3,
			}),
			Description = React.createElement("TextLabel", {
				[React.Tag] = "map-description grow",
				LayoutOrder = 4,
				Text = preset.description,
			}),
		}),
		Grid = React.createElement("TextLabel", {
			[React.Tag] = "map-grid-note faint",
			LayoutOrder = 5,
			Text = `Grid: {math.round(world_scale.MAP_UNIT_STUDS)} studs`,
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
