--[[
compress/decompress cartridges
maybe this should accept the current loaded ROM ...
--]]
local ffi = require 'ffi'
local assertle = require 'ext.assert'.le
local asserteq = require 'ext.assert'.eq
local vec3i = require 'vec-ffi.vec3i'
local Image = require 'image'
local App = require 'numo9.app'

-- 40200 right now
-- that's 512 x 513 x 1
-- or should I save it in 3bpp?
-- meh
local cartImageSize = vec3i(331, 331, 3)
assertle(App.romSize, cartImageSize:volume())

--[[
assumes 'rom' is ptr to the start of our ROM memory
--]]
local function toCartImage(rom)
	local romSize = App.romSize
	local dstImage = Image(cartImageSize.x, cartImageSize.y, cartImageSize.z, 'unsigned char'):clear()
	ffi.copy(dstImage.buffer, rom, App.romSize)
	return dstImage
end

-- TODO image io is tied to file rw because
-- so reading is from files now
local function fromCartImageFile(fn)
	local romImg = Image(fn)
	asserteq(romImg.channels, 3)
	assertle(App.romSize, romImg.width * romImg.height * romImg.channels)
	return ffi.string(romImg.buffer, App.romSize)
end

return {
	toCartImage = toCartImage,
	fromCartImageFile = fromCartImageFile,
}
