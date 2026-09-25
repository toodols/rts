"""Turns Beyond All Reason maps into data modules the game builds its ground from.

Every map's page on beyondallreason.info/maps serves three images, which are in `source/`:

    <slug>-h.webp    the heightmap, 8-bit grey, from the page's min height (black) to its max height (white)
    <slug>-tex.png   the top-down texture
    <slug>-m.webp    the metal map, a bright dot for every metal spot

This reads them and writes `src/shared/bar_maps/<name>.luau` for each map in MAPS: the heights resampled onto the game's own heightmap
grid, one sample to a 4 stud cell at 11 elmos to the stud, so the map is exactly as big as it is in BAR, what Roblox material every cell is (the texture's colour nearest to one of
the map's reference colours below, with the material coloured the average of the texture it stands for), where the
metal spots are and where the teams start. Positions are kept as fractions of the map across and heights in elmos,
and `bar_maps/init.luau` turns them into studs.

Run from anywhere:  python tools/bar_maps/import_bar_maps.py
Needs numpy, Pillow and scipy.
"""

import base64
import os

import numpy as np
from PIL import Image
from scipy import ndimage

HERE = os.path.dirname(os.path.abspath(__file__))
SOURCE = os.path.join(HERE, "source")
OUT = os.path.join(HERE, "..", "..", "src", "shared", "bar_maps")

# The game's scale, from src/shared/config.luau: elmos to the stud, and studs to a heightmap cell. A map is as big here as
# it is in BAR, and sampled once per cell, so nothing is resampled twice.
ELMOS_PER_STUD = 11
CELL_STUDS = 4
ELMOS_PER_MAP_UNIT = 512

# A metal blob this many times the median blob's area is a rich spot.
RICH_AREA_FACTOR = 1.6

