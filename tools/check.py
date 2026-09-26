"""Every check the repository holds itself to, from one command, run from anywhere:

    python tools/check.py                 # every step
    python tools/check.py types arena     # some of them
    python tools/check.py --list

Each step prints what failed and a PASS or FAIL line, and the command exits 1 if any failed. The steps:

- types:       luau-lsp over the game place and the lobby place, each with its own Rojo sourcemap: no type errors.
- tests:       the game's tests headless (tools/headless_tests/run.luau all), and the engine stand-in's own
               (tools/lib/tests).
- arena:       the golden AI duels (tools/golden/<name>.json), played headless, have to come out exactly as their
               recorded results (<name>.out), every field but the real time taken. A change that means to play a
               different game re-records them: python tools/check.py --record-goldens.
- style:       StyLua (formatting) over src/ and tools/, and selene (lints) over src/ and tools/.
- stylesheets: the committed StyleSheet modules are what their SCSS compiles to, with no outlass warnings
               (tools/stylesheets.py check).
- art:         the committed art is what the model pipeline builds (tools/model_pipeline/check_art.py).
- places:      the place each Rojo project serves into is the one src/shared/places.luau names for it.

As a git pre-commit hook, so that nothing is committed without passing it (run once in the checkout):

    git config core.hooksPath tools/hooks

The tools it runs are the repository's own (aftman.toml: rojo, luau-lsp, lune, stylua, selene; requirements.txt), and
luau-lsp reads Roblox's API from globalTypes.d.luau at the repository's root, which is not checked in (README.md).
"""

import argparse
import json
import re
import shutil
import subprocess
import sys
import tempfile
from concurrent.futures import ThreadPoolExecutor
from pathlib import Path

REPO_ROOT = Path(__file__).resolve().parent.parent
GOLDEN_DIR = REPO_ROOT / "tools" / "golden"
DEFINITIONS = REPO_ROOT / "globalTypes.d.luau"

# What luau-lsp leaves out of each place: the packages and the command bar are not ours, and the game and the lobby are
# checked apart, each against its own sourcemap.
LSP_IGNORED = ("Packages/**", "**/pow/**", "**/openskill/**")
PLACES = {
    "game": ("rts-game.project.json", ["src"], ["src/lobby/**", "src/lobby_init.client.luau"]),
    "lobby": ("rts-lobby.project.json", ["src/lobby", "src/lobby_init.client.luau"], []),
}


def run(command, **kwargs):
    """`command` run from the repository's root: (exit code, everything it printed)."""
    result = subprocess.run(command, cwd=REPO_ROOT, capture_output=True, text=True, encoding="utf-8", errors="replace", **kwargs)
    return result.returncode, result.stdout + result.stderr


def types():
    if not DEFINITIONS.is_file():
        return [f"no {DEFINITIONS.name} at the repository's root: fetch it from the luau-lsp repository (README.md)"]
    errors = set()
    with tempfile.TemporaryDirectory() as temp:
        for place, (project, paths, ignored) in PLACES.items():
            sourcemap = Path(temp) / f"{place}_sourcemap.json"
            code, out = run(["rojo", "sourcemap", project, "-o", str(sourcemap)])
            if code != 0:
                return [f"rojo sourcemap {project} failed:\n{out}"]
            ignores = [f"--ignore={pattern}" for pattern in (*LSP_IGNORED, *ignored)]
            _, out = run(["luau-lsp", "analyze", f"--sourcemap={sourcemap}", f"--definitions={DEFINITIONS}", *ignores, *paths])
            for line in out.splitlines():
                if "TypeError" in line or "SyntaxError" in line:
                    # luau-lsp repeats an error once for every module that requires the one it is in
                    line = re.sub(r" \[[^]]*\]", "", line)
                    errors.add(re.sub(r"^.*?(src[\\/])", r"\1", line))
    return sorted(errors)


def tests():
    problems = []
    code, out = run(["lune", "run", "tools/headless_tests/run.luau", "all"])
    print("\n".join(line for line in out.splitlines() if re.match(r"(FAIL|ERROR)\b|\d+ passed,", line)))
    if code != 0:
        problems.append("headless tests: some failed or errored")
    for test in sorted((REPO_ROOT / "tools" / "lib" / "tests").glob("*.luau")):
        code, out = run(["lune", "run", test.relative_to(REPO_ROOT).as_posix()])
        if code != 0:
            problems.append(f"{test.relative_to(REPO_ROOT).as_posix()}:\n{out[-2000:]}")
    return problems


def _play(match_path):
    """The result of the match at `match_path`, played headless, as the last line the arena prints."""
    code, out = run(["lune", "run", "tools/ai_arena/arena.luau", "-"], input=match_path.read_text(encoding="utf-8"))
    return code, out.strip().splitlines()[-1] if out.strip() else ""


def _flat(result, prefix=""):
    flat = {}
    for key, value in result.items():
        if isinstance(value, dict):
            flat.update(_flat(value, f"{prefix}{key}."))
        else:
            flat[prefix + key] = value
    return flat


def goldens():
    return sorted(GOLDEN_DIR.glob("*.json"))


