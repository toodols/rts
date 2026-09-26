"""Compiles the game's and the lobby's SCSS into the StyleSheet modules the clients require, and the theme's palette on
its own into the StyleSheet module Luau reads its colours from (src/client_shared/theme_stylesheet.lua), and checks the
committed modules are what their SCSS compiles to now.

    python tools/stylesheets.py build [game|lobby|theme] [outlass arguments, e.g. --watch]
    python tools/stylesheets.py check

`build` compiles both sheets, or the one named (watching blocks, so watch one at a time). `check` compiles each into a
temporary file and fails if outlass warned about anything (a warning is CSS Roblox cannot express) or if the result
differs from the committed module: an SCSS change whose module was not rebuilt.

outlass comes from PATH if it is installed, and otherwise is built from its checkout beside this repository's main
working tree (../outlass). It is unreleased, with no commits to pin a version by, so it has to be OUTLASS_VERSION, which
the committed modules name as what compiled them, and `check` is how any other difference in it shows up.
"""

import functools
import shutil
import subprocess
import sys
import tempfile
from pathlib import Path

REPO_ROOT = Path(__file__).resolve().parent.parent
# the outlass every committed module is compiled by
OUTLASS_VERSION = "0.1.0"

# Each sheet: its SCSS and the module it compiles to. The game's and the lobby's share the theme, mixins and base rules
# in src/client_shared/stylesheets/.
SHEETS = {
    "game": ("src/client/ui/stylesheets/default.scss", "src/client/ui/stylesheets/default_stylesheet.lua"),
    "lobby": ("src/lobby/client/stylesheets/lobby.scss", "src/lobby/client/stylesheets/lobby_stylesheet.lua"),
    "theme": ("src/client_shared/theme.scss", "src/client_shared/theme_stylesheet.lua"),
}


def outlass_checkout():
    """../outlass beside the repository's main working tree (a git worktree's own parent is not where it is)."""
    common = subprocess.run(
        ["git", "rev-parse", "--path-format=absolute", "--git-common-dir"], cwd=REPO_ROOT, capture_output=True, text=True
    ).stdout.strip()
    main_tree = Path(common).parent if common else REPO_ROOT
    return main_tree.parent / "outlass"


@functools.cache
def outlass():
    """The command that runs outlass, once it is known to be OUTLASS_VERSION."""
    installed = shutil.which("outlass")
    command = [installed] if installed else [
        "cargo", "run", "--release", "--quiet", "--manifest-path", str(outlass_checkout() / "Cargo.toml"), "--"
    ]
    result = subprocess.run(command + ["--version"], cwd=REPO_ROOT, capture_output=True, text=True)
    version = result.stdout.strip().removeprefix("outlass ")
    if result.returncode != 0 or version != OUTLASS_VERSION:
        sys.exit(f"needs outlass {OUTLASS_VERSION} (on PATH, or checked out at {outlass_checkout()}); found: "
                 f"{(result.stdout + result.stderr).strip()[:300]}")
    return command


def compile_sheet(scss, out, extra=()):
    """Runs outlass on `scss` into `out`; returns what it printed other than the line saying it wrote the file."""
    result = subprocess.run(
        outlass() + [scss, "--approx", "-o", str(out), *extra], cwd=REPO_ROOT, capture_output=True, text=True
    )
    said = [line for line in (result.stdout + result.stderr).splitlines() if line.strip() and not line.startswith("wrote ")]
    if result.returncode != 0:
        sys.exit(f"outlass failed on {scss}:\n" + "\n".join(said))
    return said


def build(args):
    names = [args.pop(0)] if args and args[0] in SHEETS else list(SHEETS)
    for name in names:
        scss, module = SHEETS[name]
        if "--watch" in args:
            # watching never returns, so it runs attached
            subprocess.run(outlass() + [scss, "--approx", "-o", module, *args], cwd=REPO_ROOT)
            continue
        for line in compile_sheet(scss, module, args):
            print(f"{name}: {line}")
        print(f"wrote {module}")


def check():
    problems = []
    with tempfile.TemporaryDirectory() as scratch:
        for name, (scss, module) in SHEETS.items():
            out = Path(scratch) / Path(module).name
            problems += [f"{scss}: {line}" for line in compile_sheet(scss, out)]
            if out.read_bytes() != (REPO_ROOT / module).read_bytes():
                problems.append(f"{module} is not what {scss} compiles to now: run build_stylesheets")
    for problem in problems:
        print(problem)
    print(f"{len(problems)} problems")
    sys.exit(1 if problems else 0)


def main():
    if len(sys.argv) < 2 or sys.argv[1] not in ("build", "check"):
        sys.exit(__doc__)
    if sys.argv[1] == "build":
        build(sys.argv[2:])
    else:
        check()


if __name__ == "__main__":
    main()
