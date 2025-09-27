local ffi = require 'ffi'
local class = require 'ext.class'
local assert = require 'ext.assert'

--[[
.type = int = class static member
.addr
.addrEnd
.ramptr = app.ram.v + blob.addr
:getPtr()
:getSize() (TODO make this just .size since it shouldn't ever change, even though it is varies per-class)
--]]
local Blob = class()

function Blob:copyToROM()
	assert.index(self, 'ramptr', "failed to find ramptr for blob of type "..tostring(self.type))
	ffi.copy(self.ramptr, self:getPtr(), self:getSize())
end

function Blob:copyFromROM()
	assert.ne(self.ramptr, ffi.null)
	ffi.copy(self:getPtr(), self.ramptr, self:getSize())
end

-- static method:
function Blob:buildFileName(filenamePrefix, filenameSuffix, blobIndex)
	return filenamePrefix..(blobIndex == 0 and '' or blobIndex)..filenameSuffix
end

-- static method:
function Blob:getFileName(blobIndex)
	return self:buildFileName(self.filenamePrefix, self.filenameSuffix, blobIndex)
end

-- static method:
function Blob:loadBinStr(data)
	return self.class(data)
end

function Blob:toBinStr()
	return ffi.string(self:getPtr(), self:getSize())
end

return Blob
