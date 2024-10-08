#!/usr/bin/env sh
# how to recreate win64 and linux64 package using their stashed binaries + the osx dist
rm -fr dist
../dist/run.lua
mkdir dist/numo9-win64
mkdir dist/numo9-linux64
cp -R dist/osx/numo9.app/Contents/Resources  dist/numo9-win64/data
cp -R dist/osx/numo9.app/Contents/Resources  dist/numo9-linux64/data
cp -R dist-multi/linux64/* dist/numo9-linux64/
cp -R dist-multi/win64/* dist/numo9-win64/
rm -fr dist/numo9-win64/data/bin/OSX/
rm dist/numo9-win64/data/mime/core.so
rm dist/numo9-win64/data/socket/core.so
rm -fr dist/numo9-linux64/data/bin/OSX/
# no need, they have alreayd been overwritten by dist-multi/linux64/*
#rm dist/numo9-linux64/data/mime/core.so
#rm dist/numo9-linux64/data/socket/core.so
cd dist
zip -r numo9-win64.zip numo9-win64/
zip -r numo9-linux64.zip numo9-linux64/
cd osx
zip -r numo9-osx.zip numo9.app/
mv numo9-osx.zip ..
