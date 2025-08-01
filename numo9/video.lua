local ffi = require 'ffi'
local op = require 'ext.op'
local template = require 'template'
local table = require 'ext.table'
local class = require 'ext.class'
local math = require 'ext.math'
local assert = require 'ext.assert'
local Image = require 'image'
local gl = require 'gl'
local glreport = require 'gl.report'
local GLFBO = require 'gl.fbo'
local GLTex2D = require 'gl.tex2d'
local GLGeometry = require 'gl.geometry'
local GLSceneObject = require 'gl.sceneobject'
local GLTypes = require 'gl.types'
local GLGlobal = require 'gl.global'

require 'vec-ffi.vec4ub'
require 'vec-ffi.create_vec3'{dim=4, ctype='unsigned short'}	-- vec4us_t

local numo9_rom = require 'numo9.rom'
local spriteSize = numo9_rom.spriteSize
local spriteSheetSize = numo9_rom.spriteSheetSize
local spriteSheetSizeInTiles = numo9_rom.spriteSheetSizeInTiles
local spriteSheetAddr = numo9_rom.spriteSheetAddr
local tileSheetAddr = numo9_rom.tileSheetAddr
local tilemapAddr = numo9_rom.tilemapAddr
local tilemapSize = numo9_rom.tilemapSize
local paletteSize = numo9_rom.paletteSize
local paletteAddr = numo9_rom.paletteAddr
local paletteInBytes = numo9_rom.paletteInBytes
local fontAddr = numo9_rom.fontAddr
local fontImageSize = numo9_rom.fontImageSize
local fontImageSizeInTiles = numo9_rom.fontImageSizeInTiles
local fontInBytes = numo9_rom.fontInBytes
local framebufferAddr = numo9_rom.framebufferAddr
local frameBufferSize = numo9_rom.frameBufferSize
local clipMax = numo9_rom.clipMax
local mvMatScale = numo9_rom.mvMatScale
local mvMatType = numo9_rom.mvMatType
local menuFontWidth = numo9_rom.menuFontWidth

local mvMatInvScale = 1 / mvMatScale

local function vec2to4(m, x, y, z)
	return
		(m[0] * x + m[4] * y + m[12]) * mvMatInvScale,
		(m[1] * x + m[5] * y + m[13]) * mvMatInvScale,
		(m[2] * x + m[6] * y + m[14]) * mvMatInvScale,
		(m[3] * x + m[7] * y + m[15]) * mvMatInvScale
end
local function vec3to4(m, x, y, z)
	return
		(m[0] * x + m[4] * y + m[ 8] * z + m[12]) * mvMatInvScale,
		(m[1] * x + m[5] * y + m[ 9] * z + m[13]) * mvMatInvScale,
		(m[2] * x + m[6] * y + m[10] * z + m[14]) * mvMatInvScale,
		(m[3] * x + m[7] * y + m[11] * z + m[15]) * mvMatInvScale
end

local function glslnumber(x)
	local s = tostring(tonumber(x))
	if s:find'e' then return s end
	if not s:find'%.' then s = s .. '.' end
	return s
end

local function settableindex(t, i, ...)
	if select('#', ...) == 0 then return end
	t[i] = ...
	settableindex(t, i+1, select(2, ...))
end

local function settable(t, ...)
	settableindex(t, 1, ...)
end

-- either seems to work fine
local texelFunc = 'texture'
--local texelFunc = 'texelFetch'

local texInternalFormat_u8 = gl.GL_R8UI
local texInternalFormat_u16 = gl.GL_R16UI

-- 'REV' means first channel first bit ... smh
-- so even tho 5551 is on hardware since forever, it's not on ES3 or WebGL, only GL4...
-- in case it's missing, just use single-channel R16 and do the swizzles manually
local internalFormat5551 = texInternalFormat_u16
local formatInfo = GLTex2D.formatInfoForInternalFormat[internalFormat5551]
local format5551 = formatInfo.format
local type5551 = formatInfo.types[1]	-- gl.GL_UNSIGNED_SHORT

	-- convert it here to vec4 since default UNSIGNED_SHORT_1_5_5_5_REV uses vec4
local glslCode5551 = [[
// assumes the uint is [0,0xffff]
// returns rgba in [0,0x1f]
uvec4 u16to5551(uint x) {
	return uvec4(
		x & 0x1fu,
		(x & 0x3e0u) >> 5u,
		(x & 0x7c00u) >> 10u,
		((x & 0x8000u) >> 15u) * 0x1fu
	);
}
]]

local function textureSize(tex)
	return 'textureSize('..tex..', 0)'
end

--[[
args:
	texvar = glsl var name
	tex = GLTex object
	tc
	from (optional) 'vec2' or 'ivec2'
	to (optional) 'vec4' or 'uvec4'
is this going to turn into a parser?
--]]
local function readTex(args)
	local texvar = args.texvar
	local tc = args.tc
	if args.from == 'vec2' then
		if texelFunc == 'texelFetch' then
			tc = 'ivec2(('..tc..') * vec2('..textureSize(texvar)..'))'
		end
	elseif args.from == 'ivec2' then
		if texelFunc ~= 'texelFetch' then
			tc = '(vec2('..tc..') + .5) / vec2('..textureSize(texvar)..')'
		end
	end
	local dst
	if texelFunc == 'texelFetch' then
		dst = texelFunc..'('..texvar..', '..tc..', 0)'
	else
		dst = texelFunc..'('..texvar..', '..tc..')'
	end

	-- TODO this is for when args.tex is a 5551 GL_R16UI
	-- and to's type is vec4 ...
	--  however you can't always test for GL_R16UI because this is also tilemapRAMs when reading tileIndex ...
	--  .. but that one's dest is uvec4 so meh
	-- but if I set that internalFormat then args.to will become uvec4, and then this will be indistinguishble from the tilemapRAMs ...
	-- so I would need an extra flag for "to vec4 5551"
	-- or should I already be setting them to vec4?
	if args.to == 'u16to5551' then
		dst = 'u16to5551(('..dst..').r)'
	elseif args.to == 'uvec4' then
		-- convert to uint, assume the source is a texture texel
		if args.tex:getGLSLFragType() == 'uvec4' then
			dst = 'uvec4('..dst..')'
		end
	end
	return dst
end

-- r,g,b,a is 8bpp
-- result is 5551 16bpp
local function rgba8888_4ch_to_5551(r,g,b,a)
	return bit.bor(
		bit.band(0x001f, bit.rshift(r, 3)),
		bit.band(0x03e0, bit.lshift(g, 2)),
		bit.band(0x7c00, bit.lshift(b, 7)),
		a == 0 and 0 or 0x8000
	)
end

-- rgba5551 is 16bpp
-- result is r,g,b,a 8bpp
local function rgba5551_to_rgba8888_4ch(rgba5551)
	-- rounding ... for 5 bits into 8 bits, OR with the upper 3 bits again shifted down 5 bits ... so its a repeated-decimal
	local r = bit.band(rgba5551, 0x1F)
	local g = bit.band(rgba5551, 0x3E0)
	local b = bit.band(rgba5551, 0x7C00)
	return
		bit.bor(
			bit.lshift(r, 3),	-- shift bit 4 to bit 7
			bit.rshift(r, 2)	-- shift bit 4 to bit 2
		),
		bit.bor(
			bit.rshift(g, 2),	-- shift bit 9 to bit 7
			bit.rshift(g, 7)	-- shift bit 9 to bit 2
		),
		bit.bor(
			bit.rshift(b, 7),	-- shift bit 14 to bit 7
			bit.rshift(b, 12)	-- shift bit 14 to bit 2
		),
		bit.band(rgba5551, 0x8000) == 0 and 0 or 0xff
end

-- rgb565 is 16bpp
-- result is r,g,b 8bpp
local function rgb565rev_to_rgba888_3ch(rgb565)
	local b = bit.band(rgb565, 0x1F)
	local g = bit.band(rgb565, 0x7E0)
	local r = bit.band(rgb565, 0xF800)
	return
		bit.bor(
			bit.rshift(r, 8),		-- shift bit 15 to bit 7
			bit.rshift(r, 13)		-- shift bit 15 to bit 2
		),
		bit.bor(
			bit.rshift(g, 3),		-- shift bit 10 to bit 7
			bit.rshift(g, 9)		-- shift bit 10 to bit 1
		),
		bit.bor(
			bit.lshift(b, 3),		-- shift bit 4 to bit 7
			bit.rshift(b, 2)		-- shift bit 4 to bit 2
		)
end

-- when I say 'reverse' i mean reversed order of bitfields
-- when opengl says 'reverse' it means reversed order of reading hex numbers or something stupid
local function argb8888revto5551(rgba)
	local a = bit.band(bit.rshift(rgba, 24), 0xff)
	local r = bit.band(bit.rshift(rgba, 16), 0xff)
	local g = bit.band(bit.rshift(rgba, 8), 0xff)
	local b = bit.band(rgba, 0xff)
	return rgba8888_4ch_to_5551(r,g,b,a)
end

-- upon boot, upload the logo to the whole sheet
local function resetLogoOnSheet(spriteSheetPtr)
	local splashImg = Image'splash.png'
	assert.eq(splashImg.channels, 1)
	assert.eq(splashImg.width, spriteSheetSize.x)
	assert.eq(splashImg.height, spriteSheetSize.y)
	-- TODO don't do the whole spritesheet ...
	for y=0,spriteSheetSize.y-1 do
		for x=0,spriteSheetSize.x-1 do
			local index = x + spriteSheetSize.x * y
			spriteSheetPtr[index] = splashImg.buffer[index] == 0
				and 0xfc or 0xf0	-- subtract out the white
				--and 0xff or 0xf0	-- subtract light-gray (to fade? nah not working)
				--and 0xf0 or 0xfc	-- opposite, good for adding i guess?
		end
	end
end

local function resetROMFont(fontPtr, fontFilename)
	-- paste our font letters one bitplane at a time ...
	-- TODO just hardcode this resource in the code?
	local fontImg = assert(Image(fontFilename or 'font.png'), "failed to find file "..tostring(fontFilename))
	local srcx, srcy = 0, 0
	local dstx, dsty = 0, 0
	local function inc2d(x, y, w, h)
		x = x + 8
		if x < w then return x, y end
		x = 0
		y = y + 8
		if y < h then return x, y end
	end
	for i=0,255 do
		local b = bit.band(i, 7)
		local mask = bit.bnot(bit.lshift(1, b))
		assert.lt(srcx, fontImg.width)
		assert.lt(srcy, fontImg.height)
		assert.lt(dstx, fontImageSize.x)
		assert.lt(dsty, fontImageSize.y)
		for by=0,7 do
			for bx=0,7 do
				local srcp = fontImg.buffer
					+ srcx + bx
					+ fontImg.width * (
						srcy + by
					)
				local dstp = fontPtr
					+ dstx + bx
					+ fontImageSize.x * (
						dsty + by
					)
				dstp[0] = bit.bor(
					bit.band(mask, dstp[0]),
					bit.lshift(srcp[0], b)
				)
			end
		end
		srcx, srcy = inc2d(srcx, srcy, fontImg.width, fontImg.height)
		if not srcx then break end
		if b == 7 then
			dstx, dsty = inc2d(dstx, dsty, fontImageSize.x, fontImageSize.y)
			if not dstx then break end
		end
	end
end

-- TODO every time App calls this, make sure its paletteRAM.dirtyCPU flag is set
-- it would be here but this is sometimes called by n9a as well
local function resetPalette(ptr)	-- uint16_t*
	for i,c in ipairs(
		--[[ garbage colors
		function(i)
			return math.floor(math.random() * 0xffff)
		end
		--]]
		-- [[ builtin palette
		table{
			-- tic80
			0x00000000,
			0xff562b5a,
			0xffa44654,
			0xffe08260,
			0xfff7ce82,
			0xffb7ed80,
			0xff60b46c,
			0xff3b7078,
			0xff2b376b,
			0xff415fc2,
			0xff5ca5ef,
			0xff93ecf5,
			0xfff4f4f4,
			0xff99afc0,
			0xff5a6c84,
			0xff343c55,
			-- https://en.wikipedia.org/wiki/List_of_software_palettes
			0x00000000,
			0xff75140c,
			0xff377d22,
			0xff807f26,
			0xff00097a,
			0xff75197c,
			0xff367e7f,
			0xffc0c0c0,
			0xff7f7f7f,
			0xffe73123,
			0xff74f84b,
			0xfffcfa53,
			0xff001ef2,
			0xffe63bf3,
			0xff71f7f9,
			0xfffafafa,
			-- ega palette: https://moddingwiki.shikadi.net/wiki/EGA_Palette
			0x00000000,
			0xff0000AA,
			0xff00AA00,
			0xff00AAAA,
			0xffAA0000,
			0xffAA00AA,
			0xffAA5500,
			0xffAAAAAA,
			0xff555555,
			0xff5555FF,
			0xff55FF55,
			0xff55FFFF,
			0xffFF5555,
			0xffFF55FF,
			0xffFFFF55,
			0xffFFFFFF,
		}:mapi(argb8888revto5551)

		--]]
		:rep(16)	-- make sure it fills 0-255
		:sub(1, 240)	-- make sure we don't iterate across too many colors and ptr goes oob ...
		:append(table{
			-- editor palette
			0x00000000,
			0xff562b5a,
			0xffa44654,
			0xffe08260,
			0xfff7ce82,
			0xffb7ed80,
			0xff60b46c,
			0xff3b7078,
			0xff2b376b,
			0xff415fc2,
			0xff5ca5ef,
			0xff93ecf5,
			0xfff4f4f4,
			0xff99afc0,
			0xff5a6c84,
			0xff343c55,
		}:mapi(argb8888revto5551))
	) do
		ptr[0] = c
		ptr = ptr + 1
	end
end

local function resetROMPalette(rom)
	resetPalette(rom.palette)
end


--[[
makes an image whose buffer is at a location in RAM
makes a GLTex2D that goes with that image
provides dirty/flushing functions
--]]
local RAMGPUTex = class()

