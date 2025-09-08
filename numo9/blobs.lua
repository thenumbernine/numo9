local ffi = require 'ffi'
local table = require 'ext.table'
local string = require 'ext.string'
local path = require 'ext.path'
local assert = require 'ext.assert'
local class = require 'ext.class'
local tolua = require 'ext.tolua'
local fromlua = require 'ext.fromlua'
local vec2i = require 'vec-ffi.vec2i'
local vector = require 'ffi.cpp.vector-lua'
local struct = require 'struct'
local Image = require 'image'
local AudioWAV = require 'audio.io.wav'
-- meh why deal with this bloat
--local OBJLoader = require 'mesh.objloader'

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
local sampleType = numo9_rom.sampleType
local sizeofRAMWithoutROM = numo9_rom.sizeofRAMWithoutROM
local loopOffsetType = numo9_rom.loopOffsetType
local mvMatType = numo9_rom.mvMatType
local meshIndexType = numo9_rom.meshIndexType
local voxelmapSizeType = numo9_rom.voxelmapSizeType

local numo9_video = require 'numo9.video'
local rgba5551_to_rgba8888_4ch = numo9_video.rgba5551_to_rgba8888_4ch
local rgba8888_4ch_to_5551 = numo9_video.rgba8888_4ch_to_5551
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
function BlobDataAbs:saveFile(filepath, blobIndex, blobs)
	assert(filepath:write(self.data))
end
-- static method:
function BlobDataAbs:loadFile(filepath, basepath, blobIndex)
	return self.class(filepath:read())
end


local function blobSubclass(name, parent)
	local subclass = (parent or Blob):subclass()
	subclass.name = name
	blobClassForName[subclass.name] = subclass
	return subclass
end


local BlobCode = blobSubclass('code', BlobDataAbs)
BlobCode.filenamePrefix = 'code'
BlobCode.filenameSuffix = '.lua'
-- static method:
function BlobCode:loadFile(filepath, basepath, blobIndex)
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


local BlobSheet = blobSubclass('sheet', BlobImage)
BlobSheet.imageSize = spriteSheetSize
BlobSheet.imageType = 'uint8_t'
BlobSheet.filenamePrefix = 'sheet'
BlobSheet.filenameSuffix = '.png'
-- same but adds the palette
function BlobSheet:saveFile(filepath, blobIndex, blobs)
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
function BlobTileMap:saveFile(filepath, blobIndex, blobs)
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
function BlobTileMap:loadFile(filepath, basepath, blobIndex)
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
function BlobPalette:saveFile(filepath, blobIndex, blobs)
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
function BlobPalette:loadFile(filepath, basepath, blobIndex)
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
function BlobFont:saveFile(filepath, blobIndex, blobs)
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
function BlobFont:loadFile(filepath, basepath, blobIndex)
	local blob = self.class()
	resetFont(blob:getPtr(), filepath.path)
	return blob
end


