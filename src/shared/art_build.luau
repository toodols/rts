--!strict
-- Turning art (Shared.art's format, which Shared.ui_art and Shared.reclaimable_art share) into MeshParts, the one way
-- every place that shows art does it: the client's entities, ghosts, pictures and pool donuts, the lobby's scene and
-- encyclopedia (all through ClientShared.art_models), and the server's reclaimables (server/instances.luau). A team
-- part is then coloured by Shared.appearance's `team_tint`, wherever it is shown.
--
-- Roblox's importer turns every mesh uploaded from the pipeline's .glb half a turn about its own vertical axis (it faces
-- glTF's +Z the other way), so each mesh is turned back by as much (UPLOADED_TURN) where it is placed.

local AssetService = game:GetService "AssetService"
local ReplicatedStorage = game:GetService "ReplicatedStorage"

local art = require(ReplicatedStorage.Shared.art)

type Group = art.Group
type Part = art.Part

local UPLOADED_TURN = CFrame.Angles(0, math.pi, 0)
-- The material every mesh that does not glow is drawn in.
local MATERIAL = Enum.Material.SmoothPlastic

local function vector(values: { number }): Vector3
	return Vector3.new(values[1], values[2], values[3])
end

-- How a group's pieces are turned from rest when it is at `angle` (radians): a turret or a builder's head about the
-- vertical, anything that spins about its axis, and a leg, a wheel or a hatch about its own (by default across, its
-- hip or its axle); a piece that holds still not at all.
local function turn_of_group(group: Group, angle: number): CFrame
	local kind = group.kind
	if kind == "spin" then
		return CFrame.fromAxisAngle(vector(group.axis or { 0, 1, 0 }), angle)
	elseif kind == "turret" or kind == "work" then
		return CFrame.Angles(0, angle, 0)
	elseif kind == "leg" or kind == "wheel" or kind == "hatch" then
		return CFrame.fromAxisAngle(vector(group.axis or { 1, 0, 0 }), angle)
	end
	return CFrame.identity
end

-- A MeshPart of `content` for `part`: sized to the part's own bounds, whatever units it was imported in, in the part's
-- material and own colour, anchored and out of every collision, touch and query. It yields.
local function mesh_part(content: Content, part: Part): MeshPart
	local mesh = AssetService:CreateMeshPartAsync(content, { CollisionFidelity = Enum.CollisionFidelity.Box })
	mesh.Name = part.group
	mesh.Anchored = true
	mesh.CanCollide = false
	mesh.CanTouch = false
	mesh.CanQuery = false
	mesh.Material = if part.neon == true then Enum.Material.Neon else MATERIAL
	mesh.Color = Color3.new(part.color[1], part.color[2], part.color[3])
	mesh.Size = vector(part.size)
	return mesh
end

-- `part`'s uploaded mesh, fetched (`mesh_part`). It yields, and errors if the part is not uploaded or will not fetch.
local function fetch(part: Part): MeshPart
	local uri = part.mesh
	if uri == nil then
		error(`part {part.hash} is not uploaded (tools/model_pipeline/roblox/upload_art.py)`)
	end
	return mesh_part(Content.fromUri(uri), part)
end

-- `build` called on every one of `parts` at once, each in a thread of its own so that their meshes are fetched
-- together, and what each returned, in order. It yields until all have returned, and errors with the first error any
-- of them raised.
local function build_all<T>(parts: { Part }, build: (Part) -> T): { T }
	local results: { T } = table.create(#parts)
	local problem: string? = nil
	local remaining = #parts
	local waiting = coroutine.running()
	for index, part in parts do
		task.spawn(function()
			local ok, result = pcall(build, part)
			if ok then
				results[index] = result
			elseif problem == nil then
				problem = tostring(result)
			end
			remaining -= 1
			if remaining == 0 and coroutine.status(waiting) == "suspended" then
				task.spawn(waiting)
			end
		end)
	end
	if remaining > 0 then
		coroutine.yield()
	end
	if problem ~= nil then
		error(problem)
	end
	return results
end

return table.freeze({
	UPLOADED_TURN = UPLOADED_TURN,
	MATERIAL = MATERIAL,
	vector = vector,
	turn_of_group = turn_of_group,
	fetch = fetch,
	build_all = build_all,
})