--[[
args:
	app = app
	addr = where in RAM

	Image ctor:
	width
	height
	channels
	ctype
	src (optional)

	Tex ctor:
	target (optional)
	gltype
	glformat
	internalFormat
	wrap
	magFilter
	minFilter
--]]
function RAMGPUTex:init(args)
--DEBUG:print'RAMGPUTex:init begin'
glreport'before RAMGPUTex:init'
	local app = assert.index(args, 'app')
	self.app = app
	self.addr = assert.index(args, 'addr')
	assert.ge(self.addr, 0)
	local width = assert(tonumber(assert.index(args, 'width')))
	local height = assert(tonumber(assert.index(args, 'height')))
	local channels = assert.index(args, 'channels')
	if channels ~= 1 then print'DANGER - non-single-channel Image!' end
	local ctype = assert.index(args, 'ctype')
	local ctypeSize = ffi.sizeof(ctype)
	self.pixelSize = channels * ctypeSize

	self.size = width * height * channels * ctypeSize
	self.addrEnd = self.addr + self.size
	assert.le(self.addrEnd, app.memSize)
	local ptr = ffi.cast('uint8_t*', app.ram) + self.addr
	local src = args.src

--DEBUG:print(('RAMGPU 0x%x - 0x%x (size 0x%x)'):format(self.addr, self.addrEnd, self.size))

	local image = Image(width, height, channels, ctype, src)
	self.image = image
	if src then	-- if we specified a src to the Image then copy it into RAM before switching Image pointers to point at RAM
		ffi.copy(ptr, image.buffer, self.size)
	end
	-- TODO allow Image construction with ptr
	image.buffer = ffi.cast(image.format..'*', ptr)

	local tex = GLTex2D{
		target = args.target,
		internalFormat = args.internalFormat or gl.GL_RGBA,
		format = args.glformat or gl.GL_RGBA,
		type = args.gltype or gl.GL_UNSIGNED_BYTE,

		width = width,
		height = height,
		wrap = args.wrap or { -- texture_rectangle doens't support repeat ...
			s = gl.GL_CLAMP_TO_EDGE,
			t = gl.GL_CLAMP_TO_EDGE,
		},
		minFilter = args.minFilter or gl.GL_NEAREST,
		magFilter = args.magFilter or gl.GL_NEAREST,
		data = ptr,	-- ptr is stored
	}
-- this will fail when the menu font is being used
--assert.eq(tex.data, ffi.cast('uint8_t*', self.image.buffer))
	self.tex = tex
glreport'after RAMGPUTex:init'
--DEBUG:print'RAMGPUTex:init done'
end

function RAMGPUTex:overlaps(other)
	return self.addr < other.addrEnd and other.addr < self.addrEnd
end

-- TODO gonna subclass this soon ...
-- assumes it is being called from within the render loop
function RAMGPUTex:checkDirtyCPU()
	if not self.dirtyCPU then return end
	-- we should never get in a state where both CPU and GPU are dirty
	-- if someone is about to write to one then it shoudl test the other and flush it if it's dirty, then set the one
	assert(not self.dirtyGPU, "someone dirtied both cpu and gpu without flushing either")
	local app = self.app
	local tex = self.tex
	local fb = app.fb
	if app.inUpdateCallback then
		fb:unbind()
	end
-- this will fail when the menu font is being used
--assert.eq(tex.data, ffi.cast('uint8_t*', self.image.buffer))
	tex:bind()
		:subimage()
	if app.inUpdateCallback then
		fb:bind()
	end
	self.dirtyCPU = false
	self.changedSinceDraw = true	-- only used by framebufferRAM, if its GPU state ever changes, to let the app know to draw it again
end

-- TODO is this only applicable for framebufferRAM?
-- if anything else has a dirty GPU ... it'd have to be because the framebuffer was rendering to it
-- and right now, the fb is only outputting to framebufferRAM ...
function RAMGPUTex:checkDirtyGPU()
	if not self.dirtyGPU then return end
	assert(not self.dirtyCPU, "someone dirtied both cpu and gpu without flushing either")
	-- assert that fb is bound to framebufferRAM ...
	local app = self.app
	local tex = self.tex
	local image = self.image
	local fb = app.fb
	if not app.inUpdateCallback then
		fb:bind()
	end
-- this will fail when the menu font is being used
--assert.eq(tex.data, ffi.cast('uint8_t*', self.image.buffer))
	gl.glReadPixels(0, 0, tex.width, tex.height, tex.format, tex.type, image.buffer)
	if not app.inUpdateCallback then
		fb:unbind()
	end
	self.dirtyGPU = false
end

--[[
sync CPU and GPU mem then move and flag cpu-dirty so the next cycle will update
--]]
function RAMGPUTex:updateAddr(newaddr)
--DEBUG:print'checkDirtyGPU'
	self:checkDirtyGPU()	-- only the framebuffer has this
--DEBUG:print'checkDirtyCPU'
	self:checkDirtyCPU()
-- clamp or allow OOB? or error?  or what?
	newaddr = math.clamp(bit.bor(0, newaddr), 0, self.app.memSize - self.size)
--DEBUG:print(('new addr: $%x'):format(newaddr))
	self.addr = newaddr
--DEBUG:print('self.addr', self.addr)
--DEBUG:print('self.size', self.size)
	self.addrEnd = newaddr + self.size
--DEBUG:print('self.addrEnd', self.addrEnd)
	self.tex.data = ffi.cast('uint8_t*', self.app.ram.v) + self.addr
--DEBUG:print('self.tex.data', self.tex.data)
	self.image.buffer = ffi.cast(self.image.format..'*', self.tex.data)
--DEBUG:print('self.image.buffer', self.image.buffer)
	self.dirtyCPU = true
end


-- This just holds a bunch of stuff that App will dump into itself
-- so its member functions' "self"s are just 'App'.
-- I'd call it 'App' but that might be confusing because it's not really App.
local AppVideo = {}

-- called upon app init
-- 'self' == app
function AppVideo:initVideo()
	self.fb = GLFBO():unbind()


	--[[
	create these upon resetVideo() or at least upon loading a new ROM, and make a sprite/tile sheet per bank
	but I am still using the texture specs for my shader creation
	and my shader creation is done once
	so until then, just resize them here

	hmm, how to reduce texture #s as much as possible
	Can I get by binding everything everywhere overall?
	GLES3 GL_MAX_TEXTURE_SIZE must be at least 2048, so 2048x2048,
	so if our textures are restricted to 256x256 then I can save 8x8 of the 256x256 texs in just one = 64 sprite/tile sheets in just one tex ...
	... but uploading would require some row interleaving ...
	... but it wouldn't if I just stored a single 256 x 2048 texture with just 8 nested textures ...
	... or it wouldn't if I just did the texture memory unraveling in-shader (and stored it as garbage in memory)
	... oh yeah I can get even more space from using a bigger format ... like 16/32-bit RGB/A textures ...
	... and that's just a single texture for GLES3, if we want to deal with multiple bound textures we have
		GL_MAX_TEXTURE_IMAGE_UNITS is guaranteed to be at least 16

	What are allll our textures?
	- paletteMenuTex					256x1		2 bytes ... GL_R16UI
	- fontMenuTex						256x8		1 byte  ... GL_R8UI
	- checkerTex						4x4			3 bytes ... GL_RGB+GL_UNSIGNED_BYTE
	- framebufferMenuTex				256x256		3 bytes ... GL_RGB+GL_UNSIGNED_BYTE
	- framebufferRAMs._256x256xRGB565	256x256		2 bytes ... GL_RGB565+GL_UNSIGNED_SHORT_5_6_5
	- framebufferRAMs._256x256x8bpp		256x256		1 byte  ... GL_R8UI
	- per-bank:
		- sheetRAMs[i] x2				256x256		1 byte  ... GL_R8UI
		- tilemapRAMs[i]				256x256		2 bytes ... GL_R16UI
		- paletteRAMs[i]				256x1		2 bytes ... GL_R16UI
		- fontRAMs[i]					256x8		1 byte  ... GL_R8UI

	I could put sheetRAM on one tex, tilemapRAM on another, paletteRAM on another, fontRAM on another ...
	... and make each be 256 cols wide ... and as high as there are banks ...
	... but if 2048 is the min size, then 256x2048 = 8 sheets worth, and if we use sprite & tilemap then that's 4 ...
	... or I could use a 512 x 2048 tex ... and just delegate what region on the tex each sheet gets ...
	... or why not, use all 2048 x 2048 = 64 different 256x256 sheets, and sprite/tile means 32 bank max ...
	I could make a single GL tex, and share regions on it between different sheetRAMs ...
	This would break with the tex.ptr == image.ptr model ... no more calling :subimage() without specifying regions ...

	Should I just put the whole cartridge on the GPU and keep it sync'd at all times?
	How often do I modify the cartridge anyways?

	--]]
	self.sheetRAMs = table()
	self.tilemapRAMs = table()
	self.paletteRAMs = table()
	self.fontRAMs = table()
	self:resizeRAMGPUs()
	self.paletteRAM = self.paletteRAMs[1]
	self.fontRAM = self.fontRAMs[1]

	-- this table is 1:1 with videoModeInfo
	-- and used to create/assign unique framebufferRAMs
	local requestedVideoModes = table()
	local function addreq(info)
		if #requestedVideoModes == 0
		and not requestedVideoModes[0]
		then
			requestedVideoModes[0] = info
		else
			requestedVideoModes[#requestedVideoModes+1] = info
		end
	end

	-- 16bpp upper bound resolution:
	for _,wh in ipairs{
		{256, 256},	-- 1:1
		{272, 217},	-- 5:4
		{288, 216},	-- 4:3
		{304, 202},	-- 3:2
		{320, 200},	-- 8:5
		{320, 192},	-- 5:3
		{336, 189},	-- 16:9
		{336, 177},	-- 17:9
		{352, 176},	-- 2:1
		{384, 164},	-- 21:9
	} do
		for _,format in ipairs{'RGB565', '8bppIndex', 'RGB332'} do
			-- the 1:1 is added above ...
			addreq{
				width = wh[1],
				height = wh[2],
				format = format,
			}
		end
	end
	-- 8bpp upper bound resolutions:
	for _,wh in ipairs{
		{352, 352},	-- 1:1
		{400, 320},	-- 5:4
		{416, 312},	-- 4:3
		{432, 288},	-- 3:2
		{448, 280},	-- 8:5
		{464, 278},	-- 5:3
		{480, 270},	-- 16:9
		{496, 262},	-- 17:9
		{512, 256},	-- 2:1
		{544, 233},	-- 21:9
	} do
		for _,format in ipairs{'8bppIndex', 'RGB332'} do
			addreq{
				width = wh[1],
				height = wh[2],
				format = format,
			}
		end
	end
	--[[ TODO 4bpp
	-- but there's no GL formats for 4bpp ...
	-- and I'd do separate 4bpp at a time to an 8bpp buffer
	-- but it looks like GL got rid of its bitmasking features (did it?)
	for _,wh in ipairs{
		{512, 512},
		{560, 448},
		{576, 432},
		{624, 416},
		{640, 400},
		{656, 393},
		{672, 378},
		{688, 364},
		{720, 360},
		{768, 329},
	} do
		addreq{
			width = wh[1],
			height = wh[2],
			format = '4bppIndex',
		}
	end
	--]]
	-- TOOD 2bpp 1bpp...

	ffi.fill(self.ram.framebuffer, ffi.sizeof(self.ram.framebuffer), 0)

	-- hmm, is there any reason why like-format buffers can't use the same gl texture?
	self.framebufferRAMs = {}
	for i,req in pairs(requestedVideoModes) do
		local width, height = req.width, req.height
		local internalFormat, gltype, suffix
		if req.format == 'RGB565' then
			-- framebuffer is 256 x 256 x 16bpp rgb565 -- used for mode-0
			-- [[
			internalFormat = gl.GL_RGB565
			gltype = gl.GL_UNSIGNED_SHORT_5_6_5	-- for an internalFormat there are multiple gltype's so pick this one
			--]]
			--[[
			-- TODO do this but in doing so the framebuffer fragment vec4 turns into a uvec4
			-- and then the reads from u16to5551() which output vec4 no longer fit
			-- ... hmm ...
			-- ... but if I do this then the 565 hardware-blending no longer works, and I'd have to do that blending manually ...
			internalFormat = internalFormat5551
			--]]
			suffix = 'RGB565'
		elseif req.format == '8bppIndex'
		or req.format == 'RGB332'
		then
			-- framebuffer is 256 x 256 x 8bpp indexed -- used for mode-1, mode-2
			internalFormat = texInternalFormat_u8
			suffix = '8bpp'
			-- hmm TODO maybe
			-- if you want blending with RGB332 then you can use GL_R3_G3_B2 ...
			-- but it's not in GLES3/WebGL2
		elseif req.format == '4bppIndex' then
			-- here's where exceptions need to be made ...
			-- hmm, so when I draw sprites, I've got to shrink coords by half their size ... ?
			-- and then track whether we are in the lo vs hi nibble ... ?
			-- and somehow preserve the upper/lower nibbles on the sprite edges?
			-- maybe this is too tedious ...
			internalFormat = texInternalFormat_u8
			suffix = '8bpp'	-- suffix is for the framebuffer, and we are using R8UI format
			--width = bit.rshift(width, 1) + bit.band(width, 1)
		else
			error("unknown req.format "..tostring(req.format))
		end
		local key = '_'..req.width..'x'..req.height..suffix
		local framebufferRAM = self.framebufferRAMs[key]
		if not framebufferRAM then
			local formatInfo = assert.index(GLTex2D.formatInfoForInternalFormat, internalFormat)
			gltype = gltype or formatInfo.types[1]	-- there are multiple, so let the caller override
			framebufferRAM = RAMGPUTex{
				app = self,
				addr = framebufferAddr,
				width = width,
				height = height,
				channels = 1,
				internalFormat = internalFormat,
				glformat = formatInfo.format,
				gltype = gltype,
				ctype = assert.index(GLTypes.ctypeForGLType, gltype),
			}

			self.framebufferRAMs[key] = framebufferRAM
		end
		req.framebufferRAM = framebufferRAM
	end

	-- framebuffer is 256 x 144 x 16bpp rgb565
	--self.framebufferRAMs._256x144xRGB565

	-- keep menu/editor gfx separate of the fantasy-console
	do
		-- palette is 256 x 1 x 16 bpp (5:5:5:1)
		local data = ffi.new('uint16_t[?]', 256)
		resetPalette(data)
		self.paletteMenuTex = GLTex2D{
			width = paletteSize,
			height = 1,
			internalFormat = internalFormat5551,
			format = format5551,
			type = type5551,
			wrap = {
				s = gl.GL_CLAMP_TO_EDGE,
				t = gl.GL_CLAMP_TO_EDGE,
			},
			minFilter = gl.GL_NEAREST,
			magFilter = gl.GL_NEAREST,
			data = data,
		}:unbind()

		-- font is 256 x 8 x 8 bpp, each 8x8 in each bitplane is a unique letter
		local fontData = ffi.new('uint8_t[?]', fontInBytes)
		resetROMFont(fontData, 'font.png')
		self.fontMenuTex = GLTex2D{
			internalFormat = texInternalFormat_u8,
			format = GLTex2D.formatInfoForInternalFormat[texInternalFormat_u8].format,
			type = gl.GL_UNSIGNED_BYTE,
			width = fontImageSize.x,
			height = fontImageSize.y,
			wrap = {
				s = gl.GL_CLAMP_TO_EDGE,
				t = gl.GL_CLAMP_TO_EDGE,
			},
			minFilter = gl.GL_NEAREST,
			magFilter = gl.GL_NEAREST,
			data = fontData,
		}:unbind()

		-- framebuffer for the editor ... doesn't have a mirror in RAM, so it doesn't cause the net state to go out of sync
		-- TODO about a menuBufferSize (== 256x256)
		local size = frameBufferSize.x * frameBufferSize.y * 3
		local data = ffi.new('uint8_t[?]', size)
		ffi.fill(data, size)
		self.framebufferMenuTex = GLTex2D{
			internalFormat = gl.GL_RGB,
			format = gl.GL_RGB,
			type = gl.GL_UNSIGNED_BYTE,
			width = frameBufferSize.x,
			height = frameBufferSize.y,
			wrap = {
				s = gl.GL_CLAMP_TO_EDGE,
				t = gl.GL_CLAMP_TO_EDGE,
			},
			minFilter = gl.GL_NEAREST,
			magFilter = gl.GL_NEAREST,
			data = data,
		}:unbind()
	end
	--]=]

	self.quadGeom = GLGeometry{
		mode = gl.GL_TRIANGLE_STRIP,
		vertexes = {
			data = {
				0, 0,
				1, 0,
				0, 1,
				1, 1,
			},
			dim = 2,
		},
	}

	local glslVersion = cmdline.glsl or 'latest'

	-- code for converting 'uint colorIndex' to '(u)vec4 fragColor'
	-- assert palleteSize is a power-of-two ...
	local function colorIndexToFrag(destTex, decl)
		return decl..' = '..readTex{
			tex = self.paletteRAM.tex,
			texvar = 'paletteTex',
			tc = 'ivec2(int(colorIndex & '..('0x%Xu'):format(paletteSize-1)..'), 0)',
			from = 'ivec2',
			to = 'u16to5551',
		}..';\n'
	end

	-- and here's our blend solid-color option...
	local function getDrawOverrideCode(vec3)
		return [[
	if (drawOverrideSolid.a > 0.) {
		fragColor.rgb = ]]..vec3..[[(drawOverrideSolid.rgb);
	}
]]
	end

	local blitFragType = 'vec4'	-- blit screen is always to vec4 ... right?

	local function makeVideoModeRGB565(framebufferRAM)
		local modeObj = {
			framebufferRAM = framebufferRAM,
			name = 'RGB',
			-- [=[ internalFormat = gl.GL_RGB565
			colorOutput = table{
				colorIndexToFrag(framebufferRAM.tex, 'uvec4 ufragColor'),
				'fragColor = vec4(ufragColor) / 31.;',
				getDrawOverrideCode'uvec3',
			}:concat'\n',
			--]=]
			--[=[ internalFormat = internalFormat5551
			colorOutput = 'fragColor = '..readTex{
				tex = self.paletteRAM.tex,
				texvar = 'paletteTex',
				tc = 'ivec2(int(colorIndex & '..('0x%Xu'):format(paletteSize-1)..'), 0)',
				from = 'ivec2',
				to = 'uvec4',
			}..';\n'..[[

#if 0	// if anyone needs the rgb ...
			fragColor.a = (fragColor.r >> 15) * 0x1fu;
			fragColor.b = (fragColor.r >> 10) & 0x1fu;
			fragColor.g = (fragColor.r >> 5) & 0x1fu;
			fragColor.r &= 0x1fu;
			fragColor = (fragColor << 3) | (fragColor >> 2);
#else	// I think I'll just save the alpha for the immediate-after glsl code alpha discard test ...
			fragColor.a = (fragColor.r >> 15) * 0x1fu;
#endif
]]
				..getDrawOverrideCode'uvec3',
			--]=]
		}

		-- used for drawing our 16bpp framebuffer to the screen
