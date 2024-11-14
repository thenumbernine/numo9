--[[
compress/decompress cartridges
maybe this should accept the current loaded ROM ...

ok so here's a thought
if i support multiple 'banks'
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
local zlib = require 'ffi.req' 'zlib'	-- TODO maybe ... use libzip if we're storing a compressed collection of files ... but doing this would push back the conversion of files<->ROM into the application loadROM() function ...

local numo9_rom = require 'numo9.rom'
local bankSize = numo9_rom.bankSize
local bankTypeNames = numo9_rom.bankTypeNames

local numBanksType = 'uint32_t'

-- TODO image io is tied to file rw because so many image format libraries are also tied to file rw...
-- so reading is from files now
local tmploc = path'___tmp.png'
local pngCustomKey = 'nuMO'
--[[
assumes 'banks' is vector<ROM>
creates an Image and returns it
--]]
local function toCartImage(banks, bankTypes, labelImage)
	assert.is(banks, vector)
	assert.eq(banks.type, 'Bank')
	assert.is(bankTypes, vector)
	assert.eq(bankTypes.type, 'uint8_t')
	assert.eq(#bankTypes, #banks)

	local numBanks = ffi.new(numBanksType..'[1]')
	numBanks[0] = #bankTypes
	local banksAsStr = 
		ffi.string(numBanks, ffi.sizeof(numBanks))
		..bankTypes:dataToStr()
		..banks:dataToStr()
	local banksCompressed = zlib.compressLua(banksAsStr)

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
		data = banksCompressed,
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
returns vector<ROM>

TODO new format:
	- # of banks
	- list of bank types
	- list of banks
- then hand these off to subsystems (resetROM) for preparation of resources
- for orig compat our list would be:
	- sprite sheet #0 (sprites)
	- sprite sheet #1 (tiles)
	- tilemap (1of2)
	- tilemap (2of2)
	- video extra ... holds palette and font and a lot of empty space ... this could even be fully optional to provide/load ... but it always needs to go somewhere ...
		... so for carts without video-extra i'd need palette and font space in RAM somewhere
	- audio
	- code
Then through the bank-type list, the console knows what to build gpu textures for
Hmm, seems weird to have two font or palette gpu textures, one pointing to RAM and another to the cart's custom version ... meh?
--]]
local function fromCartImage(srcData)
	local banks = vector'Bank'
	-- [=[ loading as an image
--DEBUG:assert(not tmploc:exists())
	assert(path(tmploc):write(srcData))
	local romImage = Image(tmploc.path)
	tmploc:remove()
--DEBUG:assert(not tmploc:exists())
	-- [[ storing in png metadata
	local banksCompressed = assert.index(romImage.unknown or {}, pngCustomKey, "couldn't find png custom chunk").data
	local banksAsStr = zlib.uncompressLua(banksCompressed)

	local banksAsStrPtr = ffi.cast('char*', banksAsStr)
	local banksAsStrOfs = 0
	
	local numBanks = ffi.new(numBanksType..'[1]')
	ffi.copy(numBanks, banksAsStrPtr + banksAsStrOfs, ffi.sizeof(numBanks))
	banksAsStrOfs = banksAsStrOfs + ffi.sizeof(numBanks)
	assert.le(banksAsStrOfs, #banksAsStr)

	local bankTypes = vector('uint8_t', numBanks[0])
	ffi.copy(bankTypes.v, banksAsStrPtr + banksAsStrOfs, numBanks[0])
	banksAsStrOfs = banksAsStrOfs + numBanks[0]
	assert.le(banksAsStrOfs, #banksAsStr)

	banks:resize(numBanks[0])
	assert.ge(banks:getNumBytes(), #banksAsStr - banksAsStrOfs)
	ffi.copy(banks.v, banksAsStrPtr + banksAsStrOfs, #banksAsStr - banksAsStrOfs)
	--]]
	return banks, bankTypes
	--]=]
end

-- convert multiple banks' code into a single string
local function codeBanksToStr(banks, bankTypes)
	assert.is(banks, vector)
	assert.eq(banks.type, 'Bank')
	assert.is(bankTypes, vector)
	assert.eq(bankTypes.type, 'uint8_t')
	assert.eq(#bankTypes, #banks)

	local codePages = table()
	for bankNo=0,#banks-1 do
		local bank = banks.v + bankNo
		if bankType.v[bankNo] == assert(bankTypeNames:find'code') then
			local bankCode = ffi.string(bank.code, bankSize)
			codePages:insert(bankCode)
		end
	end
	local code = codePages:concat()
	-- trim off trailing \0's - do it here and not per-bank to allow statements (and possibly '\0' strings) to cross the code bank boundaries
	local codeEnd = #code
	while codeEnd > 0 and code:byte(codeEnd) == 0 do
		codeEnd = codeEnd - 1
	end
	return code:sub(1, codeEnd)
end

local function codeStrToBanks(banks, bankTypes, code)
	assert.is(banks, vector)
	assert.eq(banks.type, 'Bank')
	assert.is(bankTypes, vector)
	assert.eq(bankTypes.type, 'uint8_t')
	assert.eq(#bankTypes, #banks)

	assert.type(code, 'string')

	-- assume there's no code banks already ... ? and then insert new code?
	-- ... or should I overwrite the old banks, and ... remove any extras?
	-- nah just assume none
	local numBanksPrev = #banks
	for bankNo=0,numBanksPrev-1 do
		if bankType.v[bankNo] == assert(bankTypeNames:find'code') then
			error'WARNING - found a previous code bank when we were writing code banks'
		end
	end

	local n = #code
--DEBUG:print('code size is', n)
	local numBanksNeededForCode = math.ceil(n / bankSize)
--DEBUG:print('num banks needed is', numBanksNeededForCode)
	banks:resize(numBanksPrev + numBanksNeededForCode)
	ffi.fill(banks.v[numBanksPrev].v, ffi.sizeof'Bank' * numBanksNeededForCode)
	for bankNo=0,numBanksNeededForCode-1 do
		local bank = banks.v[bankNo + numBanksPrev]
		local i1 = bankNo*bankSize
		local i2 = (bankNo+1)*bankSize
		local s = code:sub(i1+1, i2)
		assert.le(#s, bankSize)
		ffi.fill(bank.v, 0, bankSize)
		ffi.copy(bank.v, s)
	end
end

return {
	toCartImage = toCartImage,
	fromCartImage = fromCartImage,
	codeBanksToStr = codeBanksToStr,
	codeStrToBanks = codeStrToBanks,
}
