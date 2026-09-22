@echo off
rem Compiles src/client/ui/stylesheets/default.scss (and its partials in default/) into the
rem StyleSheet module the client requires. Uses `outlass` from PATH if it's installed, otherwise
rem builds it from ../outlass. Extra arguments are passed through, e.g. `build_stylesheets --watch`.
setlocal
set INPUT=src/client/ui/stylesheets/default.scss
set OUTPUT=src/client/ui/stylesheets/default_stylesheet.lua

where outlass >nul 2>nul
if %errorlevel%==0 (
	outlass %INPUT% --approx -o %OUTPUT% %*
) else (
	cargo run --release --quiet --manifest-path ../outlass/Cargo.toml -- %INPUT% --approx -o %OUTPUT% %*
)
