"""Checks the committed art against the pipeline, without Blender:

    python tools/model_pipeline/check_art.py

Each problem is one line, and any makes it exit 1. It fails when:
- a module is not what its generator last built (built.json), carries raw vertices, or names a mesh that is not
  uploaded: the game can only show uploaded meshes;
- a generator was never built, or its inputs (its code and its def's numbers) changed since it was, or meshes it was
  waiting for were uploaded since: rebuild it (build.ps1 -Stale);
- a module has no generator, or is in another category's folder, or does not map to what the game finds it by: the
  art of a def (src/shared/art) is named after the def its generator declares (DEF), a skin's names a skin that uses it
  (SKIN), and a reclaimable's is some reclaimable def's feature art;
- the art module format (art_format.py) and src/shared/art/init.luau's types disagree, or
  src/shared/unit_defs/turret_mounts.luau is not what the generators' MOUNTS declare;
- roblox/uploads.json keeps what no model uses any more (roblox/record_meshes.py prune);
- a generator writes a colour (an RGBA literal, or an rgb() of bytes) anywhere but generators/shared/palette.py.
"""

import argparse
import ast
import sys

import art_format
import manifest
import turret_mounts

sys.path.insert(0, str(manifest.REPO_ROOT / "tools"))

import game_data  # noqa: E402

SKINS_DIR = manifest.REPO_ROOT / "src" / "shared" / "skins"


def module_problems(name, path, built, declared, categories):
    """What is wrong with the committed module at `path`."""
    where = path.relative_to(manifest.REPO_ROOT).as_posix()
    text = path.read_text(encoding="utf-8")
    hashes, unnamed = art_format.module_hashes(text)
    if name not in declared:
        return [f"{where}: no generator builds it"]
    problems = []
    output = categories[declared[name]["CATEGORY"]]
    if manifest.OUTPUT_DIRS[output] != path.parent:
        problems.append(f"{where}: its generator's category puts it in {manifest.OUTPUT_DIRS[output].relative_to(manifest.REPO_ROOT).as_posix()}")
    if "vertices = " in text:
        problems.append(f"{where}: carries raw vertices, which the game cannot show; upload its meshes and rebuild it")
    elif unnamed:
        problems.append(f"{where}: {unnamed} parts name no uploaded mesh; upload them (roblox/upload_art.py {name}) and rebuild it")
    entry = built.get(name)
    if entry is not None and (hashes != entry["hashes"] or manifest.module_digest(text) != entry["digest"]):
        pending = f", upload its meshes (roblox/upload_art.py {name})" if entry["pending"] else ""
        problems.append(f"{where}: is not its generator's last build; rebuild it{pending} and commit what the build writes")
    return problems


def generator_problems(name, declared, built, defs, uploads, modules, skin_sources):
    """What is wrong with generator `name`'s build, and with what its art maps to in the game."""
    problems = []
    entry = built.get(name)
    def_name = declared.get("DEF")
    def_entry = defs.get(def_name) if def_name is not None else None
    if def_name is not None and def_entry is None:
        problems.append(f"{name}: declares DEF = {def_name!r}, which is not a def")
    if entry is None:
        problems.append(f"{name}: never built (build.ps1 {name})")
    else:
        if entry["inputs"] != manifest.fingerprint(name, def_entry):
            problems.append(f"{name}: out of date, its code or its def changed since it was built (build.ps1 -Stale)")
        uploaded_since = [h for h in entry["pending"] if h in uploads["assets"]]
        if uploaded_since:
            problems.append(f"{name}: {len(uploaded_since)} of its meshes were uploaded since it was built (build.ps1 -Stale)")
    if name not in modules:
        problems.append(f"{name}: has no module (build.ps1 {name})")

    # what the game finds this art by
    category = declared["CATEGORY"]
    if category in ("entity", "ship") and def_name != name:
        problems.append(f"{name}: a def's art is found by the def's name, so it declares DEF = {name!r}")
    elif category == "prop" and def_name != name and "SKIN" not in declared:
        problems.append(f"{name}: dresses no def or skin (declare DEF, named after it, or SKIN)")
    elif category == "prop" and "SKIN" in declared:
        source = skin_sources.get(declared["SKIN"])
        if source is None:
            problems.append(f"{name}: declares SKIN = {declared['SKIN']!r}, which is not a skin (src/shared/skins)")
        elif f'art = "{name}"' not in source:
            problems.append(f"{name}: skin {declared['SKIN']!r} never uses it")
    elif category == "reclaimable" and not any(d.get("feature_art") == name for d in defs.values()):
        problems.append(f"{name}: no reclaimable def is drawn in it (a def's feature.art)")
    return problems


