"""unit_defs `scorpion`: a sabot battery, 1x2x1 cells (4x8x4 studs), in its own gold. Under 100 triangles.

The tower line's sloped plinth and tapered column under a flat, heavy launcher head: a low armored
housing with a magazine at the back and two square launch rails side by side, held nearly level (the sabot
is a rocket-boosted shell fired at ground targets that drops only a little), tied at the muzzle by a dark
collar. The head yaws with weapon 1.
"""

from . import defense_a_common as d

KEY = "scorpion"
ACCENT = (226 / 255, 178 / 255, 74 / 255, 1.0)  # Color3.fromRGB(226, 178, 74)
GLOW = (1.0, 0.36, 0.1, 1.0)  # a hot rocket orange, clear of the gold
SWIVEL_Z = 4.5
ELEV = 8.0


def generate(params):
    base = d.Parts()
    base.loft([d.square(3.9, 0.0), d.square(2.9, 1.2)], side="trim", top="trim")
    base.loft([d.square(1.3, 1.2), d.square(1.0, SWIVEL_Z)], side="body")

    head = d.Parts()
    fr = d.Frame()
    head.block_u(fr, 0.0, 0.0, 0.0, 1.2, (2.3, 2.5), (1.6, 1.5), top_shift_f=-0.3,
                 tags={"all": "accent", "bottom": None})
    # the magazine: a dark block sunk into the back of the housing's roof
    head.block_u(fr, 0.0, -0.75, 0.9, 1.5, (1.3, 1.1), (1.1, 0.85), top_shift_f=-0.05,
                 tags={"all": "trim", "bottom": None})

    rails = d.Frame(origin=(0.0, -0.5, 0.7), elev=ELEV)
    # the rails leave the glacis side by side, braced by a dark band and tied at the muzzle by a collar
    for x in (-0.33, 0.33):
        head.block_f(rails, x, 0.0, 0.4, 2.8, (0.3, 0.3), tags={"all": "body", "back": None})
        head.cone_f(rails, 4, 0.2, 3.05, 0.26, x=x)
    head.block_f(rails, 0.0, 0.0, 1.55, 1.75, (1.0, 0.38), tags={"all": "trim"})
    head.block_f(rails, 0.0, 0.0, 2.72, 3.05, (1.12, 0.42), (1.06, 0.38), tags={"all": "trim"})

    objects = d.base_objects(base, KEY, "trim")
    objects += d.head_objects(head, (0.0, 0.0, SWIVEL_Z), KEY, accent_color=ACCENT, glow_color=GLOW)
    return objects
