--!strict
-- The client's built art, for everything it shows art in: the entities' own (Client.art), build ghosts, the pool
-- donuts, every picture of a def or of the HUD's own art (unit_picture, art_icon), and the lobby's scene. Art is found
-- by name, in Shared.art (a def's, a skin's, a pool donut's) or else in Shared.ui_art (the HUD's keys, cursor and
-- icons). Each is built once, the first time anything asks for it (Shared.art_build: its meshes fetched all at once),
-- and whatever shows it copies its meshes. Every mesh is uploaded (tools/model_pipeline): art with one that is not fails
-- to build, and shows nothing.

local ReplicatedStorage = game:GetService "ReplicatedStorage"

local appearance = require(ReplicatedStorage.Shared.appearance)
local art = require(ReplicatedStorage.Shared.art)
local art_build = require(ReplicatedStorage.Shared.art_build)
local signal = require(ReplicatedStorage.Shared.signal)
local unit_defs = require(ReplicatedStorage.Shared.unit_defs)

type Art = art.Art
type Part = art.Part
type Signal<T...> = signal.Signal<T...>

-- "building" also covers art that is there to be built and has not been asked for yet.
export type Status = "ready" | "building" | "missing" | "failed"

-- One mesh of some art, built: a MeshPart to copy, what group it belongs to, where it sits relative to that group's
-- pivot (`position`, turned by `turn`: `offset` is the two together) and where at rest relative to the art's origin
-- (`rest`), how big it is, its own colour, and whether it glows or takes its team's colour.
export type TemplatePart = {
	mesh: MeshPart,
	group: string,
	position: Vector3,
	turn: CFrame,
	offset: CFrame,
	rest: CFrame,
	size: Vector3,
	color: Color3,
	neon: boolean,
	team: boolean,
}

export type Template = {
	name: string,
	art: Art,
	parts: { TemplatePart },
}

local templates: { [string]: Template } = {}
local building: { [string]: boolean } = {}
local failed: { [string]: boolean } = {}
-- told once the art of that name has been built, or has failed to be
local finished: { [string]: Signal<> } = {}

-- The art called `name`, or nil if there is none.
local function data_of(name: string): Art?
	if art.has(name) then
		return art.get(name)
	end
	local folder = ReplicatedStorage.Shared:FindFirstChild "ui_art"
	local module = if folder ~= nil then folder:FindFirstChild(name) else nil
	if module == nil or module:IsA "ModuleScript" == false then
		return nil
	end
	return (require :: any)(module) :: Art
end

local function status(name: string): Status
	if templates[name] ~= nil then
		return "ready"
	elseif building[name] == true then
		return "building"
	elseif failed[name] == true then
		return "failed"
	elseif data_of(name) == nil then
		return "missing"
	end
	return "building"
end

-- Starts building the art called `name`, once. It builds in a thread of its own.
local function build(name: string)
	if templates[name] ~= nil or building[name] == true or failed[name] == true then
		return
	end
	local data = data_of(name)
	if data == nil then
		return
	end
	building[name] = true
	task.spawn(function()
		type Built = { part: Part, mesh: MeshPart }
		local ok, result = pcall(art_build.build_all, data.parts, function(part: Part): Built
			return { part = part, mesh = art_build.fetch(part) }
		end)
		building[name] = nil
		if ok then
			local parts: { TemplatePart } = table.create(#data.parts)
			for _, built in result :: { Built } do
				local part = built.part
				local group = data.groups[part.group]
				local pivot = if group ~= nil then CFrame.new(art_build.vector(group.pivot)) else CFrame.identity
				local position = art_build.vector(part.offset)
				local turn = art_build.UPLOADED_TURN
				table.insert(parts, {
					mesh = built.mesh,
					group = part.group,
					position = position,
					turn = turn,
					offset = CFrame.new(position) * turn,
					rest = pivot * CFrame.new(position) * turn,
					size = built.mesh.Size,
					color = built.mesh.Color,
					neon = part.neon == true,
					team = part.team == true,
				})
			end
			templates[name] = { name = name, art = data, parts = parts }
		else
			-- nothing is shown in this art: an entity stays an invisible hitbox and a picture falls back, so say why once
			failed[name] = true
			warn(`could not build the art {name}: {result}`)
		end
		local done = finished[name]
		finished[name] = nil
		if done ~= nil then
			done.fire()
		end
	end)
end

-- The art called `name`, built, or nil while it is not (`status` says why); asking starts it building.
local function template(name: string): Template?
	local found = templates[name]
	if found == nil then
		build(name)
	end
	return found
end

-- Calls `callback` once the art called `name` has been built or has failed, starting it building if it had not yet.
-- Only for art whose status is "building". Returns a function that cancels the call.
local function when_built(name: string, callback: () -> ()): () -> ()
	local done = finished[name]
	if done == nil then
		done = signal.new()
		finished[name] = done
	end
	local cancel = done.subscribe(callback)
	build(name)
	return cancel
end

-- The art called `name`, built, waiting for it if it is still being built: nil only if there is none or it failed.
-- It yields.
local function await(name: string): Template?
	local found = template(name)
	if found ~= nil or status(name) ~= "building" then
		return found
	end
	local thread = coroutine.running()
	when_built(name, function()
		task.spawn(thread)
	end)
	coroutine.yield()
	return templates[name]
end

-- A copy of each mesh of the art called `name` at rest, its origin at the origin, in the order of its template's
-- parts and each named after its group, parented to nothing; or nil while there is none (`status`). Given a `team`,
-- `name` is a def's art, and its team parts take the team's colour.
local function copy_parts(name: string, team: Color3?): { MeshPart }?
	local found = template(name)
	if found == nil then
		return nil
	end
	local def_color = if team ~= nil then unit_defs.get(name).color else nil
	local parts = table.create(#found.parts)
	for _, source in found.parts do
		local part = source.mesh:Clone()
		part.CFrame = source.rest
		if def_color ~= nil and source.team then
			part.Color = appearance.team_tint(def_color, team :: Color3)
		end
		table.insert(parts, part)
	end
	return parts
end

-- The same copy as a model of its own, its pivot at the art's origin.
local function copy(name: string, team: Color3?): Model?
	local parts = copy_parts(name, team)
	if parts == nil then
		return nil
	end
	local model = Instance.new "Model"
	model.Name = name
	for _, part in parts do
		part.Parent = model
	end
	model.WorldPivot = CFrame.identity
	return model
end

-- Builds all of `names` at once, and returns when every one is built, or failed, or `timeout` seconds have gone by,
-- whichever is first, with the names of any still not built.
local function preload(names: { string }, timeout: number): { string }
	for _, name in names do
		build(name)
	end
	local deadline = os.clock() + timeout
	while os.clock() < deadline do
		local waiting = false
		for _, name in names do
			if building[name] == true then
				waiting = true
				break
			end
		end
		if waiting == false then
			break
		end
		task.wait()
	end
	local missing = {}
	for _, name in names do
		if templates[name] == nil then
			table.insert(missing, name)
		end
	end
	return missing
end

return table.freeze({
	status = status,
	template = template,
	await = await,
	when_built = when_built,
	copy_parts = copy_parts,
	copy = copy,
	preload = preload,
})
