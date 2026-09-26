-- Loads the game's own modules, from src/ as they are, into the stand-in's DataModel (engine.luau), laid out the way the
-- Rojo project lays them out, so that `require(script.Parent.state)` and `require(ReplicatedStorage.Shared.tick_rate)`
-- find what they find in Roblox.
--
-- Each module is compiled as it is, with two changes that leave its lines where they are:
--
-- - Before its first line, on that same line, the Roblox globals it may use (`game`, `script`, `require`, `Vector3`,
--   `typeof`, `task`...) are brought in as locals, from engine.luau and datatypes.luau.
-- - The few things a Roblox Vector3 answers that Luau's own vector does not are rewritten (vector_rewrite.luau).
--
-- A module can also be swapped for a stand-in (`stand_ins`), which a session does only for the ones that draw the game
-- for players (terrain, the entities' models) and have nothing to do with how it plays.

local fs = require "@lune/fs"
local luau = require "@lune/luau"
local serde = require "@lune/serde"

local engine = require "./engine"
local datatypes = require "./datatypes"
local vector_rewrite = require "./vector_rewrite"

-- Loading -----------------------------------------------------------------------------------------------------------

-- The globals a module is given, in the order the header below brings them in.
local GLOBAL_NAMES = {
	"__vector",
	"game",
	"workspace",
	"script",
	"require",
	"Instance",
	"Vector3",
	"Vector2",
	"CFrame",
	"Random",
	"typeof",
	"task",
	"warn",
	"Color3",
	"BrickColor",
	"Enum",
	"UDim",
	"UDim2",
	"NumberRange",
	"NumberSequence",
	"NumberSequenceKeypoint",
	"ColorSequence",
	"ColorSequenceKeypoint",
	"Rect",
	"Font",
	"PhysicalProperties",
	"Faces",
	"Axes",
	"Vector3int16",
	"Vector2int16",
	"tick",
	"time",
}

local HEADER = `local __globals = ...; local {table.concat(GLOBAL_NAMES, ", ")} = `
do
	local reads = {}
	for index, name in GLOBAL_NAMES do
		reads[index] = `__globals.{name}`
	end
	HEADER ..= table.concat(reads, ", ") .. "; "
end

local shared_globals: { [string]: any } = {
	__vector = datatypes.vector_methods,
	game = engine.game,
	workspace = engine.workspace,
	Instance = engine.Instance,
	Vector3 = datatypes.Vector3,
	Vector2 = datatypes.Vector2,
	CFrame = datatypes.CFrame,
	Random = datatypes.Random,
	typeof = datatypes.typeof,
	task = engine.task,
	-- the game's warnings are kept out of a match's output, which is its result
	warn = function() end,
	Color3 = datatypes.Color3,
	BrickColor = datatypes.BrickColor,
	Enum = datatypes.Enum,
	UDim = datatypes.UDim,
	UDim2 = datatypes.UDim2,
	NumberRange = datatypes.NumberRange,
	NumberSequence = datatypes.NumberSequence,
	NumberSequenceKeypoint = datatypes.NumberSequenceKeypoint,
	ColorSequence = datatypes.ColorSequence,
	ColorSequenceKeypoint = datatypes.ColorSequenceKeypoint,
	Rect = datatypes.Rect,
	Font = datatypes.Font,
	PhysicalProperties = datatypes.PhysicalProperties,
	Faces = datatypes.Faces,
	Axes = datatypes.Axes,
	Vector3int16 = datatypes.Vector3int16,
	Vector2int16 = datatypes.Vector2int16,
	tick = os.clock,
	time = os.clock,
}

-- each module's file, what it returned once it has run, and the stand-ins
local files: { [any]: string } = {}
local loaded: { [any]: any } = {}
local loading: { [any]: boolean } = {}
local stand_ins: { [string]: any } = {}

local require_module: (any) -> any

local function globals_for(script: any): { [string]: any }
	local globals = table.clone(shared_globals)
	globals.script = script
	globals.require = require_module
	return globals
end

require_module = function(module: any): any
	if type(module) == "string" then
		-- a path, as Lune's own require takes
		return require(module)
	end
	local cached = loaded[module]
	if cached ~= nil then
		return cached
	end
	local path = files[module]
	if path == nil then
		error(`require of {module} headless, which has no source`)
	end
	local stand_in = stand_ins[path]
	if stand_in ~= nil then
		loaded[module] = stand_in
		return stand_in
	end
	assert(loading[module] == nil, `{path} requires itself, round a cycle`)
	loading[module] = true
	local original = fs.readFile(path)
	-- Studio compiles without optimisation, which counts every constant against a function's 200 locals, so a module
	-- that only loads optimised would play here and fail to load there: compile it as Studio does first.
	local ok, problem = pcall(luau.compile, original, { optimizationLevel = 0 })
	if not ok then
		error(`{path} would not load in Studio: {problem}`)
	end
	local source = HEADER .. vector_rewrite.rewrite(original, path)
	local chunk = luau.load(source, { debugName = path, codegenEnabled = true })
	local result = chunk(globals_for(module))
	loading[module] = nil
	loaded[module] = result
	return result
end

-- The files that make a directory a script of its own, as Rojo reads them, the first there is.
local INIT_FILES = { "init.luau", "init.lua", "init.server.luau", "init.server.lua" }

-- The instance Rojo makes of the directory at `path`, named `name`: a script of its init file, if it has one (a server
-- script for an init.server file), and otherwise a folder.
local function directory_instance(path: string, name: string): any
	for _, candidate in INIT_FILES do
		if fs.isFile(`{path}/{candidate}`) then
			local child =
				engine.new_instance(if string.find(candidate, "server") then "Script" else "ModuleScript", name)
			files[child] = `{path}/{candidate}`
			return child
		end
	end
	return engine.new_instance("Folder", name)
end

-- Lays the directory `directory` out under `parent` as Rojo does: a module for each .luau file, a folder for each
-- directory (or a module, if it has an init.luau), and a remote event or the like for each .model.json.
local function lay_out(parent: any, directory: string)
	local names = fs.readDir(directory)
	table.sort(names)
	for _, name in names do
		local path = `{directory}/{name}`
		if fs.isDir(path) then
			local child = directory_instance(path, name)
			child.Parent = parent
			lay_out(child, path)
			continue
		end
		if table.find(INIT_FILES, name) ~= nil then
			continue
		end
		local base, extension = string.match(name, "^(.-)%.([%w%.]+)$")
		if base == nil then
			continue
		end
		if extension == "luau" or extension == "lua" then
			local child = engine.new_instance("ModuleScript", base)
			files[child] = path
			child.Parent = parent
		elseif extension == "server.luau" or extension == "server.lua" then
			local child = engine.new_instance("Script", base)
			files[child] = path
			child.Parent = parent
		elseif extension == "model.json" then
			local model = serde.decode("json", fs.readFile(path))
			local child = engine.new_instance(model.ClassName or "Folder", model.Name or base)
			child.Parent = parent
		elseif extension == "json" then
			local child = engine.new_instance("ModuleScript", base)
			files[child] = path
			stand_ins[path] = serde.decode("json", fs.readFile(path))
			child.Parent = parent
		end
	end
end

-- Builds the DataModel from the Rojo project at `project_path` (relative to `root`), leaving out what only a player's
-- client runs and what a headless game has no use for (`skip`, by the node's path in the project, like
-- "ReplicatedStorage.Client").
local function build(root: string, project_path: string, skip: { [string]: boolean })
	local project = serde.decode("json", fs.readFile(`{root}/{project_path}`))
	local function visit(node: { [string]: any }, instance: any, where: string)
		for key, child_node in node do
			if string.sub(key, 1, 1) == "$" or type(child_node) ~= "table" then
				continue
			end
			local child_where = if where == "" then key else `{where}.{key}`
			if skip[child_where] then
				continue
			end
			local child: any
			if instance == engine.game then
				child = engine.game:GetService(key)
			else
				child = instance:FindFirstChild(key)
			end
			local path = child_node["$path"]
			if child == nil then
				local class = child_node["$className"] or "Folder"
				if path ~= nil then
					local full = `{root}/{path}`
					if fs.isDir(full) then
						child = directory_instance(full, key)
					else
						child = engine.new_instance("ModuleScript", key)
						files[child] = full
					end
				else
					child = engine.new_instance(class, key)
				end
				child.Parent = instance
			end
			if path ~= nil and fs.isDir(`{root}/{path}`) then
				lay_out(child, `{root}/{path}`)
			end
			visit(child_node, child, child_where)
		end
	end
	visit(project.tree, engine.game, "")
end

local function noop() end

-- The names the module in `source` exports: the keys of the table it returns, written as `return table.freeze({` with
-- one `name = ...,` a line, as every module of the game's is.
local function exports_of(source: string): { string }
	local body = string.match(source, "\nreturn table%.freeze%(%{\n(.-)\n%}%)")
	assert(body ~= nil, "a stood-in module has to end by returning its exports")
	local names = {}
	for name in string.gmatch(body, "\t([%a_][%w_]*) =") do
		table.insert(names, name)
	end
	return names
end

-- Puts a stand-in in place of the module at `path` (a file path as the project gives it, from `root`): everything the
-- module itself exports, each doing nothing and answering nothing, but for what `answers` says, which has to be among
-- them. So the stand-in keeps up with the module as it changes.
local function stand_in(root: string, path: string, answers: { [string]: any })
	local value = {}
	for _, name in exports_of(fs.readFile(`{root}/{path}`)) do
		value[name] = noop
	end
	for name, answer in answers do
		assert(value[name] ~= nil, `{path} exports no "{name}" to stand in for`)
		value[name] = answer
	end
	stand_ins[`{root}/{path}`] = table.freeze(value)
end

return {
	build = build,
	stand_in = stand_in,
	require = require_module,
}
