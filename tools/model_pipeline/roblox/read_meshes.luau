--!strict
-- Reads the mesh asset ids of the art models roblox/upload_art.py uploaded: only Studio can open a Model asset and see
-- the MeshId of each MeshPart in it. `record_meshes.py script` writes a copy of this with MODELS filled in; run that in
-- Studio's command bar (or through the MCP's execute_luau) in Edit mode, save its output to a file, and pass the file
-- to `record_meshes.py record`. Each model prints one line, "MESHES " and a JSON object of its name to the MeshId of
-- each of its MeshParts, which are named by the hash of their mesh.

local HttpService = game:GetService "HttpService"
local InsertService = game:GetService "InsertService"

-- each pending model's name and asset id
local MODELS: { [string]: number } = {
	--[[models]]
}

for name, asset_id in MODELS do
	local ok, model = pcall(InsertService.LoadAsset, InsertService, asset_id)
	if ok == false then
		warn(`{name}: could not load model {asset_id}: {model}`)
		continue
	end
	local meshes = {}
	for _, part in model:GetDescendants() do
		if part:IsA "MeshPart" then
			meshes[part.Name] = part.MeshId
		end
	end
	model:Destroy()
	print("MESHES " .. HttpService:JSONEncode({ [name] = meshes }))
end
