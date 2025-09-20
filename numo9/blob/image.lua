local ffi = require 'ffi'
local assert = require 'ext.assert'
local vec2i = require 'vec-ffi.vec2i'
local Image = require 'image'

local Blob = require 'numo9.blob.blob'

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
	return ffi.cast('uint8_t*', self.image.buffer)
end

function BlobImage:getSize()
	return self.image:getBufferSize()
end

function BlobImage:saveFile(filepath, blobIndex, blobs)
	local image = self:makeImage()
	ffi.copy(ffi.cast('uint8_t*', image.buffer), self:getPtr(), self:getSize())
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
	ffi.copy(ffi.cast('uint8_t*', image.buffer), data, image:getBufferSize())
	return self.class(image)
end

return BlobImage
