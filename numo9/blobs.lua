local ffi = require 'ffi'
local table = require 'ext.table'
local assert = require 'ext.assert'
local class = require 'ext.class'
local vector = require 'ffi.cpp.vector-lua'
local struct = require 'struct'

local numo9_rom = require 'numo9.rom'
local blobCountType = numo9_rom.blobCountType
local BlobEntry = numo9_rom.BlobEntry
local spriteSheetInBytes = numo9_rom.spriteSheetInBytes
local tilemapInBytes = numo9_rom.tilemapInBytes
local paletteInBytes = numo9_rom.paletteInBytes
local fontInBytes = numo9_rom.fontInBytes

-- maps from type-index to name
local blobClassNameForType = table{
	'code',		-- always only 1 of these
	'sheet',	-- sprite sheet, tile sheet
	'tilemap',
	'palette',
	'font',
	'sfx',
	'music',
	'brush',
	'brushmap',
	-- TODO 'voxelmap' = voxel-map of models from some lookup table
	-- TODO 'obj3d'
}

-- maps from name to type-index
local blobTypeForClassName = blobClassNameForType:mapi(function(name, typeValue)
	return typeValue, name
end):setmetatable(nil)


-- maps from name to class
local blobClassForName = {}

--[[
.type = int = class static member
.addr
.ramptr = app.ram.v + blob.addr
:getPtr() / :getSize()
--]]
local Blob = class()
function Blob:copyToRAM()
	assert.ne(self.ramptr, ffi.null)
	ffi.copy(self.ramptr, self:getPtr(), self:getSize())
end
function Blob:copyFromRAM()
	assert.ne(self.ramptr, ffi.null)
	ffi.copy(self:getPtr(), self.ramptr, self:getSize())
end

local BlobCode = Blob:subclass()
blobClassForName.code = BlobCode
function BlobCode:init(data)	-- optional
	self.data = data
end
function BlobCode:getPtr()
	return ffi.cast('uint8_t*', self.data)
end
function BlobCode:getSize()
	return #self.data
end

local BlobSheet = Blob:subclass()
blobClassForName.sheet = BlobSheet
function BlobSheet:init(data)
	-- TODO
end
function BlobSheet:getSize()
	return spriteSheetInBytes
end

local BlobTileMap = Blob:subclass()
blobClassForName.tilemap = BlobTileMap
function BlobTileMap:init(data)
	-- TODO
end
function BlobTileMap:getSize()
	return tilemapInBytes
end

local BlobPalette = Blob:subclass()
blobClassForName.palette = BlobPalette
function BlobPalette:init(data)
	-- TODO
end
function BlobPalette:getSize()
	return paletteInBytes
end

local BlobFont = Blob:subclass()
blobClassForName.font = BlobFont
function BlobFont:init(data)
	-- TODO
end
function BlobFont:getSize()
	return fontInBytes
end

local BlobSFX = Blob:subclass()
blobClassForName.sfx = BlobSFX
function BlobSFX:init(data)
	-- TODO
end

local BlobMusic = Blob:subclass()
blobClassForName.music = BlobMusic
function BlobMusic:init(data)
	-- TODO
end

local BlobBrush = Blob:subclass()
blobClassForName.brush = BlobBrush
function BlobBrush:init(data)
	-- TODO
end

local BlobBrushMap = Blob:subclass()
blobClassForName.brushmap = BlobBrushMap
function BlobBrushMap:init(data)
	-- TODO
end


local blobClassForType = {}
for blobClassIndex,blobClass in pairs(blobClassForName) do
	blobClass.type = blobClassIndex
	blobClassForType[blobClass.type] = blobClass
end


local AppBlobs = {}

function AppBlobs:initBlobs()
	self.blobs = {}

	self:addBlob'code'
	self:addBlob'sheet'
	self:addBlob'sheet'
	self:addBlob'tilemap'
	self:addBlob'palette'
	self:addBlob'font'

	self:buildRAMFromBlobs()
end

function AppBlobs:addBlob(blobClassName)
	self.blobs[blobClassName] = self.blobs[blobClassName] or table()
	self.blobs[blobClassName]:insert(blobClass())
end

