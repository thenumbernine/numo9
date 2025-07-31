--[[
compress/decompress cartridges
maybe this should accept the current loaded ROM ...

ok so here's a thought
if i support multiple 'blobs'
or if i store the cart in a png
why even bother convert stuff?
why not just save it in a zip file, and let the loader target our zip data or a directory structure, like a pak file.
and if fantasy-consoles like tik-80 say "swap won't handle code, leave that to us", then lol why even include code in the 'cart' data structure?
why not just work with the uncompressed directories and then optionally use a zip file...
but this would now beg the question, how to reconcile this with the virtual filesystem ...

so for all else except code, it is convenient to just copy RAM->ROM over
for code ... hmm, if I put it in a zip file, it is very convenient to just keep it in one giant code.lua file ...
--]]
local ffi = require 'ffi'
local assert = require 'ext.assert'
local table = require 'ext.table'
local path = require 'ext.path'
local vector = require 'ffi.cpp.vector-lua'
local Image = require 'image'
local zlib = require 'ffi.req' 'zlib'	-- TODO maybe ... use libzip if we're storing a compressed collection of files ... but doing this would push back the conversion of files<->ROM into the application openROM() function ...

local numo9_rom = require 'numo9.rom'
local codeSize = numo9_rom.codeSize
local audioDataSize = numo9_rom.audioDataSize
local sfxTableSize = numo9_rom.sfxTableSize
local musicTableSize = numo9_rom.musicTableSize
local sizeofRAMWithoutROM = num9_rom.sizeofRAMWithoutROM

local numo9_blobs = require 'numo9.blobs'
local blobClassForName = numo9_blobs.blobClassForName
local blobsToByteArray = numo9_blobs.blobsToByteArray
local byteArrayToBlobs = numo9_blobs.byteArrayToBlobs


-- TODO image io is tied to file rw because so many image format libraries are also tied to file rw...
-- so reading is from files now
local tmploc = ffi.os == 'Windows' and path'___tmp.png' or path'/tmp/__tmp.png'
local pngCustomKey = 'nuMO'
--[[
assumes blobs[blobClassName] = table()
creates an Image and returns it
--]]
local function toCartImage(blobs, labelImage)
	local info = blobsToByteArray(blobs)

	local blobsAsStr = ffi.string(info.ram.v + sizeofRAMWithoutROM, info.memSize - sizeofRAMWithoutROM)
	local blobsCompressed = zlib.compressLua(blobsAsStr)

	-- [[ storing in png metadata
	local baseLabelImage = Image'defaultlabel.png'
	assert.eq(baseLabelImage.channels, 4)
	local romImage = Image(baseLabelImage.width, baseLabelImage.height, 4, 'uint8_t'):clear()
	if labelImage then
		labelImage = labelImage:setChannels(4)
		romImage:pasteInto{image=labelImage, x=math.floor((romImage.width-labelImage.width)/2), y=0}
	end
	--[[ paste without alpha
	romImage:pasteInto{image=baseLabelImage, x=0, y=0}
	--]]
	-- [[ paste-with-alpha, TODO move to image library?
	for i=0,baseLabelImage.width*baseLabelImage.height-1 do
		local dstp = romImage.buffer + 4 * i
		local srcp = baseLabelImage.buffer + 4 * i
		for ch=0,2 do
			local f = srcp[3] / 255
			dstp[ch] = srcp[ch] * f + dstp[ch] * (1 - f)
		end
		dstp[3] = math.max(srcp[3], dstp[3])
	end
	--]]
	romImage.unknown = romImage.unknown or {}
	romImage.unknown[pngCustomKey] = {
		-- TODO you could save the regions that are used like tic80
		-- or you could just zlib zip the whole thing
		data = blobsCompressed,
	}
	--]]

--DEBUG:assert(not tmploc:exists())
	assert(romImage:save(tmploc.path))
	local data = assert(tmploc:read())
	tmploc:remove()
--DEBUG:assert(not tmploc:exists())
	return data
	--]=]
end

--[[
takes an Image
returns blobs[]
--]]
local function fromCartImage(srcData)
	-- [=[ loading as an image

	-- [[ from disk
--DEBUG:assert(not tmploc:exists())
	assert(path(tmploc):write(srcData))
	local romImage = Image(tmploc.path)
	tmploc:remove()
--DEBUG:assert(not tmploc:exists())
	--]]
	--[[ from memory
	local romImage = require 'image.luajit.png':loadMem(srcData)
	--]]

	-- [[ storing in png metadata
	local blobsCompressed = assert.index(romImage.unknown or {}, pngCustomKey, "couldn't find png custom chunk").data
	local blobsAsStr = zlib.uncompressLua(blobsCompressed)
--DEBUG:print('blob data length, decompressed: '..('0x%x'):format(#blobsAsStr))

	-- pad the RAM portion
	blobsAsStr = (' '):rep(sizeofRAMWithoutROM) .. blobsAsStr

	local blobs = byteArrayToBlobs(ffi.cast('uint8_t*', blobsAsStr), #blobsAsStr)
	--]]
	--]=]

	assert.index(blobs, 'code')
	assert.len(blobs.code, 1)
	-- assert sprite sheet as well?

	return blobs
end

-- convert blobs' code into a single string
local function codeBlobsToStr(blobs)
	assert.type(blobs, 'table')
	assert.is(blobs.code, blobClassForName.code)
	assert.len(blobs.code, 1)	-- hmm TODO maybe I'll turn this into a zip ... and directory structure ... gah feature creep...
	assert.type(blobs.code[1].data, 'string')

	return blobs.code[1].data
end

local function codeStrToBlobs(blobs, code)
	assert.type(code, 'string')

	assert.type(blobs, 'table')
	assert.is(blobs.code, blobClassForName.code)
	assert.len(blobs.code, 1)

	blobs.code[1].data = code
end

--[[
sfxs is indexed 1 to sfxTableSize and has .data and .loopOffset
musics is indexed 1 to musicTableSize and has .data
--]]
local function buildAudio(bank, sfxs, musics)
	local audioDataOffset = 0
	-- returns start and end of offset into audioData for 'data' to go
	local function addToAudio(data, size)
		local addr = audioDataOffset
		assert(addr + size <= audioDataSize, "audio data overflow")
		ffi.copy(bank.audioData + addr, data, size)
		audioDataOffset = audioDataOffset + math.ceil(size / 2) * 2 -- lazy integer rup
		return addr
	end
	for i=0,sfxTableSize-1 do
		local sfxsrc = sfxs[i+1]
		local sfx = bank.sfxAddrs + i
		local data = sfxsrc and sfxsrc.data
		if not data then
			sfx.len = 0
			sfx.addr = 0
		else
			sfx.len = #data
			sfx.addr = addToAudio(data, sfx.len)
		end
		sfx.loopOffset = sfxsrc and sfxsrc.loopOffset or 0
	end
	for i=0,musicTableSize-1 do
		local music = bank.musicAddrs + i
		local musicsrc = musics[i+1]
		local data = musicsrc and musicsrc.data
		if not data then
			music.len = 0
			music.addr = 0
		else
			music.len = #data
			music.addr = addToAudio(data, music.len)
		end
	end
end

return {
	toCartImage = toCartImage,
	fromCartImage = fromCartImage,
	codeBlobsToStr = codeBlobsToStr,
	codeStrToBlobs = codeStrToBlobs,
	buildAudio = buildAudio,
}
