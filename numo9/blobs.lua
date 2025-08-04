local ffi = require 'ffi'
local table = require 'ext.table'
local string = require 'ext.string'
local path = require 'ext.path'
local assert = require 'ext.assert'
local class = require 'ext.class'
local vector = require 'ffi.cpp.vector-lua'
local struct = require 'struct'
local Image = require 'image'

local numo9_rom = require 'numo9.rom'
local blobCountType = numo9_rom.blobCountType
local BlobEntry = numo9_rom.BlobEntry
local spriteSheetSize = numo9_rom.spriteSheetSize
local spriteSheetInBytes = numo9_rom.spriteSheetInBytes
local tilemapSize = numo9_rom.tilemapSize
local tilemapInBytes = numo9_rom.tilemapInBytes
local paletteSize = numo9_rom.paletteSize
local paletteType = numo9_rom.paletteType
local paletteInBytes = numo9_rom.paletteInBytes
local fontInBytes = numo9_rom.fontInBytes
local fontImageSize = numo9_rom.fontImageSize 

local numo9_video = require 'numo9.video'
local resetBlobFont = numo9_video.resetBlobFont

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

-- static method:
function Blob:getFileName(blobNo)
	return self.filenamePrefix..(blobNo == 1 and '' or blobNo)..self.filenameSuffix
end


local BlobCode = Blob:subclass()
blobClassForName.code = BlobCode
function BlobCode:init(data)	-- optional
	self.data = data or ''	-- make sure it's not nil for casting ptr
end
function BlobCode:getPtr()
	return ffi.cast('uint8_t*', self.data)
end
function BlobCode:getSize()
	return #self.data
end
BlobCode.filename = 'code$.lua'
BlobCode.filenamePrefix = 'code'
BlobCode.filenameSuffix = '.lua'
function BlobCode:getFileName(blobNo)
	return 'code'..(blobNo == 1 and '' or blobNo)..'.lua'
end
function BlobCode:saveFile(basepath, blobNo)
	print'saving code...'
	local code = self.data
	local fp = basepath(self:getFileName(blobNo))
	if #code > 0 then
		assert(fp:write(code))
	--else
	--	fp:remove()
	end
end
-- static method:
function BlobCode:loadFile(filepath, basepath)
	print'loading code...'
	local code = assert(filepath:read())
	
	-- [[ preproc here ... replace #include's with included code ...
	-- or what's another option ... I could have my own virtual filesystem per cartridge ... and then allow 'require' functions ... and then worry about where to mount the cartridge ...
	-- that sounds like a much better idea.
	-- so here's a temp fix ...
	local includePaths = table{
		basepath,
		path'include',
	}
	local included = {}
	local function insertIncludes(s)
		return string.split(s, '\n'):mapi(function(l)
			local loc = l:match'^%-%-#include%s+(.*)$'
			if loc then
				if included[loc] then 
					return l..'-- ALREADY INCLUDED'
				end
				included[loc] = true
				for _,incpath in ipairs(includePaths) do
					local d = incpath(loc):read()
					if d then
						return table{
							'----------------------- BEGIN '..loc..'-----------------------',
							insertIncludes(d),
							'----------------------- END '..loc..'  -----------------------',
						}:concat'\n'
					end
				end
				error("couldn't find "..loc.." in include paths: "..tolua(includePaths:mapi(function(p) return p.path end)))
			else
				return l
			end
		end):concat'\n'
	end
	code = insertIncludes(code)
	--]]

	return BlobCode(code)
end


local BlobSheet = Blob:subclass()
blobClassForName.sheet = BlobSheet
-- static method:
function BlobSheet:makeImage()
	return Image(spriteSheetSize.x, spriteSheetSize.y, 1, 'uint8_t')
end
function BlobSheet:init(image)
	if image then
		assert.eq(image.width, spriteSheetSize.x)
		assert.eq(image.height, spriteSheetSize.y)
		assert.eq(image.channels, 1)
		assert.eq(image.format, 'uint8_t')
		self.image = image
	else
		self.image = self:makeImage()
	end
