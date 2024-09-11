#!/usr/bin/env luajit
--[[
n9a - achive/unarchive n9 files

n9a x file.n9 = extract archive to file/
n9a a file = pack directory to file.n9
--]]
local ffi = require 'ffi'
local path = require 'ext.path'
local asserteq = require 'ext.assert'.eq
local assertlt = require 'ext.assert'.lt
local Image = require 'image'
local App = require 'numo9.app'
local fromCartImage = require 'numo9.archive'.fromCartImage
local toCartImage = require 'numo9.archive'.toCartImage

local cmd, fn = ...
assert(cmd and fn, "expected: `n9a.lua cmd fn`")

local p = path(fn)
local basename, ext = p:getext()
asserteq(ext, 'n9')

-- TODO ... this and requestMem and everything ... organize plz ...
local spriteOffset = 0
local tileOffset = 0x10000
local tilemapOffset = 0x20000
local paletteOffset = 0x40000
local codeOffset = 0x40200
local endOffset = codeOffset + App.codeSize
asserteq(endOffset, ffi.sizeof'ROM')

-- should probably use the same lib as numo9 uses for its compression/saving ...
if cmd == 'x' then

	assert(p:exists(), tostring(fn).." doesn't exist")
	basename:mkdir()
	assert(basename:isdir())

print'loading cart...'
	local romStr = fromCartImage((assert(p:read())))
	assert(#romStr >= ffi.sizeof'ROM')
	local romPtr = ffi.cast('char*', romStr)

print'saving sprite sheet...'
	-- sprite tex: 256 x 256 x 8bpp ... TODO needs to be indexed
	-- TODO save a palette'd image
	local image = Image(App.spriteSheetSize.x, App.spriteSheetSize.y, 1, 'unsigned char')
	ffi.copy(image.buffer, romPtr + spriteOffset, App.spriteSheetSize:volume())
	image:save(basename'sprite.png'.path)

print'saving tile sheet...'
	-- tile tex: 256 x 256 x 8bpp ... TODO needs to be indexed
	ffi.copy(image.buffer, romPtr + tileOffset, App.spriteSheetSize:volume())
	image:save(basename'tiles.png'.path)

print'saving tile map...'
	-- tilemap: 256 x 256 x 16bpp ... low byte goes into ch0, high byte goes into ch1, ch2 is 0
	local image = Image(App.tilemapSize.x, App.tilemapSize.x, 3, 'unsigned char')
	local mapPtr = romPtr + tilemapOffset
	local imagePtr = image.buffer
	for y=0,App.tilemapSize.y-1 do
		for x=0,App.tilemapSize.x-1 do
			imagePtr[0] = mapPtr[0]
			imagePtr = imagePtr + 1
			mapPtr = mapPtr + 1

			imagePtr[0] = mapPtr[0]
			imagePtr = imagePtr + 1
			mapPtr = mapPtr + 1

			imagePtr[0] = 0
			imagePtr = imagePtr + 1
		end
	end
	image:save(basename'tilemap.png'.path)

print'saving palette...'
	-- palette: 16 x 16 x 24bpp 8bpp r g b
	local image = Image(16, 16, 4, 'unsigned char')
	local imagePtr = image.buffer
	local palPtr = ffi.cast('unsigned short *', romPtr + paletteOffset)
	for y=0,15 do
		for x=0,15 do
			imagePtr[0] = bit.lshift(bit.band(palPtr[0], 0x1F), 3)
			imagePtr[1] = bit.lshift(bit.band(bit.rshift(palPtr[0], 5), 0x1F), 3)
			imagePtr[2] = bit.lshift(bit.band(bit.rshift(palPtr[0], 10), 0x1F), 3)
			imagePtr[3] = bit.band(1, bit.rshift(palPtr[0], 15)) == 0 and 0 or 0xff
			palPtr = palPtr + 1
			imagePtr = imagePtr + 4
		end
	end
	image:save(basename'pal.png'.path)

print'saving code...'
	local code = ffi.string(romPtr + codeOffset, App.codeSize)	-- TODO max size on this ...
	local i = code:find('\0', 1, true)
	if i then code = code:sub(1, i-1) end
	basename'code.lua':write(code)

elseif cmd == 'a' then

	assert(basename:isdir())
	local romPtr = ffi.new('uint8_t[?]', ffi.sizeof'ROM')

print'loading sprite sheet...'
	local image = Image(basename'sprite.png'.path)
	asserteq(image.width, App.spriteSheetSize.x)
	asserteq(image.height, App.spriteSheetSize.y)
	asserteq(image.channels, 1)
	assert(ffi.sizeof(image.format), 1)
	ffi.copy(romPtr + spriteOffset, image.buffer, App.spriteSheetSize:volume())

print'loading tile sheet...'
	local image = Image(basename'tiles.png'.path)
	asserteq(image.width, App.spriteSheetSize.x)
	asserteq(image.height, App.spriteSheetSize.y)
	asserteq(image.channels, 1)
	assert(ffi.sizeof(image.format), 1)
	ffi.copy(romPtr + tileOffset, image.buffer, App.spriteSheetSize:volume())

print'loading tile map...'
	local image = Image(basename'tilemap.png'.path)
	asserteq(image.width, App.tilemapSize.x)
	asserteq(image.height, App.tilemapSize.y)
	asserteq(image.channels, 3)
	asserteq(ffi.sizeof(image.format), 1)
	local mapPtr = romPtr + tilemapOffset
	local imagePtr = image.buffer
	for y=0,App.tilemapSize.y-1 do
		for x=0,App.tilemapSize.x-1 do
			mapPtr[0] = imagePtr[0]
			imagePtr = imagePtr + 1
			mapPtr = mapPtr + 1

			mapPtr[0] = imagePtr[0]
			imagePtr = imagePtr + 1
			mapPtr = mapPtr + 1

			imagePtr = imagePtr + 1
		end
	end
	image:save(basename'tilemap.png'.path)

print'loading palette...'
	local image = Image(basename'pal.png'.path)
	asserteq(image.width, 16)
	asserteq(image.height, 16)
	asserteq(image.channels, 4)
	asserteq(ffi.sizeof(image.format), 1)
	local imagePtr = image.buffer
	local palPtr = ffi.cast('unsigned short *', romPtr + paletteOffset)
	for y=0,15 do
		for x=0,15 do
			palPtr[0] = bit.bor(
				bit.band(0x001f, bit.rshift(imagePtr[0], 3)),
				bit.band(0x03e0, bit.lshift(imagePtr[1], 2)),
				bit.band(0x7c00, bit.lshift(imagePtr[2], 7)),
				imagePtr[3] == 0 and 0 or 0x8000
			)
			palPtr = palPtr + 1
			imagePtr = imagePtr + 4
		end
	end

print'loading code...'
	local code = basename'code.lua':read()
	local n = #code
	assertlt(n+1, App.codeSize)
	local codeMem = romPtr + codeOffset
	ffi.copy(codeMem, code, n)
	codeMem[n] = 0	-- null term

print'saving cart...'
	assert(path(fn):write(toCartImage(romPtr)))
else

	error("unknown cmd "..tostring(cmd))

end