--DEBUG:print'mode 0 blitScreenObj'
		modeObj.blitScreenObj = GLSceneObject{
			program = {
				version = glslVersion,
				precision = 'best',
				vertexCode = [[
layout(location=0) in vec2 vertex;
out vec2 tcv;

uniform mat4 mvProjMat;

void main() {
	tcv = vertex;
	gl_Position = mvProjMat * vec4(vertex, 0., 1.);
}
]],
				fragmentCode = template([[
precision highp isampler2D;
precision highp usampler2D;	// needed by #version 300 es

in vec2 tcv;

layout(location=0) out <?=blitFragType?> fragColor;
uniform <?=framebufferRAM.tex:getGLSLSamplerType()?> framebufferTex;

void main() {
#if 1	// internalFormat = gl.GL_RGB565
	fragColor = ]]..readTex{
		tex = framebufferRAM.tex,
		texvar = 'framebufferTex',
		tc = 'tcv',
		from = 'vec2',
		to = blitFragType,
	}..[[;
#endif
#if 0	// internalFormat = internalFormat5551
	uint rgba5551 = ]]..readTex{
		tex = framebufferRAM.tex,
		texvar = 'framebufferTex',
		tc = 'tcv',
		from = 'vec2',
		to = blitFragType,
	}..[[.r;

	fragColor.a = float(rgba5551 >> 15);
	fragColor.b = float((rgba5551 >> 10) & 0x1fu) / 31.;
	fragColor.g = float((rgba5551 >> 5) & 0x1fu) / 31.;
	fragColor.r = float(rgba5551 & 0x1fu) / 31.;
#endif
}
]],				{
					framebufferRAM = framebufferRAM,
					blitFragType = blitFragType,
				}),
				uniforms = {
					framebufferTex = 0,
				},
			},
			texs = {framebufferRAM.tex},
			geometry = self.quadGeom,
			-- glUniform()'d every frame
			uniforms = {
				mvProjMat = self.blitScreenView.mvProjMat.ptr,
			},
		}

		return modeObj
	end

	local function makeVideoMode8bppIndex(framebufferRAM)
		local modeObj = {
			framebufferRAM = framebufferRAM,

			-- generator properties
			-- indexed mode can't blend so ... no draw-override
			name = 'Index',
			-- this part is only needed for alpha
			colorOutput = table{
				colorIndexToFrag(framebufferRAM.tex, 'uvec4 palColor'),
				[[
	fragColor.r = colorIndex;
	fragColor.g = 0u;
	fragColor.b = 0u;
	// only needed for quadSprite / quadMap:
	fragColor.a = (palColor.a << 3) | (palColor.a >> 2);
]],
	-- hmm, idk what to do with drawOverrideSolid in 8bppIndex
	-- but I don't want the GLSL compiler to optimize away the attr...
				getDrawOverrideCode'uvec3',
			}:concat'\n',
		}

		-- used for drawing our 8bpp indexed framebuffer to the screen
	--DEBUG:print'mode 1 blitScreenObj'
		modeObj.blitScreenObj = GLSceneObject{
			program = {
				version = glslVersion,
				precision = 'best',
				vertexCode = [[
layout(location=0) in vec2 vertex;
out vec2 tcv;
uniform mat4 mvProjMat;
void main() {
	tcv = vertex;
	gl_Position = mvProjMat * vec4(vertex, 0., 1.);
}
]],
				fragmentCode = template([[
precision highp isampler2D;
precision highp usampler2D;	// needed by #version 300 es

in vec2 tcv;

layout(location=0) out <?=blitFragType?> fragColor;

uniform <?=framebufferRAM.tex:getGLSLSamplerType()?> framebufferTex;
uniform <?=self.paletteRAM.tex:getGLSLSamplerType()?> paletteTex;

<?=glslCode5551?>

void main() {
	uint colorIndex = ]]..readTex{
		tex = framebufferRAM.tex,
		texvar = 'framebufferTex',
		tc = 'tcv',
		from = 'vec2',
		to = blitFragType,
	}..[[.r;
]]..colorIndexToFrag(framebufferRAM.tex, 'uvec4 ufragColor')..[[
	fragColor = vec4(ufragColor) / 31.;
}
]],				{
					framebufferRAM = framebufferRAM,
					self = self,
					blitFragType = blitFragType,
					glslCode5551 = glslCode5551,
				}),
				uniforms = {
					framebufferTex = 0,
					paletteTex = 1,
				},
			},
			texs = {
				framebufferRAM.tex,
				self.paletteRAM.tex,
			},
			geometry = self.quadGeom,
			-- glUniform()'d every frame
			uniforms = {
				mvProjMat = self.blitScreenView.mvProjMat.ptr,
			},
		}

		return modeObj
	end

	local function makeVideoModeRGB332(framebufferRAM)
		local modeObj = {
			framebufferRAM = framebufferRAM,

			-- generator properties
			name = 'RGB332',
			colorOutput = colorIndexToFrag(framebufferRAM.tex, 'uvec4 palColor')..'\n'
				..[[
	/*
	palColor is 5 5 5 5
	fragColor is 3 3 2
	so we lose   2 2 3 bits
	so we can dither those in ...
	*/
#if 1	// dithering
	uvec2 ufc = uvec2(gl_FragCoord);

	// 2x2 dither matrix, for the lower 2 bits that get discarded
	// hmm TODO should I do dither discard bitflags?
	uint threshold = (ufc.y & 1u) | (((ufc.x ^ ufc.y) & 1u) << 1u);	// 0-3

	if ((palColor.x & 3u) > threshold) palColor.x+=4u;
	if ((palColor.y & 3u) > threshold) palColor.y+=4u;
	if ((palColor.z & 3u) > threshold) palColor.z+=4u;
	palColor = clamp(palColor, 0u, 31u);
#endif
	fragColor.r = (palColor.r >> 2) |
				((palColor.g >> 2) << 3) |
				((palColor.b >> 3) << 6);
	fragColor.g = 0u;
	fragColor.b = 0u;
	// only needed for quadSprite / quadMap:
	fragColor.a = (palColor.a << 3) | (palColor.a >> 2);
]]
	-- hmm, idk what to do with drawOverrideSolid in 8bppIndex
	-- but I don't want the GLSL compiler to optimize away the attr...
	..getDrawOverrideCode'uvec3',
		}

		-- used for drawing 8bpp framebufferRAMs._256x256x8bpp as rgb332 framebuffer to the screen
--DEBUG:print'mode 2 blitScreenObj'
		modeObj.blitScreenObj = GLSceneObject{
			program = {
				version = glslVersion,
				precision = 'best',
				vertexCode = [[
layout(location=0) in vec2 vertex;
out vec2 tcv;
uniform mat4 mvProjMat;
void main() {
	tcv = vertex;
	gl_Position = mvProjMat * vec4(vertex, 0., 1.);
}
]],
				fragmentCode = template([[
precision highp isampler2D;
precision highp usampler2D;	// needed by #version 300 es

in vec2 tcv;

layout(location=0) out <?=blitFragType?> fragColor;

uniform <?=framebufferRAM.tex:getGLSLSamplerType()?> framebufferTex;

void main() {
	uint rgb332 = ]]..readTex{
		tex = framebufferRAM.tex,
		texvar = 'framebufferTex',
		tc = 'tcv',
		from = 'vec2',
		to = blitFragType,
	}..[[.r;
	fragColor.r = float(rgb332 & 0x7u) / 7.;
	fragColor.g = float((rgb332 >> 3) & 0x7u) / 7.;
	fragColor.b = float((rgb332 >> 6) & 0x3u) / 3.;
	fragColor.a = 1.;
}
]],				{
					framebufferRAM = framebufferRAM,
					blitFragType = blitFragType,
				}),
				uniforms = {
					framebufferTex = 0,
					paletteTex = 1,
				},
			},
			texs = {
				framebufferRAM.tex,
				self.paletteRAM.tex,
			},
			geometry = self.quadGeom,
			-- glUniform()'d every frame
			uniforms = {
				mvProjMat = self.blitScreenView.mvProjMat.ptr,
			},
		}

		return modeObj
	end

	local function gcd(a,b)
		while b ~= 0 do
			a, b = b, a % b
		end
		return a
	end
	local function reduce(a, b)
		local c = gcd(a, b)
		return a / c, b / c
	end

	self.videoModeInfo = requestedVideoModes:map(function(req)
		local framebufferRAM = assert.index(req, 'framebufferRAM')
		local info
		if req.format == 'RGB565' then
			info = makeVideoModeRGB565(framebufferRAM)
		elseif req.format == '8bppIndex' then
			info = makeVideoMode8bppIndex(framebufferRAM)
		elseif req.format == 'RGB332' then
			info = makeVideoModeRGB332(framebufferRAM)
		elseif req.format == '4bppIndex' then
			return nil
		else
			error("unknown req.format "..tostring(req.format))
		end
		info.format = req.format
		-- only used for the intro screen console output:
		local w, h = reduce(req.width, req.height)
		info.formatDesc = req.width..'x'..req.height..'x'..req.format
		return info
	end)

	-- make output shaders per-video-mode
	-- set them up as our app fields to use upon setVideoMode
	for infoIndex,info in pairs(self.videoModeInfo) do
		assert(math.log(paletteSize, 2) % 1 == 0)	-- make sure our palette is a power-of-two