# Each map: its BAR name, its wind (least and most) and tidal strength from its page, its size (in BAR map units of 512
# elmos), the heightmap's range in elmos from its page, its
# team start boxes from BAR's map_list.yaml (x0, y0, x1, y1 on 0..200 with y down, the first team's box first), the
# texture palette as (reference colour, material) and the material its cliffs are made of.
MAPS = [
    {
        "name": "supreme_isthmus",
        "wind": (1, 19),
        "tidal": 21,
        "display_name": "Supreme Isthmus",
        "source": "supreme-isthmus",
        "version": "v2.1",
        "author": "Nikuksis",
        "size": (24, 24),
        "heights": (-148, 655),
        "boxes": [(0, 120, 80, 200), (120, 0, 200, 80)],
        # the map has spawn points of its own; these are its front players, P4 and P5 against P12 and P13, in elmos
        "spawns": [[(2513, 7983), (4595, 7440)], [(9764, 4339), (7729, 4835)]],
        "palette": [
            ((100, 98, 92), "Slate"),
            ((87, 86, 80), "Slate"),
            ((75, 74, 65), "Rock"),
            ((63, 83, 12), "Grass"),
            ((91, 97, 11), "LeafyGrass"),
            ((144, 117, 109), "Limestone"),
            ((112, 101, 44), "Sandstone"),
        ],
        "cliff": "Rock",
        "water_color": (46, 74, 92),
    },
    {
        "name": "hooked",
        "wind": (0, 8),
        "tidal": 80,
        "display_name": "Hooked",
        "source": "hooked",
        "version": "1.1.1",
        "author": "Raghna",
        "size": (6, 4),
        "heights": (-60, 940),
        "boxes": [(0, 0, 40, 200), (160, 0, 200, 200)],
        "spawns": None,
        "palette": [
            ((155, 143, 89), "Sand"),
            ((140, 127, 77), "Sand"),
            ((140, 138, 138), "Slate"),
            ((114, 111, 112), "Slate"),
            ((170, 172, 166), "Limestone"),
            ((90, 87, 69), "Rock"),
            ((49, 48, 41), "Basalt"),
        ],
        "cliff": "Basalt",
        "water_color": (52, 84, 104),
    },
    {
        "name": "center_command",
        "wind": (1, 19),
        "tidal": 75,
        "display_name": "Center Command",
        "source": "center-command",
        "version": "BAR v1.0",
        "author": "Nikuksis",
        "size": (16, 8),
        "heights": (-200, 700),
        "boxes": [(0, 0, 50, 200), (150, 0, 200, 200)],
        "spawns": None,
        "palette": [
            ((51, 76, 28), "Grass"),
            ((67, 79, 33), "LeafyGrass"),
            ((58, 59, 18), "Ground"),
            ((78, 78, 14), "Ground"),
            ((37, 40, 16), "Rock"),
            ((17, 18, 11), "Mud"),
            ((104, 98, 73), "Sandstone"),
        ],
        "cliff": "Rock",
        "water_color": (40, 70, 60),
    },
    {
        "name": "rifted",
        "wind": (1, 19),
        "tidal": 15,
        "display_name": "Rifted",
        "source": "rifted",
        "version": "V2",
        "author": "Beherith",
        "size": (16, 16),
        "heights": (-41, 960),
        "boxes": [(0, 150, 50, 200), (150, 0, 200, 50)],
        "spawns": None,
        "palette": [
            ((106, 106, 50), "Grass"),
            ((80, 82, 38), "Grass"),
            ((57, 60, 27), "LeafyGrass"),
            ((105, 104, 124), "Rock"),
            ((72, 72, 88), "Slate"),
            ((42, 42, 51), "Basalt"),
            ((170, 162, 109), "Sand"),
        ],
        "cliff": "Slate",
        "water_color": (44, 86, 96),
    },
    {
        "name": "comet_catcher",
        "wind": (1, 4),
        "tidal": 0,
        "display_name": "Comet Catcher",
        "source": "comet-catcher",
        "version": "Remake 1.8",
        "author": "IceXuick",
        "size": (16, 12),
        "heights": (100, 450),
        "boxes": [(0, 0, 40, 200), (160, 0, 200, 200)],
        "spawns": None,
        "palette": [
            ((158, 158, 151), "Sand"),
            ((149, 149, 142), "Sand"),
            ((142, 142, 135), "Sand"),
            ((130, 130, 124), "Ground"),
            ((110, 110, 106), "Rock"),
            ((87, 89, 85), "Basalt"),
            ((62, 63, 61), "Basalt"),
        ],
        "cliff": "Rock",
        "water_color": (60, 70, 80),
    },
    {
        "name": "altair_crossing",
        "wind": (12, 27),
        "tidal": 20,
        "display_name": "Altair Crossing",
        "source": "altair-crossing",
        "version": "V4.1",
        "author": "Beherith",
        "size": (8, 8),
        "heights": (-125, 875),
        "boxes": [(0, 0, 40, 200), (160, 0, 200, 200)],
        "spawns": None,
        "palette": [
            ((59, 70, 26), "Grass"),
            ((78, 89, 32), "LeafyGrass"),
            ((106, 119, 45), "LeafyGrass"),
            ((166, 159, 128), "Sandstone"),
            ((139, 135, 101), "Sandstone"),
            ((110, 107, 83), "Ground"),
            ((81, 80, 60), "Rock"),
        ],
        "cliff": "Rock",
        "water_color": (40, 76, 100),
    },
    {
        "name": "ancient_bastion",
        "wind": (6, 22),
        "tidal": 18,
        "display_name": "Ancient Bastion",
        "source": "ancient-bastion",
        "version": "Remake 0.5",
        "author": "Russ838, Nikuksis",
        "size": (32, 16),
        "heights": (100, 710),
        # the fortress is the west team's
        "boxes": [(0, 0, 60, 200), (140, 0, 200, 200)],
        "spawns": None,
        "palette": [
            ((35, 43, 21), "Grass"),
            ((47, 53, 26), "LeafyGrass"),
            ((66, 65, 34), "Ground"),
            ((72, 68, 37), "Ground"),
            ((63, 63, 55), "Cobblestone"),
            ((97, 90, 78), "Rock"),
            ((88, 85, 68), "Rock"),
            ((119, 121, 111), "Limestone"),
            ((128, 129, 118), "Limestone"),
        ],
        "cliff": "Rock",
        "water_color": (40, 70, 90),
    },
    {
        "name": "folsom_dam",
        "wind": (2, 20),
        "tidal": 10,
        "display_name": "Folsom Dam",
        "source": "folsom-dam",
        "version": "Remake 1.17",
        "author": "IceXuick",
        "size": (20, 14),
        "heights": (-150, 1190),
        "boxes": [(0, 0, 60, 200), (140, 0, 200, 200)],
        "spawns": None,
        "palette": [
            ((38, 52, 13), "Grass"),
            ((51, 62, 19), "LeafyGrass"),
            ((27, 18, 9), "Rock"),
            ((34, 29, 17), "Rock"),
            ((42, 43, 41), "Slate"),
            ((49, 45, 36), "Slate"),
            ((68, 66, 53), "Slate"),
            ((89, 82, 74), "Concrete"),
            ((112, 106, 99), "Concrete"),
            ((118, 110, 89), "Sand"),
            ((127, 121, 103), "Sand"),
        ],
        "cliff": "Rock",
        "water_color": (44, 78, 88),
    },
    {
        "name": "pinewood_derby",
        "wind": (2, 15),
        "tidal": 20,
        "display_name": "Pinewood Derby",
        "source": "pinewood-derby",
        "version": "V1",
        "author": "Beherith",
        "size": (12, 6),
        "heights": (-125, 875),
        "boxes": [(0, 0, 40, 200), (160, 0, 200, 200)],
        "spawns": None,
        "palette": [
            ((48, 56, 21), "Grass"),
            ((66, 77, 30), "Grass"),
            ((103, 110, 38), "LeafyGrass"),
            ((131, 122, 85), "Ground"),
            ((108, 102, 75), "Ground"),
            ((80, 77, 58), "Rock"),
            ((148, 141, 110), "Sandstone"),
            ((180, 172, 144), "Limestone"),
        ],
        "cliff": "Rock",
        "water_color": (42, 74, 84),
    },
    {
        "name": "acidic_quarry",
        "wind": (2, 24),
        "tidal": 0,
        "display_name": "Acidic Quarry",
        "source": "acidic-quarry",
        "version": "5.17",
        "author": "BasiC, Beherith, IceXuick",
        # the map list's two-team boxes, down the west and east sides
        "boxes": [(15, 15, 60, 185), (140, 15, 185, 185)],
        "size": (12, 12),
        "heights": (-97, 353),
        "spawns": None,
        "palette": [
            ((52, 58, 26), "Grass"),
            ((64, 71, 29), "Grass"),
            ((40, 44, 24), "Grass"),
            ((81, 88, 36), "LeafyGrass"),
            ((24, 25, 22), "Basalt"),
            ((75, 73, 64), "Slate"),
            ((105, 99, 84), "Rock"),
            ((132, 128, 113), "Limestone"),
        ],
        "cliff": "Basalt",
        # the quarry pits hold acid, not water
        "water_color": (96, 120, 30),
    },
    {
        "name": "aurelia",
        "wind": (3, 16),
        "tidal": 14,
        "display_name": "Aurelia",
        "source": "aurelia",
        "version": "v4.1",
        "author": "Johannes",
        "size": (14, 14),
        "heights": (-75, 261),
        "boxes": [(0, 0, 200, 52), (0, 148, 200, 200)],
        "spawns": None,
        "palette": [
            ((154, 77, 54), "Sand"),
            ((169, 91, 54), "Sand"),
            ((136, 64, 53), "Sand"),
            ((131, 106, 102), "Rock"),
            ((113, 89, 90), "Rock"),
            ((142, 91, 82), "Sandstone"),
            ((162, 114, 105), "Limestone"),
            ((93, 68, 67), "Basalt"),
        ],
        "cliff": "Rock",
        "water_color": (70, 84, 90),
    },
    {
        "name": "canis_river",
        "wind": (4, 14),
        "tidal": 10,
        "display_name": "Canis River",
        "source": "canis-river",
        "version": "v1.4",
        "author": "Phalange",
        "size": (14, 14),
        "heights": (-115, 885),
        "boxes": [(0, 140, 115, 200), (85, 0, 200, 60)],
        "spawns": None,
        "palette": [
            ((246, 228, 178), "Sand"),
            ((240, 218, 168), "Sand"),
            ((221, 199, 153), "Sand"),
            ((199, 179, 136), "Sand"),
            ((166, 138, 100), "Sandstone"),
            ((146, 122, 89), "Sandstone"),
            ((108, 92, 67), "Rock"),
            ((63, 53, 40), "Basalt"),
        ],
        "cliff": "Rock",
        "water_color": (60, 90, 96),
    },
    {
        "name": "boulder_beach",
        "wind": (1, 19),
        "tidal": 15,
        "display_name": "Boulder Beach",
        "source": "boulder-beach",
        "version": "V1",
        "author": "Beherith",
        "size": (16, 16),
        "heights": (-205, 795),
        "boxes": [(0, 0, 70, 200), (130, 0, 200, 200)],
        "spawns": None,
        "palette": [
            ((177, 159, 112), "Sand"),
            ((142, 132, 103), "Sand"),
            ((56, 80, 25), "Grass"),
            ((69, 92, 33), "LeafyGrass"),
            ((156, 153, 136), "Limestone"),
            ((100, 103, 83), "Slate"),
            ((72, 79, 61), "Rock"),
            ((38, 43, 35), "Basalt"),
        ],
        "cliff": "Rock",
        "water_color": (40, 86, 100),
    },
    {
        "name": "charlie_in_the_hills",
        "wind": (2, 22),
        "tidal": 20,
        "display_name": "Charlie In The Hills",
        "source": "charlie-in-the-hills",
        "version": "Remake v1.1.1",
        "author": "Nikuksis, after Enetheru, LathanStanley and Ralphie",
        "size": (16, 16),
        "heights": (-111, 1156),
        "boxes": [(0, 0, 200, 50), (0, 150, 200, 200)],
        "spawns": None,
        "palette": [
            ((45, 51, 25), "Grass"),
            ((58, 57, 40), "Ground"),
            ((71, 68, 56), "Rock"),
            ((87, 81, 71), "Rock"),
            ((99, 94, 83), "Slate"),
            ((29, 28, 23), "Basalt"),
            ((124, 101, 87), "Sandstone"),
            ((160, 116, 100), "Sandstone"),
        ],
        "cliff": "Rock",
        "water_color": (40, 66, 70),
    },
    {
        "name": "coast_to_coast",
        "wind": (5, 20),
        "tidal": 16,
        "display_name": "Coast To Coast",
        "source": "coast-to-coast",
        "version": "BAR v1.0",
        "author": "Nikuksis",
        "size": (12, 8),
        "heights": (-180, 520),
        "boxes": [(0, 0, 40, 200), (160, 0, 200, 200)],
        "spawns": None,
        "palette": [
            ((225, 205, 162), "Sand"),
            ((215, 194, 153), "Sand"),
            ((200, 180, 159), "Sandstone"),
            ((190, 171, 149), "Sandstone"),
            ((177, 159, 139), "Sandstone"),
            ((148, 134, 108), "Ground"),
            ((107, 99, 86), "Rock"),
            ((83, 76, 66), "Basalt"),
        ],
        "cliff": "Rock",
        "water_color": (40, 110, 130),
    },
    {
        "name": "devils_postpiles",
        "wind": (6, 14),
        "tidal": 12,
        "display_name": "Devil's Postpiles",
        "source": "devils-postpiles",
        "version": "1.1.1",
        "author": "AidanNaut",
        "size": (12, 12),
        "heights": (-199, 646),
        "boxes": [(0, 0, 32, 200), (168, 0, 200, 200)],
        "spawns": None,
        "palette": [
            ((63, 83, 10), "Grass"),
            ((74, 84, 22), "Grass"),
            ((89, 94, 23), "Grass"),
            ((102, 101, 14), "LeafyGrass"),
            ((87, 81, 62), "Mud"),
            ((101, 98, 45), "Mud"),
            ((103, 100, 85), "Slate"),
            ((141, 111, 26), "Sandstone"),
        ],
        "cliff": "Slate",
        "water_color": (54, 70, 40),
    },
    {
        "name": "faster_than_light",
        "wind": (0, 0),
        "tidal": 0,
        "display_name": "Faster Than Light",
        "source": "faster-than-light",
        "version": "1.1",
        "author": "ShaunJS",
        "size": (12, 12),
        "heights": (-50, 950),
        "boxes": [(13, 23, 73, 73), (125, 129, 175, 189)],
        "spawns": None,
        "palette": [
            ((32, 46, 62), "Pavement"),
            ((29, 34, 43), "Pavement"),
            ((60, 63, 81), "Concrete"),
            ((65, 69, 89), "Concrete"),
            ((75, 78, 85), "Asphalt"),
            ((85, 89, 95), "Asphalt"),
            ((15, 13, 27), "Basalt"),
            ((9, 8, 18), "Basalt"),
        ],
        "cliff": "Basalt",
        # the ship floats in space; what lies under the decks is the void
        "water_color": (10, 9, 20),
    },
    {
        "name": "gasbag_grabens",
        "wind": (4, 16),
        "tidal": 0,
        "display_name": "Gasbag Grabens",
        "source": "gasbag-grabens",
        "version": "1.1.1",
        "author": "AidanNaut",
        "size": (18, 12),
        "heights": (-230, 770),
        "boxes": [(28, 80, 48, 160), (152, 40, 172, 120)],
        "spawns": None,
        "palette": [
            ((108, 101, 58), "Ground"),
            ((124, 118, 69), "Ground"),
            ((95, 78, 46), "Mud"),
            ((140, 88, 68), "Sandstone"),
            ((74, 60, 33), "Rock"),
            ((51, 42, 21), "Rock"),
            ((60, 135, 10), "Grass"),
            ((56, 99, 13), "Grass"),
        ],
        "cliff": "Rock",
        # the grabens hold acid, not water
        "water_color": (90, 130, 20),
    },
    {
        "name": "great_divide",
        "wind": (0, 20),
        "tidal": 16,
        "display_name": "Great Divide",
        "source": "great-divide",
        "version": "V1",
        "author": "NOiZE",
        "size": (6, 8),
        "heights": (243, 682),
        "boxes": [(0, 0, 200, 40), (0, 160, 200, 200)],
        "spawns": None,
        "palette": [
            ((50, 80, 2), "Grass"),
            ((61, 94, 3), "Grass"),
            ((67, 70, 8), "Ground"),
            ((86, 81, 24), "Ground"),
            ((109, 103, 22), "Ground"),
            ((98, 83, 76), "Rock"),
            ((141, 123, 125), "Limestone"),
            ((59, 50, 41), "Basalt"),
        ],
        "cliff": "Rock",
        "water_color": (40, 76, 100),
    },
    {
        "name": "greenest_fields",
        "wind": (5, 20),
        "tidal": 20,
        "display_name": "Greenest Fields",
        "source": "greenest-fields",
        "version": "1.3.1",
        "author": "IceXuick",
        "size": (16, 16),
        "heights": (100, 850),
        "boxes": [(0, 0, 200, 40), (0, 160, 200, 200)],
        "spawns": None,
        "palette": [
            ((50, 58, 15), "Grass"),
            ((74, 80, 18), "LeafyGrass"),
            ((102, 100, 48), "Ground"),
            ((142, 128, 87), "Ground"),
            ((167, 147, 112), "Sandstone"),
            ((180, 160, 126), "Sandstone"),
            ((191, 173, 138), "Sandstone"),
            ((205, 186, 150), "Sandstone"),
        ],
        "cliff": "Sandstone",
        "water_color": (40, 76, 100),
    },
]