end
function BlobSheet:getPtr()
	return self.image + 0
end
function BlobSheet:getSize()
	return spriteSheetInBytes
end
BlobSheet.filenamePrefix = 'sheet'
BlobSheet.filenameSuffix = '.png'
function BlobSheet:getFileName(blobNo)
	return 'sheet'..(blobNo == 1 and '' or blobNo)..'.png'
end
function BlobSheet:saveFile(basepath, blobNo, blobs)
	print'saving sheet...'
	-- sprite tex: 256 x 256 x 8bpp ... TODO needs to be indexed
	-- TODO save a palette'd image
	local image = self:makeImage()
	ffi.copy(image.buffer, sheetBlob:getPtr(), self:getSize())
	image.palette = blobs.palette[1]:toTable()
	image:save(basepath(self:getFileName(blobNo)).path)
end
-- static method:
function BlobSheet:loadFile(filepath)
	print'loading sprite sheet...'
	local image = assert(Image(filepath.path))
	return BlobSheet(image)
end


local BlobTileMap = Blob:subclass()
blobClassForName.tilemap = BlobTileMap
-- static method:
function BlobTileMap:makeImage()
	return Image(tilemapSize.x, tilemapSize.y, 1, 'uint16_t')
end
function BlobTileMap:init(image)
	if image then
		assert.eq(image.width, tilemapSize.x)
		assert.eq(image.height, tilemapSize.y)
		assert.eq(image.channels, 1)
		assert.eq(image.format, 'uint16_t')
		self.image = image
	else
		self.image = self:makeImage()
	end
end
function BlobTileMap:getPtr()
	return ffi.cast('uint8_t*', self.image.buffer)
end
function BlobTileMap:getSize()
	return tilemapInBytes
end
BlobTileMap.filenamePrefix = 'tilemap'
BlobTileMap.filenameSuffix = '.png'
function BlobTileMap:getFileName(blobNo)
	return 'tilemap'..(blobNo == 1 and '' or blobNo)..'.png'
end
function BlobTileMap:saveFile(basepath, blobNo)
	print'saving tile map...'
	-- tilemap: 256 x 256 x 16bpp ... low byte goes into ch0, high byte goes into ch1, ch2 is 0
	local saveImg = Image(tilemapSize.x, tilemapSize.x, 3, 'uint8_t')
	local blobPtr = self:getPtr()
	local savePtr = saveImg.buffer
	for y=0,tilemapSize.y-1 do
		for x=0,tilemapSize.x-1 do
			savePtr[0] = blobPtr[0]
			savePtr = savePtr + 1
			blobPtr = blobPtr + 1

			savePtr[0] = blobPtr[0]
			savePtr = savePtr + 1
			blobPtr = blobPtr + 1

			savePtr[0] = 0
			savePtr = savePtr + 1
		end
	end
	saveImg:save(basepath(self:getFileName(blobNo)).path)
end
-- static method:
function BlobTileMap:loadFile(filepath)
	print'loading tile map...'
	local loadImg = assert(Image(filepath.path))
	assert.eq(loadImg.width, tilemapSize.x)
	assert.eq(loadImg.height, tilemapSize.y)
	assert.eq(loadImg.channels, 3)
	assert.eq(ffi.sizeof(loadImg.format), 1)

	local blobImg = self:makeImage()
	local blobPtr = ffi.cast('uint8_t*', blobImg.buffer)
	local loadPtr = loadImg.buffer
	for y=0,tilemapSize.y-1 do
		for x=0,tilemapSize.x-1 do
			blobPtr[0] = loadPtr[0]
			loadPtr = loadPtr + 1
			blobPtr = blobPtr + 1

			blobPtr[0] = loadPtr[0]
			loadPtr = loadPtr + 1
			blobPtr = blobPtr + 1

			loadPtr = loadPtr + 1
		end
	end
	return BlobTileMap(blobImg)
end


local BlobPalette = Blob:subclass()
blobClassForName.palette = BlobPalette
-- static method:
function BlobPalette:makeImage()
	return Image(paletteSize, 1, 1, paletteType)
