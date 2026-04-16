local ffi = require 'ffi'
local BlobImage = require 'numo9.blob.image'
local gl = require 'gl'

local numo9_rom = require 'numo9.rom'
local spriteSheetSize = numo9_rom.spriteSheetSize


local uint8_t = ffi.typeof'uint8_t'
local uint8_t_p = ffi.typeof'uint8_t*'


local BlobSheet = BlobImage:subclass()

BlobSheet.imageSize = spriteSheetSize
BlobSheet.imageType = uint8_t
BlobSheet.internalFormat = gl.GL_R8UI
--BlobSheet.gltype = gl.GL_UNSIGNED_BYTE == formatInfo.types[1]

BlobSheet.filenamePrefix = 'sheet'
BlobSheet.filenameSuffix = '.png'

-- same but adds the palette
function BlobSheet:saveFile(filepath, blobIndex, blobs, paletteIndex)
--DEBUG:print'saving sheet...'
	-- sprite tex: 256 x 256 x 8bpp ... TODO needs to be indexed
	-- TODO save a palette'd image
	local image = self:makeImage()
	ffi.copy(ffi.cast(uint8_t_p, image.buffer), self:getPtr(), self:getSize())
	local paletteBlob = blobs.palette[1+(paletteIndex or 0)] or blobs.palette[1]
	image.palette = paletteBlob:toTable()
	image:save(filepath.path)
end

-- used for new game (and post-splash-screen) to reset the initial sheet to its default
-- which will have a single default tile for the default mesh and default voxelmap
function BlobSheet:setDefault()
	self.image:clear()
	for j=0,15 do
		for i=0,15 do
			local d = math.min(i, 15 - i, j, 15 - j)
			local c = d < 4 and 0xf - d or 0x1f
			self.image.buffer[16 + i + self.image.width * j] = c
		end
	end

	return self
end

return BlobSheet
