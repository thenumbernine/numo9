local ffi = require 'ffi'
local BlobImage = require 'numo9.blob.image'
local gl = require 'gl'

local numo9_rom = require 'numo9.rom'
local spriteSheetSize = numo9_rom.spriteSheetSize

local numo9_video = require 'numo9.video'
local texInternalFormat_u8 = numo9_video.texInternalFormat_u8

local BlobSheet = BlobImage:subclass()

BlobSheet.imageSize = spriteSheetSize
BlobSheet.imageType = 'uint8_t'
BlobSheet.internalFormat = texInternalFormat_u8
--BlobSheet.gltype = gl.GL_UNSIGNED_BYTE == formatInfo.types[1]

BlobSheet.filenamePrefix = 'sheet'
BlobSheet.filenameSuffix = '.png'

-- same but adds the palette
function BlobSheet:saveFile(filepath, blobIndex, blobs)
--DEBUG:print'saving sheet...'
	-- sprite tex: 256 x 256 x 8bpp ... TODO needs to be indexed
	-- TODO save a palette'd image
	local image = self:makeImage()
	ffi.copy(ffi.cast('uint8_t*', image.buffer), self:getPtr(), self:getSize())
	image.palette = blobs.palette[1]:toTable()
	image:save(filepath.path)
end

return BlobSheet
