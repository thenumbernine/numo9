#!/usr/bin/env luajit
--[[
n9a - achive/unarchive n9 files

n9a x file.n9 = extract archive to file/
n9a a file = pack directory to file.n9
--]]
local path = require 'ext.path'
local asserteq = require 'ext.assert'.eq

local cmd, fn = ...
assert(cmd and fn, "expected: `n9a.lua cmd fn`")

local p = path(fn)
assert(p:exists(), tostring(fn).." doesn't exist")
local basename, ext = p:getext()
asserteq(ext, 'n9')

-- TODO ... this and requestMem and everything ... organize plz ...
local spriteOffset = 0
local tileOffset = 0x10000
local tilemapOffset = 0x20000
local paletteOffset = 0x40000
local codeOffset = 0x40200

-- should probably use the same lib as numo9 uses for its compression/saving ...
if cmd == 'x' then
	local romStr = require 'numo9.archive'.fromCartImageFile(fn)
	local romPtr = ffi.cast('char*', romStr)
	
	local image = Image(App.spriteSize.x, App.spriteSize.y, 1, 'unsigned char')
	-- TODO save a palette'd image

	-- sprite tex: 256 x 256 x 8bpp ... TODO needs to be indexed
	ffi.copy(image.buffer, romPtr + spriteOffset, App.spriteSize:volume())
	image:save(basename'sprite.png')

	-- tile tex: 256 x 256 x 8bpp ... TODO needs to be indexed
	ffi.copy(image.buffer, romPtr + tileOffset, App.spriteSize:volume())
	image:save(basename'tiles.png')

	-- tilemap: 256 x 256 x 16bpp ... low byte goes into ch0, high byte goes into ch1, ch2 is 0
	local image = Image(App.tilemapSize.x, App.tilemapSize.x, 3, 'unsigned char')
	local mapPtr = romPtr + paletteOffset
	for y=0,App.tilemapSize.y-1 do
		for x=0,App.tilemapSize.x-1 do
			image.buffer[0 + 3 * (x + App.tilemapSize.x * y)] = mapPtr[0]
			mapPtr = mapPtr + 1
			image.buffer[1 + 3 * (x + App.tilemapSize.x * y)] = mapPtr[0]
			mapPtr = mapPtr + 1
			image.buffer[2 + 3 * (x + App.tilemapSize.x * y)] = 0
		end
	end
	image:save(basename'tilemap.png')

	-- palette: 16 x 16 x 24bpp 8bpp r g b
	local image = Image(16, 16, 3, 'unsigned char')
	local palPtr = ffi.cast('unsigned short *', romPtr + paletteOffset)
	for y=0,15 do
		for x=0,15 do
			image.buffer[0 + 3 * (x + 16 * y)] = bit.lshift(bit.band(palPtr[0], 0x1F), 3)
			image.buffer[1 + 3 * (x + 16 * y)] = bit.lshift(bit.band(bit.rshift(palPtr[0], 5), 0x1F), 3)
			image.buffer[2 + 3 * (x + 16 * y)] = bit.lshift(bit.band(bit.rshift(palPtr[0], 10), 0x1F), 3)
			palPtr = palPtr + 1
		end
	end
	image:save(basename'pal.png')

	local code = ffi.string(romPtr + codeOffset, self.codeSize)	-- TODO max size on this ...
	local i = code:find('\0', 1, true)
	if i then code = code:sub(1, i-1) end
	basename'code.lua':write(code)
elseif cmd == 'a' then
	
else
	error("unknown cmd "..tostring(cmd))
end
