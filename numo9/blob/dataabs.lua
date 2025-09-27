local ffi = require 'ffi'
local Blob = require 'numo9.blob.blob'

-- abstract class:
-- tempted to merge this with Blob and just use the string's buffer for everything elses buffer ...
local BlobDataAbs = Blob:subclass()

function BlobDataAbs:init(data)
	self.data = data or ''
end

function BlobDataAbs:getPtr()
	return ffi.cast('uint8_t*', self.data)
end

function BlobDataAbs:getSize()
	return #self.data
end

return BlobDataAbs
