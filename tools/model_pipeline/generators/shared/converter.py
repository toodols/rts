"""Shared builder for the energy converter family: energy_converter, advanced_energy_converter
and epic_energy_converter, each filling its def's footprint in its def's colour. One design that grows per tier
rather than only scaling, under 100 triangles:

- a sloped steel-blue tank whose top holds a glowing energy pool right up at the brim -- "filled to the brim with
  energy" -- and a metal output hood on the front (Blender -Y, Roblox +Z),
- tier 2 adds four capacitor posts at the corners,
- tier 3 also raises a condenser spire out of the middle of the pool, tipped with a glow.
"""

from . import common
from . import palette


def generate(params, tier):
    """tier: 1 (energy_converter), 2 (advanced_energy_converter) or 3 (epic_energy_converter)."""
    collider = params["collider"]
    height = collider["height"]
    w = min(collider["width"], collider["length"])

    m = common.Materials(params["color"], palette.CONVERTER_CYAN)

    objects = []

    tank_h = height * (0.55 if tier >= 2 else 0.62)
    tank = common.drop_bottom(common.block("tank", w * 0.95, w * 0.95, tank_h, top=(w * 0.82, w * 0.82)))
    m.accent(tank)
    objects.append(tank)

    # the pool stands just proud of the tank's top, inside a lip of the tank's own edge
    pool = common.drop_bottom(common.box("pool", w * 0.68, w * 0.68, height * 0.05, origin=(0.0, 0.0, tank_h)))
    m.glow(pool)
    objects.append(pool)

    # metal output hood on the front, dark, sloping back into the tank
    chute_w = w * 0.36
    chute = common.drop_bottom(
        common.block("chute", chute_w, w * 0.18, tank_h * 0.55, top=(chute_w * 0.8, w * 0.05), top_offset=(0.0, w * 0.06), origin=(0.0, -w * 0.5, 0.0))
    )
    common.trim_mat(chute)
    objects.append(chute)

    if tier >= 2:
        post_w = w * 0.12
        post_h = height * 0.85 - tank_h
        c = w * 0.38
        for sx in (-1.0, 1.0):
            for sy in (-1.0, 1.0):
                post = common.drop_bottom(
                    common.block("post", post_w, post_w, post_h, top=(post_w * 0.6, post_w * 0.6), origin=(sx * c, sy * c, tank_h))
                )
                common.body_mat(post)
                objects.append(post)

    if tier >= 3:
        spire_h = height * 0.95 - tank_h
        spire = common.pyramid("spire", w * 0.14, w * 0.14, spire_h, origin=(0.0, 0.0, tank_h), base=False)
        common.body_mat(spire)
        objects.append(spire)
        tip = common.octahedron("spire_tip", w * 0.05, origin=(0.0, 0.0, tank_h + spire_h * 0.75))
        m.glow(tip)
        objects.append(tip)

    return objects
