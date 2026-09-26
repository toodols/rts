# Model pipeline: Python generators → Blender → uploaded meshes → art modules

Every def, skin, reclaimable and HUD picture the game draws is a low-poly model built procedurally here, uploaded to
Roblox as meshes, and described to the game by a generated Luau "art module" that names those meshes.

```
generators/<name>.py ──build.ps1 (headless Blender)──▶ build/<name>_art.glb + art module + built.json
       build/<name>_art.glb ──roblox/upload_art.py──▶ Roblox Model (pending in roblox/uploads.json)
       Studio (roblox/read_meshes.luau) ──record_meshes.py record──▶ mesh ids in roblox/uploads.json
       build.ps1 -Stale ──▶ art modules that name the uploaded meshes
```

## Requirements

- Blender 5.2 (manifest.py's `BLENDER_VERSION`; build.py refuses any other, since a mesh's hash depends on how Blender
  triangulates it, and another version could re-hash, and so re-upload, everything). `build.ps1` finds the 5.2 install,
  or takes `-Blender <path to blender.exe>`.
- [lune](https://github.com/lune-org/lune) (aftman.toml): the build reads each def's collider and colour from the game's
  own modules through `tools/game_data.luau`.
- Arial Black (`C:/Windows/Fonts/ariblk.ttf`, the very file `shared/tutorial.py` names by its hash) for the tutorial
  keys' glyphs.
- For uploads: `requests` (requirements.txt), and an Open Cloud key with asset:read and asset:write (see
  `tools/roblox_open_cloud.py` for where it is looked for; the creator is `tools/roblox_creator.json`).

## Generators

`generators/<name>.py` builds one model named `<name>`. It has a `generate(params) -> [bpy objects]` function and
declares, as literals (manifest.py's `DECLARATIONS`):

- `CATEGORY` (manifest.py's `CATEGORIES`): where its module goes and what it may spend.

  | category | module goes to | triangles | notes |
  |---|---|---|---|
  | `entity` | `src/shared/art/` | 100 | units and buildings, held to their collider |
  | `ship` | `src/shared/art/` | 100 | and at most 7 MeshParts |
  | `prop` | `src/shared/art/` | 300 | skins and the tutorial's boulder; places its own origin |
  | `reclaimable` | `src/shared/reclaimable_art/` | 60 | rocks and trees, which the server stretches to each collider |
  | `hud` | `src/shared/ui_art/` | 800 | HUD pictures (icons, the tutorial's keys and mouse); places its own origin |

- `DEF`, the def it dresses (a unit's or building's art is found by its def's name, so it is the generator's own name;
  a reclaimable's def names the art it is drawn in), or `SKIN`, the skin that uses it (`src/shared/skins`). A generator
  with a `DEF` gets `params["collider"]` (studs: a box's `width`, `height`, `length`, or a capsule's `radius`, `height`
  and BAR's `width` and `length`) and `params["color"]` (the def's colour, RGBA 0-1, its team accent). Nothing is copied
  out of the defs: change a def and `build.ps1 -Stale` rebuilds its model.
- `MOUNTS`, for a model with turrets: where each turret weapon turns and fires from (see `turret_mounts.py`). The build
  checks the art agrees, and writes `src/shared/unit_defs/turret_mounts.luau`, which is what the simulation fires from.
- `ENVELOPE` and `TRIANGLES`, each with a comment saying why, for a model allowed past its collider or its budget.

The first object a generator returns is the footprint the model is centred on (unless its category places its own
origin). A unit with a capsule collider is then stretched to fill its BAR collision volume (build.py's `fill_volume`).
Every model of a def is then checked against its collider: nothing may reach past a capsule (walking legs at either end
of their stride included), a building's standing body past its box footprint, anything past the top, or below the
ground unless it floats. Anything that does, or overspends, fails the build.

`generators/shared/` holds what generators share: `common.py` (the one mesh builder `mesh`, the face collector `Faces`,
the primitives -- `ngon`, `rect`, `block`, `pyramid`, ... -- pivots and art groups, and the paints `Materials`),
`palette.py` (every colour; check_art.py fails on one written anywhere else), `polygons.py` (2D outlines) and one module
per family (`air_t1`, `bot_t1`, `ship_t1`, `vehicle_t2`, ...) with that family's own shapes. A mesh is a few strong
shapes with the faces nobody sees left out, and no bevels; only a part's colour, whether it glows and whether it takes
its team's colour reach the game.

Moving pieces: `common.art_group(obj, "turret_1", pivot=True, kind="turret", weapon=1)` puts an object in a rigid piece
that follows weapon 1's aim; `kind="work"` turns toward what a builder builds, `"spin"`, `"leg"`, `"wheel"` and
`"hatch"` are described in `common.art_group`. `art_format.py` is the module format, which check_art.py holds
`src/shared/art/init.luau`'s types to.

## Building

```powershell
tools/model_pipeline/build.ps1 grunt tick          # build these
tools/model_pipeline/build.ps1 -Stale              # build every model whose inputs changed, or whose meshes were uploaded since
tools/model_pipeline/build.ps1 -All                # build everything
tools/model_pipeline/build.ps1 -List
```

A build writes each model's art module, `build/<name>_art.glb` (its meshes not on Roblox yet, for uploading), a preview
render (`build/<name>.png`; `-NoRender` skips it) and its entry in `built.json`: the module and a digest of it, its mesh
hashes, the Blender version and a fingerprint of its inputs (the code of its generator, of the shared modules it
imports and of the build, without docstrings, and its def's numbers). A part whose mesh is not uploaded yet is written
with only its hash: the game can show no model until all of its meshes are uploaded.

`python tools/model_pipeline/check_art.py` (also `python tools/check.py art`) checks the committed art without Blender:
every module is its generator's last build from its current inputs, names only uploaded meshes and maps to a def or a
skin; the colours are all in the palette; turret_mounts.luau is what the generators declare; and uploads.json keeps
nothing unused.

HUD icons can be looked over without Blender or Studio: `python tools/model_pipeline/icon_sheet.py [names...]` draws
them flat into `build/icons_sheet.png`.

## Uploading

```powershell
python tools/model_pipeline/roblox/upload_art.py [name ...]      # every built model with meshes not on Roblox yet
python tools/model_pipeline/roblox/record_meshes.py script       # writes build/read_meshes.luau
```

Run `build/read_meshes.luau` in Studio (command bar, Edit mode): only Studio can open an uploaded Model and see its
MeshIds. Save what it prints to a file, then:

```powershell
python tools/model_pipeline/roblox/record_meshes.py record <file>
tools/model_pipeline/build.ps1 -Stale
```

`upload_art.py` never uploads a model twice: one already uploaded and waiting to be recorded is skipped. `record_meshes.py
prune` drops the mesh ids nothing uses any more.
