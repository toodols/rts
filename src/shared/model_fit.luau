-- Sits a model on its collider: the lowest point of the model goes on the bottom of the collider, whatever
-- the model's size and wherever its author put the pivot vertically. The server does it to the models it
-- places and the client does it to the ghosts it draws, so the two agree.

-- How far below `pivot` the lowest point of any part of the model is, along the pivot's own up axis.
-- Measured over every corner of every part, so it does not depend on how the parts are turned.
local function lowest_below_pivot(model: Model, pivot: CFrame): number
	local lowest = math.huge
	for _, descendant in model:GetDescendants() do
		if descendant:IsA "BasePart" then
			local half = descendant.Size / 2
			for _, x in { -1, 1 } do
				for _, y in { -1, 1 } do
					for _, z in { -1, 1 } do
						local corner = descendant.CFrame * Vector3.new(half.X * x, half.Y * y, half.Z * z)
						lowest = math.min(lowest, pivot:PointToObjectSpace(corner).Y)
					end
				end
			end
		end
	end
	if lowest == math.huge then
		return 0
	end
	return lowest
end

-- The entity's position is the middle of its collider, and a model is placed by putting its pivot there,
-- so the pivot is moved up the model to the point half a collider above the model's lowest point. Only
-- its height changes: where it sits across the model, and which way it faces, stay as authored. With a
-- primary part the pivot is that part's own, and it is the part's offset that has to move; setting the
-- model's world pivot would change nothing.
local function align_to_collider_bottom(model: Model, collider_height: number)
	local pivot = model:GetPivot()
	local lift = lowest_below_pivot(model, pivot) + collider_height / 2
	local primary = model.PrimaryPart
	if primary ~= nil then
		primary.PivotOffset = primary.PivotOffset * CFrame.new(0, lift, 0)
	else
		model.WorldPivot = pivot * CFrame.new(0, lift, 0)
	end
end

return table.freeze({
	align_to_collider_bottom = align_to_collider_bottom,
})
