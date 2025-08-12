local ffi = require 'ffi'
local table = require 'ext.table'
local string = require 'ext.string'
local path = require 'ext.path'
local assert = require 'ext.assert'
local class = require 'ext.class'
local vec2i = require 'vec-ffi.vec2i'
local vector = require 'ffi.cpp.vector-lua'
local struct = require 'struct'
local Image = require 'image'
local AudioWAV = require 'audio.io.wav'

local numo9_rom = require 'numo9.rom'
local blobCountType = numo9_rom.blobCountType
local BlobEntry = numo9_rom.BlobEntry
local spriteSheetSize = numo9_rom.spriteSheetSize
local spriteSheetInBytes = numo9_rom.spriteSheetInBytes
local tilemapSize = numo9_rom.tilemapSize
local paletteSize = numo9_rom.paletteSize
local paletteType = numo9_rom.paletteType
local fontImageSize = numo9_rom.fontImageSize
local audioSampleType = numo9_rom.audioSampleType
local audioSampleRate = numo9_rom.audioSampleRate
local sizeofRAMWithoutROM = numo9_rom.sizeofRAMWithoutROM
local loopOffsetType = numo9_rom.loopOffsetType
local mvMatType = numo9_rom.mvMatType

local numo9_video = require 'numo9.video'
local rgba5551_to_rgba8888_4ch = numo9_video.rgba5551_to_rgba8888_4ch
local rgba8888_4ch_to_5551 = numo9_video.rgba8888_4ch_to_5551
local resetFont = numo9_video.resetFont
local resetPalette = numo9_video.resetPalette

local function hex(n)
	return ('0x%x'):format(n)
end

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
	'data',		-- arbitrary binary blob
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
function Blob:copyToROM()
	assert(self.ramptr, "failed to find ramptr for blob of type "..tostring(self.type))
	ffi.copy(self.ramptr, self:getPtr(), self:getSize())
end
function Blob:copyFromROM()
	assert.ne(self.ramptr, ffi.null)
	ffi.copy(self:getPtr(), self.ramptr, self:getSize())
end
-- static method:
function Blob:getFileName(blobIndex)
	assert.index(self, 'filenamePrefix', 'name='..self.name)
	assert.index(self, 'filenameSuffix', 'name='..self.name)
	return self.filenamePrefix..(blobIndex == 0 and '' or blobIndex)..self.filenameSuffix
end
-- static method:
function Blob:loadBinStr(data)
	return self.class(data)
end


local function blobSubclass(name, parent)
	local subclass = (parent or Blob):subclass()
	subclass.name = name
	blobClassForName[subclass.name] = subclass
	return subclass
end


local BlobCode = blobSubclass'code'
function BlobCode:init(data)	-- optional
	assert.type(data, 'string', "BlobCode needs a non-empty string")
	assert.gt(#data, 0, "BlobCode needs a non-empty string")
	self.data = data
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
function BlobCode:saveFile(filepath)
--DEBUG:print'saving code...'
	local code = self.data
	if #code > 0 then
		assert(filepath:write(code))
	--else
	--	filepath:remove()
	end
end
-- static method:
function BlobCode:loadFile(filepath, basepath)
--DEBUG:print'loading code...'
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
					return '-- ALREADY INCLUDED: '..l
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
				error("couldn't find "..loc.." in include paths: "..require 'ext.tolua'(includePaths:mapi(function(p) return p.path end)))
			else
				return l
			end
		end):concat'\n'
	end
	code = insertIncludes(code)
	--]]

	return BlobCode(code)
end


-- abstract class
local BlobImage = Blob:subclass()
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
function BlobImage:saveFile(filepath, blobs)
	local image = self:makeImage()
	ffi.copy(ffi.cast('uint8_t*', image.buffer), self:getPtr(), self:getSize())
	image:save(filepath.path)
end
-- static method:
function BlobImage:loadFile(filepath)
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


local BlobSheet = blobSubclass('sheet', BlobImage)
BlobSheet.imageSize = spriteSheetSize
BlobSheet.imageType = 'uint8_t'
BlobSheet.filenamePrefix = 'sheet'
BlobSheet.filenameSuffix = '.png'
-- same but adds the palette
function BlobSheet:saveFile(filepath, blobs)
--DEBUG:print'saving sheet...'
	-- sprite tex: 256 x 256 x 8bpp ... TODO needs to be indexed
	-- TODO save a palette'd image
	local image = self:makeImage()
	ffi.copy(ffi.cast('uint8_t*', image.buffer), self:getPtr(), self:getSize())
	image.palette = blobs.palette[1]:toTable()
	image:save(filepath.path)
end