def grid_shape(size):
    """Cells along x and z: as many as the map is across at the game's scale, to the nearest even number, since the map
    is centred on (0, 0) and only an even number of cells puts its edges on the terrain's voxel grid."""
    return tuple(2 * round(units * ELMOS_PER_MAP_UNIT / ELMOS_PER_STUD / CELL_STUDS / 2) for units in size)


def load_heights(entry, cells_x, cells_z):
    """Height samples at the cell corners, in elmos: (cells_z + 1) rows of (cells_x + 1)."""
    image = Image.open(os.path.join(SOURCE, entry["source"] + "-h.webp")).convert("RGB")
    grey = np.asarray(image)[:, :, 0].astype(np.float64)
    rows, cols = grey.shape
    # corner samples span the whole image, first pixel to last, as a BAR heightmap does the map
    ys = np.linspace(0, rows - 1, cells_z + 1)
    xs = np.linspace(0, cols - 1, cells_x + 1)
    # smooth first, over about the area one sample stands for, so the resampling does not alias, and never less than
    # enough to melt the 8-bit steps of the source into slopes
    sigma = max(0.8, (cols - 1) / cells_x / 2)
    grey = ndimage.gaussian_filter(grey, sigma)
    yy, xx = np.meshgrid(ys, xs, indexing="ij")
    sampled = ndimage.map_coordinates(grey, [yy, xx], order=1)
    low, high = entry["heights"]
    return low + sampled / 255 * (high - low)


