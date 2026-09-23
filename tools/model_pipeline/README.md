# Model pipeline: .blend → Python → .glb → Roblox

Buildings today are boxes the size of their collider (see README.md "Not built yet"). This is
the tooling to replace them with real, parametric models instead of hand modeling every one:

```
generators/*.py (Python, uses bpy)  ->  build.py (headless Blender)  ->  build/*.glb  ->  Roblox
```

A generator is a plain Python module with a `generate(params) -> bpy object(s)` function that
builds a mesh procedurally from a handful of parameters (width, height, floor count, roof style,
...). `build.py` runs it inside headless Blender and exports the result as glTF binary (`.glb`).
Nothing here depends on hand-authored `.blend` files, though generators can also load and modify
one if you want to start from hand-modeled geometry.

## Requirements

- [Blender](https://www.blender.org/download/) 4.x, with `blender` on PATH (or pass `-Blender`
  to `build.ps1` with the full path to `blender.exe`).
- For the Roblox upload step: a [Roblox Open Cloud API key](https://create.roblox.com/dashboard/credentials)
  with `asset:write` for the target creator, and the creator's user or group id.

## Building a model

```powershell
tools/model_pipeline/build.ps1 building_basic -Params '{"width":16,"depth":12,"height":10,"floors":2,"roof":"peaked"}'
```

This runs Blender headlessly, calls `generators/building_basic.py`'s `generate(params)`, and
writes `tools/model_pipeline/build/building_basic.glb`. `-Out` overrides the output path; omit
`-Params` to use the generator's defaults.

List available generators:

```powershell
tools/model_pipeline/build.ps1 -List
```

## Getting a model into the game

Every build also writes the model's art data module to `src/shared/art/<generator>.luau` (`-LuauOut` to put it
elsewhere, `-NoLuau` to skip it). Name the generator after the def and that is all it takes: Rojo syncs the module
into `ReplicatedStorage.Shared.art`, the server gives that def an invisible hitbox instead of a placeholder, and
each client builds the meshes itself with EditableMesh (`src/client/art.luau`). Nothing is uploaded to Roblox,
which suits models that are still changing; the experience only has to allow EditableMesh (Game Settings >
Security > Allow Mesh / Image APIs).

To have the client load real mesh assets instead of building them (no EditableMesh needed), upload them:

```powershell
# key with asset:read + asset:write, in tools/model_pipeline/roblox/.api_key (gitignored)
python tools/model_pipeline/roblox/upload_art.py --creator-type User --creator-id 123456
```

It uploads each model's `build/<def>_art.glb` (one node per mesh, named by the mesh's hash) as a Model, and skips
defs whose meshes are all uploaded already. Only Studio can see which mesh asset ids a Model holds
(`InsertService:LoadAsset`), so read them there, map each def to `{ hash: MeshId }` in a JSON file, and run
`roblox/record_meshes.py <file>` to put them in `roblox/uploads.json`. The next build writes an uploaded mesh into
its art module as `mesh = "rbxassetid://..."`; anything not uploaded keeps its vertices and is built as before.

The module holds the model's rigid pieces and one mesh per material of each piece. A generator puts an object in a
moving piece with `common.art_group(obj, "turret_1", pivot=True, kind="turret", weapon=1)`: `kind="turret"` follows
that weapon's aim (a weapon with a `turret` in its def turns in the sim and fires only once it faces its target),
`kind="work"` turns toward what a builder is working on, and `kind="spin"` turns about `axis` at `speed`. Anything
it does not put in a piece is part of the static `base`. Materials with "accent" in their name take the team's
colour. The first object a generator returns is its footprint, which the model is centred on.

## Getting the .glb into Roblox Studio

For a model to be uploaded for good, two ways, pick whichever fits:

**Manual (no setup, good for iterating on a generator):** In Studio, `File > Import 3D Model...` (Beta
feature, enable "3D Import" under Studio settings if it's missing) and pick the `.glb`. This makes
a `Model` of `MeshPart`s directly in the current place. Drag it into `src/models/<name>/` as an
`.rbxm` (right click > Save to File) and Rojo will sync it into `ReplicatedStorage.Models` like any
other file, since `src/models` is `$ignoreUnknownInstances` in `rts-game.project.json`.

**Scripted, via Roblox Studio MCP tools:** the MCP tools in this session (`insert_asset`, etc.) place
assets that already exist on Roblox by numeric asset id — they don't read local files directly, so
the `.glb` has to be uploaded to Roblox first to get that id:

```powershell
$env:ROBLOX_API_KEY = "..."          # Open Cloud key, asset:write scope
python tools/model_pipeline/roblox/upload_open_cloud.py `
    tools/model_pipeline/build/building_basic.glb `
    --creator-type User --creator-id 123456 --name building_basic
```

This prints the resulting numeric asset id once Roblox finishes processing (it moderates new mesh
uploads, usually seconds to a couple minutes). Feed that id to
`mcp__Roblox_Studio__insert_asset(assetId=..., assetType="Model")` to drop it straight into the
open Studio session, then save it out to `src/models/` the same way as the manual path.

## Adding a new generator

A model is at most **100 triangles**, whatever it is: the game is meant to carry thousands of units. Build it from
a few strong shapes (`box`, `tapered_box`, `pyramid`, `octahedron`, `band`, six-sided `cylinder`s), drop hidden
undersides with `common.drop_bottom`, and skip bevels (`finish_all`); the build warns past the limit.

Copy `generators/building_basic.py` as a starting point. `generators/common.py` has the shared
helpers (boxes, modular wall segments, gabled/flat roofs, simple UV unwrap + material assignment)
so new generators stay declarative instead of re-deriving mesh math. `generate(params)` must
return a list of the top-level `bpy.types.Object`s to export; `build.py` handles joining,
triangle-limit warnings, origin placement (centered on X/Z, base at Y=0, to match how
`instances.luau` places entities) and the actual glTF export.
