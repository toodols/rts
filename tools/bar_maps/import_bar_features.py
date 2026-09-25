"""Brings over what Beyond All Reason's maps have lying on them: their geothermal vents and their reclaimable features.

The map pages the rest of each map comes from (import_bar_maps.py) do not say where these are, but the maps themselves
do, so this downloads each map's archive from BAR's file CDN and reads it:

    maps/*.smf                           the map file, whose feature section places features, geovents among them
    mapconfig/featureplacer/set.lua      where most maps put their trees and rocks, through smoth's FeaturePlacer
    features/*.lua                       the map's own feature defs: what each holds and how long it takes to reclaim

A feature's def is looked for among the map's own defs, then every other map's (Hooked places Rifted's pines without
shipping their defs), then BAR's own features/rocks30.lua and the engine trees, and its reclaim time is the engine's
default of (metal + energy) * 6 when the def does not give one (FeatureDefHandler.cpp). A feature that is not
reclaimable, or holds nothing, is left out.

It writes src/shared/bar_maps/<name>_features.luau for each map, with positions as fractions of the map across (u, from
its west edge) and down (v, from its north edge), as the other data modules have them.

Run from anywhere:  python tools/bar_maps/import_bar_features.py
Needs lupa (Lua for Python) and 7-Zip (7z on the PATH, or in Program Files). The archives are kept in the system's
temporary folder between runs, since they are large.
"""

import glob
import json
import math
import os
import re
import shutil
import struct
import subprocess
import tempfile
import urllib.parse
import urllib.request

import lupa

HERE = os.path.dirname(os.path.abspath(__file__))
OUT = os.path.join(HERE, "..", "..", "src", "shared", "bar_maps")
CACHE = os.path.join(tempfile.gettempdir(), "bar_map_archives")

BAR_RAW = "https://raw.githubusercontent.com/beyond-all-reason/Beyond-All-Reason/master/"
# BAR's own features, which a map can place without defining them
BAR_FEATURES = ["features/rocks30.lua", "features/enginetrees_override.lua"]

# Each map by its name here and its springName in BAR's maps-metadata map_list.yaml
MAPS = {
    "supreme_isthmus": "Supreme Isthmus v2.1",
    "hooked": "Hooked 1.1.1",
    "center_command": "Center Command BAR v1.0",
    "rifted": "Rifted_V2",
    "comet_catcher": "Comet Catcher Remake 1.8",
    "altair_crossing": "Altair_Crossing_V4.1",
    "ancient_bastion": "Ancient Bastion Remake 0.5",
    "folsom_dam": "FolsomDamR 1.17",
    "pinewood_derby": "Pinewood_Derby_V1",
    "acidic_quarry": "AcidicQuarry 5.17",
    "aurelia": "Aurelia v4.1",
    "canis_river": "Canis River v1.4",
    "boulder_beach": "Boulder_Beach_V1",
    "charlie_in_the_hills": "Charlie In The Hills Remake v1.1.1",
    "coast_to_coast": "Coast To Coast BAR v1.0",
    "devils_postpiles": "Devil's Postpiles 1.1.1",
    "faster_than_light": "Faster Than Light 1.1",
    "gasbag_grabens": "Gasbag Grabens 1.1.1",
    "great_divide": "Great Divide V1",
    "greenest_fields": "Greenest Fields 1.3.1",
}

# How what a feature holds decides which of the game's reclaimables it is drawn as (unit_defs/reclaimable.luau): metal
# makes a rock, sized by its footprint; energy alone makes a tree, or a shrub if it holds little.
SHRUB_ENERGY = 100


def seven_zip():
    found = shutil.which("7z")
    if found:
        return found
    for candidate in [r"C:\Program Files\7-Zip\7z.exe", r"C:\Program Files (x86)\7-Zip\7z.exe"]:
        if os.path.exists(candidate):
            return candidate
    raise SystemExit("7-Zip is needed to open the map archives")


# the CDN turns away Python's own user agent
HEADERS = {"User-Agent": "Mozilla/5.0 (import_bar_features.py)"}


def get(url):
    return urllib.request.urlopen(urllib.request.Request(url, headers=HEADERS))


def download(spring_name):
    os.makedirs(CACHE, exist_ok=True)
    query = urllib.parse.quote(spring_name)
    with get(f"https://files-cdn.beyondallreason.dev/find?category=map&springname={query}") as reply:
        found = json.load(reply)
    if not found:
        raise SystemExit(f"BAR's file CDN has no map {spring_name!r}")
    path = os.path.join(CACHE, found[0]["filename"])
    if not os.path.exists(path):
        print(f"downloading {found[0]['filename']}")
        with get(found[0]["mirrors"][0]) as reply, open(path, "wb") as out:
            shutil.copyfileobj(reply, out)
    return path


def extract(archive):
    target = archive + ".x"
    if not os.path.isdir(target):
        subprocess.run(
            [seven_zip(), "x", "-y", f"-o{target}", archive, "maps/*.smf", "mapconfig/featureplacer/set.lua",
             "features/*.lua", "-r"],
            check=True,
            stdout=subprocess.DEVNULL,
        )
    return target


def smf_features(path):
    """The map's size in elmos, and every feature its SMF places as (name, x, z, heading)."""
    data = open(path, "rb").read()
    header = struct.unpack_from("<16s i i i i i i i f f i i i i i i i", data, 0)
    size = (header[3] * 8, header[4] * 8)
    offset = header[15]
    type_count, feature_count = struct.unpack_from("<ii", data, offset)
    offset += 8
    types = []
    for _ in range(type_count):
        end = data.index(b"\0", offset)
        types.append(data[offset:end].decode("latin1"))
        offset = end + 1
    features = []
    for _ in range(feature_count):
        kind, x, _y, z, rotation, _scale = struct.unpack_from("<ifffff", data, offset)
        offset += 24
        features.append((types[kind], x, z, rotation))
    return size, features


