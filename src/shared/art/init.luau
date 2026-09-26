-- Procedural art: the meshes tools/model_pipeline generates, one module per def (or skin) named after it. Every mesh
-- is uploaded to Roblox and named by its asset id (tools/model_pipeline/check_art.py fails on a module that is not).
-- The client dresses the entity itself (src/client/art.luau), and where a def has art the server's model is only an
-- invisible hitbox.
--
-- Each module holds `groups`, the model's rigid pieces, and `parts`, one mesh per material of a piece. The types below are
-- the format tools/model_pipeline/art_format.py writes, which check_art.py holds them to.

-- How a piece of a model moves (see `Group`).
export type GroupKind = "turret" | "work" | "spin" | "leg" | "wheel" | "hatch"

export type Group = {
	-- relative to the model's origin: the middle of its footprint, on the ground, facing +Z
	pivot: { number },
	-- how it moves: "turret" follows weapon `weapon`'s aim (where the weapon fires from is its def's, as
	-- `Weapon.turret_mount`, which this piece is built to agree with), "work" turns toward what a builder is working on, "spin"
	-- turns about `axis` at `speed` radians a second, and "leg" swings `swing` radians either way about `axis` (its
	-- hip), once per `stride` studs the unit walks, `phase` of a cycle apart from its other legs. Nil for a piece that
	-- holds still.
	kind: GroupKind?,
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
}

export type Part = {
	group: string,
	color: { number },
	-- where the middle of the mesh is, relative to its group's pivot, and how big it is
	offset: { number },
	size: { number },
	-- a hash of its geometry, which is what it is named by on Roblox
	hash: string,
	-- its asset id, once it has been uploaded: until every mesh of a model is, it needs uploading
	mesh: string?,
	-- glows, as Neon
	neon: boolean?,
	-- takes its team's colour, as a part named "Team" does on a hand-made model
	team: boolean?,
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