def upload_problems(uploads, built):
    """What uploads.json keeps that nothing uses: meshes no model has, and models of generators that are gone."""
    used = manifest.used_hashes(built)
    names = set(manifest.generator_names())
    problems = []
    dead = [h for h in uploads["assets"] if h not in used]
    if dead:
        problems.append(f"uploads.json: {len(dead)} meshes are used by no model (roblox/record_meshes.py prune)")
    gone = sorted(name for name in uploads["models"] if name not in names)
    if gone:
        problems.append(f"uploads.json: models of generators that are gone: {', '.join(gone)} (roblox/record_meshes.py prune)")
    return problems


def colour_problems():
    """Every colour written into a generator outside shared/palette.py, which names them all: an RGBA tuple of 0-1
    numbers ending in an opaque 1.0, or a call of rgb()."""
    problems = []
    palette_path = manifest.SHARED_DIR / "palette.py"
    for path in sorted([*manifest.GENERATORS_DIR.glob("*.py"), *manifest.SHARED_DIR.glob("*.py")]):
        if path == palette_path:
            continue
        for node in ast.walk(ast.parse(path.read_text(encoding="utf-8"))):
            numbers = [e.value for e in node.elts] if isinstance(node, ast.Tuple) and all(
                isinstance(e, ast.Constant) and isinstance(e.value, (int, float)) for e in node.elts
            ) else []
            is_rgba = len(numbers) == 4 and numbers[3] == 1.0 and all(0 <= n <= 1 for n in numbers)
            is_rgb = isinstance(node, ast.Call) and getattr(node.func, "attr", getattr(node.func, "id", None)) == "rgb"
            if is_rgba or is_rgb:
                where = path.relative_to(manifest.REPO_ROOT).as_posix()
                problems.append(f"{where}:{node.lineno}: a colour of its own; name it in generators/shared/palette.py")
    return problems


def main():
    parser = argparse.ArgumentParser()
    parser.add_argument("--game-root", default=None, help="read the game's numbers from another checkout")
    args = parser.parse_args()
    built = manifest.load_built()
    uploads = manifest.load_uploads()
    defs = (game_data.load(args.game_root) if args.game_root else game_data.load())["defs"]
    names = manifest.generator_names()
    declared = {name: manifest.declarations(name) for name in names}
    categories = {name: category["output"] for name, category in manifest.CATEGORIES.items()}
    skin_sources = {p.stem: p.read_text(encoding="utf-8") for p in SKINS_DIR.glob("*.luau") if p.stem != "init"}

    modules = manifest.committed_modules()

    problems = []
    for name, path in sorted(modules.items()):
        problems += module_problems(name, path, built, declared, categories)
    for name in names:
        problems += generator_problems(name, declared[name], built, defs, uploads, modules, skin_sources)
    problems += [f"src/shared/art/init.luau: {p}" for p in art_format.type_problems(manifest.ART_TYPES_PATH.read_text(encoding="utf-8"))]
    problems += upload_problems(uploads, built)
    problems += colour_problems()
    problems += turret_mounts.problems(declared)

    for problem in problems:
        print(problem)
    print(f"{len(problems)} problems")
    sys.exit(1 if problems else 0)


if __name__ == "__main__":
    main()
