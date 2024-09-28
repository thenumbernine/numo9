--[[
compress/decompress cartridges
maybe this should accept the current loaded ROM ...
--]]
local ffi = require 'ffi'
local assertle = require 'ext.assert'.le
local asserteq = require 'ext.assert'.eq
local assertge = require 'ext.assert'.ge
local asserttype = require 'ext.assert'.type
local path = require 'ext.path'
local vec3i = require 'vec-ffi.vec3i'
local Image = require 'image'

-- only need to require this to make sure it defines ROM and RAM ctypes
-- TODO maybe move that into its own file?
local App = require 'numo9.app'

-- 40200 right now
local cartImageSize = vec3i(363, 363, 3)
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
local tmploc = path'___tmp.tiff'

--[[
assumes 'rom' is ptr to the start of our ROM memory
creates an Image and returns it
--]]
local function toCartImage(rom, labelImage)
	asserttype(rom, 'cdata')
	local romImage = Image(cartImageSize.x, cartImageSize.y, cartImageSize.z, 'uint16_t'):clear()
	
	-- TODO image hardcodes this to 1) file io and 2) extension ... because a lot of the underlying image format apis do too ... fix me plz
	--[[ if it's 8bpp ...
	ffi.copy(romImage.buffer, rom, ffi.sizeof'ROM')
	--]]
	-- [[ if it's 16bpp ... use the lower byte for storage and upper byte for a cartridge label image
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

--DEBUG:assert(not tmploc:exists())
	assert(romImage:save(tmploc.path))
	local data = assert(tmploc:read())
	tmploc:remove()
--DEBUG:assert(not tmploc:exists())
	return data
end

--[[
takes an Image
--]]
local function fromCartImage(imageFileData)
--DEBUG:assert(not tmploc:exists())
	assert(path(tmploc):write(imageFileData))
	local romImage = Image(tmploc.path)
	tmploc:remove()
--DEBUG:assert(not tmploc:exists())

	asserteq(romImage.channels, 3)
	assertle(ffi.sizeof'ROM', romImage.width * romImage.height * romImage.channels)
	
	local rom = ffi.new'ROM'
	--[[ if it's 8bpp ...
	ffi.copy(rom.v, romImage.buffer, ffi.sizeof'ROM')
	--]]
	-- [[ if it's 16bpp ...	
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
end

return {
	toCartImage = toCartImage,
	fromCartImage = fromCartImage,
}
