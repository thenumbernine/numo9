local ffi = require 'ffi'
local class = require 'ext.class'
local assert = require 'ext.assert'

--[[
.type = int = class static member
.addr
.addrEnd
.ramptr = app.ram.v + blob.addr
:getPtr()
:getSize()
NOTICE -
	getPtr and getSize are functions because some blobs have vectors underlying
	but really this is a bad idea.
	whenever a blob size changes its addresses go out of sync with the RAM mapping
	so it's better to either ...
		- never resize blobs
		- or every time you do, rebuild the RAM
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

function Blob:saveFile(filepath, blobIndex, blobs)
	assert(filepath:write(self:toBinStr()))
end

-- static method:
function Blob:loadFile(filepath, basepath, blobIndex)
	return self.class(filepath:read())
end

return Blob
