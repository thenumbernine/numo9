local ffi = require 'ffi'
local assert = require 'ext.assert'
local table = require 'ext.table'
local vec2i = require 'vec-ffi.vec2i'
local Image = require 'image'
local gl = require 'gl'

local numo9_rom = require 'numo9.rom'
local paletteType = numo9_rom.paletteType
local paletteSize = numo9_rom.paletteSize

local numo9_video = require 'numo9.video'
local rgba5551_to_rgba8888_4ch = numo9_video.rgba5551_to_rgba8888_4ch
local rgba8888_4ch_to_5551 = numo9_video.rgba8888_4ch_to_5551
local internalFormat5551 = numo9_video.internalFormat5551

local BlobImage = require 'numo9.blob.image'


local uint8_t = ffi.typeof'uint8_t'
local uint8_t_p = ffi.typeof'uint8_t*'
local uint16_t = ffi.typeof'uint16_t'
local uint16_t_p = ffi.typeof'uint16_t*'


assert.eq(paletteType, ffi.typeof(uint16_t))
assert.eq(paletteSize, 256)

local BlobPalette = BlobImage:subclass()

-- palette is 256 x 1 x 16 bpp (5:5:5:1)
BlobPalette.imageSize = vec2i(paletteSize, 1)
BlobPalette.imageType = paletteType
BlobPalette.internalFormat = internalFormat5551

BlobPalette.filenamePrefix = 'palette'
BlobPalette.filenameSuffix = '.png'

-- reshape image
function BlobPalette:saveFile(filepath, blobIndex, blobs)
	-- palette: 16 x 16 x 24bpp 8bpp r g b
	local saveImg = Image(16, 16, 4, uint8_t)
	local savePtr = ffi.cast(uint8_t_p, saveImg.buffer)
	local blobPtr = ffi.cast(uint16_t_p, self:getPtr())
	for i=0,paletteSize-1 do
		-- TODO packptr in numo9/app.lua
		savePtr[0], savePtr[1], savePtr[2], savePtr[3] = rgba5551_to_rgba8888_4ch(blobPtr[0])
		blobPtr = blobPtr + 1
		savePtr = savePtr + 4
	end
	saveImg:save(filepath.path)
end

function BlobPalette:toTable()
	local paletteTable = table()
	local palPtr = ffi.cast(uint16_t_p, self:getPtr())
	for i=1,paletteSize do
		paletteTable:insert{rgba5551_to_rgba8888_4ch(palPtr[0])}
		palPtr = palPtr + 1
	end
	return paletteTable
end

-- static method:
-- reshape image
function BlobPalette:loadFile(filepath, basepath, blobIndex)
	local loadImg = assert(Image(filepath.path))
	assert.eq(loadImg.width, 16)
	assert.eq(loadImg.height, 16)
	assert.eq(loadImg.width * loadImg.height, paletteSize)
	assert.eq(loadImg.channels, 4)
	assert.eq(ffi.sizeof(loadImg.format), 1)
	local loadPtr = ffi.cast(uint8_t_p, loadImg.buffer)

	local blobImg = self:makeImage()
	local blobPtr = ffi.cast(uint16_t_p, blobImg.buffer)
	for i=0,paletteSize-1 do
		blobPtr[0] = rgba8888_4ch_to_5551(
			loadPtr[0],
			loadPtr[1],
			loadPtr[2],
			loadPtr[3]
		)
		blobPtr = blobPtr + 1
		loadPtr = loadPtr + 4
	end
	return BlobPalette(blobImg)
end

return BlobPalette
