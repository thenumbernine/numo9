local ffi = require 'ffi'
local table = require 'ext.table'
local assert = require 'ext.assert'
local class = require 'ext.class'

local numo9_rom = require 'numo9.rom'
local BlobEntry = numo9_rom.BlobEntry
local sizeofRAMWithoutROM = numo9_rom.sizeofRAMWithoutROM
local mvMatType = numo9_rom.mvMatType

local numo9_video = require 'numo9.video'
local resetFont = numo9_video.resetFont
local resetPalette = numo9_video.resetPalette

-- maps from type-index to name
local blobClassNameForType = table{
	'sheet',	-- sprite sheet, tile sheet
	'tilemap',
	'palette',
	'font',
	'sfx',
	'music',
	-- these go last because they are most likely to not be short/long aligned
	'code',		-- at least 1 of these
	'data',		-- arbitrary binary blob. reset on reload.
	'persist',	-- save data: arbitrary binary blob that persists

	'brush',	-- TODO hmm not sure about this one, because brushes are gonna vary, they are functions that take in relx rely globalx globaly output a sheet index
	'brushmap',	-- 'brushmap' is a collection of xywh brushes to be stamped onto the tilemap

	'mesh3d', 	-- ... but what format?  xyzuv triangles ... and indexes or nah, since the video API doesn't care anyways?  or at least for compression's sake?
	'voxelmap', -- = voxel-map of models from some lookup table
	-- voxel map high bits = 24 possible orientations of a cube, so needs 5 bits for orientation (wow so many ...)
	--  2 bits = yaw z-axis rotation, 2 bits = roll / x-axis rotation, 1 bit = yaw / y-axis rotation
	-- should voxel map be 16bit then? 11 = lookup of model, 5 = orientation?
	-- then entries should point to objs ... and to texel shifts, right?  we dont want a zillion copies of cube ... we should point to separate obj and sheet ...
	-- 16bit then: 8 to lookup model, 3 to lookup texture sheet, 5 to orientate sheet?
	-- or 32bit?  11:model, 10:sprite 3:sheet, 3:palette, 5:orientation ...
	-- nah i won't encourage cart programmers to change sheet/palette mid-voxelmap render
	-- 32-bit: 17:model 10:sprite 5:orientation
}

-- maps from name to class
local blobClassForName = {
	code = require 'numo9.blob.code',
	sheet = require 'numo9.blob.sheet' ,
	tilemap = require 'numo9.blob.tilemap',
	palette = require 'numo9.blob.palette',
	font = require 'numo9.blob.font',
	sfx = require 'numo9.blob.sfx',
	music = require 'numo9.blob.music',
	data = require 'numo9.blob.data',
	persist = require 'numo9.blob.persist',
	brush = require 'numo9.blob.brush',
	brushmap = require 'numo9.blob.brushmap',
	mesh3d = require 'numo9.blob.mesh3d',
	voxelmap = require 'numo9.blob.voxelmap',
}


-- maps from name to type-index
local blobTypeForClassName = blobClassNameForType:mapi(function(name, typeValue)
	return typeValue, name
end):setmetatable(nil)

local blobClassForType = {}
for blobClassName,blobClass in pairs(blobClassForName) do
	blobClass.name = blobClassName
	blobClass.type = assert.index(blobTypeForClassName, blobClassName)
	blobClassForType[blobClass.type] = blobClass
end

--[[
keys = each blob type-name, values = an array for each one
TODO include holdram, ram, etc?  or nah?  cuz blobs <-> ram, right?
--]]
local BlobSet = class()
function BlobSet:init()
	for _,name in ipairs(blobClassNameForType) do
		self[name] = table()
	end
end
function BlobSet:copyToROM()
	for _,blobsForType in pairs(self) do
		for _,blob in ipairs(blobsForType) do
			blob:copyToROM()
		end
	end
end
function BlobSet:copyFromROM()
	for _,blobsForType in pairs(self) do
		for _,blob in ipairs(blobsForType) do
			blob:copyFromROM()
		end
	end
end
function BlobSet:assertPtrs(info)	-- info or app
	assert.index(info, 'ram')
	for name,blobsForType in pairs(self) do
		for i,blob in ipairs(blobsForType) do
			local errmsg = "blob type="..name.." index="..i
			assert.index(blob, 'addr', errmsg)
			assert.index(blob, 'ramptr', errmsg)
			assert.eq(info.ram.v + blob.addr, blob.ramptr, errmsg)
			assert.le(info.ram.v, blob.ramptr, errmsg)
			assert.lt(blob.ramptr, info.ram.v + info.memSize, errmsg)
		end
	end
