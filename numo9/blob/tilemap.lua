local ffi = require 'ffi'
local assert = require 'ext.assert'
local Image = require 'image'
local gl = require 'gl'

local numo9_rom = require 'numo9.rom'
local tilemapSize = numo9_rom.tilemapSize

local numo9_video = require 'numo9.video'
local texInternalFormat_u16 = numo9_video.texInternalFormat_u16

local BlobImage = require 'numo9.blob.image'


local uint8_t = ffi.typeof'uint8_t'
local uint8_t_p = ffi.typeof'uint8_t*'
local uint16_t = ffi.typeof'uint16_t'


local BlobTileMap = BlobImage:subclass()

BlobTileMap.imageSize = tilemapSize
BlobTileMap.imageType = uint16_t
BlobTileMap.internalFormat = texInternalFormat_u16
--BlobTileMap.gltype = gl.GL_UNSIGNED_SHORT == formatInfo.types[1]
--[[
16bpp ...
- 10 bits of lookup into BlobSheet
- 4 bits high palette nibble
- 1 bit hflip
- 1 bit vflip
- .... 2 bits rotate ... ? nah
- .... 8 bits palette offset ... ? nah
--]]


BlobTileMap.filenamePrefix = 'tilemap'
BlobTileMap.filenameSuffix = '.png'

-- swizzle / unswizzle channels
function BlobTileMap:saveFile(filepath, blobIndex, blobs)
	local saveImg = Image(tilemapSize.x, tilemapSize.x, 3, uint8_t)
	local savePtr = ffi.cast(uint8_t_p, saveImg.buffer)
	local blobPtr = self:getPtr()
	for y=0,tilemapSize.y-1 do
		for x=0,tilemapSize.x-1 do
			savePtr[0] = blobPtr[0]
			savePtr = savePtr + 1
			blobPtr = blobPtr + 1

			savePtr[0] = blobPtr[0]
			savePtr = savePtr + 1
			blobPtr = blobPtr + 1

			savePtr[0] = 0
			savePtr = savePtr + 1
		end
	end
	saveImg:save(filepath.path)
end

-- static method:
-- swizzle / unswizzle channels
function BlobTileMap:loadFile(filepath, basepath, blobIndex)
	local loadImg = assert(Image(filepath.path))
	assert.eq(loadImg.width, tilemapSize.x)
	assert.eq(loadImg.height, tilemapSize.y)
	assert.eq(loadImg.channels, 3)
	assert.eq(ffi.sizeof(loadImg.format), 1)
	local loadPtr = ffi.cast(uint8_t_p, loadImg.buffer)

	local blobImg = self:makeImage()
	local blobPtr = ffi.cast(uint8_t_p, blobImg.buffer)
	for y=0,tilemapSize.y-1 do
		for x=0,tilemapSize.x-1 do
			blobPtr[0] = loadPtr[0]
			loadPtr = loadPtr + 1
			blobPtr = blobPtr + 1

			blobPtr[0] = loadPtr[0]
			loadPtr = loadPtr + 1
			blobPtr = blobPtr + 1

			loadPtr = loadPtr + 1
		end
	end
	return BlobTileMap(blobImg)
end

return BlobTileMap
