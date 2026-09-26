@echo off
rem Compiles the game's stylesheet, src/client/ui/stylesheets/default.scss (and its partials in default/), and the
rem lobby's, src/lobby/client/stylesheets/lobby.scss (and its partials in lobby/), both on the theme, mixins and base
rem rules they share (src/client_shared/stylesheets/), into the StyleSheet modules the
rem clients require, and the palette Luau reads (src/client_shared/theme.scss): see tools/stylesheets.py.
rem `build_stylesheets game`, `build_stylesheets lobby` or `build_stylesheets theme` compiles one, and
rem further arguments go to outlass, e.g. `build_stylesheets lobby --watch`. `python tools/stylesheets.py check` checks
rem the committed modules are what the SCSS compiles to now.
python "%~dp0tools\stylesheets.py" build %*
