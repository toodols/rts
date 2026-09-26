@echo off
rem Builds src/client/ui/stylesheets/preview.html (gitignored), a browser reference render of default.scss for
rem comparing against the Roblox render of the same sheet. Needs node, and dart-sass -- `sass` from
rem PATH if it's installed, otherwise npx fetches it. Extra arguments are passed through, e.g.
rem `build_preview --watch`, `build_preview --open`.
setlocal
node src/client/ui/stylesheets/preview/build.js %*
