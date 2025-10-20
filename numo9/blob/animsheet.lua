local ffi = require 'ffi'
local assert = require 'ext.assert'
local vec2i = require 'vec-ffi.vec2i'
local Image = require 'image'
local gl = require 'gl'

local BlobImage = require 'numo9.blob.image'

local numo9_rom = require 'numo9.rom'
local animSheetType = numo9_rom.animSheetType
local animSheetPtrType = numo9_rom.animSheetPtrType 
local animSheetSize = numo9_rom.animSheetSize


local uint8_t = ffi.typeof'uint8_t'
local uint8_t_p = ffi.typeof'uint8_t*'


local BlobAnimSheet = BlobImage:subclass()

-- animsheet is 1024 x 1 x 16 bpp
BlobAnimSheet.imageSize = vec2i(1024, 1)
BlobAnimSheet.imageType = animSheetType
BlobAnimSheet.internalFormat = gl.GL_R16UI

BlobAnimSheet.filenamePrefix = 'animsheet'
BlobAnimSheet.filenameSuffix = '.png'

-- reshape image
function BlobAnimSheet:saveFile(filepath, blobIndex, blobs)
	-- saved in 32 x 32 x r,g,b x 8bpp
	local saveImg = Image(32, 32, 3, uint8_t)
	local savePtr = ffi.cast(uint8_t_p, saveImg.buffer)
	local blobPtr = ffi.cast(animSheetPtrType, self:getPtr())
	for i=0,animSheetSize-1 do
		ffi.cast(animSheetPtrType, savePtr)[0] = blobPtr[0]
		blobPtr = blobPtr + 1
		savePtr = savePtr + saveImg.channels
	end
	saveImg:save(filepath.path)
end

-- static method:
-- reshape image
function BlobAnimSheet:loadFile(filepath, basepath, blobIndex)
	local loadImg = assert(Image(filepath.path))
	assert.eq(loadImg.width, 32)
	assert.eq(loadImg.height, 32)
	assert.eq(loadImg.width * loadImg.height, animSheetSize)
	assert.eq(loadImg.channels, 3)
	assert.eq(ffi.sizeof(loadImg.format), 1)
	local loadPtr = ffi.cast(uint8_t_p, loadImg.buffer)

	local blobImg = self:makeImage()
	local blobPtr = ffi.cast(animSheetPtrType, blobImg.buffer)
	for i=0,animSheetSize-1 do
		blobPtr[0] = ffi.cast(animSheetPtrType, loadPtr)[0]
		blobPtr = blobPtr + 1
		loadPtr = loadPtr + loadImg.channels
	end
	return BlobAnimSheet(blobImg)
end

return BlobAnimSheet
