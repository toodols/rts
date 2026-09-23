@echo off
rem Compiles the game's stylesheet, src/client/ui/stylesheets/default.scss (and its partials in default/), and the
rem lobby's, src/lobby/client/stylesheets/lobby.scss (which uses the same partials), into the StyleSheet modules the
rem clients require. Uses `outlass` from PATH if it's installed, otherwise builds it from ../outlass. Extra arguments
rem are passed through to both, e.g. `build_stylesheets --watch` (watching one sheet blocks, so run it per sheet:
rem `build_stylesheets --watch` watches the game's, `build_stylesheets lobby --watch` the lobby's).
setlocal
set GAME_INPUT=src/client/ui/stylesheets/default.scss
set GAME_OUTPUT=src/client/ui/stylesheets/default_stylesheet.lua
set LOBBY_INPUT=src/lobby/client/stylesheets/lobby.scss
set LOBBY_OUTPUT=src/lobby/client/stylesheets/lobby_stylesheet.lua

where outlass >nul 2>nul
if %errorlevel%==0 (
	set OUTLASS=outlass
) else (
	set OUTLASS=cargo run --release --quiet --manifest-path ../outlass/Cargo.toml --
)

if "%1"=="lobby" (
	shift
	goto lobby
)
if "%1"=="game" (
	shift
	goto game
)
%OUTLASS% %GAME_INPUT% --approx -o %GAME_OUTPUT% %*
%OUTLASS% %LOBBY_INPUT% --approx -o %LOBBY_OUTPUT% %*
goto :eof

:game
%OUTLASS% %GAME_INPUT% --approx -o %GAME_OUTPUT% %1 %2 %3 %4 %5
goto :eof

:lobby
%OUTLASS% %LOBBY_INPUT% --approx -o %LOBBY_OUTPUT% %1 %2 %3 %4 %5
goto :eof
