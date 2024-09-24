#!/usr/bin/env sh
# TODO have ../dist/run do this ... in fact I half-started on that in dist's `linuxWin64` target
rm -fr dist
../dist/run.lua linux
rm dist/numo9-linux64.zip
mv dist/numo9-linux64 dist/numo9
cp -R ../dist/bin_Windows dist/numo9/data/bin/Windows
# not using cimgui for this ... also not using openal or vorbis or ogg but meh
rm dist/numo9/data/bin/Windows/x64/cimgui_sdl.dll
cp run_Windows/* dist/numo9/
cd dist
zip -r numo9.zip numo9/
