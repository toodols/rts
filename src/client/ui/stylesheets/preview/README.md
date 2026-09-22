# preview

Builds `../preview.html`, a browser reference render of `default.scss`. Open it next to the game
and compare: anything that differs is outlass translating a property differently, Roblox lacking
it, or one of the harness assumptions in `harness.css` being wrong.

```bash
./build_preview.bat            # one shot, from the repo root
./build_preview.bat --watch    # rebuild when the SCSS or the page parts change
./build_preview.bat --open     # build, then open it
./build_preview.bat --verbose  # keep dart-sass's deprecation warnings
./build_preview.bat --fonts    # re-fetch fonts.css from Google Fonts, then build
```

The CSS in the page is dart-sass output from the project's own partials, not a hand translation, so
it stays honest as the sheet changes. `preview.html` is generated — edit the parts here instead.

| file | what it is |
| --- | --- |
| `build.js` | compile, substitute, concatenate, check |
| `web.scss` | the sass entry: the same five partials `default.scss` compiles |
| `page.head.html` | doctype through the opening `<style>` |
| `fonts.css` | `@font-face` aliases mapping Michroma / RobotoMono / Source Sans Pro to web equivalents |
| `harness.css` | Roblox box-model assumptions, then the page's own chrome (all `h-` prefixed) |
| `page.body.html` | the markup, mirroring the React trees, and the divergence notes |

## Why `web.scss` looks like `default.scss`

It didn't used to. Two things made dart-sass reject the sheet that outlass accepted, so the entry
here was written with `@import` and a hand-written `:root` to work around them:

- **`@extend` scope.** Three `@extend`s — `_resource_bar.scss` (`.readout`), `_selection_panel.scss`
  (`.heading`) and `_build_menu.scss` (`.hazard`) — target selectors declared in `_main.scss`.
  dart-sass scopes an `@extend` to the stylesheet it is written in plus that stylesheet's transitive
  dependencies, and hard-errors with `The target selector was not found.`; outlass used to resolve
  extension sheet-wide. Each of those three partials now `@use`s `main`, which is what makes the
  target visible, and outlass scopes extension the same way.
- **Bare `$var` in a custom property.** `_theme.scss` published its palette as `--Void: $void`.
  dart-sass never evaluates a custom property's value and emitted the literal text, which a browser
  stores and then fails to resolve; outlass used to evaluate it. The `:root` block interpolates
  now, `#{$void}`, which both compilers read the same way.

So the file is `default.scss` with a different compiler pointed at it, and `build.js` no longer has
to delete `:root` blocks or rename `text-stroke` on the way through. What it still substitutes is
Roblox-only syntax with no CSS meaning: element selectors like `Frame`, and `@priority`.
