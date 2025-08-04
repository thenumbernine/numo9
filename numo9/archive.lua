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
local blobsToStr = numo9_blobs.blobsToStr
local strToBlobs = numo9_blobs.strToBlobs


-- TODO image io is tied to file rw because so many image format libraries are also tied to file rw...
-- so reading is from files now
local tmploc = ffi.os == 'Windows' and path'___tmp.png' or path'/tmp/__tmp.png'
local pngCustomKey = 'nuMO'
--[[
assumes blobs[blobClassName] = table()
creates an Image and returns it
--]]
local function blobsToCartImage(blobs, labelImage)
	local blobsAsStr = blobsToStr(blobs)
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
takes an Image of a n9 png
returns a string of the ROM data representing the blobs
--]]
local function cartImageToBlobStr(cartImgData)
	-- loading as an image

	-- [[ from disk
--DEBUG:assert(not tmploc:exists())
	assert(path(tmploc):write(cartImgData))
	local romImage = Image(tmploc.path)
	tmploc:remove()
--DEBUG:assert(not tmploc:exists())
	--]]
	--[[ from memory
	local romImage = require 'image.luajit.png':loadMem(cartImgData)
	--]]

	-- [[ storing in png metadata
	local blobsCompressed = assert.index(romImage.unknown or {}, pngCustomKey, "couldn't find png custom chunk").data
	local blobsAsStr = zlib.uncompressLua(blobsCompressed)
--DEBUG:print('blob data length, decompressed: '..('0x%x'):format(#blobsAsStr))

	-- pad the RAM portion
	blobsAsStr = (' '):rep(sizeofRAMWithoutROM) .. blobsAsStr

	return blobsAsStr 
end

--[[
takes an Image
returns blobs[]
--]]
local function cartImageToBlobs(cartImgData)
	local blobsAsStr = cartImageToBlobStr(cartImgData)
	local blobs = strToBlobs(blobsAsStr)
	return blobs
end

return {
	blobsToCartImage = blobsToCartImage,
	cartImageToBlobs = cartImageToBlobs,
	cartImageToBlobStr = cartImageToBlobStr,
}
