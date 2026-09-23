"""Shared builder for the fusion reactor family: fusion_reactor, advanced_fusion_reactor and
epic_fusion_reactor. unit_defs/building.luau gives them one color (Color3.fromRGB(232, 200, 92))
at three sizes (3, 4 and 5 grid cells cubed), so this is one design -- "an energetic contained orb
on the base" -- that grows more containment per tier instead of only scaling up, and stays under 100 triangles:

- a sloped deck with a glowing orb above it and four dark spikes leaning in round it,
- one equatorial containment ring on tier 1, plus a standing one on tier 2, plus a second, crossed standing one
  on tier 3 (a gyroscope). Rings are open hexagonal bands (five-sided on tier 3, to stay in budget).

The standing rings are rigid pieces of their own centred on the orb (common.art_group), and spin in the game.
"""

import math

from . import common

ACCENT_COLOR = (0.910, 0.784, 0.361, 1.0)  # unit_defs Color3.fromRGB(232, 200, 92)
GLOW_COLOR = (1.0, 0.82, 0.25, 1.0)


def generate(params, tier):
    """tier: 1 (fusion_reactor), 2 (advanced_fusion_reactor) or 3 (epic_fusion_reactor)."""
    width = float(params.get("width", 12.0))
    depth = float(params.get("depth", 12.0))
    height = float(params.get("height", 12.0))
    w = min(width, depth)

    def accent_mat(obj):
        common.apply_material(obj, "reactor_accent", ACCENT_COLOR, roughness=0.4, metallic=0.3)

    def glow_mat(obj):
        common.apply_material(obj, "reactor_glow", GLOW_COLOR, roughness=0.1, emission=1.2)

    objects = []

    deck_h = height * 0.14
    deck = common.drop_bottom(common.tapered_box("deck", w * 0.97, w * 0.97, deck_h, w * 0.8, w * 0.8))
    common.body_mat(deck)
    objects.append(deck)

    orb_r = w * 0.2
    orb_z = deck_h + orb_r * 1.5
    orb = common.octahedron("orb", orb_r, origin=(0.0, 0.0, orb_z))
    orb.rotation_euler = (0.0, 0.0, math.radians(45.0))
    glow_mat(orb)
    objects.append(orb)

    # four spikes from the deck's corners leaning in over the orb (four triangles each, no base)
    spike_h = orb_z + orb_r * 1.6 - deck_h
    corner = w * 0.33
    for sx in (-1.0, 1.0):
        for sy in (-1.0, 1.0):
            spike = common.pyramid(
                "spike", w * 0.11, w * 0.11, spike_h, apex=(-sx * w * 0.1, -sy * w * 0.1),
                origin=(sx * corner, sy * corner, deck_h), base=False,
            )
            common.trim_mat(spike)
            objects.append(spike)

    segments = 5 if tier >= 3 else 6
    band_h = w * 0.05
    equator = common.band("ring_equator", orb_r * 1.7, band_h, segments=segments, origin=(0.0, 0.0, orb_z))
    accent_mat(equator)
    objects.append(equator)

    standing = []
    if tier >= 2:
        standing.append(("ring_meridian", orb_r * 1.45, (math.pi / 2.0, 0.0, 0.0), 0.9))
    if tier >= 3:
        standing.append(("ring_cross", orb_r * 1.25, (math.pi / 2.0, 0.0, math.pi / 2.0), -0.9))
    for name, radius, rot, speed in standing:
        ring = common.band(name, radius, band_h, segments=segments, origin=(0.0, 0.0, orb_z))
        ring.rotation_euler = rot
        accent_mat(ring)
        # the standing rings turn about the vertical, each the other way to the last, sweeping through one
        # another round the orb like a gyroscope's
        objects.append(common.art_group(ring, name, pivot=True, kind="spin", axis=(0.0, 0.0, 1.0), speed=speed))

    return objects