def arena():
    problems = []
    with ThreadPoolExecutor(len(goldens())) as pool:
        played = list(pool.map(_play, goldens()))
    for match, (code, line) in zip(goldens(), played):
        try:
            new = json.loads(line)
        except json.JSONDecodeError:
            problems.append(f"{match.stem}: did not finish (exit {code}): {line[:600]}")
            continue
        old = json.loads(match.with_suffix(".out").read_text(encoding="utf-8"))
        before, after = _flat(old), _flat(new)
        changed = [
            f"{key} {before.get(key)} -> {after.get(key)}"
            for key in sorted(set(before) | set(after))
            if key != "real_seconds" and before.get(key) != after.get(key)
        ]
        if not new.get("ok"):
            problems.append(f"{match.stem}: not ok: {line[:600]}")
        elif changed:
            problems.append(f"{match.stem}: {len(changed)} fields differ from its golden result: {'; '.join(changed[:12])}")
        else:
            print(f"{match.stem}: as recorded ({after.get('real_seconds')} s)")
    return problems


def record_goldens():
    with ThreadPoolExecutor(len(goldens())) as pool:
        played = list(pool.map(_play, goldens()))
    for match, (code, line) in zip(goldens(), played):
        if code != 0 or not json.loads(line).get("ok"):
            sys.exit(f"{match.stem} did not play: {line[:600]}")
        match.with_suffix(".out").write_text(line + "\n", encoding="utf-8", newline="\n")
        print(f"recorded {match.with_suffix('.out').relative_to(REPO_ROOT).as_posix()}")


def style():
    problems = []
    # StyLua on a copy of the sources with LF line endings: the repository keeps each file's own, a mix of LF and CRLF,
    # which is not what this checks
    with tempfile.TemporaryDirectory() as temp:
        # aftman.toml too: aftman picks a tool's version by the directory it is run in
        for config in ("stylua.toml", ".styluaignore", "aftman.toml"):
            shutil.copy(REPO_ROOT / config, Path(temp) / config)
        for folder in ("src", "tools"):
            for path in (REPO_ROOT / folder).rglob("*.lua*"):
                copy = Path(temp) / path.relative_to(REPO_ROOT)
                copy.parent.mkdir(parents=True, exist_ok=True)
                copy.write_bytes(path.read_bytes().replace(b"\r\n", b"\n"))
        result = subprocess.run(["stylua", "--num-threads", "1", "--check", "src", "tools"], cwd=temp, capture_output=True, text=True)
    if result.returncode != 0:
        unformatted = sorted(set(re.findall(r"^Diff in (.+):$", result.stdout, re.M)))
        problems.append("StyLua would reformat (run `stylua <file>`): " + ", ".join(unformatted or [result.stderr.strip()]))
    code, out = run(["selene", "src", "tools"])
    if code != 0 or re.search(r"^[1-9]\d* (errors|warnings)", out, re.M):
        problems.append("selene:\n" + out[-4000:])
    return problems


def stylesheets():
    code, out = run([sys.executable, "tools/stylesheets.py", "check"])
    return [out.strip()] if code != 0 else []


def art():
    code, out = run([sys.executable, "tools/model_pipeline/check_art.py"])
    return [out.strip()] if code != 0 else []


def places():
    """The place each project serves into is the one src/shared/places.luau names for it."""
    source = (REPO_ROOT / "src" / "shared" / "places.luau").read_text(encoding="utf-8")
    problems = []
    for name, project in (("GAME", "rts-game.project.json"), ("LOBBY", "rts-lobby.project.json")):
        named = re.search(rf"^local {name} = (\d+)$", source, re.M)
        served = json.loads((REPO_ROOT / project).read_text(encoding="utf-8")).get("servePlaceIds", [])
        if named is None or served != [int(named.group(1))]:
            problems.append(f"{project} serves into {served}, and src/shared/places.luau names {name} {named and named.group(1)}")
    return problems


STEPS = {
    "types": types,
    "tests": tests,
    "arena": arena,
    "style": style,
    "stylesheets": stylesheets,
    "art": art,
    "places": places,
}


def main():
    sys.stdout.reconfigure(encoding="utf-8", errors="replace")
    parser = argparse.ArgumentParser(description="Runs the repository's checks (see this script's docstring).")
    parser.add_argument("steps", nargs="*", metavar="step", help=f"any of: {', '.join(STEPS)} (default: all)")
    parser.add_argument("--list", action="store_true", help="list the steps")
    parser.add_argument("--record-goldens", action="store_true", help="play the golden duels and record their results")
    args = parser.parse_args()
    if args.list:
        print("\n".join(STEPS))
        return
    if args.record_goldens:
        record_goldens()
        return
    unknown = [name for name in args.steps if name not in STEPS]
    if unknown:
        parser.error(f"no such step: {', '.join(unknown)}")
    failed = []
    for name in args.steps or STEPS:
        print(f"== {name}")
        problems = STEPS[name]()
        for problem in problems:
            print(problem)
        print(f"{'FAIL' if problems else 'PASS'} {name}")
        if problems:
            failed.append(name)
    print(f"failed: {', '.join(failed)}" if failed else "every check passed")
    sys.exit(1 if failed else 0)


if __name__ == "__main__":
    main()
