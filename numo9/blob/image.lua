require 'ext.gc'	-- make sure luajit can __gc lua-tables
local ffi = require 'ffi'
local assert = require 'ext.assert'
local vec2i = require 'vec-ffi.vec2i'
local Image = require 'image'
local gl = require 'gl'
local GLTex2D = require 'gl.tex2d'

local RAMGPUTex = require 'numo9.ramgpu'

local Blob = require 'numo9.blob.blob'

local numo9_rom = require 'numo9.rom'
local spriteSheetSize = numo9_rom.spriteSheetSize


local uint8_t_p = ffi.typeof'uint8_t*'


-- abstract class
local BlobImage = Blob:subclass()

-- subclass must define these:
--BlobImage.imageSize = vec2i(...)
--BlobImage.imageType = ...

-- static method:
function BlobImage:makeImage()
	local image = Image(self.imageSize.x, self.imageSize.y, 1, self.imageType)
	ffi.fill(image.buffer, self.imageSize.x * self.imageSize.y * ffi.sizeof(self.imageType))
	return image
end

function BlobImage:init(image)
	if image then
		assert.eq(image.width, self.imageSize.x)
		assert.eq(image.height, self.imageSize.y)
		assert.eq(image.channels, 1)
		assert.eq(image.format, self.imageType)
		self.image = image
	else
		self.image = self:makeImage()
	end
end

function BlobImage:getPtr()
	return ffi.cast(uint8_t_p, self.image.buffer)
end

function BlobImage:getSize()
	return self.image:getBufferSize()
end

function BlobImage:saveFile(filepath, blobIndex, blobs)
	local image = self:makeImage()
	ffi.copy(ffi.cast(uint8_t_p, image.buffer), self:getPtr(), self:getSize())
	image:save(filepath.path)
end

-- static method:
function BlobImage:loadFile(filepath, basepath, blobIndex)
	local image = Image(filepath.path)
	return self.class(image)
end

-- static method:
function BlobImage:loadBinStr(data)
	local image = self:makeImage()
	assert.eq(#data, image:getBufferSize())
	ffi.copy(ffi.cast(uint8_t_p, image.buffer), data, image:getBufferSize())
	return self.class(image)
end

function BlobImage:buildRAMGPU(app)
	if self.ramgpu then
--DEBUG:print('BlobImage:buildRAMGPU '..self.name..' updating addr')
		self.ramgpu:updateAddr(self.addr)
		return
	end

	local formatInfo = GLTex2D.formatInfoForInternalFormat[self.internalFormat]

--DEBUG:print('BlobImage:buildRAMGPU '..self.name..' creating new')
	self.ramgpu = RAMGPUTex{
		app = app,
		addr = self.addr,
		width = self.imageSize.x,
		height = self.imageSize.y,
		channels = 1,
		ctype = self.imageType,
		internalFormat = self.internalFormat,
		glformat = formatInfo.format,
		gltype = formatInfo.types[1],
	}
end

function BlobImage:delete()
	if self.ramgpu then
		self.ramgpu:delete()
		self.ramgpu = nil
	end
end

BlobImage.__gc = BlobImage.delete

return BlobImage