def quantize(heights):
    """Heights as bytes over the range the map actually uses, which is finer than the page's, and that range."""
    lowest = float(np.floor(heights.min()))
    highest = float(np.ceil(heights.max()))
    scaled = np.round((heights - lowest) / (highest - lowest) * 255)
    return np.clip(scaled, 0, 255).astype(np.uint8), lowest, highest


def load_materials(entry, cells_x, cells_z):
    """The palette index of every cell, and the colour each material is given, from the texture."""
    image = Image.open(os.path.join(SOURCE, entry["source"] + "-tex.png")).convert("RGB")
    # a few texels per cell, so each cell can take the material most of it is
    detail = 4
    texels = np.asarray(image.resize((cells_x * detail, cells_z * detail), Image.BOX)).astype(np.float64)

    palette = entry["palette"]
    references = np.array([colour for colour, _ in palette], dtype=np.float64)
    distances = ((texels[:, :, None, :] - references[None, None, :, :]) ** 2).sum(axis=3)
    nearest = distances.argmin(axis=2)

    # materials are what is written, not reference colours, so several colours may make one material
    materials = []
    for _, material in palette:
        if material not in materials:
            materials.append(material)
    to_material = np.array([materials.index(material) for _, material in palette])
    texel_materials = to_material[nearest]

    # each cell is whichever material most of its texels are
    blocks = texel_materials.reshape(cells_z, detail, cells_x, detail).transpose(0, 2, 1, 3).reshape(cells_z, cells_x, -1)
    counts = np.stack([(blocks == index).sum(axis=2) for index in range(len(materials))], axis=2)
    cells = counts.argmax(axis=2)

    # then a majority filter, so single stray cells do not speckle the ground
    padded = np.pad(cells, 1, mode="edge")
    votes = np.zeros((cells_z, cells_x, len(materials)), dtype=np.int32)
    for dz in range(3):
        for dx in range(3):
            window = padded[dz : dz + cells_z, dx : dx + cells_x]
            for index in range(len(materials)):
                votes[:, :, index] += window == index
    votes[np.arange(cells_z)[:, None], np.arange(cells_x)[None, :], cells] += 1
    cells = votes.argmax(axis=2)

    colours = {}
    for index, material in enumerate(materials):
        chosen = texels[texel_materials == index]
        colours[material] = tuple(int(round(value)) for value in chosen.mean(axis=0)) if len(chosen) else (128, 128, 128)

    if entry["cliff"] not in materials:
        raise ValueError(f"{entry['name']}: cliff material {entry['cliff']} is not in its palette")
    return cells.astype(np.uint8), materials, colours