--DEBUG:print('mode '..infoIndex..' solidObj')
		info.solidObj = GLSceneObject{
			program = {
				version = glslVersion,
				precision = 'best',
				vertexCode = template([[
precision highp isampler2D;
precision highp usampler2D;	// needed by #version 300 es

layout(location=0) in vec4 vertex;

/*
This is the texcoord for sprite shaders.
This is the model-space coord (within box min/max) for solid/round shaders.
(TODO for round shader, should this be after transform? but then you'd have to transform the box by mvmat in the fragment shader too ...)
*/
layout(location=1) in vec2 texcoord;

/*
flat, flags for sprite vs solid etc:

extra.x:
	bit 0/1 =
		00 = use solid path
		01 = use sprite path
		10 = use tilemap path

for solid:
	.x = flags:
		bit 0/1 = render pathway = 00
		bit 2 = draw a solid round quad
		bit 4 = solid shader uses borderOnly
	.y = colorIndex

for sprites:
	.x:
		bit 0/1 = render pathway = 01
		bit 2 = don't use transparentIndex (on means don't test transparency at all ... set this when transparentIndex is OOB)
		bits 3-5 = spriteBit shift
			Specifies which bit to read from at the sprite.
			Only needs 3 bits.
			  (extra.x >> 3) == 0 = read sprite low nibble.
			  (extra.x >> 3) == 4 = read sprite high nibble.

	.y = spriteMask;
		Specifies the mask after shifting the sprite bit
		  0x01u = 1bpp
		  0x03u = 2bpp
		  0x07u = 3bpp
		  0x0Fu = 4bpp
		  0xFFu = 8bpp
		I'm giving this all 8 bits, but honestly I could just represent it as 3 bits and calculate the mask as ((1 << mask) - 1)

	.z = transparentIndex;
		Specifies which colorIndex to use as transparency.
		This is the value of the sprite texel post sprite bit shift & mask, but before applying the paletteIndex shift / high bits.
		If you want fully opaque then just choose an oob color index.

	.w = paletteIndex;
		For now this is an integer added to the 0-15 4-bits of the sprite tex.
		You can set the top 4 bits and it'll work just like OR'ing the high color index nibble.
		Or you can set it to low numbers and use it to offset the palette.
		Should this be high bits? or just an offset to OR? or to add?

for tilemap:
	.x
		bit 0/1 = render pathway = 10
		bit 2 = on = 16x16 tiles, off = 8x8 tiles

	.y = mapIndexOffset lo byte
	.z = mapIndexOffset hi byte (2 bits worth? how many bits should the tilemap index offset care about?)
*/
layout(location=2) in uvec4 extraAttr;

// flat, the solid-blend color
layout(location=3) in vec4 drawOverrideSolidAttr;

// flat, the bbox of the currently drawn quad, only used for round-rendering of solid-shader
layout(location=4) in vec4 boxAttr;

/*
flat, the screen scissor bbox, because I don't want to flush and redraw every time I change the scissor region.
*/
layout(location=5) in vec4 scissorAttr;

//GLES3 says we have at least 16 attributes to use ...

// the bbox world coordinates, used with 'boxAttr' for rounding
out vec2 tcv;

flat out uvec4 extra;
flat out vec4 drawOverrideSolid;
flat out vec4 box;
flat out vec4 scissor;

uniform vec2 frameBufferSize;

void main() {
	tcv = texcoord;
	drawOverrideSolid = drawOverrideSolidAttr;
	extra = extraAttr;
	box = boxAttr;
	scissor = scissorAttr;

	gl_Position = vertex;

	//instead of a projection matrix, here I'm going to convert from framebuffer pixel coordinates to GL homogeneous coordinates.
	gl_Position.xy *= 2.;
	gl_Position.xy /= frameBufferSize;
	gl_Position.xy -= 1.;
}
]]),
				fragmentCode = template([[
precision highp isampler2D;
precision highp usampler2D;	// needed by #version 300 es

in vec2 tcv;		// framebuffer pixel coordinates before transform , so they are sprite texels

flat in uvec4 extra;	// flags (round, borderOnly), colorIndex
flat in vec4 drawOverrideSolid;
flat in vec4 box;		// x, y, w, h in world coordinates, used for round / border calculations
flat in vec4 scissor;	// x, y, w, h

layout(location=0) out <?=fragType?> fragColor;

uniform <?=self.paletteRAM.tex:getGLSLSamplerType()?> paletteTex;
uniform <?=self.sheetRAMs[1].tex:getGLSLSamplerType()?> sheetTex;
uniform <?=self.tilemapRAMs[1].tex:getGLSLSamplerType()?> tilemapTex;

<?=glslCode5551?>

float sqr(float x) { return x * x; }
float lenSq(vec2 v) { return dot(v,v); }

void main() {
	if (gl_FragCoord.x < scissor.x ||
		gl_FragCoord.y < scissor.y ||
		gl_FragCoord.x >= scissor.x + scissor.z + 1. ||
		gl_FragCoord.y >= scissor.y + scissor.w + 1.
	) {
		discard;
	}

	uvec2 uFragCoord = uvec2(gl_FragCoord);
	uint threshold = (uFragCoord.y >> 1) & 1
		| ((uFragCoord.x ^ uFragCoord.y) & 2)
		| ((uFragCoord.y & 1) << 2)
		| (((uFragCoord.x ^ uFragCoord.y) & 1) << 3);
	uint dither = extra.y;
	if ((dither & (1u << threshold)) != 0u) discard;

	uint pathway = extra.x & 3u;

	// solid shading pathway
	if (pathway == 0u) {
		bool round = (extra.x & 4u) != 0u;
		bool borderOnly = (extra.x & 8u) != 0u;
		uint colorIndex = (extra.x >> 8u) & 0xffu;

		if (round) {
			// midpoint-circle / Bresenham algorithm, like Tic80 uses:
			// figure out which octant of the circle you're in
			// then compute deltas based on if |dy| / |dx|
			// (x/a)^2 + (y/b)^2 = 1
			// x/a = √(1 - (y/b)^2)
			// x = a√(1 - (y/b)^2)
			// y = b√(1 - (x/a)^2)
			vec2 radius = .5 * box.zw;
			vec2 center = box.xy + radius;
			vec2 delta = tcv - center;
			//if (box.w < box.z) {					// idk why I was using this?
			if (abs(delta.y) > abs(delta.x)) {		// good for doing proper ellipse borders.
				// top/bottom quadrant
				float by = radius.y * sqrt(1. - sqr(delta.x / radius.x));
				if (delta.y > by || delta.y < -by) discard;
				if (borderOnly) {
					// TODO think this through
					// calculate screen space epsilon at this point
					//float eps = abs(dFdy(tcv.y));
					// more solid for 3D
					float eps = sqrt(lenSq(dFdx(tcv)) + lenSq(dFdy(tcv)));
					//float eps = length(vec2(dFdx(tcv.x), dFdy(tcv.y)));
					//float eps = max(abs(dFdx(tcv.x)), abs(dFdy(tcv.y)));
					if (delta.y < by-eps && delta.y > -by+eps) discard;
				}
			} else {
				// left/right quadrant
				float bx = radius.x * sqrt(1. - sqr(delta.y / radius.y));
				if (delta.x > bx || delta.x < -bx) discard;
				if (borderOnly) {
					// calculate screen space epsilon at this point
					//float eps = abs(dFdx(tcv.x));
					// more solid for 3D
					float eps = sqrt(lenSq(dFdx(tcv)) + lenSq(dFdy(tcv)));
					//float eps = length(vec2(dFdx(tcv.x), dFdy(tcv.y)));
					//float eps = max(abs(dFdx(tcv.x)), abs(dFdy(tcv.y)));
					if (delta.x < bx-eps && delta.x > -bx+eps) discard;
				}
			}
		} else {
			if (borderOnly) {
				// calculate screen space epsilon at this point
				//vec2 eps = abs(vec2(dFdx(tcv.x), dFdy(tcv.y)));
				float eps = sqrt(lenSq(dFdx(tcv))+lenSq(dFdy(tcv)));
				//float eps = length(vec2(dFdx(tcv.x), dFdy(tcv.y)));
				//float eps = max(abs(dFdx(tcv.x)), abs(dFdy(tcv.y)));

				if (tcv.x > box.x+eps
					&& tcv.x < box.x+box.z-eps
					&& tcv.y > box.y+eps
					&& tcv.y < box.y+box.w-eps
				) discard;
			}
			// else default solid rect
		}

<?=info.colorOutput?>

	// sprite shading pathway
	} else if (pathway == 1u) {

		uint spriteBit = (extra.x >> 3) & 7u;
		uint spriteMask = (extra.x >> 8) & 0xffu;
		uint transparentIndex = extra.z;

		// shift the oob-transparency 2nd bit up to the 8th bit,
		// such that, setting this means `transparentIndex` will never match `colorIndex & spriteMask`;
		transparentIndex |= (extra.x & 4u) << 6;

		uint paletteIndex = extra.w;

		uint colorIndex = ]]
				..readTex{
					tex = self.sheetRAMs[1].tex,
					texvar = 'sheetTex',
					tc = 'tcv',
					from = 'vec2',
					to = 'uvec4',
				}
				..[[.r;

		colorIndex >>= spriteBit;
		colorIndex &= spriteMask;
		if (colorIndex == transparentIndex) discard;
		colorIndex += paletteIndex;
		colorIndex &= 0xFFu;

<?=info.colorOutput?>

<? if fragType == 'uvec4' then ?>
		if (fragColor.a == 0u) discard;
<? else ?>
		if (fragColor.a < .5) discard;
<? end ?>

	} else if (pathway == 2u) {

		int mapIndexOffset = int(extra.z);

		//0 = draw 8x8 sprites, 1 = draw 16x16 sprites
		uint draw16Sprites = (extra.x >> 2) & 1u;

		const uint tilemapSizeX = <?=tilemapSize.x?>u;
		const uint tilemapSizeY = <?=tilemapSize.y?>u;

		// convert from input normalized coordinates to tilemap texel coordinates
		// [0, tilemapSize)^2
		ivec2 tci = ivec2(
			int(tcv.x * float(tilemapSizeX << draw16Sprites)),
			int(tcv.y * float(tilemapSizeY << draw16Sprites))
		);

		// convert to map texel coordinate
		// [0, tilemapSize)^2
		ivec2 tileTC = ivec2(
			(tci.x >> (3u + draw16Sprites)) & 0xFF,
			(tci.y >> (3u + draw16Sprites)) & 0xFF
		);

		//read the tileIndex in tilemapTex at tileTC
		//tilemapTex is R16, so red channel should be 16bpp (right?)
		// how come I don't trust that and think I'll need to switch this to RG8 ...
		int tileIndex = int(]]..readTex{
			tex = self.tilemapRAMs[1].tex,
			texvar = 'tilemapTex',
			tc = 'tileTC',
			from = 'ivec2',
			to = 'uvec4',
		}..[[.r);

		tileIndex += mapIndexOffset;

		//[0, 31)^2 = 5 bits for tile tex sprite x, 5 bits for tile tex sprite y
		ivec2 tileIndexTC = ivec2(
			tileIndex & 0x1F,				// tilemap bits 0..4
			(tileIndex >> 5) & 0x1F			// tilemap bits 5..9
		);
		int palHi = (tileIndex >> 10) & 0xF;	// tilemap bits 10..13
		if ((tileIndex & (1<<14)) != 0) tci.x = ~tci.x;	// tilemap bit 14
		if ((tileIndex & (1<<15)) != 0) tci.y = ~tci.y;	// tilemap bit 15

		int mask = (1 << (3u + draw16Sprites)) - 1;
		// [0, spriteSize)^2
		ivec2 tileTexTC = ivec2(
			(tci.x & mask) ^ (tileIndexTC.x << 3),
			(tci.y & mask) ^ (tileIndexTC.y << 3)
		);

		// sheetTex is R8 indexing into our palette ...
		uint colorIndex = ]]..readTex{
			tex = self.sheetRAMs[2].tex,
			texvar = 'sheetTex',
			tc = 'tileTexTC',
			from = 'ivec2',
			to = 'uvec4',
		}..[[.r;

		colorIndex += uint(palHi) << 4;

		<?=info.colorOutput?>

<? if fragType == 'uvec4' then ?>
		if (fragColor.a == 0u) discard;
<? else ?>
		if (fragColor.a < .5) discard;
<? end ?>

	// I had an extra pathway and I didn't know what to use it for
	// and I needed a RGB option for the cart browser (maybe I should just use this for all the menu system and just skip on the menu-palette?)
	} else if (pathway == 3u) {

		fragColor = <?=fragType?>(]]
				..readTex{
					tex = self.sheetRAMs[1].tex,
					texvar = 'sheetTex',
					tc = 'tcv',
					from = 'vec2',
					to = fragType,
				}
				..[[ / 255.);

	}	// pathway
}
]],				{
					self = self,
					info = info,
					glslnumber = glslnumber,
					fragType = info.framebufferRAM.tex:getGLSLFragType(),
					glslCode5551 = glslCode5551,
					tilemapSize = tilemapSize,
				}),
				uniforms = {
					paletteTex = 0,
					sheetTex = 1,
					tilemapTex = 2,
					frameBufferSize = {
						info.framebufferRAM.tex.width,
						info.framebufferRAM.tex.height,
					},
				},
			},
			geometry = {
				mode = gl.GL_TRIANGLES,
			},
			vertexes = {
				usage = gl.GL_DYNAMIC_DRAW,
				dim = 4,
				useVec = true,
			},
			attrs = {
				texcoord = {
					buffer = {
						usage = gl.GL_DYNAMIC_DRAW,
						dim = 2,
						useVec = true,
					},
				},
				extraAttr = {
					type = gl.GL_UNSIGNED_SHORT,
					--divisor = 3,
					buffer = {
						usage = gl.GL_DYNAMIC_DRAW,
						type = gl.GL_UNSIGNED_SHORT,
						dim = 4,
						useVec = true,
						ctype = 'vec4us_t',
					},
				},
				drawOverrideSolidAttr = {
					type = gl.GL_UNSIGNED_BYTE,		-- I'm uploading uint8_t[4]
					normalize = true,				-- data will be normalized to [0,1]
					--divisor = 3,
					buffer = {
						usage = gl.GL_DYNAMIC_DRAW,
						type = gl.GL_UNSIGNED_BYTE,	-- gl will receive uint8_t[4]
						dim = 4,
						useVec = true,
						ctype = 'vec4ub_t',			-- cpu buffer will hold vec4ub_t's
					},
				},
				-- TODO how about using divisors?
				-- though I've heard mixed reviews on their performance...
				boxAttr = {
					--divisor = 3,	-- 6 honestly ...
					buffer = {
						usage = gl.GL_DYNAMIC_DRAW,
						dim = 4,
						useVec = true,
					},
				},
				scissorAttr = {
					--divisor = 3,	-- 6 honestly ...
					buffer = {
						usage = gl.GL_DYNAMIC_DRAW,
						dim = 4,
						useVec = true,
					},
				},
			},
		}
	end

	-- for the editor

	-- a pattern for transparencies
	self.checkerTex = GLTex2D{
		type = gl.GL_UNSIGNED_BYTE,
		format = gl.GL_RGB,
		internalFormat = gl.GL_RGB,
		magFilter = gl.GL_NEAREST,
		minFilter = gl.GL_NEAREST,
		--minFilter = gl.GL_NEAREST_MIPMAP_NEAREST,		-- doesn't work so well with alpha channesl
		--[[ checkerboard
		image = Image(2,2,3,'uint8_t', {0xf0,0xf0,0xf0,0xfc,0xfc,0xfc,0xfc,0xfc,0xfc,0xf0,0xf0,0xf0}),
		--]]
		-- [[ gradient
		image = Image(4,4,3,'uint8_t', {
			0xf0,0xf0,0xf0, 0xfd,0xfd,0xfd, 0xfe,0xfe,0xfe, 0xff,0xff,0xff,
			0xfd,0xfd,0xfd, 0xfe,0xfe,0xfe, 0xff,0xff,0xff, 0xf0,0xf0,0xf0,
			0xfe,0xfe,0xfe, 0xff,0xff,0xff, 0xf0,0xf0,0xf0, 0xfd,0xfd,0xfd,
			0xff,0xff,0xff, 0xf0,0xf0,0xf0, 0xfd,0xfd,0xfd, 0xfe,0xfe,0xfe,
		}),
		--]]
	}


	local app = self

	self.triBuf = {
--DEBUG:flushCallsPerFrame = 0,
--DEBUG:flushSizes = {},
		flush = function(self)
--DEBUG: self.flushCallsPerFrame = self.flushCallsPerFrame + 1

			local sceneObj = self.sceneObj
			if not sceneObj then return end	-- for some calls called before this is even created ...

			-- flush the old
			local n = #sceneObj.attrs.vertex.buffer.vec
			if n == 0 then return end

--DEBUG: self.flushSizes[n] = (self.flushSizes[n] or 0) + 1

			-- resize if capacity changed, upload
			for name,attr in pairs(sceneObj.attrs) do
				attr.buffer:endUpdate()
			end

			-- bind textures
			-- TODO bind here or elsewhere to prevent re-binding of the same texture ...
			app.lastTilemapTex:bind(2)
			app.lastSolidSheetTex:bind(1)
			app.lastSolidPaletteTex:bind(0)

			sceneObj.geometry.count = n

			sceneObj.program:use()
			sceneObj:enableAndSetAttrs()
			sceneObj.geometry:draw()
			sceneObj:disableAttrs()

			-- reset the vectors and store the last capacity
			sceneObj:beginUpdate()

			app.lastSolidPaletteTex = nil
			app.lastSolidSheetTex = nil
		end,
		addTri = function(
			self,
			paletteTex,
			sheetTex,
			tilemapTex,

			-- per vtx
			x1, y1, z1, w1, u1, v1,
			x2, y2, z2, w2, u2, v2,
			x3, y3, z3, w3, u3, v3,

			-- divisor
			extraX, extraY, extraZ, extraW,
			blendSolidR, blendSolidG, blendSolidB, blendSolidA,
			boxX, boxY, boxW, boxH
		)
			local sceneObj = self.sceneObj
			local vertex = sceneObj.attrs.vertex.buffer.vec
			local texcoord = sceneObj.attrs.texcoord.buffer.vec
			local extraAttr = sceneObj.attrs.extraAttr.buffer.vec
			local drawOverrideSolidAttr = sceneObj.attrs.drawOverrideSolidAttr.buffer.vec
			local boxAttr = sceneObj.attrs.boxAttr.buffer.vec
			local scissorAttr = sceneObj.attrs.scissorAttr.buffer.vec

			-- if the textures change then flush
			if app.lastSolidPaletteTex ~= paletteTex
			or app.lastSolidSheetTex ~= sheetTex
			or app.lastTilemapTex ~= tilemapTex
			then
				self:flush()
				app.lastSolidPaletteTex = paletteTex
				app.lastSolidSheetTex = sheetTex
				app.lastTilemapTex = tilemapTex
			end

			-- push
			local v
			v = vertex:emplace_back()
			v.x, v.y, v.z, v.w = x1, y1, z1, w1
			v = vertex:emplace_back()
			v.x, v.y, v.z, v.w = x2, y2, z2, w2
			v = vertex:emplace_back()
			v.x, v.y, v.z, v.w = x3, y3, z3, w3

			v = texcoord:emplace_back()
			v.x, v.y = u1, v1
			v = texcoord:emplace_back()
			v.x, v.y = u2, v2
			v = texcoord:emplace_back()
			v.x, v.y = u3, v3

			for j=0,2 do
				v = drawOverrideSolidAttr:emplace_back()
				v.x, v.y, v.z, v.w = blendSolidR, blendSolidG, blendSolidB, blendSolidA

				v = extraAttr:emplace_back()
				v.x, v.y, v.z, v.w = extraX, extraY, extraZ, extraW

				v = boxAttr:emplace_back()
				v.x, v.y, v.z, v.w = boxX, boxY, boxW, boxH

				v = scissorAttr:emplace_back()
				v.x, v.y, v.z, v.w = app:getClipRect()
			end
		end,
	}

	self:resetVideo()