--[[
format:
uint32_t loopOffset
uint16_t samples[]
--]]
local BlobSFX = blobSubclass('sfx', BlobDataAbs)
BlobSFX.filenamePrefix = 'sfx'
BlobSFX.filenameSuffix = '.wav'
function BlobSFX:init(data)
	BlobSFX.super.init(self, data)
	assert.gt(#data, ffi.sizeof(loopOffsetType))		-- make sure there's room for the initial loopOffset
	assert.eq((#data - ffi.sizeof(loopOffsetType))  % ffi.sizeof(audioSampleType), 0)	-- make sure it's sample-type-aligned
end
-- static method:
function BlobSFX:getSFXDescPath(filepath, blobIndex)
	return filepath:getdir()(
		self:buildFileName(self.filenamePrefix..'-desc', '.txt', blobIndex)
	)
end
function BlobSFX:saveFile(filepath, blobIndex, blobs)
	AudioWAV:save{
		filename = filepath.path,
		ctype = audioSampleType,
		channels = 1,
		data = self.data:sub(ffi.sizeof(loopOffsetType)+1),
		size = #self.data - ffi.sizeof(loopOffsetType),
		freq = audioSampleRate,
	}
	local sfxDescPath = self:getSFXDescPath(filepath, blobIndex)
	if self.loopOffset and self.loopOffset ~= 0 then
		sfxDescPath:write(tolua{loopOffset = self.loopOffset})
	else
		sfxDescPath:remove()
	end
end
-- static method:
function BlobSFX:loadFile(filepath, basepath, blobIndex)
	local wav = AudioWAV:load(filepath.path)

	local loopOffset
	local sfxDescPath = self:getSFXDescPath(filepath, blobIndex)
	if sfxDescPath:exists() then
		xpcall(function()
			loopOffset = fromlua(assert(sfxDescPath:read())).loopOffset
		end, function(err)
			print(sfxDescPath..':\n'..err..'\n'..debug.traceback())
		end)
	end

	return self:loadWav(wav, loopOffset)
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


local BlobMusic = blobSubclass('music', BlobDataAbs)
BlobMusic.filenamePrefix = 'music'
BlobMusic.filenameSuffix = '.bin'


local BlobData = blobSubclass('data', BlobDataAbs)
BlobData.filenamePrefix = 'data'
BlobData.filenameSuffix = '.bin'


-- 256 bytes for pico8, 1024 bytes for tic80 ... snes is arbitrary, 2k for SMW, 8k for Metroid / Final Fantasy, 32k for Yoshi's Island
-- how to identify unique cartridges?  pico8 uses 'cartdata' function with a 64-byte identifier, tic80 uses either `saveid:` in header or md5
-- tic80 metadata includes title, author, some dates..., description, some urls ...
local BlobPersist = blobSubclass('persist', BlobDataAbs)
BlobPersist.filenamePrefix = 'persist'
BlobPersist.filenameSuffix = '.bin'


-- not yet used...
local BlobBrush = blobSubclass('brush', BlobDataAbs)
BlobBrush.filenamePrefix = 'brush'
BlobBrush.filenameSuffix = '.lua'


local BlobBrushMap = blobSubclass'brushmap'
BlobBrushMap.filenamePrefix = 'brushmap'
BlobBrushMap.filenameSuffix = '.bin'
function BlobBrushMap:init(data)
	data = data or ''
	assert.eq(#data % ffi.sizeof'Stamp', 0, "data is not Stamp-aligned")
	local numStamps = #data / ffi.sizeof'Stamp'
	self.vec = vector('Stamp', numStamps)
	assert.len(self.vec, numStamps)
	assert.len(data, self.vec:getNumBytes())
	ffi.copy(self.vec.v, data, self.vec:getNumBytes())
end
function BlobBrushMap:getPtr()
	return ffi.cast('uint8_t*', self.vec.v)
end
function BlobBrushMap:getSize()
	return self.vec:getNumBytes()
end
function BlobBrushMap:saveFile(filepath, blobIndex, blobs)
	assert(filepath:write(ffi.string(self:getPtr(), self:getSize())))
end
-- static method:
function BlobBrushMap:loadFile(filepath, basepath, blobIndex)
	return self.class(filepath:read())
end


--[[
mesh3D data
especially because I'm adding voxelmap next
mesh3D will hold...

struct {
	int16_t x, y, z;
	uint8_t u, v;
} Vertex;

uint16_t numVertexes
uint16_t numIndexes
Vertex vertexes[]
uint16_t indexes[]
--]]
local BlobMesh3D = blobSubclass('mesh3d', BlobDataAbs)
BlobMesh3D.filenamePrefix = 'mesh3d'
BlobMesh3D.filenameSuffix = '.obj'
function BlobMesh3D:init(data)
	self.data = data or ''

	local minsize = 2 * ffi.sizeof(meshIndexType)	-- # vtxs, # indexes
	if #self.data < minsize then self.data = ('\0'):rep(minsize) end

	-- validate...
	local numVtxs = self:getNumVertexes()	-- maek sure its valid / asesrt-error if its not
	local numIndexes = self:getNumIndexes()
	local indexes = self:getIndexPtr()
	if numIndexes ~= 0 then
		for i=0,numIndexes-1 do
			assert.le(0, indexes[i])
			assert.lt(indexes[i], numVtxs)
		end
	end
end
function BlobMesh3D:getNumVertexes()
	return ffi.cast(meshIndexType..'*', self:getPtr())[0]
end
function BlobMesh3D:getNumIndexes()
	return ffi.cast(meshIndexType..'*', self:getPtr())[1]
end
function BlobMesh3D:getVertexPtr()
	local vtxptr = ffi.cast('Vertex*',
		self:getPtr()
		+ ffi.sizeof(meshIndexType) * 2	-- skip header
	)
	assert.le(0, ffi.cast('uint8_t*', vtxptr + self:getNumVertexes()) - self:getPtr())
	assert.le(ffi.cast('uint8_t*', vtxptr + self:getNumVertexes()) - self:getPtr(), #self.data)
	return vtxptr
end
function BlobMesh3D:getIndexPtr()
	local ptr = ffi.cast('uint8_t*',
		self:getVertexPtr()
		+ self:getNumVertexes()
	) -- skip vertexes
	local indptr = ffi.cast(meshIndexType..'*', ptr)
	assert.le(0, ffi.cast('uint8_t*', indptr + self:getNumIndexes()) - self:getPtr())
	assert.eq(ffi.cast('uint8_t*', indptr + self:getNumIndexes()) - self:getPtr(), #self.data)
	return indptr
end
function BlobMesh3D:saveFile(filepath, blobIndex, blobs)
	--[[ use mesh library objloader
	local mesh = OBJLoader():save(filepath)
	--]]
	-- [[ save ourselves
	-- x / 2^8 <=> needs 8 digits of precision
	-- but (x + .5) / 2^8 <=> needs 9 digits of precision
	local o = table()
	local vtxs = self:getVertexPtr()
	local numVtxs = self:getNumVertexes()
	for i=0,numVtxs-1 do
		local v = vtxs + i
		o:insert('v '..table{v.x, v.y, v.z}:mapi(function(x)
			return ('%.9f'):format((x + .5) / 256)
		end):concat' ')
	end
	for i=0,numVtxs-1 do
		local v = vtxs + i
		o:insert('vt '..table{v.u, v.v}:mapi(function(x)
			return ('%.9f'):format((x + .5) / 256)
		end):concat' ')
	end
	local numIndexes = self:getNumIndexes()
	if numIndexes == 0 then
		for i=0,numVtxs-2,3 do
			o:insert('f '..(i+1)..' '..(i+2)..' '..(i+3))
		end
	else
		local indexes = self:getIndexPtr()
		for i=0,numIndexes-2,3 do
			-- convert 0-based to 1-based
			o:insert('f '..(1+indexes[i])..' '..(1+indexes[i+1])..' '..(1+indexes[i+2]))
		end
	end
	filepath:write(o:concat'\n'..'\n')
	--]]
end
-- static method
function BlobMesh3D:loadFile(filepath, basepath, blobIndex)
	--[[
	local mesh = OBJLoader():load(filepath)
	--]]
	-- [[
	local vs = table()
	local vts = table()
	local is = table()
	for line in io.lines(tostring(filepath)) do
		local words = string.split(string.trim(line), '%s+')
		local lineType = words:remove(1):lower()
		if lineType == 'v' then
			assert.ge(#words, 2)
			vs:insert{
				math.floor((tonumber(words[1]) or 0) * 256),
				math.floor((tonumber(words[2]) or 0) * 256),
				math.floor((tonumber(words[3]) or 0) * 256)
			}
		elseif lineType == 'vt' then
			assert.ge(#words, 2)
			vts:insert{
				math.floor((tonumber(words[1]) or 0) * 256),
				math.floor((tonumber(words[2]) or 0) * 256)
			}
		elseif lineType == 'f' then
			assert(not line:find'/', "sorry I don't support faces with /'s in them, go delete that trash right now.")
			assert.len(words, 3, "sorry I only support triangles")
			for i=1,3 do
				is:insert((assert(tonumber(words[i]))))
			end
		else
			print('ignoring lineType', lineType)
		end
	end

	local o = vector'int16_t'
	o:emplace_back()[0] = #vs
	o:emplace_back()[0] = #is
	assert.eq(#vs, #vts, "your vertexes and texcoords must match.  Sorry I don't do any splitting and re-merging of geometry here")
	for i=1,#vs do
		local v = assert.index(vs, i)
		local vt = assert.index(vts, i)
		o:emplace_back()[0] = v[1]
		o:emplace_back()[0] = v[2]
		o:emplace_back()[0] = v[3]
		local uv = ffi.cast('uint8_t*', o:emplace_back())
		uv[0] = vt[1]
		uv[1] = vt[2]
	end

	local allInARow = true
	for i,j in ipairs(is) do
		if i ~= j then
			allInARow = false
			break
		end
	end
	-- if indexes are sequential then don't save them
	if allInARow then
		o.v[1] = 0	-- clear index count
	else
		for _,i in ipairs(is) do
			o:emplace_back()[0] = i-1	-- convert from 1-based to 0-based
		end
	end
	return self.class(o:dataToStr())
	--]]
end


--[[
format:
uint32_t width, height, depth;
typedef struct {
	uint32_t modelIndex : 17;
	uint32_t tileXOffset: 5;
	uint32_t tileYOffset: 5;
	uint32_t orientation : 5;	// 2: z-axis yaw, 2: x-axis roll, 1:y-axis pitch
} VoxelBlock;
VoxelBlock data[width*height*depth];
--]]
local BlobVoxelMap = blobSubclass('voxelmap', BlobDataAbs)
BlobVoxelMap.filenamePrefix = 'voxelmap'
BlobVoxelMap.filenameSuffix = '.vox'
function BlobVoxelMap:init(data)
	self.data = data or ''
	local minsize = 3 * ffi.sizeof(voxelmapSizeType)	-- header
	if #self.data < minsize then self.data = ('\0'):rep(minsize) end

	-- validate
	self:getWidth()
	self:getHeight()
	self:getDepth()
end
function BlobVoxelMap:getWidth()
	return ffi.cast(voxelmapSizeType..'*', self:getPtr())[0]
end
function BlobVoxelMap:getHeight()
	return ffi.cast(voxelmapSizeType..'*', self:getPtr())[1]
end
function BlobVoxelMap:getDepth()
	return ffi.cast(voxelmapSizeType..'*', self:getPtr())[2]
end
function BlobVoxelMap:getVoxelPtr()
	return ffi.cast('Voxel*', self:getPtr() + ffi.sizeof(voxelmapSizeType) * 3)
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
print('adding blob #'..index..' at addr '..('0x%x'):format(addr)..' - '..('0x%x'):format(addr + blobSize)..' type '..blob.type..'/'..blobClassName)
		assert.le(0, addr)
		assert.le(addr, memSize)
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

local minBlobPerType = {
	code = 1,
	sheet = 2,		-- TODO don't need 2 min here, heck we don't even need 1 min.
	tilemap = 1,
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