def load_metal(entry):
    """Every metal spot as (u, v, rich), u across and v down the map from 0 to 1."""
    image = Image.open(os.path.join(SOURCE, entry["source"] + "-m.webp")).convert("L")
    grey = np.asarray(image).astype(np.float64)
    rows, cols = grey.shape
    mask = grey > grey.max() * 0.35
    labels, count = ndimage.label(mask)
    if count == 0:
        return []
    indices = range(1, count + 1)
    centres = ndimage.center_of_mass(grey, labels, indices)
    areas = ndimage.sum(mask, labels, indices)
    median = float(np.median(areas))
    spots = []
    for (y, x), area in zip(centres, areas):
        spots.append(((x + 0.5) / cols, (y + 0.5) / rows, area >= median * RICH_AREA_FACTOR))
    # sorted, so the file does not churn when nothing has moved
    spots.sort(key=lambda spot: (round(spot[1], 3), round(spot[0], 3)))
    return spots


def box_starts(box):
    """Two starts in a start box, as (u, v): either side of its middle, across the line to the map's middle."""
    x0, y0, x1, y1 = (value / 200 for value in box)
    centre = np.array([(x0 + x1) / 2, (y0 + y1) / 2])
    towards = np.array([0.5, 0.5]) - centre
    across = np.array([-towards[1], towards[0]])
    across /= np.linalg.norm(across)
    # how far the box reaches that way from its middle, and a starts goes half way out along it
    reach = min(
        (x1 - x0) / 2 / abs(across[0]) if abs(across[0]) > 1e-9 else np.inf,
        (y1 - y0) / 2 / abs(across[1]) if abs(across[1]) > 1e-9 else np.inf,
    )
    offset = across * reach * 0.5
    return [tuple(centre + offset), tuple(centre - offset)]


