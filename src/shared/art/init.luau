-- Procedural art: the meshes tools/model_pipeline generates for a def, one module per def, named after it. A
-- mesh that has been uploaded to Roblox is named by its asset id; one that has not carries its vertices, and the
-- client builds it with EditableMesh. Either way the client dresses the entity itself (src/client/art.luau), and
-- where a def has art the server's model is only an invisible hitbox.
--
-- Each module holds `groups`, the model's rigid pieces, and `parts`, one mesh per material of a piece. See
-- build.py's export_art for the format.

export type Group = {
	-- relative to the model's origin: the middle of its footprint, on the ground, facing +Z
	pivot: { number },
	-- how it moves: "turret" follows weapon `weapon`'s aim, "work" turns toward what a builder is working on, "spin"
	-- turns about `axis` at `speed` radians a second, and "leg" swings `swing` radians either way about `axis` (its
	-- hip), once per `stride` studs the unit walks, `phase` of a cycle apart from its other legs. Nil for a piece that
	-- holds still.
	kind: string?,
	weapon: number?,
	axis: { number }?,
	speed: number?,
	swing: number?,
	phase: number?,
	stride: number?,
	-- a "wheel" rolls about `axis` by the distance driven over `radius`; a "hatch" swings `open` radians about
	-- `axis` when weapon `weapon` fires
	radius: number?,
	open: number?,
	-- for a "turret", where its weapon fires from, relative to its pivot and at rest (the server's weapon_origin)
	muzzle: { number }?,
}

export type Part = {
	group: string,
	color: { number },
	-- where the middle of the mesh is, relative to its group's pivot, and how big it is
	offset: { number },
	size: { number },
	-- a hash of its geometry, which is what it is named by on Roblox
	hash: string,
	-- its asset id, once it has been uploaded; until then, its vertices and triangles
	mesh: string?,
	-- glows, as Neon
	neon: boolean?,
	-- takes its team's colour, as a part named "Team" does on a hand-made model
	team: boolean?,
	vertices: string?,
	triangles: string?,
}

export type Art = {
	groups: { [string]: Group },
	parts: { Part },
}

local loaded: { [string]: Art | false } = {}

-- The art for `def_name`, or nil if it has none.
local function get(def_name: string): Art?
	local cached = loaded[def_name]
	if cached ~= nil then
		return if cached == false then nil else cached
	end
	local module = script:FindFirstChild(def_name)
	if module == nil or module:IsA "ModuleScript" == false then
		loaded[def_name] = false
		return nil
	end
	local art = (require :: any)(module) :: Art
	loaded[def_name] = art
	return art
end

-- Whether `def_name` has art, without loading it. Asked every frame for every entity on the client, so it is kept.
local known: { [string]: boolean } = {}
local function has(def_name: string): boolean
	local cached = known[def_name]
	if cached ~= nil then
		return cached
	end
	local module = script:FindFirstChild(def_name)
	local found = module ~= nil and module:IsA "ModuleScript"
	known[def_name] = found
	return found
end

-- Every def that has art, by name.
local function names(): { string }
	local found = {}
	for _, module in script:GetChildren() do
		if module:IsA "ModuleScript" then
			table.insert(found, module.Name)
		end
	end
	return found
end

-- How tall `def_name`'s art stands from the ground, or nil if it has none, taken from where each of its meshes sits
-- at rest. Art can stand taller than its collider (the commander does), which is what bars drawn over it need.
local heights: { [string]: number | false } = {}
local function height(def_name: string): number?
	local cached = heights[def_name]
	if cached ~= nil then
		return if cached == false then nil else cached
	end
	local data = if has(def_name) then get(def_name) else nil
	if data == nil then
		heights[def_name] = false
		return nil
	end
	local top = 0
	for _, part in data.parts do
		local pivot = data.groups[part.group].pivot
		top = math.max(top, pivot[2] + part.offset[2] + part.size[2] / 2)
	end
	heights[def_name] = top
	return top
end

return table.freeze({
	get = get,
	has = has,
	names = names,
	height = height,
})