PLACED = re.compile(
    r"""name\s*=\s*['"]([^'"]+)['"]\s*,\s*x\s*=\s*([-\d.]+)\s*,\s*(?:y\s*=\s*[-\d.]+\s*,\s*)?z\s*=\s*([-\d.]+)"""
    r"""(?:\s*,\s*rot\s*=\s*['"]?([-\d.]+))?"""
)


def placer_features(path):
    """Every feature FeaturePlacer's set.lua puts down, as (name, x, z, heading), leaving out lines commented away."""
    if not os.path.exists(path):
        return []
    features = []
    for line in open(path, encoding="latin1"):
        if line.strip().startswith("--"):
            continue
        for match in PLACED.finditer(line):
            # FeaturePlacer's rot is a heading in Spring's units, 65536 to the turn
            heading = float(match.group(4) or 0) * math.pi / 32768
            features.append((match.group(1), float(match.group(2)), float(match.group(3)), heading))
    return features


def feature_defs(sources):
    """Every feature def in `sources`, Lua files of them, by lowercased name, as the numbers that matter here."""
    lua = lupa.LuaRuntime(unpack_returned_tuples=True)
    lua.execute(
        """
        function lowerkeys(t) local n = {} for k, v in pairs(t) do n[string.lower(k)] = v end return n end
        VFS = { Include = function() return {} end, DirList = function() return {} end,
            FileExists = function() return false end }
        Spring = { Echo = function() end, GetModOptions = function() return {} end }
        """
    )
    defs = {}
    for name, source in sources:
        try:
            result = lua.execute(source)
        except lupa.LuaError as error:
            print(f"  skipping {name}: {str(error)[:80]}")
            continue
        if result is None:
            continue
        for key, table in result.items():
            if lupa.lua_type(table) != "table":
                continue
            fields = {str(k).lower(): v for k, v in table.items() if isinstance(k, str)}
            metal = float(fields.get("metal") or 0)
            energy = float(fields.get("energy") or 0)
            reclaim = fields.get("reclaimtime")
            entry = {
                "metal": metal,
                "energy": energy,
                "reclaim": float(reclaim) if reclaim is not None else max(1.0, (metal + energy) * 6),
                "reclaimable": fields.get("reclaimable", True) not in (False, 0, "false", "0"),
                "footprint": float(fields.get("footprintx") or 1),
            }
            defs[str(key).lower()] = entry
            if fields.get("name"):
                defs[str(fields["name"]).lower()] = entry
    return defs


def fetch(path):
    with get(BAR_RAW + path) as reply:
        return reply.read().decode("latin1")


def drawn_as(entry):
    if entry["metal"] > 0:
        if entry["footprint"] >= 4:
            return "large_rock"
        return "rock" if entry["footprint"] >= 2 else "small_rock"
    return "shrub" if entry["energy"] <= SHRUB_ENERGY else "tree"


def main():
    extracted = {name: extract(download(spring_name)) for name, spring_name in MAPS.items()}

    everyone = []
    for folder in extracted.values():
        for path in glob.glob(os.path.join(folder, "features", "*.lua")):
            everyone.append((path, open(path, encoding="latin1").read()))
    shared = feature_defs([(path, fetch(path)) for path in BAR_FEATURES] + everyone)

    for name, folder in extracted.items():
        own = feature_defs(
            [(path, open(path, encoding="latin1").read()) for path in glob.glob(os.path.join(folder, "features", "*.lua"))]
        )
        size, placed = smf_features(glob.glob(os.path.join(folder, "maps", "*.smf"))[0])
        placed += placer_features(os.path.join(folder, "mapconfig", "featureplacer", "set.lua"))

        vents = []
        lines = []
        unknown = set()
        for feature, x, z, heading in placed:
            u, v = x / size[0], z / size[1]
            if not (0 <= u <= 1 and 0 <= v <= 1):
                continue
            if feature.lower() == "geovent":
                vents.append((u, v))
                continue
            entry = own.get(feature.lower()) or shared.get(feature.lower())
            if entry is None:
                unknown.add(feature)
                continue
            if not entry["reclaimable"] or entry["metal"] + entry["energy"] <= 0:
                continue
            lines.append(
                f"{drawn_as(entry)} {u:.5f} {v:.5f} {heading:.2f} {entry['metal']:g} {entry['energy']:g} "
                f"{entry['reclaim']:g}"
            )

        vent_lines = "\n".join(f"\t\tVector2.new({u:.5f}, {v:.5f})," for u, v in vents)
        path = os.path.join(OUT, f"{name}_features.luau")
        with open(path, "w", encoding="utf-8", newline="\n") as out:
            out.write(
                f"""-- What {name} has lying on it in Beyond All Reason: its geothermal vents and its reclaimable features.
-- Generated by tools/bar_maps/import_bar_features.py from the map's own archive; do not edit, rerun that.

return table.freeze({{
	-- every geothermal vent, as a fraction of the map across and down
	geovents = {{
{vent_lines}
	}},
	-- one reclaimable a line: what it is drawn as, where it is (across, down), its heading in radians, and the metal
	-- and energy it holds and the buildpower reclaiming it takes
	features = [[
{chr(10).join(lines)}
]],
}})
"""
            )
        note = f", {len(unknown)} unknown ({', '.join(sorted(unknown)[:5])})" if unknown else ""
        print(f"{name}: {len(vents)} geovents, {len(lines)} reclaimables{note}")


if __name__ == "__main__":
    main()
