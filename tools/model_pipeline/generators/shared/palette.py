"""Every colour a model is painted in (RGBA, 0 to 1), named by what it is, in one place: check_art.py fails on a colour
written anywhere else in generators/, so no colour is kept twice or drifts apart between the models that share it.

Each model adds its def's colour as its team accent (build.py's params["color"]), and a reclaimable is its def's
colour; neither is here. A glow is Neon in the game (common.glow_mat).
"""


def rgb(r, g, b):
    """A colour from 0-255 bytes, as Color3.fromRGB takes them."""
    return (r / 255.0, g / 255.0, b / 255.0, 1.0)


# --- the paints every unit and building share (common.Materials) ---------------------------------------------------

BODY = (0.40, 0.40, 0.43, 1.0)  # gunmetal body panels
TRIM = (0.17, 0.17, 0.19, 1.0)  # near-black trim: footings, collars, braces
HIVIS = (0.95, 0.78, 0.12, 1.0)  # a builder's high-vis yellow, which unlike an accent no team tints

# --- glows ---------------------------------------------------------------------------------------------------------

NANO = (0.35, 0.95, 0.75, 1.0)  # a nanolathe's green-cyan emitter
AMBER = (1.0, 0.72, 0.15, 1.0)  # the towers' warm amber: plasma guns, ships' windows, a tank's lamps and muzzle
HEADLIGHT = (1.0, 0.78, 0.35, 1.0)  # the tier-two vehicles' warm headlight amber
JET_EXHAUST = (1.0, 0.55, 0.16, 1.0)  # the aircraft's exhaust, amber-orange
ELECTRIC_BLUE = (0.35, 0.65, 1.0, 1.0)  # a stealth jet's cold exhaust; the Thor's tesla coils
LENS_ORANGE = (1.0, 0.5, 0.0, 1.0)  # a destroyer's gun lens
HOT_ORANGE = (1.0, 0.55, 0.15, 1.0)  # a heavy rocket's motor, the commander's disintegrator
ROCKET_MOTOR = (1.0, 0.6, 0.2, 1.0)  # a light rocket's motor
ROCKET_FLAME = (1.0, 0.36, 0.1, 1.0)  # a hot rocket orange, clear of the gold
PLASMA_ORANGE = (1.0, 0.42, 0.08, 1.0)  # a heavy plasma cannon's feeds
PLASMA_GOLD = (1.0, 0.72, 0.25, 1.0)  # a light plasma cannon's muzzle
HEAT_ORANGE = (1.0, 0.45, 0.12, 1.0)  # the experimentals' heat
GEOTHERMAL_CORE = (1.0, 0.5, 0.12, 1.0)  # geothermal heat, orange
VENT_HEAT = (1.0, 0.24, 0.05, 1.0)  # a geothermal vent's heat, redder than an extractor's molten ore
DEEP_VENT_HEAT = (1.0, 0.38, 0.10, 1.0)  # the advanced geothermal plant's molten orange-red
MOLTEN_ORE = (1.0, 0.55, 0.18, 1.0)  # molten ore in an extractor's throat
SOLAR_GLOW = (1.0, 0.82, 0.30, 1.0)  # a solar collector's light
FUSION_GLOW = (1.0, 0.82, 0.25, 1.0)  # a fusion reactor's orb
WARNING_AMBER = (1.0, 0.55, 0.1, 1.0)  # warning lights, amber
WARNING_RED = (1.0, 0.25, 0.12, 1.0)  # warning lights, red
BEACON_RED = (1.0, 0.25, 0.15, 1.0)  # an assault bot's visor, a wind turbine's warning light
LASER_RED = (1.0, 0.12, 0.08, 1.0)  # a red laser lens
SIGHT_RED = (1.0, 0.15, 0.08, 1.0)  # a gun's red sight
HOSTILE_RED = (1.0, 0.35, 0.25, 1.0)  # a drone's hostile red eye, its laser's colour
SCOUT_EYE = (1.0, 0.35, 0.2, 1.0)  # a scout's red eye; a tier-two bot's glow unless it has its own
SPIDER_EYE = (1.0, 0.3, 0.2, 1.0)  # a spider bot's eyes
LASER_ORANGE = (1.0, 0.45, 0.25, 1.0)  # a light laser rifle, hot red-orange
HEAVY_LASER = (1.0, 0.22, 0.12, 1.0)  # a heavy laser, red
SNIPER_YELLOW = (1.0, 0.95, 0.2, 1.0)  # a sniper's scope
LASER_YELLOW = (1.0, 0.95, 0.3, 1.0)  # a hovercraft's yellow laser
LASER_GREEN = (0.2, 1.0, 0.25, 1.0)  # a heavy hovercraft's green laser lens
MENDING_GREEN = (0.35, 1.0, 0.55, 1.0)  # a self-mending bot's visor
ICE_BLUE = (0.55, 0.85, 1.0, 1.0)  # a blue laser
SEEKER_BLUE = (0.55, 0.9, 1.0, 1.0)  # icy blue seeker lenses
DEFLECTOR_BLUE = (0.55, 0.95, 1.0, 1.0)  # a plasma deflector's ice blue
INTERCEPTOR_BLUE = (0.45, 0.9, 1.0, 1.0)  # an anti-nuke's interceptor ice blue
PLASMA_BLUE = (0.45, 0.85, 1.0, 1.0)  # an artillery walker's plasma
AA_BLUE = (0.25, 0.8, 1.0, 1.0)  # a cold seeker blue for the anti-air missiles
TACHYON = (0.2, 0.8, 1.0, 1.0)  # the tachyon accelerator's cyan
STORAGE_CYAN = (0.45, 0.95, 1.0, 1.0)  # an energy store's cells, far from its gold and steel
CONVERTER_CYAN = (0.35, 0.85, 1.0, 1.0)  # an energy converter's pool
AQUA = (0.35, 0.9, 1.0, 1.0)  # a tidal generator's glow, the commander's visor
HEAVY_PLASMA = (0.2, 0.7, 1.0, 1.0)  # a heavy plasma cannon, blue
EMP = rgb(130, 215, 255)  # the pale turquoise of an EMP
SCAVENGER = (0.85, 0.25, 1.0, 1.0)  # the scavengers' violet