local BlobTileMap = blobSubclass('tilemap', BlobImage)
BlobTileMap.imageSize = tilemapSize
BlobTileMap.imageType = 'uint16_t'
BlobTileMap.filenamePrefix = 'tilemap'
BlobTileMap.filenameSuffix = '.png'
-- swizzle / unswizzle channels
function BlobTileMap:saveFile(filepath)
	local saveImg = Image(tilemapSize.x, tilemapSize.x, 3, 'uint8_t')
	local savePtr = ffi.cast('uint8_t*', saveImg.buffer)
	local blobPtr = self:getPtr()
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
	saveImg:save(filepath.path)
end
-- static method:
-- swizzle / unswizzle channels
function BlobTileMap:loadFile(filepath)
	local loadImg = assert(Image(filepath.path))
	assert.eq(loadImg.width, tilemapSize.x)
	assert.eq(loadImg.height, tilemapSize.y)
	assert.eq(loadImg.channels, 3)
	assert.eq(ffi.sizeof(loadImg.format), 1)
	local loadPtr = ffi.cast('uint8_t*', loadImg.buffer)

	local blobImg = self:makeImage()
	local blobPtr = ffi.cast('uint8_t*', blobImg.buffer)
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


assert.eq(paletteType, 'uint16_t')
assert.eq(paletteSize, 256)
local BlobPalette = blobSubclass('palette', BlobImage)
BlobPalette.imageSize = vec2i(paletteSize, 1)
BlobPalette.imageType = paletteType
BlobPalette.filenamePrefix = 'palette'
BlobPalette.filenameSuffix = '.png'
-- reshape image
function BlobPalette:saveFile(filepath)
	-- palette: 16 x 16 x 24bpp 8bpp r g b
	local saveImg = Image(16, 16, 4, 'uint8_t')
	local savePtr = ffi.cast('uint8_t*', saveImg.buffer)
	local blobPtr = ffi.cast('uint16_t*', self:getPtr())
	for i=0,paletteSize-1 do
		-- TODO packptr in numo9/app.lua
		savePtr[0], savePtr[1], savePtr[2], savePtr[3] = rgba5551_to_rgba8888_4ch(blobPtr[0])
		blobPtr = blobPtr + 1
		savePtr = savePtr + 4
	end
	saveImg:save(filepath.path)
end
function BlobPalette:toTable()
	local paletteTable = table()
	local palPtr = ffi.cast('uint16_t*', self:getPtr())
	for i=1,paletteSize do
		paletteTable:insert{rgba5551_to_rgba8888_4ch(palPtr[0])}
		palPtr = palPtr + 1
	end
	return paletteTable
end
-- static method:
-- reshape image
function BlobPalette:loadFile(filepath)
	local loadImg = assert(Image(filepath.path))
	assert.eq(loadImg.width, 16)
	assert.eq(loadImg.height, 16)
	assert.eq(loadImg.width * loadImg.height, paletteSize)
	assert.eq(loadImg.channels, 4)
	assert.eq(ffi.sizeof(loadImg.format), 1)
	local loadPtr = ffi.cast('uint8_t*', loadImg.buffer)

	local blobImg = self:makeImage()
	local blobPtr = ffi.cast('uint16_t*', blobImg.buffer)
	for i=0,paletteSize-1 do
		blobPtr[0] = rgba8888_4ch_to_5551(
			loadPtr[0],
			loadPtr[1],
			loadPtr[2],
			loadPtr[3]
		)
		blobPtr = blobPtr + 1
		loadPtr = loadPtr + 4
	end
	return BlobPalette(blobImg)
end


local BlobFont = blobSubclass('font', BlobImage)
BlobFont.imageSize = fontImageSize
BlobFont.imageType = 'uint8_t'
BlobFont.filenamePrefix = 'font'
BlobFont.filenameSuffix = '.png'
function BlobFont:saveFile(filepath)
--DEBUG:print'saving font...'
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
	saveImg:save(filepath.path)
end
-- static method:
function BlobFont:loadFile(filepath)
	local blob = self.class()
	resetFont(blob:getPtr(), filepath.path)
	return blob
end


