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
local assertle = require 'ext.assert'.le
local asserteq = require 'ext.assert'.eq
local assertge = require 'ext.assert'.ge
local asserttype = require 'ext.assert'.type
local assertindex = require 'ext.assert'.index
local path = require 'ext.path'
local vec3i = require 'vec-ffi.vec3i'
local Image = require 'image'

-- only need to require this to make sure it defines ROM and RAM ctypes
-- TODO maybe move that into its own file?
local App = require 'numo9.app'

-- 40200 right now
local cartImageSize = vec3i(364, 364, 3)
if ffi.sizeof'ROM' >= cartImageSize:volume() then
	print("You need to resize your cartridge image size for the ROM image to fit into the cartridge file.")
	print(" ROM size: "..ffi.sizeof'ROM')
	print(" cart size: "..cartImageSize:volume())
	print(" cart image dim: "..cartImageSize)
	local newSize = math.ceil(math.sqrt(tonumber(ffi.sizeof'ROM') / 3))
	print("How about a new size of "..vec3i(newSize, newSize, 3))
	error'here'
end

-- TODO image io is tied to file rw because so many image format libraries are also tied to file rw...
-- so reading is from files now
local tmploc = path'___tmp.png'
local pngCustomKey = 'nuMO'
--[[
assumes 'rom' is ptr to the start of our ROM memory
creates an Image and returns it
--]]
local function toCartImage(rom, labelImage)
	asserttype(rom, 'cdata')
	--[[ saving the raw binary
	return ffi.string(rom, ffi.sizeof'ROM')
	--]]

	-- [=[ save as an image
	-- TODO image hardcodes this to 1) file io and 2) extension ... because a lot of the underlying image format apis do too ... fix me plz
	--[[ store it as an 8bpp PNG ...
	local romImage = Image(cartImageSize.x, cartImageSize.y, cartImageSize.z, 'uint8_t'):clear()
	ffi.copy(romImage.buffer, rom, ffi.sizeof'ROM')
	--]]
	-- [[ storing in png metadata
	local baseLabelImage = Image'defaultlabel.png'
	asserteq(baseLabelImage.channels, 4)
	local romImage = Image(baseLabelImage.width, baseLabelImage.height, 4, 'uint8_t'):clear()
	if labelImage then
		romImage:pasteInto{image=labelImage, x=math.floor((romImage.width-labelImage.width)/2), y=0}
	end
	--[[
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
	romImage.unknown[pngCustomKey] = {data=ffi.string(rom, ffi.sizeof'ROM')}
	--]]
	--[[ if it's 16bpp ... use the lower byte for storage and upper byte for a cartridge label image
	local romImage = Image(cartImageSize.x, cartImageSize.y, cartImageSize.z, 'uint16_t'):clear()
	if labelImage then
		assertge(labelImage.channels, 3, "label image must be RGB")
		asserteq(ffi.sizeof(labelImage.format), 1, "label image must be 8bp")
	end
	local index = 0
	for y=0,cartImageSize.y-1 do
		for x=0,cartImageSize.x-1 do
			for ch=0,cartImageSize.z-1 do
				if index < ffi.sizeof'ROM' then
					romImage.buffer[index] = rom.v[index]
				else
					romImage.buffer[index] = 0
				end

				if labelImage then
					romImage.buffer[index] = bit.bor(
						romImage.buffer[index],
						bit.lshift(
							bit.band(0xff, labelImage.buffer[
								ch + labelImage.channels * (
									math.floor(x / romImage.width * labelImage.width)
									+ labelImage.width * math.floor(y / romImage.height * labelImage.height)
								)
							]),
							8
						)
					)
				end

				index = index + 1
			end
		end
	end
	--]]
	--[[ TODO save png with custom chunk holding the cart data
	-- TODO TODO change image png loader to support custom chunks
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
--]]
local function fromCartImage(srcData)
	local rom = ffi.new'ROM'
	--[[ saving/loading raw data
	ffi.copy(rom.v, ffi.cast('uint8_t*', srcData), ffi.sizeof'ROM')
	return rom
	--]]
	-- [=[ loading as an image
--DEBUG:assert(not tmploc:exists())
	assert(path(tmploc):write(srcData))
	local romImage = Image(tmploc.path)
	tmploc:remove()
--DEBUG:assert(not tmploc:exists())
	-- [[ storing in png metadata
	local data = assertindex(romImage.unknown or {}, pngCustomKey, "couldn't find png custom chunk").data
	assertle(ffi.sizeof'ROM', #data)
	ffi.copy(rom.v, data, ffi.sizeof'ROM')
	--]]
	--[[ if it's 8bpp ...
	asserteq(romImage.channels, 3)
	assertle(ffi.sizeof'ROM', romImage.width * romImage.height * romImage.channels)
	ffi.copy(rom.v, romImage.buffer, ffi.sizeof'ROM')
	--]]
	--[[ if it's 16bpp ...
	asserteq(romImage.channels, 3)
	assertle(ffi.sizeof'ROM', romImage.width * romImage.height * romImage.channels)
	local index = 0
	for y=0,cartImageSize.y-1 do
		for x=0,cartImageSize.x-1 do
			for ch=0,cartImageSize.z-1 do
				-- handles the cast from short to byte
				if index >= ffi.sizeof'ROM' then goto fromCartImageDone end
				rom.v[index] = romImage.buffer[index]
				index = index + 1
			end
		end
	end
::fromCartImageDone::
	--]]
	return rom
	--]=]
end

return {
	toCartImage = toCartImage,
	fromCartImage = fromCartImage,
}