def starts_for(entry):
    """The four start slots, as (u, v): odd slots are the first team's, even the second's, so 1 faces 2 and 3 faces 4."""
    if entry["spawns"] is not None:
        width = entry["size"][0] * 512
        depth = entry["size"][1] * 512
        teams = [[(x / width, z / depth) for x, z in team] for team in entry["spawns"]]
    else:
        teams = [box_starts(box) for box in entry["boxes"]]
    return [teams[0][0], teams[1][0], teams[0][1], teams[1][1]]


def lua_string(data: bytes) -> str:
    text = base64.b64encode(data).decode("ascii")
    # broken into lines so an editor can open the file
    width = 116
    lines = [text[i : i + width] for i in range(0, len(text), width)]
    return "[[\n" + "\n".join(lines) + "]]"


def colour(value):
    return f"Color3.fromRGB({value[0]}, {value[1]}, {value[2]})"


def write(entry):
    cells_x, cells_z = grid_shape(entry["size"])
    heights, low, high = quantize(load_heights(entry, cells_x, cells_z))
    cells, materials, colours = load_materials(entry, cells_x, cells_z)
    metal = load_metal(entry)
    starts = starts_for(entry)

    material_lines = "\n".join(f"\t\tEnum.Material.{material}," for material in materials)
    colour_lines = "\n".join(f"\t\t[Enum.Material.{material}] = {colour(colours[material])}," for material in materials)
    start_lines = "\n".join(f"\t\tVector2.new({u:.4f}, {v:.4f})," for u, v in starts)
    box_lines = "\n".join(
        f"\t\t{{ min = Vector2.new({x0 / 200:.4f}, {y0 / 200:.4f}), max = Vector2.new({x1 / 200:.4f}, {y1 / 200:.4f}) }},"
        for x0, y0, x1, y1 in entry["boxes"]
    )
    metal_lines = "\n".join(
        f"\t\t{{ at = Vector2.new({u:.4f}, {v:.4f}), rich = {'true' if rich else 'false'} }}," for u, v, rich in metal
    )
    text = f"""-- {entry['display_name']} ({entry['version']}, by {entry['author']}), from Beyond All Reason's map page.
-- Generated by tools/bar_maps/import_bar_maps.py from the images in tools/bar_maps/source; do not edit, rerun that.

return table.freeze({{
	name = "{entry['name']}",
	display_name = "{entry['display_name']}",
	-- in BAR map units, 512 elmos each
	size = Vector2.new({entry['size'][0]}, {entry['size'][1]}),
	cells_x = {cells_x},
	cells_z = {cells_z},
	-- a height byte of 0 is this many elmos up, and 255 this many
	lowest = {low:g},
	highest = {high:g},
	-- (cells_z + 1) rows of (cells_x + 1) height bytes, the first row along the map's north edge
	heights = {lua_string(heights.tobytes())},
	-- cells_z rows of cells_x bytes, each an index into materials counted from 0
	cells = {lua_string(cells.tobytes())},
	materials = {{
{material_lines}
	}},
	colors = {{
{colour_lines}
	}},
	cliff = Enum.Material.{entry['cliff']},
	water_color = {colour(entry['water_color'])},
	-- how hard the wind blows, least and most, and how strong the tide is, as the map's page gives them
	min_wind = {entry['wind'][0]},
	max_wind = {entry['wind'][1]},
	tidal_strength = {entry['tidal']},
	-- as fractions of the map across and down from its north-west corner; the first team on odd slots
	starts = {{
{start_lines}
	}},
	-- each team's start box, where its players choose to start, from BAR's map list, the same way
	start_boxes = {{
{box_lines}
	}},
	metal = {{
{metal_lines}
	}},
}})
"""
    path = os.path.join(OUT, entry["name"] + ".luau")
    with open(path, "w", encoding="utf-8", newline="\n") as file:
        file.write(text)
    usage = {material: int((cells == index).sum()) for index, material in enumerate(materials)}
    print(
        f"{entry['name']}: {cells_x}x{cells_z} cells, {len(metal)} metal spots "
        f"({sum(1 for spot in metal if spot[2])} rich), {os.path.getsize(path) // 1024} KB, materials {usage}"
    )
    return cells, materials, colours


def preview(results):
    """A picture of what each map's materials came out as, beside its texture, in source/preview.png."""
    tiles = []
    for entry, (cells, materials, colours) in results:
        lookup = np.array([colours[material] for material in materials], dtype=np.uint8)
        painted = Image.fromarray(lookup[cells]).resize((cells.shape[1] * 2, cells.shape[0] * 2), Image.NEAREST)
        texture = Image.open(os.path.join(SOURCE, entry["source"] + "-tex.png")).convert("RGB").resize(painted.size)
        tile = Image.new("RGB", (painted.width * 2 + 8, painted.height), "white")
        tile.paste(texture, (0, 0))
        tile.paste(painted, (painted.width + 8, 0))
        tiles.append(tile)
    sheet = Image.new("RGB", (max(tile.width for tile in tiles), sum(tile.height + 8 for tile in tiles)), "white")
    y = 0
    for tile in tiles:
        sheet.paste(tile, (0, y))
        y += tile.height + 8
    sheet.save(os.path.join(HERE, "preview.png"))


def main():
    os.makedirs(OUT, exist_ok=True)
    results = [(entry, write(entry)) for entry in MAPS]
    preview(results)


if __name__ == "__main__":
    main()
