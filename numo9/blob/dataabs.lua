local ffi = require 'ffi'
local vector = require 'stl.vector-lua'
local Blob = require 'numo9.blob.blob'


local uint8_t = ffi.typeof'uint8_t'


-- abstract class:
-- tempted to merge this with Blob ...
local BlobDataAbs = Blob:subclass()

function BlobDataAbs:init(data)
	if data then
		local n = #data
		self.vec = vector(uint8_t, n)
		ffi.copy(self.vec.v, data, n)
	else
		self.vec = vector(uint8_t)
	end
end

function BlobDataAbs:getPtr()
	return self.vec.v
end

function BlobDataAbs:getSize()
	return #self.vec
end

return BlobDataAbs