# --- surfaces ------------------------------------------------------------------------------------------------------

CANOPY_GLASS = (0.10, 0.16, 0.22, 1.0)  # dark tinted canopy glass
INK = (0.06, 0.06, 0.08, 1.0)  # near-black: a rubber ducky's eyes, the cursor's outline
SOLAR_CELL = (0.07, 0.11, 0.24, 1.0)  # deep blue photovoltaic glass
SCAVENGER_DARK = (0.10, 0.08, 0.12, 1.0)  # the scavenger beacons' near-black, a touch purple
RUBBER = (0.06, 0.06, 0.07, 1.0)  # a hovercraft's skirt: matte black rubber, darker than the metal trim
SKIRT = (0.08, 0.08, 0.09, 1.0)  # a light hovercraft's skirt
WIND_BLADE = (0.75, 0.76, 0.78, 1.0)  # a wind turbine's pale blades
CONCRETE = (0.50, 0.52, 0.54, 1.0)  # a wall's concrete teeth

# --- props: the skins' floats, the tutorial's boulder, the scenery ------------------------------------------------

FLOAT_WHITE = (0.96, 0.96, 0.94, 1.0)  # a pool float's white
DONUT_RED = (0.9, 0.22, 0.2, 1.0)  # the striped ring's stripes
DONUT_VALVE = (0.8, 0.8, 0.78, 1.0)
LIFEBUOY_RED = (0.9, 0.2, 0.18, 1.0)
DOUGH = (0.83, 0.6, 0.36, 1.0)
ICING = (0.96, 0.45, 0.66, 1.0)
DUCK_YELLOW = (1.0, 0.83, 0.16, 1.0)
DUCK_BEAK = (1.0, 0.5, 0.08, 1.0)
BOULDER = (0.47, 0.45, 0.42, 1.0)
BOULDER_RUBBLE = (0.31, 0.27, 0.23, 1.0)
TREE_TRUNK = (0.361, 0.259, 0.173, 1.0)  # 92, 66, 44

# --- the HUD's pictures (shown unlit, ClientShared.art_icon) -------------------------------------------------------

ICON_OUTLINE = rgb(22, 24, 30)  # every icon's outline, which also draws what is inside it
ICON_FILL = rgb(236, 244, 252)  # every icon's fill: the HUD's text colour (stylesheets' $text)
KEYCAP = (0.86, 0.86, 0.83, 1.0)
KEY_GLYPH = (0.10, 0.10, 0.12, 1.0)
MOUSE_SHELL = (0.15, 0.15, 0.17, 1.0)
MOUSE_BUTTON = (0.62, 0.63, 0.66, 1.0)
MOUSE_WHEEL = (0.36, 0.37, 0.40, 1.0)
CURSOR_FILL = (0.97, 0.97, 0.97, 1.0)
CHECK_FILL = (0.22, 0.80, 0.30, 1.0)
CHECK_RIM = (0.04, 0.30, 0.08, 1.0)
CROSS_FILL = (0.90, 0.18, 0.16, 1.0)
CROSS_RIM = (0.38, 0.04, 0.04, 1.0)