end

-- resize the # of RAMGPUs to match the # banks
function AppVideo:resizeRAMGPUs()
--DEBUG:print'AppVideo:resizeRAMGPUs'
	local numBanks = #self.banks
	for i=2*numBanks+1,#self.sheetRAMs do
		self.sheetRAMs[i] = nil
	end
	for i=1,2*numBanks do
		local bankNo = bit.rshift(i-1, 1)
		local addr
		if bit.band(i-1, 1) == 0 then
			addr = ffi.cast('uint8_t*', self.ram.bank[bankNo].spriteSheet) - ffi.cast('uint8_t*', self.ram.v)
		else
			addr = ffi.cast('uint8_t*', self.ram.bank[bankNo].tileSheet) - ffi.cast('uint8_t*', self.ram.v)
		end
		if self.sheetRAMs[i] then
			self.sheetRAMs[i]:updateAddr(addr)
		else
			self.sheetRAMs[i] = RAMGPUTex{
				app = self,
				addr = addr,
				width = spriteSheetSize.x,
				height = spriteSheetSize.y,
				channels = 1,
				ctype = 'uint8_t',
				internalFormat = texInternalFormat_u8,
				glformat = GLTex2D.formatInfoForInternalFormat[texInternalFormat_u8].format,
				gltype = gl.GL_UNSIGNED_BYTE,
			}
		end
	end

	for i=numBanks+1,#self.tilemapRAMs do
		self.tilemapRAMs[i] = nil
	end
	for i=1,numBanks do
		--[[
		16bpp ...
		- 10 bits of lookup into sheetRAMs
		- 4 bits high palette nibble
		- 1 bit hflip
		- 1 bit vflip
		- .... 2 bits rotate ... ? nah
		- .... 8 bits palette offset ... ? nah
		--]]
		local addr = ffi.cast('uint8_t*', self.ram.bank[i-1].tilemap) - ffi.cast('uint8_t*', self.ram.v)
		if self.tilemapRAMs[i] then
			self.tilemapRAMs[i]:updateAddr(addr)
		else
			self.tilemapRAMs[i] = RAMGPUTex{
				app = self,
				addr = addr,
				width = tilemapSize.x,
				height = tilemapSize.y,
				channels = 1,
				ctype = 'uint16_t',
				internalFormat = texInternalFormat_u16,
				glformat = GLTex2D.formatInfoForInternalFormat[texInternalFormat_u16].format,
				gltype = gl.GL_UNSIGNED_SHORT,
			}
		end
	end

	for i=numBanks+1,#self.paletteRAMs do
		self.paletteRAMs[i] = nil
	end
	for i=1,numBanks do
--DEBUG:print('creating palette for bank #'..(i-1))
		-- palette is 256 x 1 x 16 bpp (5:5:5:1)
		local addr = ffi.cast('uint8_t*', self.ram.bank[i-1].palette) - ffi.cast('uint8_t*', self.ram.v)
		if self.paletteRAMs[i] then
			self.paletteRAMs[i]:updateAddr(addr)
		else
			self.paletteRAMs[i] = RAMGPUTex{
				app = self,
				addr = addr,
				width = paletteSize,
				height = 1,
				channels = 1,
				ctype = 'uint16_t',
				internalFormat = internalFormat5551,
				glformat = format5551,
				gltype = type5551,
			}
		end
	end

	for i=numBanks+1,#self.fontRAMs do
		self.fontRAMs[i] = nil
	end
	for i=1,numBanks do
		-- font is gonna be stored planar, 8bpp, 8 chars per 8x8 sprite per-bitplane
		-- so a 256 char font will be 2048 bytes
		-- TODO option for 2bpp etc fonts?
		-- before I had fonts just stored as a certain 1bpp region of the sprite sheet ...
		-- eventually have custom sized spritesheets and drawText refer to those?
		-- or eventually just make all textures 1D and map regions of RAM, and have the tile shader use offsets for horz and vert step?
		local addr = ffi.cast('uint8_t*', self.ram.bank[i-1].font) - ffi.cast('uint8_t*', self.ram.v)
--DEBUG:assert.ge(addr, 0)
--DEBUG:assert.lt(addr + fontInBytes, self.memSize)
--DEBUG:print('creating font for bank #'..(i-1)..' from addr '..('$%x / %d'):format(addr, addr))
		if self.fontRAMs[i] then
--DEBUG:print'...updating old addr'
			self.fontRAMs[i]:updateAddr(addr)
		else
--DEBUG:print'...creating new obj'
			self.fontRAMs[i] = RAMGPUTex{
				app = self,
				addr = addr,
				width = fontImageSize.x,
				height = fontImageSize.y,
				channels = 1,
				ctype = 'uint8_t',
				internalFormat = texInternalFormat_u8,
				glformat = GLTex2D.formatInfoForInternalFormat[texInternalFormat_u8].format,
				gltype = gl.GL_UNSIGNED_BYTE,
			}
		end
	end
--DEBUG:print'AppVideo:resizeRAMGPUs done'
end

function AppVideo:allRAMRegionsCheckDirtyGPU()
	-- TODO this current method updates *all* GPU/CPU framebuffer textures
	-- but if I provide more options, I'm only going to want to update the one we're using (or things would be slow)
	for k,v in pairs(self.framebufferRAMs) do
		v:checkDirtyGPU()
	end
	for _,ramgpu in ipairs(self.sheetRAMs) do
		ramgpu:checkDirtyGPU()
	end
	for _,ramgpu in ipairs(self.tilemapRAMs) do
		ramgpu:checkDirtyGPU()
	end
	for _,ramgpu in ipairs(self.paletteRAMs) do
		ramgpu:checkDirtyGPU()
	end
	for _,ramgpu in ipairs(self.fontRAMs) do
		ramgpu:checkDirtyGPU()
	end
end

function AppVideo:allRAMRegionsCheckDirtyCPU()
	-- TODO this current method updates *all* GPU/CPU framebuffer textures
	-- but if I provide more options, I'm only going to want to update the one we're using (or things would be slow)
	for k,v in pairs(self.framebufferRAMs) do
		v:checkDirtyCPU()
	end
	for _,ramgpu in ipairs(self.sheetRAMs) do
		ramgpu:checkDirtyCPU()
	end
	for _,ramgpu in ipairs(self.tilemapRAMs) do
		ramgpu:checkDirtyCPU()
	end
	for _,ramgpu in ipairs(self.paletteRAMs) do
		ramgpu:checkDirtyCPU()
	end
	for _,ramgpu in ipairs(self.fontRAMs) do
		ramgpu:checkDirtyCPU()
	end
end

function AppVideo:resetVideo()
--DEBUG:print'App:resetVideo'
	-- remake the textures every time the # bank changes thanks to loadRAM()
	self:resizeRAMGPUs()

	-- flush all before resetting RAM addrs in case any are pointed to the addrs' location
	-- do the framebuffers explicitly cuz typically 'checkDirtyGPU' just does the current one
	-- and also because the first time resetVideo() is called, the video mode hasn't been set yet, os the framebufferRAM hasn't been assigned yet
	self:allRAMRegionsCheckDirtyGPU()

	-- reset these
	self.ram.framebufferAddr:fromabs(framebufferAddr)
	self.ram.spriteSheetAddr:fromabs(spriteSheetAddr)
	self.ram.tileSheetAddr:fromabs(tileSheetAddr)
	self.ram.tilemapAddr:fromabs(tilemapAddr)
	self.ram.paletteAddr:fromabs(paletteAddr)
	self.ram.fontAddr:fromabs(fontAddr)
	-- and these, which are the ones that can be moved

	-- TODO this current method updates *all* GPU/CPU framebuffer textures
	-- but if I provide more options, I'm only going to want to update the one we're using (or things would be slow)
	for k,v in pairs(self.framebufferRAMs) do
		v:updateAddr(framebufferAddr)
	end

	self.sheetRAMs[1]:updateAddr(spriteSheetAddr)
	self.sheetRAMs[2]:updateAddr(tileSheetAddr)
	self.tilemapRAMs[1]:updateAddr(tilemapAddr)
	self.paletteRAMs[1]:updateAddr(paletteAddr)
	self.fontRAMs[1]:updateAddr(fontAddr)

	-- do this to set the framebufferRAM before doing checkDirtyCPU/GPU
	self.ram.videoMode = 0	-- 16bpp RGB565
	--self.ram.videoMode = 1	-- 8bpp indexed
	--self.ram.videoMode = 2	-- 8bpp RGB332
	self:setVideoMode(self.ram.videoMode)

	ffi.copy(self.ram.bank, self.banks.v[0].v, ffi.sizeof'ROM')
	-- [[ update now ...
	for _,sheetRAM in ipairs(self.sheetRAMs) do
		sheetRAM.tex:bind()
			:subimage()
		sheetRAM.dirtyCPU = false
	end
	for _,tilemapRAM in ipairs(self.tilemapRAMs) do
		tilemapRAM.tex:bind()
			:subimage()
		tilemapRAM.dirtyCPU = false
	end
	self.paletteRAM.tex:bind()
		:subimage()
	self.paletteRAM.dirtyCPU = false
	self.fontRAM.tex:bind()
		:subimage()
	self.fontRAM.dirtyCPU = false
	--]]
	--[[ update later ...
	self:setDirtyCPU()
	--]]

	self.ram.blendMode = 0xff	-- = none
	self.ram.blendColor = rgba8888_4ch_to_5551(255,0,0,255)	-- solid red

	for i=0,255 do
		self.ram.fontWidth[i] = 5
	end

	self.ram.textFgColor = 0xfc
	self.ram.textBgColor = 0xf0

	-- 4 uint8 bytes: x, y, w, h ... width and height are inclusive so i can do 0 0 ff ff and get the whole screen
	self:setClipRect(0, 0, clipMax, clipMax)

	-- hmm, this matident isn't working ,but if you put one in your init code then it does work ... why ...
	self:matident()
