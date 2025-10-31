local ffi = require 'ffi'
local Image = require 'image'
local gl = require 'gl'

local numo9_rom = require 'numo9.rom'
local fontImageSize = numo9_rom.fontImageSize

local numo9_video = require 'numo9.video'
local resetFont = numo9_video.resetFont

local BlobImage = require 'numo9.blob.image'


local uint8_t = ffi.typeof'uint8_t'


local BlobFont = BlobImage:subclass()

BlobFont.imageSize = fontImageSize
BlobFont.imageType = uint8_t
BlobFont.internalFormat = gl.GL_R8UI
-- font is gonna be stored planar, 8bpp, 8 chars per 8x8 sprite per-bitplane
-- so a 256 char font will be 2048 bytes
-- TODO option for 2bpp etc fonts?
-- before I had fonts just stored as a certain 1bpp region of the sprite sheet ...
-- eventually have custom sized spritesheets and drawText refer to those?
-- or eventually just make all textures 1D and map regions of RAM, and have the tile shader use offsets for horz and vert step?


BlobFont.filenamePrefix = 'font'
BlobFont.filenameSuffix = '.png'

function BlobFont:saveFile(filepath, blobIndex, blobs)
--DEBUG:print'saving font...'
	local saveImg = Image(256, 64, 1, uint8_t)
	for xl=0,31 do
		for yl=0,7 do
			local ch = bit.bor(xl, bit.lshift(yl, 5))
			for x=0,7 do
				for y=0,7 do
					saveImg.buffer[
						bit.bor(
							x,
							bit.lshift(xl, 3),
							bit.lshift(y, 8),
							bit.lshift(yl, 11)
						)
					] = bit.band(bit.rshift(self:getPtr()[
						bit.bor(
							x,
							bit.band(ch, bit.bnot(7)),
							bit.lshift(y, 8)
						)
					], bit.band(ch, 7)), 1)
				end
			end
		end
	end
	saveImg.palette = {{0,0,0},{255,255,255}}
	saveImg:save(filepath.path)
end

-- static method:
function BlobFont:loadFile(filepath, basepath, blobIndex)
	local blob = self.class()
	resetFont(blob:getPtr(), filepath.path)
	return blob
end

return BlobFont