--[[
format:
uint32_t loopOffset
uint16_t samples[]
--]]
local BlobSFX = blobSubclass'sfx'
BlobSFX.filenamePrefix = 'sfx'
BlobSFX.filenameSuffix = '.wav'
function BlobSFX:init(data)
	assert.gt(#data, ffi.sizeof(loopOffsetType))		-- make sure there's room for the initial loopOffset
	assert.eq((#data - ffi.sizeof(loopOffsetType))  % ffi.sizeof(audioSampleType), 0)	-- make sure it's sample-type-aligned
	self.data = assert(data)
end
function BlobSFX:getPtr()
	return ffi.cast('uint8_t*', self.data)
end
function BlobSFX:getSize()
	return #self.data
end
function BlobSFX:saveFile(filepath)
	print('!!! WARNING !!! TODO BlobSFX:saveFile('..filepath..')')
end
-- static method:
function BlobSFX:loadFile(filepath, basepath, blobIndex)
	local wav = AudioWAV():load(filepath.path)

	local tmp = {}
	assert(load(basepath('waveform'..(blobIndex == 0 and '' or blobIndex)..'.txt'):read() or '', nil, nil, tmp))()	-- crash upon syntax error

	return self:loadWav(wav, tmp.loopOffset)
end
-- static method:
function BlobSFX:loadWav(wav, loopOffset)
	assert.eq(wav.channels, 1)	-- waveforms / sfx are mono
	-- TODO resample if they are different.
	-- for now I'm just saving them in this format and being lazy
	assert.eq(wav.ctype, audioSampleType)
	assert.eq(wav.freq, audioSampleRate)

	local i = ffi.new(loopOffsetType..'[1]')
	i[0] = loopOffset or 0
	local data = ffi.string(ffi.cast('char*', i), ffi.sizeof(loopOffsetType))
		.. wav.data
	return BlobSFX(data)
end


local BlobMusic = blobSubclass'music'
BlobMusic.filenamePrefix = 'music'
BlobMusic.filenameSuffix = '.bin'
function BlobMusic:init(data)
	assert.type(data, 'string')
	self.data = data
end
function BlobMusic:getPtr()
	return ffi.cast('uint8_t*', self.data)
end
function BlobMusic:getSize()
	return #self.data
end
-- static method:
function BlobMusic:loadFile(filepath)
	return self.class(filepath:read())
end


local BlobBrush = blobSubclass'brush'
BlobBrush.filenamePrefix = 'brush'
BlobBrush.filenameSuffix = '.lua'
function BlobBrush:init(data)
	self.data = assert(data)
end
function BlobBrush:getPtr()
	return ffi.cast('uint8_t*', self.data)
end
function BlobBrush:getSize()
	return #self.data
end
-- static method:
function BlobBrush:loadFile(filepath)
	return self.class(filepath:read())
end


local BlobBrushMap = blobSubclass'brushmap'
BlobBrushMap.filenamePrefix = 'brushmap'
BlobBrushMap.filenameSuffix = '.lua'
function BlobBrushMap:init(data)
	self.data = assert(data)
end
function BlobBrushMap:getPtr()
	return ffi.cast('uint8_t*', self.data)
end
function BlobBrushMap:getSize()
	return #self.data
end
-- static method:
function BlobBrushMap:loadFile(filepath)
	return self.class(filepath:read())
end


local BlobData = blobSubclass'data'
BlobData.filenamePrefix = 'data'
BlobData.filenameSuffix = '.bin'
function BlobData:init(data)
	self.data = assert(data)
end
function BlobData:getPtr()
	return ffi.cast('uint8_t*', self.data)
end
function BlobData:getSize()
	return #self.data
end
-- static method:
function BlobData:loadFile(filepath)
	return self.class(filepath:read())
end


local blobClassForType = {}
for blobClassName,blobClass in pairs(blobClassForName) do
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
print(('memSize = 0x%0x'):format(memSize))

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
		assert.lt(0, blobSize, "I don't support empty blobs, found one for type "..tostring(blobClassName))
print('adding blob #'..index..' at addr '..hex(addr)..' - '..hex(addr + blobSize)..' type '..blob.type..'/'..blobClassName)
		assert.le(0, addr)
		assert.lt(addr, memSize)
		blobEntryPtr.type = blob.type
		blobEntryPtr.addr = addr
		blobEntryPtr.size = blobSize

		local srcptr = blob:getPtr()
		assert.ne(srcptr, ffi.null)
		blob.addr = addr
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

--[[
after loading a cart, not all default blobs are present
this fills those up, esp useful for font and palette which have default content
but also creates the empty sheet / tilemap if they are needed
--]]
function AppBlobs:buildRAMFromBlobs()
	for name,count in pairs{
		--code = 1,	-- don't init empty code blobs ...
		sheet = 2,
		tilemap = 1,
		palette = 1,
		font = 1,
	} do
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
		assert.le(0, blobEntryPtr.addr)
		assert.le(blobEntryPtr.addr + blobEntryPtr.size, size)
		local blobClass = assert.index(blobClassForType, blobEntryPtr.type)
		local blobClassName = blobClass.name
--DEBUG:print('\tloading blob #'..index..' type='..blobClassName..' addr='..hex(blobEntryPtr.addr)..' size='..hex(blobEntryPtr.size))
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
	BlobEntry = BlobEntry,
	blobClassNameForType = blobClassNameForType,
	blobClassForName = blobClassForName,
	blobTypeForClassName = blobTypeForClassName,
	byteArrayToBlobs = byteArrayToBlobs,
	blobsToStr = blobsToStr,
	strToBlobs = strToBlobs,
	BlobSet = BlobSet,
}