--DEBUG:print'App:resetVideo done'
end

-- flush anything from gpu to cpu
function AppVideo:checkDirtyGPU()
	for _,sheetRAM in ipairs(self.sheetRAMs) do
		sheetRAM:checkDirtyGPU()
	end
	for _,tilemapRAM in ipairs(self.tilemapRAMs) do
		tilemapRAM:checkDirtyGPU()
	end
	self.paletteRAM:checkDirtyGPU()
	self.fontRAM:checkDirtyGPU()
	self.framebufferRAM:checkDirtyGPU()
end

function AppVideo:setDirtyCPU()
	for _,sheetRAM in ipairs(self.sheetRAMs) do
		sheetRAM.dirtyCPU = true
	end
	for _,tilemapRAM in ipairs(self.tilemapRAMs) do
		tilemapRAM.dirtyCPU = true
	end
	self.paletteRAM.dirtyCPU = true
	self.fontRAM.dirtyCPU = true
	self.framebufferRAM.dirtyCPU = true
end

--[[
each video mode should uniquely ...
- pick the framebufferTex
- pick the blit SceneObj
- pick / setup flags for each other shader (since RGB modes need RGB output, indexed modes need indexed output ...)
--]]
function AppVideo:setVideoMode(mode)
	if type(mode) == 'string' then
		mode = self.videoModeInfos:find(nil, function(info) return info.formatDesc == mode end)
		if not mode then
			return false, "failed to find video mode"
		end
	end
	if self.currentVideoMode == mode then return true end

	-- first time we won't have a solidObj to flush
	if self.triBuf then
		self.triBuf:flush()	-- flush before we redefine what info.solidObj is, which .triBuf:flush() depends on
	end

	local info = self.videoModeInfo[mode]
	if info then
		self.framebufferRAM = info.framebufferRAM
		self.blitScreenObj = info.blitScreenObj
		self.solidObj = info.solidObj

		self.triBuf.sceneObj = self.solidObj
	else
		error("unknown video mode "..tostring(mode))
	end
	self.blitScreenObj.texs[1] = self.framebufferRAM.tex

	self:setFramebufferTex(self.framebufferRAM.tex)
	self.currentVideoMode = mode

	return true
end