end
function BlobPalette:init(image)
	if image then
		assert.eq(image.width, paletteSize)
		assert.eq(image.height, 1)
		assert.eq(image.channels, 1)
		assert.eq(image.format, paletteType)
		self.image = image
	else
		self.image = self:makeImage()
	end
end
function BlobPalette:getPtr()
	return ffi.cast('uint8_t*', self.image.buffer + 0)
end
function BlobPalette:getSize()
	return paletteInBytes
end
BlobPalette.filenamePrefix = 'palette'
BlobPalette.filenameSuffix = '.png'
function BlobPalette:getFileName(blobNo)
	return 'palette'..(blobNo == 1 and '' or blobNo)..'.png'
end
function BlobPalette:saveFile(basepath, blobNo)
	print'saving palette...'
	-- palette: 16 x 16 x 24bpp 8bpp r g b
	local saveImg = Image(16, 16, 4, 'uint8_t')
	local savePtr = saveImg.buffer
	local blobPtr = ffi.cast('uint16_t*', self:getPtr())
	for y=0,15 do
		for x=0,15 do
			-- TODO packptr in numo9/app.lua
			local r,g,b,a = rgba5551_to_rgba8888_4ch(blobPtr[0])
			savePtr[0], savePtr[1], savePtr[2], savePtr[3] = r,g,b,a
			blobPtr = blobPtr + 1
			savePtr = savePtr + 4
		end
	end
	saveImg:save(basepath(self:getFileName(blobNo)).path)
end
function BlobPalette:toTable()
	local paletteTable = table()
	local palPtr = ffi.cast('uint16_t*', self:getPtr())
	for i=0,255 do
		paletteTable:insert{rgba5551_to_rgba8888_4ch(palPtr[0])}
		palPtr = palPtr + 1
	end
	return paletteTable
end
-- static method:
function BlobPalette:loadFile(filepath)
	print'loading palette...'
	local loadImg = assert(Image(filepath.path))
	assert.eq(loadImg.width, 16)
	assert.eq(loadImg.height, 16)
	assert.eq(loadImg.channels, 4)
	assert.eq(ffi.sizeof(loadImg.format), 1)

	local loadPtr = loadImg.buffer
	local blobImg = self:makeImage()
	local blobPtr = ffi.cast('uint16_t*', blobImg.buffer)
	for y=0,15 do
		for x=0,15 do
			blobPtr[0] = rgba8888_4ch_to_5551(
				loadPtr[0],
				loadPtr[1],
				loadPtr[2],
				loadPtr[3]
			)
			blobPtr = blobPtr + 1
			loadPtr = loadPtr + 4
		end
	end
	return BlobPalette(blobImage)
end


local BlobFont = Blob:subclass()
blobClassForName.font = BlobFont
-- static method:
function BlobFont:makeImage()
	return Image(fontImageSize.x, fontImageSize.y, 1, 'uint8_t')
end
function BlobFont:init(image)
	if image then
		assert.eq(image.width, fontImageSize.x)
		assert.eq(image.height, fontImageSize.y)
		assert.eq(image.channels, 1)
		assert.eq(image.format, 'uint8_t')
	else
		self.image = self:makeImage()
	end
end
function BlobFont:getPtr()
	return self.image.buffer + 0
end
function BlobFont:getSize()
	return fontInBytes
end
BlobFont.filenamePrefix = 'font'
BlobFont.filenameSuffix = '.png'
function BlobFont:getFileName(blobNo)
	return 'font'..(blobNo == 1 and '' or blobNo)..'.png'
end
function BlobFont:saveFile(basepath, blobNo)
	print'saving font...'
	local saveImg = Image(256, 64, 1, 'uint8_t')
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
	saveImg:save(basepath(self:getFileName(blobNo)).path)
end
-- static method:
function BlobFont:loadFile(filepath)
	local blob = BlobFont()
	resetBlobFont(blob:getPtr(), filepath.path)
	return blob
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
