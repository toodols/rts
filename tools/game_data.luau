--!strict
-- Prints, as JSON, the numbers the tools take from the game itself rather than keeping copies: the scale constants of
-- shared/world_scale, from shared/unit_defs each def's collider and colour, whether it floats and what art it is drawn
-- in if it is a reclaimable, and each BAR map's makers as shared/bar_maps/rights credits them. The game's own modules
-- are loaded into the engine's stand-in (tools/lib), as the arena and the headless tests load them, so what the tools
-- read is what the game plays with.
--
--     lune run tools/game_data.luau [root]
--
-- `root` is the checkout to read (default: the working directory). tools/game_data.py runs this.

local process = require "@lune/process"
local serde = require "@lune/serde"
local stdio = require "@lune/stdio"

local engine = require "./lib/engine"
local loader = require "./lib/loader"

-- only the shared modules are read; nothing of the server or a client is needed
local SKIPPED = {
	["ReplicatedStorage.Client"] = true,
	["ReplicatedStorage.Packages"] = true,
	["ServerScriptService"] = true,
	["StarterPlayer"] = true,
}

-- The scale numbers a tool converts with.
local SCALE_KEYS = { "CELL_STUDS", "ELMOS_PER_STUD" }

local function color_bytes(color: any): { number }
	return { math.round(color.R * 255), math.round(color.G * 255), math.round(color.B * 255) }
end

local function collider_of(collider: { [string]: any }): { [string]: any }
	if collider.shape == "box" then
		return { shape = "box", width = collider.width, height = collider.height, length = collider.length }
	end
	assert(collider.shape == "capsule", `unknown collider shape {collider.shape}`)
	-- the capsule's BAR volume, not just its radius: the art fills the volume BAR draws the unit at
	assert(
		typeof(collider.width) == "number" and typeof(collider.length) == "number",
		"a capsule collider has no width and length"
	)
	return {
		shape = "capsule",
		radius = collider.radius,
		height = collider.height,
		width = collider.width,
		length = collider.length,
	}
end

local root = process.args[1] or process.cwd
loader.build(root, "rts-game.project.json", SKIPPED)
local shared = engine.game:GetService("ReplicatedStorage").Shared
local world_scale = loader.require(shared:FindFirstChild "world_scale")
local unit_defs = loader.require(shared:FindFirstChild "unit_defs")
local map_rights = loader.require(shared:FindFirstChild("bar_maps"):FindFirstChild "rights")

local out_scale = {}
for _, key in SCALE_KEYS do
	out_scale[key] = world_scale[key]
end

local out_defs = {}
for name, def in unit_defs.defs do
	local entry: { [string]: any } = { collider = collider_of(def.collider) }
	if def.color ~= nil then
		entry.color = color_bytes(def.color)
	end
	-- one that floats rides the water's surface, which its art may reach under
	entry.floats = unit_defs.floats(def)
	-- a reclaimable is drawn in its feature's art, which it names
	if def.feature ~= nil then
		entry.feature_art = def.feature.art
	end
	out_defs[name] = entry
end

-- each BAR map's makers, as the game credits them
local out_map_credits = {}
for name in map_rights.RIGHTS do
	out_map_credits[name] = map_rights.credit(name)
end

stdio.write(serde.encode("json", { scale = out_scale, defs = out_defs, map_credits = out_map_credits }, false) .. "\n")
