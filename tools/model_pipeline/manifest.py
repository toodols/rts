"""Where the model pipeline keeps things, and its two records. Plain Python: build.py (in Blender), check_art.py and
the upload scripts in roblox/ all read these, and every load checks a record's shape, so a record written by an older
script fails loudly instead of being half understood.

- built.json: what each generator last built. Per generator, the art module it wrote, the hashes of that module's
  meshes and a digest of its text, the Blender that made them (a mesh's hash depends on how Blender triangulates it), a
  fingerprint of the code
  and numbers the build read (so a build can tell which modules are out of date: build.py --stale), and `pending`,
  the hashes of its meshes that were not on Roblox yet when it was built, which are what build/<name>_art.glb holds.
- roblox/uploads.json: what is on Roblox, an asset-id store (tools/roblox_open_cloud.py). `assets` maps a mesh's hash
  to its asset id; `models` holds each art model uploaded for its meshes: its asset id, the hashes it was uploaded
  with, and whether Studio has read its meshes' ids yet (`pending`).
"""

import ast
import functools
import hashlib
import json
import sys
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parent.parent))

import art_format  # noqa: E402
import roblox_open_cloud  # noqa: E402

PIPELINE_ROOT = Path(__file__).resolve().parent
REPO_ROOT = PIPELINE_ROOT.parent.parent
GENERATORS_DIR = PIPELINE_ROOT / "generators"
SHARED_DIR = GENERATORS_DIR / "shared"
BUILD_DIR = PIPELINE_ROOT / "build"
BUILT_PATH = PIPELINE_ROOT / "built.json"
UPLOADS_PATH = PIPELINE_ROOT / "roblox" / "uploads.json"
ART_TYPES_PATH = REPO_ROOT / "src" / "shared" / "art" / "init.luau"

# The Blender every mesh is built with: a mesh's hash depends on how Blender triangulates it, so another version
# could re-hash, and so need re-uploading, everything. build.py refuses any other.
BLENDER_VERSION = "5.2"

# Where each kind of art module goes, synced by Rojo into ReplicatedStorage.Shared: `art` dresses the defs (and the
# skins), `ui_art` is the HUD's pictures, `reclaimable_art` the rocks and trees the server builds from their meshes.
OUTPUT_DIRS = {
    "art": REPO_ROOT / "src" / "shared" / "art",
    "ui_art": REPO_ROOT / "src" / "shared" / "ui_art",
    "reclaimable_art": REPO_ROOT / "src" / "shared" / "reclaimable_art",
}

# What each kind of model is (a generator's CATEGORY): where its art module goes (manifest.OUTPUT_DIRS), the triangles and MeshParts it may
# spend, whether the build centres it on its footprint or the generator places its own origin, and whether it is held
# to its def's collider.
# - entity: a unit or building. The game carries thousands, so each is a handful of strong low-poly shapes.
# - ship: an entity whose MeshParts are also capped, so a fleet stays cheap to draw.
# - prop: a one-off shown a few at a time (the skins, the tutorial's boulder), laid out about its own origin.
# - reclaimable: a rock or tree, dressed by the server rather than the client, which stretches it to fill each
#   reclaimable's collider (server/instances.luau): how far it reaches is its own.
# - hud: a picture in a HUD ViewportFrame, shown a few at a time, laid out about its own origin.
CATEGORIES = {
    "entity": {"output": "art", "triangles": 100, "parts": None, "centred": True, "fits": True},
    "ship": {"output": "art", "triangles": 100, "parts": 7, "centred": True, "fits": True},
    "prop": {"output": "art", "triangles": 300, "parts": None, "centred": False, "fits": True},
    "reclaimable": {"output": "reclaimable_art", "triangles": 60, "parts": None, "centred": True, "fits": False},
    "hud": {"output": "ui_art", "triangles": 800, "parts": None, "centred": False, "fits": False},
}

# The constants a generator declares about its model (build.py reads what each means), all literals: CATEGORY above all.
DECLARATIONS = ("CATEGORY", "DEF", "SKIN", "ENVELOPE", "TRIANGLES", "MOUNTS")

# What a build reads besides the generator and the shared modules it imports: the build itself and the format it
# writes.
BUILD_SOURCES = (PIPELINE_ROOT / "build.py", PIPELINE_ROOT / "art_format.py")


def generator_names():
    """Every generator: each module directly in generators/ builds one model named after it."""
    return sorted(p.stem for p in GENERATORS_DIR.glob("*.py") if p.stem != "__init__")


def generator_path(name):
    return GENERATORS_DIR / f"{name}.py"


def declarations(name):
    """What generator `name` declares (DECLARATIONS), read from its source without running it."""
    found = {}
    for node in ast.parse(generator_path(name).read_text(encoding="utf-8")).body:
        if isinstance(node, ast.Assign) and len(node.targets) == 1 and isinstance(node.targets[0], ast.Name):
            key = node.targets[0].id
            if key in DECLARATIONS:
                found[key] = ast.literal_eval(node.value)
    if found.get("CATEGORY") not in CATEGORIES:
        raise SystemExit(f"generators/{name}.py: CATEGORY must be one of {', '.join(CATEGORIES)}")
    return found


def glb_path(name):
    """The build's upload file for `name`: one node per mesh not on Roblox yet, named by the mesh's hash."""
    return BUILD_DIR / f"{name}_art.glb"