-- this is set between the VRAM tex .framebufferRAM (for draw commands that need to be reflected to the CPU)
--  and the menu tex .framebufferMenuTex (for those that don't)
function AppVideo:setFramebufferTex(tex)
	local fb = self.fb
	if not self.inUpdateCallback then
		fb:bind()
	end
	fb:setColorAttachmentTex2D(tex.id, 0, tex.target)
	local res,err = fb.check()
	if not res then
		print(err)
		print(debug.traceback())
	end
	if not self.inUpdateCallback then
		fb:unbind()
	end
end

-- exchnage two colors in the palettes, and in all spritesheets,
-- subject to some texture subregion (to avoid swapping bitplanes of things like the font)
function AppVideo:colorSwap(from, to, x, y, w, h)
	-- TODO SORT THIS OUT
	ffi.copy(self.ram.bank, self.banks.v[0].v, ffi.sizeof'ROM')
	from = math.floor(from)
	to = math.floor(to)
	x = math.floor(x)
	y = math.floor(y)
	w = math.floor(w)
	h = math.floor(h)
	if from < 0 or from >= 256 or to < 0 or to >= 256 then return false end
	x = math.clamp(x, 0, spriteSheetSize.x-1)
	y = math.clamp(y, 0, spriteSheetSize.y-1)
	w = math.clamp(w, 0, spriteSheetSize.x)
	h = math.clamp(h, 0, spriteSheetSize.y)
	local fromFound = 0
	local toFound = 0
	-- TODO option for only swap in a specific sheet/addr
	for _,sheetRAM in ipairs(self.sheetRAMs) do
		local base = sheetRAM.addr
		for j=y,y+h-1 do
			for i=x,x+w-1 do
				local addr = base + i + spriteSheetSize.x * j
				local c = self:peek(addr)
				if c == from then
					fromFound = fromFound + 1
					self:net_poke(addr, to)
				elseif c == to then
					toFound = toFound + 1
					self:net_poke(addr, from)
				end
			end
		end
	end
	-- now swap palette entries
	local fromAddr =  self.paletteRAM.addr + bit.lshift(from, 1)
	local toAddr =  self.paletteRAM.addr + bit.lshift(to, 1)
	local oldFromValue = self:peekw(fromAddr)
	self:net_pokew(fromAddr, self:peekw(toAddr))
	self:net_pokew(toAddr, oldFromValue)
	ffi.copy(self.banks.v[0].v, self.ram.bank, ffi.sizeof'ROM')
	return fromFound, toFound
end


function AppVideo:resetFont()
	self.triBuf:flush()
	self.fontRAM:checkDirtyGPU()
	resetROMFont(self.ram.bank[0].font)
	ffi.copy(self.banks.v[0].font, self.ram.bank[0].font, fontInBytes)
	self.fontRAM.dirtyCPU = true
end

-- externally used ...
-- this re-inserts the font and default palette
-- and copies those changes back into the cartridge too (stupid idea of keeping two copies of the cartridge in RAM and ROM ...)
function AppVideo:resetGFX()
	self:resetFont()

	self.paletteRAM:checkDirtyGPU()
	resetROMPalette(self.ram.bank[0])
	ffi.copy(self.banks.v[0].palette, self.ram.bank[0].palette, paletteInBytes)
	self.paletteRAM.dirtyCPU = true
end

function AppVideo:resize()
	needDrawCounter = drawCounterNeededToRedraw
end


function AppVideo:drawSolidRect(
	x,
	y,
	w,
	h,
	colorIndex,
	borderOnly,
	round,
	paletteTex	-- override for gui - hack for menus to impose their palettes
)
	if not paletteTex
	and self.paletteRAM.dirtyCPU
	then
		self.triBuf:flush()
		self.paletteRAM:checkDirtyCPU() -- before any GPU op that uses palette...
	end
	if self.framebufferRAM.dirtyCPU then
		self.triBuf:flush()
		self.framebufferRAM:checkDirtyCPU()
	end

	if w < 0 then x,w = x+w,-w end
	if h < 0 then y,h = y+h,-h end

	local xR = x + w
	local yR = y + h

	local xLL, yLL, zLL, wLL = vec2to4(self.ram.mvMat, x, y)
	local xRL, yRL, zRL, wRL = vec2to4(self.ram.mvMat, xR, y)
	local xLR, yLR, zLR, wLR = vec2to4(self.ram.mvMat, x, yR)
	local xRR, yRR, zRR, wRR = vec2to4(self.ram.mvMat, xR, yR)

	local blendSolidR, blendSolidG, blendSolidB = rgba5551_to_rgba8888_4ch(self.ram.blendColor)
	local blendSolidA = self.drawOverrideSolidA *  255

	local drawFlags = bit.bor(
		round and 4 or 0,
		borderOnly and 8 or 0
	)

	colorIndex = math.floor(colorIndex or 0)

	self.triBuf:addTri(
		paletteTex or self.paletteRAM.tex,
		self.sheetRAMs[1].tex,		-- doesn't need flushed, not used ... ?
		self.tilemapRAMs[1].tex,	-- doesn't need flushed, not used ... ?
		xLL, yLL, zLL, wLL, x, y,
		xRL, yRL, zRL, wRL, xR, y,
		xLR, yLR, zLR, wLR, x, yR,
		bit.bor(drawFlags, bit.lshift(colorIndex, 8)), self.ram.dither, 0, 0,
		blendSolidR, blendSolidG, blendSolidB, blendSolidA,
		x, y, w, h
	)

	self.triBuf:addTri(
		paletteTex or self.paletteRAM.tex,
		self.sheetRAMs[1].tex,		-- doesn't need flushed, not used ... ?
		self.tilemapRAMs[1].tex,	-- doesn't need flushed, not used ... ?
		xLR, yLR, zLR, wLR, x, yR,
		xRL, yRL, zRL, wRL, xR, y,
		xRR, yRR, zRR, wRR, xR, yR,
		bit.bor(drawFlags, bit.lshift(colorIndex, 8)), self.ram.dither, 0, 0,
		blendSolidR, blendSolidG, blendSolidB, blendSolidA,
		x, y, w, h
	)

	self.framebufferRAM.dirtyGPU = true
	self.framebufferRAM.changedSinceDraw = true
end

-- TODO get rid of this function
function AppVideo:drawBorderRect(
	x,
	y,
	w,
	h,
	colorIndex,
	...	-- round
)
	return self:drawSolidRect(x,y,w,h,colorIndex,true,...)
end

function AppVideo:drawSolidTri3D(x1, y1, z1, x2, y2, z2, x3, y3, z3, colorIndex)
	if self.paletteRAM.dirtyCPU then
		self.triBuf:flush()
		self.paletteRAM:checkDirtyCPU() -- before any GPU op that uses palette...
	end
	if self.framebufferRAM.dirtyCPU then
		self.triBuf:flush()
		self.framebufferRAM:checkDirtyCPU()
	end

	local v1x, v1y, v1z, v1w = vec3to4(self.ram.mvMat, x1, y1, z1)
	local v2x, v2y, v2z, v2w = vec3to4(self.ram.mvMat, x2, y2, z2)
	local v3x, v3y, v3z, v3w = vec3to4(self.ram.mvMat, x3, y3, z3)

	local blendSolidR, blendSolidG, blendSolidB = rgba5551_to_rgba8888_4ch(self.ram.blendColor)
	self.triBuf:addTri(
		self.paletteRAM.tex,
		self.sheetRAMs[1].tex,		-- doesn't need flushed, not used ... ?
		self.tilemapRAMs[1].tex,	-- doesn't need flushed, not used ... ?
		v1x, v1y, v1z, v1w, 0, 0,
		v2x, v2y, v2z, v2w, 1, 0,
		v3x, v3y, v3z, v3w, 0, 1,
		bit.lshift(math.floor(colorIndex or 0), 8), self.ram.dither, 0, 0,
		blendSolidR, blendSolidG, blendSolidB, self.drawOverrideSolidA * 255,
		0, 0, 1, 1		-- do box coords matter for tris if we're not using round or solid?
	)

	self.framebufferRAM.dirtyGPU = true
	self.framebufferRAM.changedSinceDraw = true
end

function AppVideo:drawSolidTri(x1, y1, x2, y2, x3, y3, colorIndex)
	return self:drawSolidTri3D(x1, y1, 0, x2, y2, 0, x3, y3, 0, colorIndex)
end

function AppVideo:drawSolidLine3D(x1, y1, z1, x2, y2, z2, colorIndex)
	if self.paletteRAM.dirtyCPU then
		self.triBuf:flush()
		self.paletteRAM:checkDirtyCPU() -- before any GPU op that uses palette...
	end
	if self.framebufferRAM.dirtyCPU then
		self.triBuf:flush()
		self.framebufferRAM:checkDirtyCPU()
	end

	local v1x, v1y, v1z, v1w = vec3to4(self.ram.mvMat, x1, y1, z1)
	local v2x, v2y, v2z, v2w = vec3to4(self.ram.mvMat, x2, y2, z2)

	local dx = v2x - v1x
	local dy = v2y - v1y
	local il = 1 / math.sqrt(dx^2 + dy^2)
	local nx = -dy * il
	local ny = dx * il

	local lineThickness = 1
	local xLL, yLL, zLL, wLL =
		v1x - nx * lineThickness,
		v1y - ny * lineThickness,
		v1z,
		v1w
	local xRL, yRL, zRL, wRL =
		v2x - nx * lineThickness,
		v2y - ny * lineThickness,
		v2z,
		v2w
	local xLR, yLR, zLR, wLR =
		v1x + nx * lineThickness,
		v1y + ny * lineThickness,
		v1z,
		v1w
	local xRR, yRR, zRR, wRR =
		v2x + nx * lineThickness,
		v2y + ny * lineThickness,
		v2z,
		v2w

	local blendSolidR, blendSolidG, blendSolidB = rgba5551_to_rgba8888_4ch(self.ram.blendColor)
	local blendSolidA = self.drawOverrideSolidA *  255
	colorIndex = math.floor(colorIndex or 0)

	self.triBuf:addTri(
		self.paletteRAM.tex,
		self.sheetRAMs[1].tex,		-- doesn't need flushed, not used ... ?
		self.tilemapRAMs[1].tex,	-- doesn't need flushed, not used ... ?
		xLL, yLL, zLL, wLL, 0, 0,
		xRL, yRL, zRL, wRL, 1, 0,
		xLR, yLR, zLR, wLR, 0, 1,
		bit.lshift(colorIndex, 8), self.ram.dither, 0, 0,
		blendSolidR, blendSolidG, blendSolidB, blendSolidA,
		0, 0, 1, 1
	)

	self.triBuf:addTri(
		self.paletteRAM.tex,
		self.sheetRAMs[1].tex,		-- doesn't need flushed, not used ... ?
		self.tilemapRAMs[1].tex,	-- doesn't need flushed, not used ... ?
		xLR, yLR, zLR, wLR, 0, 1,
		xRL, yRL, zRL, wRL, 1, 0,
		xRR, yRR, zRR, wRR, 1, 1,
		bit.lshift(colorIndex, 8), self.ram.dither, 0, 0,
		blendSolidR, blendSolidG, blendSolidB, blendSolidA,
		0, 0, 1, 1
	)

	self.framebufferRAM.dirtyGPU = true
	self.framebufferRAM.changedSinceDraw = true
end

function AppVideo:drawSolidLine(x1,y1,x2,y2,colorIndex)
	return self:drawSolidLine3D(x1,y1,0,x2,y2,0,colorIndex)
end

local mvMatPush = ffi.new(mvMatType..'[16]')
function AppVideo:clearScreen(
	colorIndex,
	paletteTex	-- override for menu ... starting to think this should be a global somewhere...
)
	ffi.copy(mvMatPush, self.ram.mvMat, ffi.sizeof(mvMatPush))

	local pushScissorX, pushScissorY, pushScissorW, pushScissorH = self:getClipRect()
	self:setClipRect(0, 0, clipMax, clipMax)

	local fbTex = self.framebufferRAM.tex
	self:matident()
	self:drawSolidRect(
		0,
		0,
		fbTex.width,
		fbTex.height,
		colorIndex or 0,
		nil,
		nil,
		paletteTex
	)

	self:setClipRect(pushScissorX, pushScissorY, pushScissorW, pushScissorH)

	ffi.copy(self.ram.mvMat, mvMatPush, ffi.sizeof(mvMatPush))
end

-- w, h is inclusive, right?  meaning for [0,256)^2 you should call (0,0,255,255)
function AppVideo:setClipRect(...)
	self.ram.clipRect[0], self.ram.clipRect[1], self.ram.clipRect[2], self.ram.clipRect[3] = ...
end

function AppVideo:getClipRect()
	return self.ram.clipRect[0], self.ram.clipRect[1], self.ram.clipRect[2], self.ram.clipRect[3]
end

-- for when we blend against solid colors, these go to the shaders to output it
AppVideo.drawOverrideSolidR = 0
AppVideo.drawOverrideSolidG = 0
AppVideo.drawOverrideSolidB = 0
AppVideo.drawOverrideSolidA = 0
function AppVideo:setBlendMode(blendMode)
	if blendMode < 0 or blendMode >= 8 then
		blendMode = -1
	end

	if self.currentBlendMode == blendMode then return end

	self.triBuf:flush()

	if blendMode == -1 then
		self.drawOverrideSolidA = 0
		gl.glDisable(gl.GL_BLEND)
	else

		gl.glEnable(gl.GL_BLEND)

		local subtract = bit.band(blendMode, 2) ~= 0
		if subtract then
			--gl.glBlendEquation(gl.GL_FUNC_SUBTRACT)		-- sprite minus framebuffer
			gl.glBlendEquation(gl.GL_FUNC_REVERSE_SUBTRACT)	-- framebuffer minus sprite
		else
			gl.glBlendEquation(gl.GL_FUNC_ADD)
		end

	-- [[ TODO this here or this in the draw commands?
		self.drawOverrideSolidA = bit.band(blendMode, 4) == 0 and 0 or 0xff	-- > 0 means we're using draw-override
	--]]
		local ca = 1
		local half = bit.band(blendMode, 1) ~= 0
		-- technically half didnt work when blending with constant-color on the SNES ...
		if half then
			ca = .5
		end
		gl.glBlendColor(1, 1, 1, ca)

		if half then
			gl.glBlendFunc(gl.GL_CONSTANT_ALPHA, gl.GL_CONSTANT_ALPHA)
		else
			gl.glBlendFunc(gl.GL_ONE, gl.GL_ONE)
		end
	end

	self.currentBlendMode = blendMode
end

--[[
'lower level' than 'drawQuad'
accepts a texture as arguments, so the UI/Editor can draw with textures outside of the RAM
doesn't care about tex dirty (cuz its probably a tex outside RAM)
doesn't care about framebuffer dirty (cuz its probably the editor framebuffer)
uses pathway 1
--]]
function AppVideo:drawQuadTex(
	paletteTex,
	sheetTex,
	x, y, w, h,	-- quad box
	tx, ty, tw, th,	-- texcoord bbox
	spriteBit,
	spriteMask,
	transparentIndex,
	paletteIndex
)
	spriteBit = spriteBit or 0
	spriteMask = spriteMask or 0xFF
	transparentIndex = transparentIndex or -1
	paletteIndex = paletteIndex or 0

	local drawFlags = bit.bor(
		-- bits 0/1 == 01b <=> use sprite pathway
		1,

		-- if transparency is oob then flag the "don't use transparentIndex" bit
		(transparentIndex < 0 or transparentIndex >= 256) and 4 or 0,

		-- store sprite bit shift in the next 3 bits
		bit.lshift(spriteBit, 3)
	)

	local blendSolidR, blendSolidG, blendSolidB = rgba5551_to_rgba8888_4ch(self.ram.blendColor)
	local blendSolidA = self.drawOverrideSolidA * 255

	local xR = x + w
	local yR = y + h

	local xLL, yLL, zLL, wLL = vec2to4(self.ram.mvMat, x, y)
	local xRL, yRL, zRL, wRL = vec2to4(self.ram.mvMat, xR, y)
	local xLR, yLR, zLR, wLR = vec2to4(self.ram.mvMat, x, yR)
	local xRR, yRR, zRR, wRR = vec2to4(self.ram.mvMat, xR, yR)

	local uL = tx
	local vL = ty
	local uR = tx + tw
	local vR = ty + th

	self.triBuf:addTri(
		paletteTex,
		sheetTex,
		self.tilemapRAMs[1].tex,	-- doesn't need flushed, not used ... ?
		xLL, yLL, zLL, wLL, uL, vL,
		xRL, yRL, zRL, wRL, uR, vL,
		xLR, yLR, zLR, wLR, uL, vR,
		bit.bor(drawFlags, bit.lshift(spriteMask, 8)), self.ram.dither, transparentIndex, paletteIndex,
		blendSolidR, blendSolidG, blendSolidB, blendSolidA,
		0, 0, 1, 1
	)

	self.triBuf:addTri(
		paletteTex,
		sheetTex,
		self.tilemapRAMs[1].tex,	-- doesn't need flushed, not used ... ?
		xLR, yLR, zLR, wLR, uL, vR,
		xRL, yRL, zRL, wRL, uR, vL,
		xRR, yRR, zRR, wRR, uR, vR,
		bit.bor(drawFlags, bit.lshift(spriteMask, 8)), self.ram.dither, transparentIndex, paletteIndex,
		blendSolidR, blendSolidG, blendSolidB, blendSolidA,
		0, 0, 1, 1
	)
end

--[[
uses pathway 3 to draw quads
--]]
function AppVideo:drawQuadTexRGB(
	paletteTex,
	sheetTex,
	x, y, w, h,	-- quad box
	tx, ty, tw, th	-- texcoord bbox
)
	local xR = x + w
	local yR = y + h

	local xLL, yLL, zLL, wLL = vec2to4(self.ram.mvMat, x, y)
	local xRL, yRL, zRL, wRL = vec2to4(self.ram.mvMat, xR, y)
	local xLR, yLR, zLR, wLR = vec2to4(self.ram.mvMat, x, yR)
	local xRR, yRR, zRR, wRR = vec2to4(self.ram.mvMat, xR, yR)

	local uL = tx
	local vL = ty
	local uR = tx + tw
	local vR = ty + th

	self.triBuf:addTri(
		paletteTex,
		sheetTex,
		self.tilemapRAMs[1].tex,	-- doesn't need flushed, not used ... ?
		xLL, yLL, zLL, wLL, uL, vL,
		xRL, yRL, zRL, wRL, uR, vL,
		xLR, yLR, zLR, wLR, uL, vR,
		3, self.ram.dither, 0, 0,
		0, 0, 0, 0,
		0, 0, 1, 1
	)

	self.triBuf:addTri(
		paletteTex,
		sheetTex,
		self.tilemapRAMs[1].tex,	-- doesn't need flushed, not used ... ?
		xLR, yLR, zLR, wLR, uL, vR,
		xRL, yRL, zRL, wRL, uR, vL,
		xRR, yRR, zRR, wRR, uR, vR,
		3, self.ram.dither, 0, 0,
		0, 0, 0, 0,
		0, 0, 1, 1
	)
end


--[[
'lower level' functionality than 'drawSprite'
but now that i'm using it for `sspr()` glue, it's in the cartridge api ...
args:
	x y w h = quad rectangle on screen
	tx ty tw th = texcoord rectangle in [0,255] pixel coordinates
	sheetIndex = 0 for sprite sheet, 1 for tile sheet
	paletteIndex = offset into the 256-color palette
	transparentIndex,
	spriteBit,
	spriteMask

sheetIndex is 0 or 1 depending on spriteSheet or tileSheet ...
should I just have an addr here?  and cache by ptr texs?
I was thinking of having some ROM metadata that flagged banks as dif types, and then for the VRAM banks generate GPU texs ...
--]]
function AppVideo:drawQuad(
	x, y, w, h,	-- quad box
	tx, ty, tw, th,	-- texcoord bbox
	sheetIndex,
	paletteIndex,
	transparentIndex,
	spriteBit,
	spriteMask,
	paletteTex	-- override for gui
)
	local sheetRAM = self.sheetRAMs[sheetIndex+1]
	if not sheetRAM then return end
	if sheetRAM.dirtyCPU then
		self.triBuf:flush()
		sheetRAM:checkDirtyCPU()			-- before we read from the sprite tex, make sure we have most updated copy
	end
	if not paletteTex
	and self.paletteRAM.dirtyCPU
	then
		self.triBuf:flush()
		self.paletteRAM:checkDirtyCPU() 		-- before any GPU op that uses palette...
	end

	-- TODO only this before we actually do the :draw()
	if self.framebufferRAM.dirtyCPU then
		self.triBuf:flush()
		self.framebufferRAM:checkDirtyCPU()		-- before we write to framebuffer, make sure we have most updated copy
	end

	self:drawQuadTex(
		paletteTex or self.paletteRAM.tex,
		sheetRAM.tex,
		x, y, w, h,
		tx / 256, ty / 256, tw / 256, th / 256,
		spriteBit, spriteMask, transparentIndex, paletteIndex
	)

	-- TODO only this after we actually do the :draw()
	self.framebufferRAM.dirtyGPU = true
	self.framebufferRAM.changedSinceDraw = true
end

function AppVideo:drawTexTri3D(
	x1,y1,z1,
	x2,y2,z2,
	x3,y3,z3,
	u1,v1,
	u2,v2,
	u3,v3,
	sheetIndex,
	paletteIndex,
	transparentIndex,
	spriteBit,
	spriteMask
)
	sheetIndex = sheetIndex or 0

	local sheetRAM = self.sheetRAMs[sheetIndex+1]
	if not sheetRAM then return end

	if sheetRAM.dirtyCPU then
		self.triBuf:flush()
		sheetRAM:checkDirtyCPU()				-- before we read from the sprite tex, make sure we have most updated copy
	end
	if self.paletteRAM.dirtyCPU then
		self.triBuf:flush()
		self.paletteRAM:checkDirtyCPU() 		-- before any GPU op that uses palette...
	end
	if self.framebufferRAM.dirtyCPU then
		self.triBuf:flush()
		self.framebufferRAM:checkDirtyCPU()		-- before we write to framebuffer, make sure we have most updated copy
	end

	spriteBit = spriteBit or 0
	spriteMask = spriteMask or 0xFF
	transparentIndex = transparentIndex or -1
	paletteIndex = paletteIndex or 0

	local drawFlags = bit.bor(
		-- bits 0/1 == 01b <=> use sprite pathway
		1,

		-- if transparency is oob then flag the "don't use transparentIndex" bit
		(transparentIndex < 0 or transparentIndex >= 256) and 4 or 0,

		-- store sprite bit shift in the next 3 bits
		bit.lshift(spriteBit, 3)
	)

	local blendSolidR, blendSolidG, blendSolidB = rgba5551_to_rgba8888_4ch(self.ram.blendColor)

	local vx1, vy1, vz1, vw1 = vec3to4(self.ram.mvMat, x1, y1, z1)
	local vx2, vy2, vz2, vw2 = vec3to4(self.ram.mvMat, x2, y2, z2)
	local vx3, vy3, vz3, vw3 = vec3to4(self.ram.mvMat, x3, y3, z3)

	self.triBuf:addTri(
		self.paletteRAM.tex,
		sheetRAM.tex,
		self.tilemapRAMs[1].tex,	-- doesn't need flushed, not used ... ?
		vx1, vy1, vz1, vw1, u1, v1,
		vx2, vy2, vz2, vw2, u2, v2,
		vx3, vy3, vz3, vw3, u3, v3,
		bit.bor(drawFlags, bit.lshift(spriteMask, 8)), self.ram.dither, transparentIndex, paletteIndex,
		blendSolidR, blendSolidG, blendSolidB, self.drawOverrideSolidA * 255,
		0, 0, 1, 1
	)

	self.framebufferRAM.dirtyGPU = true
	self.framebufferRAM.changedSinceDraw = true
end


--[[
spriteIndex =
	bits 0..4 = x coordinate in sprite sheet
	bits 5..9 = y coordinate in sprite sheet
	bit 10 = sprite sheet vs tile sheet
	bits 11.. = bank to use for sprite/tile sheet
tilesWide = width in tiles
tilesHigh = height in tiles
paletteIndex =
	byte value with high 4 bits that holds which palette to use
	... this is added to the sprite color index so really it's a palette shift.
	(should I OR it?)
transparentIndex = which color index in the sprite to use as transparency.  default -1 = none
spriteBit = index of bit (0-based) to use, default is zero
spriteMask = mask of number of bits to use, default is 0xF <=> 4bpp
scaleX = how much to scale the drawn width, default is 1
scaleY = how much to scale the drawn height, default is 1
--]]
function AppVideo:drawSprite(
	spriteIndex,
	screenX,
	screenY,
	tilesWide,
	tilesHigh,
	paletteIndex,
	transparentIndex,
	spriteBit,
	spriteMask,
	scaleX,
	scaleY
)
	tilesWide = tilesWide or 1
	tilesHigh = tilesHigh or 1
	scaleX = scaleX or 1
	scaleY = scaleY or 1
	-- vram / sprite sheet is 32 sprites wide ... 256 pixels wide, 8 pixels per sprite
	spriteIndex = math.floor(spriteIndex or 0)
	local tx = bit.band(spriteIndex, 0x1f)
	local ty = bit.band(bit.rshift(spriteIndex, 5), 0x1f)
	local sheetIndex = bit.rshift(spriteIndex, 10)
	self:drawQuad(
		-- x y w h
		screenX,
		screenY,
		tilesWide * spriteSize.x * scaleX,
		tilesHigh * spriteSize.y * scaleY,
		-- tx ty tw th in [0,255] pixels
		bit.lshift(tx, 3),
		bit.lshift(ty, 3),
		bit.lshift(tilesWide, 3),
		bit.lshift(tilesHigh, 3),
		sheetIndex,
		paletteIndex,
		transparentIndex,
		spriteBit,
		spriteMask
	)
end

-- TODO go back to tileIndex instead of tileX tileY.  That's what mset() issues after all.
-- TODO which is faster, using a single quad draw here, or chopping it up into individual quads and rendering each separately?
-- especially considering if we make them all quads and use the same shader as the sprite shader then we can batch draw all sprites + maps together.
function AppVideo:drawMap(
	tileX,			-- \_ upper-left position in the tilemap
	tileY,			-- /
	tilesWide,		-- \_ how many tiles wide & high to draw
	tilesHigh,		-- /
	screenX,		-- \_ where in the screen to draw
	screenY,		-- /
	mapIndexOffset,	-- general shift to apply to all read map indexes in the tilemap
	draw16Sprites,	-- set to true to draw 16x16 sprites instead of 8x8 sprites.  You still index tileX/Y with the 8x8 position. tilesWide/High are in terms of 16x16 sprites.
	sheetIndex,		-- which sheet to use, 0 to 2*n-1 for n banks.  even are sprite-sheets, odd are tile-sheets.
	tilemapIndex	-- which tilemap bank to use, 0 to n-1 for n banks
)
	sheetIndex = sheetIndex or 1
	local sheetRAM = self.sheetRAMs[sheetIndex+1]
	if not sheetRAM then return end
	if sheetRAM.dirtyCPU then
		self.triBuf:flush()
		sheetRAM:checkDirtyCPU()	-- TODO just use multiple sprite sheets and let the map() function pick which one
	end
	if self.paletteRAM.dirtyCPU then
		self.triBuf:flush()
		self.paletteRAM:checkDirtyCPU() 	-- before any GPU op that uses palette...
	end
	tilemapIndex = tilemapIndex or 0
	local tilemapRAM = self.tilemapRAMs[tilemapIndex+1]
	if tilemapRAM.dirtyCPU then
		self.triBuf:flush()
		tilemapRAM:checkDirtyCPU()
	end
	if self.framebufferRAM.dirtyCPU then
		self.triBuf:flush()
		self.framebufferRAM:checkDirtyCPU()
	end

	tilesWide = tilesWide or 1
	tilesHigh = tilesHigh or 1

	local draw16As0or1 = draw16Sprites and 1 or 0

	local xL = screenX or 0
	local yL = screenY or 0
	local xR = xL + tilesWide * bit.lshift(spriteSize.x, draw16As0or1)
	local yR = yL + tilesHigh * bit.lshift(spriteSize.y, draw16As0or1)

	local xLL, yLL, zLL, wLL = vec2to4(self.ram.mvMat, xL, yL)
	local xRL, yRL, zRL, wRL = vec2to4(self.ram.mvMat, xR, yL)
	local xLR, yLR, zLR, wLR = vec2to4(self.ram.mvMat, xL, yR)
	local xRR, yRR, zRR, wRR = vec2to4(self.ram.mvMat, xR, yR)

	local uL = tileX / tonumber(spriteSheetSizeInTiles.x)
	local vL = tileY / tonumber(spriteSheetSizeInTiles.y)
	local uR = uL + tilesWide / tonumber(spriteSheetSizeInTiles.x)
	local vR = vL + tilesHigh / tonumber(spriteSheetSizeInTiles.y)

	-- user has to specify high-bits
	mapIndexOffset = mapIndexOffset or 0
	local extraX = bit.bor(
		2,	-- tilemap pathway
		draw16Sprites and 4 or 0
	)
	local extraZ = mapIndexOffset

	local blendSolidR, blendSolidG, blendSolidB = rgba5551_to_rgba8888_4ch(self.ram.blendColor)
	local blendSolidA = self.drawOverrideSolidA * 255

	self.triBuf:addTri(
		self.paletteRAM.tex,
		sheetRAM.tex,
		tilemapRAM.tex,
		xLL, yLL, zLL, wLL, uL, vL,
		xRL, yRL, zRL, wRL, uR, vL,
		xLR, yLR, zLR, wLR, uL, vR,
		extraX, self.ram.dither, extraZ, 0,
		blendSolidR, blendSolidG, blendSolidB, blendSolidA,
		0, 0, 1, 1
	)

	self.triBuf:addTri(
		self.paletteRAM.tex,
		sheetRAM.tex,
		tilemapRAM.tex,
		xLR, yLR, zLR, wLR, uL, vR,
		xRL, yRL, zRL, wRL, uR, vL,
		xRR, yRR, zRR, wRR, uR, vR,
		extraX, self.ram.dither, extraZ, 0,
		blendSolidR, blendSolidG, blendSolidB, blendSolidA,
		0, 0, 1, 1
	)

	self.framebufferRAM.dirtyGPU = true
	self.framebufferRAM.changedSinceDraw = true
end

function AppVideo:drawTextCommon(fontTex, paletteTex, text, x, y, fgColorIndex, bgColorIndex, scaleX, scaleY)
	x = x or 0
	y = y or 0
	fgColorIndex = tonumber(ffi.cast('uint8_t', fgColorIndex or self.ram.textFgColor))
	bgColorIndex = tonumber(ffi.cast('uint8_t', bgColorIndex or self.ram.textBgColor))
	scaleX = scaleX or 1
	scaleY = scaleY or 1
	local x0 = x

	-- should font bg respect transparency/alpha?
	-- or why even draw a background to it? let the user?
	-- or how about use it as a separate flag?
	-- TODO this always uses the cart colors even for the menu draw routine ...
	local r,g,b,a = rgba5551_to_rgba8888_4ch(self.ram.bank[0].palette[bgColorIndex])
	if a > 0 then
		local bgw = 0
		for i=1,#text do
			local ch = text:byte(i)
			local w = scaleX * (self.inMenuUpdate and menuFontWidth or self.ram.fontWidth[ch])
			bgw = bgw + w
		end

		-- TODO the ... between drawSolidRect and drawSprite is not the same ...
		self:drawSolidRect(
			x0,
			y,
			bgw,
			scaleY * spriteSize.y,
			bgColorIndex
		)
	end

-- draw transparent-background text
	local x = x0 + 1
	y = y + 1

	local w = spriteSize.x * scaleX
	local h = spriteSize.y * scaleY
	local texSizeInTiles = fontImageSizeInTiles		-- using separate font tex
	local tw = 1 / tonumber(texSizeInTiles.x)
	local th = 1 / tonumber(texSizeInTiles.y)
	local blendSolidR, blendSolidG, blendSolidB = rgba5551_to_rgba8888_4ch(self.ram.blendColor)
	local blendSolidA = self.drawOverrideSolidA * 255
	local paletteIndex = fgColorIndex - 1

	for i=1,#text do
		local ch = text:byte(i)
		local spriteBit = bit.band(ch, 7)		-- get the bit offset
		local by = bit.rshift(ch, 3)	-- get the byte offset

		local drawFlags = bit.bor(
			-- bits 0/1 == 01b <=> use sprite pathway
			1,

			-- transparentIndex == 0, which is in-bounds, so don't set the transparentIndex oob flag
			0,

			-- store sprite bit shift in the next 3 bits
			bit.lshift(spriteBit, 3)
		)

		local xR = x + w
		local yR = y + h

		local xLL, yLL, zLL, wLL = vec2to4(self.ram.mvMat, x, y)
		local xRL, yRL, zRL, wRL = vec2to4(self.ram.mvMat, xR, y)
		local xLR, yLR, zLR, wLR = vec2to4(self.ram.mvMat, x, yR)
		local xRR, yRR, zRR, wRR = vec2to4(self.ram.mvMat, xR, yR)

		local uL = by / tonumber(texSizeInTiles.x)
		local uR = uL + tw

		self.triBuf:addTri(
			paletteTex,
			fontTex,
			self.tilemapRAMs[1].tex,	-- doesn't need flushed, not used ... ?
			xLL, yLL, zLL, wLL, uL, 0,
			xRL, yRL, zRL, wRL, uR, 0,
			xLR, yLR, zLR, wLR, uL, th,
			bit.bor(drawFlags, 0x100), self.ram.dither, 0, paletteIndex,
			blendSolidR, blendSolidG, blendSolidB, blendSolidA,
			0, 0, 1, 1
		)

		self.triBuf:addTri(
			paletteTex,
			fontTex,
			self.tilemapRAMs[1].tex,	-- doesn't need flushed, not used ... ?
			xRL, yRL, zRL, wRL, uR, 0,
			xRR, yRR, zRR, wRR, uR, th,
			xLR, yLR, zLR, wLR, uL, th,
			bit.bor(drawFlags, 0x100), self.ram.dither, 0, paletteIndex,
			blendSolidR, blendSolidG, blendSolidB, blendSolidA,
			0, 0, 1, 1
		)

		x = x + scaleX * (self.inMenuUpdate and menuFontWidth or self.ram.fontWidth[ch])
	end

	return x - x0
end

-- TODO same inlining as I just did to :drawMenuText ...
-- draw a solid background color, then draw the text transparent
-- specify an oob bgColorIndex to draw with transparent background
-- and default x, y to the last cursor position
function AppVideo:drawText(...)

-- [[ drawQuad startup
	if self.fontRAM.dirtyCPU then
		self.triBuf:flush()
		self.fontRAM:checkDirtyCPU()			-- before we read from the sprite tex, make sure we have most updated copy
	end
	if self.paletteRAM.dirtyCPU then
		self.triBuf:flush()
		self.paletteRAM:checkDirtyCPU() 		-- before any GPU op that uses palette...
	end
	if self.framebufferRAM.dirtyCPU then
		self.triBuf:flush()
		self.framebufferRAM:checkDirtyCPU()		-- before we write to framebuffer, make sure we have most updated copy
	end
--]]

	local result = self:drawTextCommon(self.fontRAM.tex, self.paletteRAM.tex, ...)

-- [[ drawQuad shutdown
	self.framebufferRAM.dirtyGPU = true
	self.framebufferRAM.changedSinceDraw = true
--]]

	return result
end

-- same as drawText but using the menu font and palette
function AppVideo:drawMenuText(...)
	return self:drawTextCommon(self.fontMenuTex, self.paletteMenuTex, ...)
end


-- matrix commands, so I don't duplicate these here in the env and in net ...
-- should I set defaults here as well?
-- I'm already setting them in env so ... nah ...

function AppVideo:matident()
	-- set-ident and scale ...
	self.ram.mvMat[0],  self.ram.mvMat[1],  self.ram.mvMat[2],  self.ram.mvMat[3]  = mvMatScale, 0, 0, 0
	self.ram.mvMat[4],  self.ram.mvMat[5],  self.ram.mvMat[6],  self.ram.mvMat[7]  = 0, mvMatScale, 0, 0
	self.ram.mvMat[8],  self.ram.mvMat[9],  self.ram.mvMat[10], self.ram.mvMat[11] = 0, 0, mvMatScale, 0
	self.ram.mvMat[12], self.ram.mvMat[13], self.ram.mvMat[14], self.ram.mvMat[15] = 0, 0, 0, mvMatScale
end

function AppVideo:mattrans(x,y,z)
	self.mvMat:applyTranslate(x, y, z)
end

function AppVideo:matrot(theta, x, y, z)
	self.mvMat:applyRotate(theta, x, y, z)
end

function AppVideo:matscale(x, y, z)
	self.mvMat:applyScale(x, y, z)
end

function AppVideo:matortho(l, r, t, b, n, f)
	-- adjust from [-1,1] to [0,256]
	-- opengl ortho matrix, which expects input space to be [-1,1]
	self.mvMat:applyTranslate(128, 128)
	self.mvMat:applyScale(128, 128)
	self.mvMat:applyOrtho(l, r, t, b, n, f)
end

function AppVideo:matfrustum(l, r, t, b, n, f)
--	self.mvMat:applyTranslate(128, 128)
--	self.mvMat:applyScale(128, 128)
	self.mvMat:applyFrustum(l, r, t, b, n, f)
	-- TODO Why is matortho a lhs transform to screen space but matfrustum a rhs transform to screen space? what did I do wrong?
	self.mvMat:applyTranslate(128, 128)
	self.mvMat:applyScale(128, 128)
end

function AppVideo:matlookat(ex, ey, ez, cx, cy, cz, upx, upy, upz)
	-- typically y+ is up, but in the 90s console era y- is up
	-- also flip x+ since OpenGL uses a RHS but I want to preserve orientation of our renderer when looking down from above, so we use a LHS
	self.mvMat:applyScale(-1, -1, 1)
	self.mvMat:applyLookAt(ex, ey, ez, cx, cy, cz, upx, upy, upz)
end

return {
	argb8888revto5551 = argb8888revto5551,
	rgba5551_to_rgba8888_4ch = rgba5551_to_rgba8888_4ch,
	rgb565rev_to_rgba888_3ch = rgb565rev_to_rgba888_3ch,
	rgba8888_4ch_to_5551 = rgba8888_4ch_to_5551,
	resetROMFont = resetROMFont,
	resetLogoOnSheet = resetLogoOnSheet,
	resetROMPalette = resetROMPalette,
	AppVideo = AppVideo,
}
