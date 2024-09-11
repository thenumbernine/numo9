--[[
compress/decompress cartridges
maybe this should accept the current loaded ROM ...
--]]
local ffi = require 'ffi'
local assertle = require 'ext.assert'.le
local asserteq = require 'ext.assert'.eq
local asserttype = require 'ext.assert'.type
local path = require 'ext.path'
local vec3i = require 'vec-ffi.vec3i'
local Image = require 'image'

-- only need to require this to make sure it defines ROM and RAM ctypes
-- TODO maybe move that into its own file?
local App = require 'numo9.app'

-- 40200 right now
-- that's 512 x 513 x 1
-- or should I save it in 3bpp?
-- meh
local cartImageSize = vec3i(331, 331, 3)
assertle(ffi.sizeof'ROM', cartImageSize:volume())

-- TODO image io is tied to file rw because
-- so reading is from files now
local tmploc = path'___tmp.png'

--[[
assumes 'rom' is ptr to the start of our ROM memory
creates an Image and returns it
--]]
local function toCartImage(rom)
	asserttype(rom, 'cdata')
	local romSize = ffi.sizeof'ROM'
	local romImg = Image(cartImageSize.x, cartImageSize.y, cartImageSize.z, 'unsigned char'):clear()
	ffi.copy(romImg.buffer, rom, ffi.sizeof'ROM')

	-- TODO image hardcodes this to 1) file io and 2) extension ... because a lot of the underlying image format apis do too ... fix me plz

	assert(not tmploc:exists())
	assert(romImg:save(tmploc.path))
	local data = assert(tmploc:read())
	tmploc:remove()
	assert(not tmploc:exists())
	return data
end

--[[
takes an Image
--]]
local function fromCartImage(imageFileData)
	assert(not tmploc:exists())
	assert(path(tmploc):write(imageFileData))
	local romImg = Image(tmploc.path)
	tmploc:remove()
	assert(not tmploc:exists())

	asserteq(romImg.channels, 3)
	assertle(ffi.sizeof'ROM', romImg.width * romImg.height * romImg.channels)
	return ffi.string(romImg.buffer, ffi.sizeof'ROM')
end

return {
	toCartImage = toCartImage,
	fromCartImage = fromCartImage,
}