end


-- reads blobs, returns resulting byte array
-- used by buildRAMFromBlobs for allocating self.memSize, self.holdram, self.ram
-- or by blobStrToCartImage for writing out the ROM data (which is just the holdram minus the RAM struct up to blobCount)
local function blobsToByteArray(blobs)
--DEBUG:print('blobsToByteArray...')
	local allBlobs = table()
	for _,blobClassName in ipairs(table.keys(blobs):sort(function(a,b)
		return blobTypeForClassName[a] < blobTypeForClassName[b]
	end)) do
		local blobsForType = blobs[blobClassName]
		allBlobs:append(blobsForType)
	end
	local numBlobs = #allBlobs

	-- RAM struct also includes blobCount and blobs[1], so you have to add to it blobs[#blobs-1]
	local memSize = ffi.sizeof'RAM'
		+ (numBlobs - 1) * ffi.sizeof(BlobEntry)
		+ (allBlobs:mapi(function(blob)
			assert.index(blob, 'getSize', 'name='..blob.name)
			return blob:getSize()
		end):sum() or 0)
--DEBUG:print(('memSize = 0x%0x'):format(memSize))

	-- if you don't keep track of this ptr then luajit will deallocate the ram ...
	local holdram = ffi.new('uint8_t[?]', memSize)
	ffi.fill(ffi.cast('uint8_t*', holdram), memSize)	-- in case it doesn't already?  for the sake of the md5 hash

	-- wow first time I've used references in LuaJIT, didn't know they were implemented.
	local ram = ffi.cast('RAM&', holdram)

	-- for each type, mapping to where in the FAT its blobEntries starts
	local blobEntriesForClassName = blobClassNameForType:mapi(function(name)
		return {
			ptr = nil,
			count = 0,
		}, name
	end)

	local ramptr = ffi.cast('uint8_t*', ram.blobEntries + numBlobs)
	ram.blobCount = numBlobs
	for indexPlusOne,blob in ipairs(allBlobs) do
		local index = indexPlusOne - 1
		local blobClassName = blob.name

		local blobEntryPtr = ram.blobEntries + index

		local addr = ramptr - ram.v
		local blobSize = blob:getSize()
--DEBUG:print('adding blob #'..index..' at addr '..('0x%x'):format(addr)..' - '..('0x%x'):format(addr + blobSize)..' type '..blob.type..'/'..blobClassName)
		assert.le(0, addr)
		assert.le(addr, memSize)
		blobEntryPtr.type = blob.type
		blobEntryPtr.addr = addr
		blobEntryPtr.size = blobSize

		local srcptr = blob:getPtr()
		assert.ne(srcptr, ffi.null)
		blob.addr = addr
		blob.addrEnd = blob.addr + blobSize
		ffi.copy(ramptr, srcptr, blobSize)
		ramptr = ramptr + blobSize

		local blobEntriesPtr = blobEntriesForClassName[blobClassName]
		if blobEntriesPtr.count == 0 then
			blobEntriesPtr.ptr = blobEntryPtr	-- BlobEntry*
			blobEntriesPtr.addr = ffi.cast('uint8_t*', blobEntryPtr) - ram.v
		end
		blobEntriesPtr.count = blobEntriesPtr.count + 1
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

--DEBUG:print('...done blobsToByteArray')
	return {
		memSize = memSize,
		holdram = holdram,
		ram = ram,
		allBlobs = allBlobs,	-- TODO instead function for building this list?
		blobEntriesForClassName = blobEntriesForClassName,
	}
end


local AppBlobs = {}

function AppBlobs:initBlobs()
--DEBUG:print('AppBlobs:initBlobs...')
	self.blobs = BlobSet()
	self:buildRAMFromBlobs()
end

local minBlobPerType = {
	code = 1,
	sheet = 1,
	tilemap = 2,	-- only because map() still defaults to 1 ... I'm going to change that soon ... then there'll be only min of 1 sheet.
	palette = 1,	-- ok we def need 1 of this
	font = 1,		-- debatable we need 1 of this
}

--[[
after loading a cart, not all default blobs are present
this fills those up, esp useful for font and palette which have default content
but also creates the empty sheet / tilemap if they are needed
--]]
function AppBlobs:buildRAMFromBlobs()
	for name,count in pairs(minBlobPerType) do
		while #self.blobs[name] < count do
			self:addBlob(name)
			if name == 'font' then
				local fontBlob = self.blobs.font:last()
				resetFont(fontBlob:getPtr())
			elseif name == 'palette' then
				local paletteBlob = self.blobs.palette:last()
				resetPalette(paletteBlob:getPtr())
			end
		end
	end

	-- operates on app, reading its .blobs, writing its .memSize, .holdram, .ram, .blobEntriesForClassName
	local info = blobsToByteArray(self.blobs)

	local oldholdram = self.holdram

	self.memSize = info.memSize
	self.holdram = info.holdram
	self.ram = info.ram
	self.blobEntriesForClassName = info.blobEntriesForClassName

	if oldholdram then
		ffi.copy(self.ram.v, ffi.cast('uint8_t*', oldholdram), sizeofRAMWithoutROM)
	end

	-- here build ram ptrs from addrs
	-- TODO really blobsToByteArray doesn't need ram, holdram, memSize at all
	-- do this every time self.blobs or self.ram changes
	for _,blobsForType in pairs(self.blobs) do
		for _,blob in ipairs(blobsForType) do
			blob.ramptr = self.ram.v + blob.addr
		end
	end

--DEBUG:print('...done AppBlobs:initBlobs')

	-- every time .ram updates, this has to update as well:
	self.mvMat.ptr = ffi.cast(mvMatType..'*', self.ram.mvMat)

	--TODO also resize all video sheets to match blobs (or merge them someday)
	-- and TODO also flush them
end

-- NOTICE this desyncs the blobs and the RAM so you'll need to then call buildRAMFromBlobs
function AppBlobs:addBlob(blobClassName)
	self.blobs[blobClassName] = self.blobs[blobClassName] or table()
	local blobClass = assert.index(blobClassForName, blobClassName)
	self.blobs[blobClassName]:insert(blobClass())
end
-- convert a RAM byte array to blobs[]
local function byteArrayToBlobs(ptr, size)
--DEBUG:print('byteArrayToBlobs begin...')
	local ram = ffi.cast('RAM&', ptr)
	local blobs = BlobSet()
	for index=0,ram.blobCount-1 do
		local blobEntryPtr = ram.blobEntries + index
		assert.le(0, blobEntryPtr.addr, 'blob #'..index..' type '..blobEntryPtr.type..' addr is oob')
		assert.le(blobEntryPtr.addr + blobEntryPtr.size, size, 'blob #'..index..' type '..blobEntryPtr.type..' addr is oob')
		local blobClass = assert.index(blobClassForType, blobEntryPtr.type)
		local blobClassName = blobClass.name
--DEBUG:print('\tloading blob #'..index..' type='..blobClassName..' addr='..('0x%x'):format(blobEntryPtr.addr)..' size='..('0x%x'):format(blobEntryPtr.size))
		local blobData = ffi.string(ram.v + blobEntryPtr.addr, blobEntryPtr.size)
		local blob = blobClass:loadBinStr(blobData)
		blobs[blobClassName] = blobs[blobClassName] or table()
		blobs[blobClassName]:insert(blob)
	end
--DEBUG:print('...done byteArrayToBlobs')
	return blobs
end

local function blobsToStr(blobs)
	local info = blobsToByteArray(blobs)
	return ffi.string(info.ram.v, info.memSize)
end

local function strToBlobs(str)
	return byteArrayToBlobs(ffi.cast('uint8_t*', str), #str)
end

function AppBlobs:copyBlobsToROM()
	assert.eq(ffi.sizeof(self.holdram), self.memSize)
	self.blobs:copyToROM()
end

function AppBlobs:copyRAMToBlobs()
	assert.eq(ffi.sizeof(self.holdram), self.memSize)
	self.blobs:copyFromROM()
end


return {
	AppBlobs = AppBlobs,
	minBlobPerType = minBlobPerType,
	BlobEntry = BlobEntry,
	blobClassNameForType = blobClassNameForType,
	blobClassForName = blobClassForName,
	blobTypeForClassName = blobTypeForClassName,
	byteArrayToBlobs = byteArrayToBlobs,
	blobsToStr = blobsToStr,
	strToBlobs = strToBlobs,
	BlobSet = BlobSet,
}