-- reads blobs, returns resulting byte array
-- used by buildRAMFromBlobs for allocating self.memSize, self.holdram, self.ram
-- or by toCartImage for writing out the ROM data (which is just the holdram minus the RAM struct up to blobCount)
local function blobsToByteArray(blobs)
	local allBlobs = table()
	for blobClassName,blobsForType in ipairs(blobs:keys():sort(function(a,b)
		return blobTypeForClassName[a] < blobTypeForClassName[b]
	end)) do
		allBlobs:append(blobsForType)
	end
	local numBlobs = #allBlobs

	-- RAM struct also includes blobCount and blobs[1], so you have to add to it blobs[#blobs-1]
	local memSize = ffi.sizeof'RAM'
		+ (numBlobs - 1) * ffi.sizeof(BlobEntry)
		+ allBlobs:mapi(function(blob) return blob.size end):sum()
--DEBUG:print(('memSize = 0x%0x'):format(memSize))

	-- if you don't keep track of this ptr then luajit will deallocate the ram ...
	local holdram = ffi.new('uint8_t[?]', memSize)
	ffi.fill(holdram+0, memSize)	-- in case it doesn't already?  for the sake of the md5 hash

	-- wow first time I've used references in LuaJIT, didn't know they were implemented.
	local ram = ffi.cast('RAM&', holdram)

	local ramptr = ffi.cast('uint8_t*', ram.blobEntries + numBlobs)
	ram.blobCount = numBlobs
	for indexPlusOne,blob in ipairs(allBlobs) do
		local index = indexPlusOne - 1
		local blobEntryPtr = ram.blobEntries + index

		local addr = ramptr - ram.v
		assert.ge(0, addr)
		assert.lt(addr, memSize)
		blobEntryPtr.type = blob.type
		blobEntryPtr.addr = addr
		local blobSize = blob:getSize()
		blobEntryPtr.size = blobSize

		local srcptr = blob:getPtr()
		assert.ne(srcptr, ffi.null)
		blob.ramptr = ramptr
		blob.addr = addr
		ffi.copy(ramptr, srcptr, blobSize)
		ramptr = ramptr + blobSize
	end
	assert.eq(ramptr, ram.v + memSize)

	-- tic80 has a reset() function for resetting RAM data to original cartridge data
	-- pico8 has a reset function that seems to do something different: reset the color and console state
	-- but pico8 does support a reload() function for copying data from cartridge to RAM ... if you specify range of the whole ROM memory then it's the same (right?)
	-- but pico8 also supports cstore(), i.e. writing to sections of a cartridge while the code is running ... now we're approaching fantasy land where you can store disk quickly - didn't happen on old Apple2's ... or in the NES case where reading was quick, the ROM was just that so there was no point to allow writing and therefore no point to address both the ROM and the ROM's copy in RAM ...
	-- but tic80 has a sync() function for swapping out the active banks ...
	-- with all that said, 'banks' here will be inaccessble by my api except a reset() function
	-- and sync() function ..
	-- TODO maybe ... keeping separate 'ROM' and 'RAM' space?  how should the ROM be accessible? with a 0xC00000 (SNES)?
	-- and then 'save' would save the ROM to virtual-filesystem, and run() and reset() would copy the ROM to RAM
	-- and the editor would edit the ROM ...

	return {
		memSize = memSize,
		holdram = holdram,
		ram = ram,
		allBlobs = allBlobs,	-- TODO instead function for building this list?
	}
end

-- convert a RAM byte array to blobs[]
local function byteArrayToBlobs(ptr, size)
	local ram = ffi.cast('RAM&', ptr)
	local blobs = {}
	for index=0,ram.blobCount-1 do
		local blobEntryPtr = ram.blobEntries + index
		assert.le(0, blobEntryPtr.addr)
		assert.le(blobEntryPtr.addr + blobEntryPtr.size, size)
		local blobClass = assert.index(blobClassForType, blobEntryPtr.type)
		local blobData = ffi.string(ram.v + blobEntryPtr.addr, blobEntryPtr.size)
		local blob = blobClass(blobData)
		blobs[blobEntryPtr.type] = blobs[blobEntryPtr.type] or table()
		blobs[blobsEntryPtr.type]:insert(blob)
	end
	return blobs
end

-- operates on app, reading its .blobs, writing its .memSize, .holdram, .ram
function AppBlobs:buildRAMFromBlobs()
	local info = blobsToByteArray(self.blobs)
	self.memSize = info.memSize
	self.holdram = info.holdram
	self.ram = info.ram
end

function AppBlobs:copyBlobsToRAM()
	assert.eq(ffi.sizeof(self.holdram), self.memSize)
	for _,blobs in pairs(self.blobs) do
		for _,blob in ipairs(blobs) do
			blob:copyToRAM()
		end
	end
end

function AppBlobs:copyRAMToBlobs()
	assert.eq(ffi.sizeof(self.holdram), self.memSize)
	for _,blobs in pairs(self.blobs) do
		for _,blob in ipairs(blobs) do
			blob:copyFromRAM()
		end
	end
end


return {
	AppBlobs = AppBlobs,
	BlobEntry = BlobEntry,
	blobClassForName = blobClassForName,
	blobsToByteArray = blobsToByteArray,
	byteArrayToBlobs = byteArrayToBlobs,
}
