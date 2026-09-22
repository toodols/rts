# Models

Art for units and buildings. Anything in here is synced to `ReplicatedStorage.Models` and picked up
automatically by `src/server/instances.luau`.

## Adding a model

Name the file after the def name in `src/shared/unit_defs.luau`, so the Bot Lab is `bot_lab.rbxm`,
and the two bots are `constructor.rbxm` and `grunt.rbxm`. Save from Studio with right click →
*Save to File*, or use a `.model.json` for something simple.

Requirements:

- The root must be a `Model`. The renderer moves it whole with `PivotTo`, so where the model's **pivot**
  sits across the model is the unit's centre, and `+Z` from it is the direction it faces. Studio's
  *Edit Pivot* sets it; a `PrimaryPart` also defines it, but is not required and is never read
  directly.
- Height is handled for you: the lowest point of the model is always placed on the bottom of the
  collider, whatever the model's size and wherever its pivot is vertically.
- A model is never rescaled: it is drawn at the size it was authored. The collider in `unit_defs.luau`
  is what the simulation uses for spacing, blocking and picking, so build the model to about that
  size, or change the collider to match. A Grunt's capsule is `radius = 1, height = 3`, so about 2
  studs across and 3 tall.
- Whatever colour, material and transparency each part has is kept. Parts named `Team` are tinted
  with the team colour, and a blueprint or a wreck is drawn over the whole model until it is finished
  or restored.
- Leave every part `Anchored`. The simulation owns position; physics must never move a unit.

Team colour is applied to any part named `Team` (or tagged `team_color`). Everything else keeps the
colour you gave it.

Until a file exists for a def, that entity renders as a primitive the size of its collider: a box
for buildings, a car, bot or triangle for units, and the server warns once per def that it is
doing so. Units get a procedural stand-in that fits inside the collider (see
`src/server/unit_placeholder.luau`), and its parts named `Team` are tinted like a real model's.