def _without_docstrings(tree):
    """`tree` with every docstring taken out: what a module does, not how it is explained."""
    for node in ast.walk(tree):
        if isinstance(node, (ast.Module, ast.ClassDef, ast.FunctionDef, ast.AsyncFunctionDef)):
            body = node.body
            if body and isinstance(body[0], ast.Expr) and isinstance(body[0].value, ast.Constant) and isinstance(body[0].value.value, str):
                node.body = body[1:] or [ast.Pass()]
    return tree


def _imported(path, tree):
    """The generator modules `path` imports (relative imports within generators/), as paths."""
    package = path.parent
    found = []
    for node in ast.walk(tree):
        if not isinstance(node, ast.ImportFrom) or node.level == 0:
            continue
        base = package
        for _ in range(node.level - 1):
            base = base.parent
        if node.module:
            base = base.joinpath(*node.module.split("."))
        if base.with_suffix(".py").is_file():
            found.append(base.with_suffix(".py"))
            continue
        for alias in node.names:
            module = base / f"{alias.name}.py"
            if module.is_file():
                found.append(module)
    return found


@functools.cache
def _read(path):
    """(code, imports) of a source file: its syntax tree without docstrings, which a comment, a docstring or a
    reformatting leaves as it is, and the generator modules it imports."""
    tree = ast.parse(path.read_text(encoding="utf-8"))
    return ast.dump(_without_docstrings(tree)), _imported(path, tree)


def sources(name):
    """Every file building `name` reads code from, with its code (see `_read`): its generator, the shared modules it
    imports (and those they import), and the build."""
    found = {}
    queue = [generator_path(name), *BUILD_SOURCES]
    while queue:
        path = queue.pop()
        if path not in found:
            found[path], imports = _read(path)
            queue.extend(imports)
    return found


# What a build takes from a generator's def (build.py's def_params).
DEF_INPUTS = ("collider", "color")


def fingerprint(name, def_entry):
    """A hash of what building `name` reads: the code of its sources (see `sources`) and its def's DEF_INPUTS."""
    digest = hashlib.sha1()
    for path, code in sorted((path.relative_to(PIPELINE_ROOT).as_posix(), code) for path, code in sources(name).items()):
        digest.update(path.encode("utf-8"))
        digest.update(code.encode("utf-8"))
    inputs = {key: def_entry[key] for key in DEF_INPUTS} if def_entry is not None else None
    digest.update(json.dumps(inputs, sort_keys=True).encode("utf-8"))
    return digest.hexdigest()[:16]


# --- the records, and their shapes --------------------------------------------------------------------------------

BUILT_ENTRY = {"module": str, "digest": str, "hashes": list, "blender": str, "inputs": str, "pending": list}
UPLOADED_ASSET = {"id": str}
UPLOADED_MODEL = {"asset_id": str, "hashes": list, "pending": bool}


def _checked(where, record, shape):
    """`record` if it has exactly the keys of `shape`, each of its type; otherwise the script stops, naming it."""
    if not isinstance(record, dict) or set(record) != set(shape):
        raise SystemExit(f"{where}: expected the keys {', '.join(sorted(shape))}, found {record!r}"[:400])
    for key, kind in shape.items():
        if not isinstance(record[key], kind):
            raise SystemExit(f"{where}: {key} should be a {kind.__name__}, found {record[key]!r}"[:400])
    return record


def load_built():
    built = json.loads(BUILT_PATH.read_text(encoding="utf-8")) if BUILT_PATH.is_file() else {}
    for name, entry in built.items():
        _checked(f"built.json {name}", entry, BUILT_ENTRY)
    return built


def save_built(built):
    BUILT_PATH.write_text(json.dumps(built, indent=2, sort_keys=True) + "\n", encoding="utf-8", newline="\n")


def load_uploads():
    uploads = roblox_open_cloud.load_store(UPLOADS_PATH)
    uploads.setdefault("models", {})
    if set(uploads) != {"assets", "models"}:
        raise SystemExit(f"uploads.json: expected assets and models, found {', '.join(sorted(uploads))}")
    for mesh_hash, asset in uploads["assets"].items():
        _checked(f"uploads.json asset {mesh_hash}", asset, UPLOADED_ASSET)
    for name, model in uploads["models"].items():
        _checked(f"uploads.json model {name}", model, UPLOADED_MODEL)
    return uploads


def save_uploads(uploads):
    roblox_open_cloud.save_store(UPLOADS_PATH, uploads)


def module_digest(text):
    """A hash of an art module's text, whatever its line endings: what built.json's `digest` holds of the module a build
    wrote, so that a module edited by hand, or not rebuilt, shows."""
    return hashlib.sha1(text.replace("\r\n", "\n").encode("utf-8")).hexdigest()[:16]


def pending_hashes(hashes, uploads):
    """Of `hashes`, those of meshes not on Roblox yet."""
    return [h for h in hashes if h not in uploads["assets"]]


def committed_modules():
    """Every art module in the game's source, by name: {name: path}."""
    return {path.stem: path for directory in OUTPUT_DIRS.values() for path in sorted(directory.glob("*.luau")) if path.stem != "init"}


def used_hashes(built):
    """The meshes something still uses: every model's last build, and every committed module (which, until it is
    rebuilt, may name meshes its generator no longer makes)."""
    used = {h for entry in built.values() for h in entry["hashes"]}
    for path in committed_modules().values():
        used.update(art_format.module_hashes(path.read_text(encoding="utf-8"))[0])
    return used
