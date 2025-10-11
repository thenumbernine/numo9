local ffi = require 'ffi'
local assert = require 'ext.assert'
local vector = require 'ffi.cpp.vector-lua'

local numo9_rom = require 'numo9.rom'
local Stamp = numo9_rom.Stamp

local Blob = require 'numo9.blob.blob'


local uint8_t_p = ffi.typeof'uint8_t*'


local BlobBrushMap = Blob:subclass()

BlobBrushMap.filenamePrefix = 'brushmap'
BlobBrushMap.filenameSuffix = '.bin'

function BlobBrushMap:init(data)
	data = data or ''
	assert.eq(#data % ffi.sizeof(Stamp), 0, "data is not Stamp-aligned")
	local numStamps = #data / ffi.sizeof(Stamp)
	self.vec = vector(Stamp, numStamps)
	assert.len(self.vec, numStamps)
	assert.len(data, self.vec:getNumBytes())
	ffi.copy(self.vec.v, data, self.vec:getNumBytes())
end

function BlobBrushMap:getPtr()
	return ffi.cast(uint8_t_p, self.vec.v)
end

function BlobBrushMap:getSize()
	return self.vec:getNumBytes()
end

return BlobBrushMap
