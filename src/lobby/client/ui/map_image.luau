--!strict
-- A map's picture, fitted into whatever box it is put in without being stretched: as wide against as deep as the map
-- is, and centred. With `grid`, a line is drawn over it every BAR map unit (512 elmos), the unit BAR gives map sizes
-- in, so two maps' grids side by side show which is bigger and by how much.

local ReplicatedStorage = game:GetService "ReplicatedStorage"

local React = require(ReplicatedStorage.Packages.react)

local map_presets = require(ReplicatedStorage.Shared.map_presets)

local map_preview = require(ReplicatedStorage.LobbyClient.map_preview)

local function grid_lines(units: Vector2): { [string]: any }
	local lines = {}
	for step = 1, math.ceil(units.X) - 1 do
		lines[`Column{step}`] = React.createElement("Frame", {
			[React.Tag] = "grid-line column",
			Position = UDim2.fromScale(step / units.X, 0),
		})
	end
	for step = 1, math.ceil(units.Y) - 1 do
		lines[`Row{step}`] = React.createElement("Frame", {
			[React.Tag] = "grid-line row",
			Position = UDim2.fromScale(0, step / units.Y),
		})
	end
	return lines
end

local function MapImage(
	props: {
		preset: string,
		seed: number,
		grid: boolean,
		-- the box it is fitted into
		tag: string,
		LayoutOrder: number?,
	}
)
	local preset = map_presets.presets[props.preset]
	local image = map_preview.use_image(props.preset, props.seed)

	local children: { [string]: any } = {
		Aspect = React.createElement("UIAspectRatioConstraint", {
			AspectRatio = preset.size.X / preset.size.Y,
			AspectType = Enum.AspectType.FitWithinMaxSize,
			DominantAxis = Enum.DominantAxis.Width,
		}),
		Picture = React.createElement("ImageLabel", {
			[React.Tag] = "map-picture",
			ImageContent = if image ~= nil then Content.fromObject(image) else Content.none,
		}),
	}
	if image == nil then
		children.Drawing = React.createElement("TextLabel", {
			[React.Tag] = "map-drawing",
			Text = "Drawing map...",
		})
	end
	if props.grid then
		children.Grid = React.createElement("Frame", {
			[React.Tag] = "map-grid",
		}, grid_lines(map_preview.units_of(preset)))
	end

	return React.createElement("Frame", {
		[React.Tag] = props.tag,
		LayoutOrder = props.LayoutOrder,
	}, {
		Fit = React.createElement("Frame", {
			[React.Tag] = "map-fit",
		}, children),
	})
end

return table.freeze({
	MapImage = MapImage,
})
