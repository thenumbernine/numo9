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
local GLProgram = require 'gl.program'
local GLSceneObject = require 'gl.sceneobject'

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
local mvMatScale = numo9_rom.mvMatScale
local packptr = numo9_rom.packptr
local unpackptr = numo9_rom.unpackptr
local menuFontWidth = numo9_rom.menuFontWidth

local function glslnumber(x)
	local s = tostring(tonumber(x))
	if s:find'e' then return s end
	if not s:find'%.' then s = s .. '.' end
	return s
end

-- TODO use either settable or packptr ... ?
local function settableindex(t, i, ...)
	if select('#', ...) == 0 then return end
	t[i] = ...
	settableindex(t, i+1, select(2, ...))
end

local function settable(t, ...)
	settableindex(t, 1, ...)
end

-- uses integer coordinates in shader.  you'd think that'd make it look more retro, but it seems shaders evolved for decades with float-only/predominant that int support is shoehorned in.
local useTextureRect = false
--local useTextureRect = true

local texelFunc = 'texture'
--local texelFunc = 'texelFetch'
-- I'm getting this error really: "No matching function for call to texelFetch(usampler2D, ivec2)"
-- so I guess I need to use usampler2DRect if I want to use texelFetch

-- on = use GL_*UI for our texture internal format, off = use regular non-integer
--local useSamplerUInt = false	-- crashes ... why. TODO.
local useSamplerUInt = true

local texInternalFormat_u8 = useSamplerUInt
	and gl.GL_R8UI	-- use this with usampler2D(Rect) ... right?
	or gl.GL_R8	-- use this with sampler2D(Rect) ... right?
	--or gl.GL_R32F	-- needs CPU data to be in

local texInternalFormat_u16 = useSamplerUInt
	and gl.GL_R16UI
	or gl.GL_R16
	--or gl.GL_R32F

-- 'REV' means first channel first bit ... smh
-- so even tho 5551 is on hardware since forever, it's not on ES3 or WebGL, only GL4...
-- in case it's missing, just use single-channel R16 and do the swizzles manually
local support5551 = op.safeindex(gl, 'GL_UNSIGNED_SHORT_1_5_5_5_REV')

local internalFormat5551, format5551, type5551, glslCode5551
if support5551 then
	internalFormat5551 = gl.GL_RGB5_A1
	format5551 = gl.GL_RGBA
	type5551 = op.safeindex(gl, 'GL_UNSIGNED_SHORT_1_5_5_5_REV')
	glslCode5551 = ''
else
	internalFormat5551 = gl.GL_R16UI
	format5551 = gl.GL_RED_INTEGER
	type5551 = gl.GL_UNSIGNED_SHORT

	-- convert it here to vec4 since default UNSIGNED_SHORT_1_5_5_5_REV uses vec4
	glslCode5551 = [[
// assumes the uint is [0,0xffff]
vec4 u16to5551(uint x) {
	return vec4(
		float(x & 0x1fu) / 31.,
		float((x & 0x3e0u) >> 5u) / 31.,
		float((x & 0x7c00u) >> 10u) / 31.,
		float((x & 0x8000u) >> 15u)
	);
}
]]
end

-- TODO move to gl?
local function infoForTex(tex)
	return assert.index(GLTex2D.formatInfoForInternalFormat, tex.internalFormat, "failed to find formatInfo for internalFormat")
end

local function glslPrefixForTex(tex)
	return GLTex2D.glslPrefixForInternalType[infoForTex(tex).internalType] or ''
end

local function samplerTypeForTex(tex)
	return glslPrefixForTex(tex)..'sampler2D'..(useTextureRect and 'Rect' or '')
end

local function fragTypeForTex(tex)
	return glslPrefixForTex(tex)..'vec4'
end

local function textureSize(tex)
	if useTextureRect then	-- textureSize(gsampler2DRect) doesn't have a LOD argument
		return 'textureSize('..tex..')'
	else
		return 'textureSize('..tex..', 0)'
	end
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
		if useTextureRect or texelFunc == 'texelFetch' then
			tc = 'ivec2(('..tc..') * vec2('..textureSize(texvar)..'))'
		end
	elseif args.from == 'ivec2' then
		if not (useTextureRect or texelFunc == 'texelFetch') then
			tc = '(vec2('..tc..') + .5) / vec2('..textureSize(texvar)..')'
		end
	end
	local dst
	if texelFunc == 'texelFetch'
	and not useTextureRect 	-- texelFetch(gsampler2DRect) doesn't have a LOD argument
	then
		dst = texelFunc..'('..texvar..', '..tc..', 0)'
	else
		dst = texelFunc..'('..texvar..', '..tc..')'
	end
	if args.to == 'u16to5551' then
		dst = 'u16to5551(('..dst..').r)'
	elseif args.to == 'uvec4' then
		-- convert to uint, assume the source is a texture texel
		if fragTypeForTex(args.tex) == 'uvec4' then
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

	self.size = width * height * channels * ffi.sizeof(ctype)
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
	image.buffer = ffi.cast(image.format..'*', ptr)

	local tex = GLTex2D{
		target = args.target or (
			useTextureRect and gl.GL_TEXTURE_RECTANGLE or nil	-- nil defaults to TEXTURE_2D
		),
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
	}:unbind()
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
		:unbind()
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
	self.fb = GLFBO{
		width = frameBufferSize.x,
		height = frameBufferSize.y,
	}:unbind()

	-- create these upon resetVideo() or at least upon loading a new ROM, and make a sprite/tile sheet per bank
	-- but I am still using the texture specs for my shader creation
	-- and my shader creation is done once
	-- so until then, just resize them here
	-- RAMRegions ... RAMBanks ... idk what to name this ...
	self.sheetRAMs = table()
	self.tilemapRAMs = table()
	self.paletteRAMs = table()
	self.fontRAMs = table()
	self:resizeRAMGPUs()
	self.spriteSheetRAM = self.sheetRAMs[1]
	self.tileSheetRAM = self.sheetRAMs[2]
	self.tilemapRAM = self.tilemapRAMs[1]
	self.paletteRAM = self.paletteRAMs[1]
	self.fontRAM = self.fontRAMs[1]

	ffi.fill(self.ram.framebuffer, ffi.sizeof(self.ram.framebuffer), 0)
	-- [=[ framebuffer is 256 x 256 x 16bpp rgb565
	self.framebufferRGB565RAM = RAMGPUTex{
		app = self,
		addr = framebufferAddr,
		width = frameBufferSize.x,
		height = frameBufferSize.y,
		channels = 1,
		ctype = 'uint16_t',
		internalFormat = gl.GL_RGB565,
		glformat = gl.GL_RGB,
		gltype = gl.GL_UNSIGNED_SHORT_5_6_5,
	}
	--]=]
	-- [=[ framebuffer is 256 x 256 x 8bpp indexed
	self.framebufferIndexRAM = RAMGPUTex{
		app = self,
		addr = framebufferAddr,
		width = frameBufferSize.x,
		height = frameBufferSize.y,
		channels = 1,
		ctype = 'uint8_t',
		internalFormat = texInternalFormat_u8,
		glformat = GLTex2D.formatInfoForInternalFormat[texInternalFormat_u8].format,
		gltype = gl.GL_UNSIGNED_BYTE,
	}
	--]=]

	-- keep menu/editor gfx separate of the fantasy-console
	do
		-- palette is 256 x 1 x 16 bpp (5:5:5:1)
		local data = ffi.new('uint16_t[?]', 256)
		resetPalette(data)
		self.paletteMenuTex = GLTex2D{
			target = useTextureRect and gl.GL_TEXTURE_RECTANGLE or nil,	-- nil defaults to TEXTURE_2D
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
			target = useTextureRect and gl.GL_TEXTURE_RECTANGLE or nil,	-- nil defaults to TEXTURE_2D
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
		local size = frameBufferSize.x * frameBufferSize.y * 3
		local data = ffi.new('uint8_t[?]', size)
		ffi.fill(data, size)
		self.framebufferMenuTex = GLTex2D{
			target = useTextureRect and gl.GL_TEXTURE_RECTANGLE or nil,	-- nil defaults to TEXTURE_2D
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

	-- desktop-GL versions ...
	-- https://www.khronos.org/opengl/wiki/Core_Language_(GLSL)
	--local glslVersion = '110'	-- gl 2.0
	--local glslVersion = '120'	-- gl 2.1
	--local glslVersion = '130'	-- gl 3.0
	--local glslVersion = '140'	-- gl 3.1	-- lowest working version on my osx before it complains that the version (too low) aren't supported ...
	--local glslVersion = '150'	-- gl 3.2
	--local glslVersion = '330'	-- gl 3.3
	--local glslVersion = '400'	-- gl 4.0
	local glslVersion = '410'	-- gl 4.1	-- highest working version on my osx before it complains ...
	--local glslVersion = '420'	-- gl 4.2
	--local glslVersion = '430'	-- gl 4.3
	--local glslVersion = '440'	-- gl 4.4
	--local glslVersion = '450'	-- gl 4.5
	--local glslVersion = '460'	-- gl 4.6

	-- GLES versions ...
	--local glslVersion = '100 es'
	--local glslVersion = '300 es'
	--local glslVersion = '310 es'
	--local glslVersion = '320 es'

	-- allow override
	glslVersion = cmdline.glsl or glslVersion

	-- code for converting 'uint colorIndex' to '(u)vec4 fragColor'
	-- assert palleteSize is a power-of-two ...
	local function colorIndexToFrag(tex, decl)
		return decl..' = '..readTex{
			tex = self.paletteRAM.tex,
			texvar = 'paletteTex',
			tc = 'ivec2(int(colorIndex & '..('0x%Xu'):format(paletteSize-1)..'), 0)',
			from = 'ivec2',
			to = support5551
				and fragTypeForTex(tex)
				or 'u16to5551'
			,
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

	self.videoModeInfo = {
		-- 16bpp rgb565
		[0]={
			framebufferRAM = self.framebufferRGB565RAM,

			-- generator properties
			name = 'RGB',
			colorOutput = colorIndexToFrag(self.framebufferRGB565RAM.tex, 'fragColor')..'\n'
				..getDrawOverrideCode'vec3',
		},
		-- 8bpp indexed
		{
			framebufferRAM = self.framebufferIndexRAM,

			-- generator properties
			-- indexed mode can't blend so ... no draw-override
			name = 'Index',
			colorOutput =
-- this part is only needed for alpha
colorIndexToFrag(self.framebufferIndexRAM.tex, 'vec4 palColor')..'\n'..
[[
	fragColor.r = colorIndex;
	fragColor.g = 0u;
	fragColor.b = 0u;
	// only needed for quadSprite / quadMap:
	fragColor.a = uint(palColor.a * 255.);
]],
		},
		-- 8bpp rgb332
		{
			framebufferRAM = self.framebufferIndexRAM,

			-- generator properties
			name = 'RGB332',
			colorOutput = colorIndexToFrag(self.framebufferIndexRAM.tex, 'vec4 palColor')..'\n'
..getDrawOverrideCode'uvec3'..'\n'
..[[
	/*
	palColor was 5 5 5 (but is now vec4 normalized)
	fragColor is 3 3 2
	so we lose   2 2 3 bits
	so we can dither those in ...
	*/
	uint r5 = uint(palColor.r * 31.);
	uint g5 = uint(palColor.g * 31.);
	uint b5 = uint(palColor.b * 31.);
	ivec2 ipixelPos = ivec2(pixelPos);
	fragColor.r = (r5 >> 2) |
				((g5 >> 2) << 3) |
				((b5 >> 3) << 6);
	fragColor.g = 0u;
	fragColor.b = 0u;
	// only needed for quadSprite / quadMap:
	fragColor.a = uint(palColor.a * 255.);
]]
},
	}

--[[ a wrapper to output the code
	local origGLSceneObject = GLSceneObject
	local function GLSceneObject(args)
		print'vertex'
		print(require 'template.showcode'(args.program.vertexCode))
		print'fragment'
		print(require 'template.showcode'(args.program.fragmentCode))
		print()
		return origGLSceneObject(args)
	end
--]]

	local blitFragType = 'vec4'	-- blit screen is always to vec4 ... right?

	-- used for drawing our 16bpp framebuffer to the screen
--DEBUG:print'mode 0 blitScreenObj'
	self.videoModeInfo[0].blitScreenObj = GLSceneObject{
		program = {
			version = glslVersion,
			precision = 'best',
			vertexCode = [[
precision highp isampler2D;
precision highp usampler2D;	// needed by #version 300 es

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
uniform <?=samplerTypeForTex(framebufferRAM.tex)?> framebufferTex;

void main() {
	fragColor = ]]..readTex{
		tex = self.videoModeInfo[0].framebufferRAM,
		texvar = 'framebufferTex',
		tc = 'tcv',
		from = 'vec2',
		to = blitFragType,
	}..[[;
}
]],			{
				framebufferRAM = self.videoModeInfo[0].framebufferRAM,
				samplerTypeForTex = samplerTypeForTex,
				blitFragType = blitFragType,
			}),
			uniforms = {
				framebufferTex = 0,
			},
		},
		texs = {self.videoModeInfo[0].framebufferRAM},
		geometry = self.quadGeom,
		-- glUniform()'d every frame
		uniforms = {
			mvProjMat = self.blitScreenView.mvProjMat.ptr,
		},
	}

	-- used for drawing our 8bpp indexed framebuffer to the screen
--DEBUG:print'mode 1 blitScreenObj'
	self.videoModeInfo[1].blitScreenObj = GLSceneObject{
		program = {
			version = glslVersion,
			precision = 'best',
			vertexCode = [[
precision highp isampler2D;
precision highp usampler2D;	// needed by #version 300 es

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

uniform <?=samplerTypeForTex(framebufferRAM.tex)?> framebufferTex;
uniform <?=samplerTypeForTex(self.paletteRAM.tex)?> paletteTex;

<?=glslCode5551?>

void main() {
	uint colorIndex = ]]..readTex{
		tex = self.videoModeInfo[1].framebufferRAM,
		texvar = 'framebufferTex',
		tc = 'tcv',
		from = 'vec2',
		to = blitFragType,
	}..[[.r;
]]..colorIndexToFrag(self.videoModeInfo[1].framebufferRAM.tex, 'fragColor')..[[
}
]],			{
				samplerTypeForTex = samplerTypeForTex,
				framebufferRAM = self.videoModeInfo[1].framebufferRAM,
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
			self.videoModeInfo[1].framebufferRAM.tex,
			self.paletteRAM.tex,
		},
		geometry = self.quadGeom,
		-- glUniform()'d every frame
		uniforms = {
			mvProjMat = self.blitScreenView.mvProjMat.ptr,
		},
	}

	-- used for drawing 8bpp framebufferIndexRAM as rgb332 framebuffer to the screen
--DEBUG:print'mode 2 blitScreenObj'
	self.videoModeInfo[2].blitScreenObj = GLSceneObject{
		program = {
			version = glslVersion,
			precision = 'best',
			vertexCode = [[
precision highp isampler2D;
precision highp usampler2D;	// needed by #version 300 es

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

uniform <?=samplerTypeForTex(framebufferRAM.tex)?> framebufferTex;

void main() {
	uint rgb332 = ]]..readTex{
		tex = self.videoModeInfo[1].framebufferRAM.tex,
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
]],			{
				framebufferRAM = self.videoModeInfo[2].framebufferRAM,
				samplerTypeForTex = samplerTypeForTex,
				blitFragType = blitFragType,
			}),
			uniforms = {
				framebufferTex = 0,
				paletteTex = 1,
			},
		},
		texs = {
			self.videoModeInfo[2].framebufferRAM.tex,
			self.paletteRAM.tex,
		},
		geometry = self.quadGeom,
		-- glUniform()'d every frame
		uniforms = {
			mvProjMat = self.blitScreenView.mvProjMat.ptr,
		},
	}

	-- make output shaders per-video-mode
	-- set them up as our app fields to use upon setVideoMode
	for infoIndex,info in pairs(self.videoModeInfo) do
--DEBUG:print('mode '..infoIndex..' lineSolidObj')
		info.lineSolidObj = GLSceneObject{
			program = {
				version = glslVersion,
				precision = 'best',
				vertexCode = template([[
precision highp isampler2D;
precision highp usampler2D;	// needed by #version 300 es

layout(location=0) in vec2 vertex;
out vec2 pixelPos;
uniform vec3 pos0;
uniform vec3 pos1;
uniform mat4 mvMat;

//instead of a projection matrix, here I'm going to convert from framebuffer pixel coordinates to GL homogeneous coordinates.
const float frameBufferSizeX = <?=glslnumber(frameBufferSize.x)?>;
const float frameBufferSizeY = <?=glslnumber(frameBufferSize.y)?>;

const float lineThickness = 1.;

void main() {
	vec4 xformPos0 = mvMat * vec4(pos0, 1.);
	vec4 xformPos1 = mvMat * vec4(pos1, 1.);
	vec4 delta = xformPos1 - xformPos0;
	gl_Position = xformPos0
		+ delta * vertex.x
		+ normalize(vec4(-delta.y, delta.x, 0., 0.)) * (vertex.y - .5) * 2. * lineThickness;
	pixelPos = gl_Position.xy;
	gl_Position.xy *= vec2(2. / frameBufferSizeX, 2. / frameBufferSizeY);
	gl_Position.xy -= 1.;
}
]],				{
					glslnumber = glslnumber,
					frameBufferSize = frameBufferSize,
				}),
				fragmentCode = template([[
precision highp isampler2D;
precision highp usampler2D;	// needed by #version 300 es

in vec2 pixelPos;
layout(location=0) out <?=fragType?> fragColor;

uniform uint colorIndex;
uniform <?=samplerTypeForTex(self.paletteRAM.tex)?> paletteTex;
uniform vec4 drawOverrideSolid;

<?=glslCode5551?>

void main() {
]]..info.colorOutput..[[
}
]],				{
					info = info,
					fragType = fragTypeForTex(info.framebufferRAM.tex),
					self = self,
					samplerTypeForTex = samplerTypeForTex,
					glslCode5551 = glslCode5551,
				}),
				uniforms = {
					paletteTex = 0,
					--mvMat = self.mvMat.ptr,
				},
			},
			texs = {self.paletteRAM.tex},
			geometry = self.quadGeom,
			-- glUniform()'d every frame
			uniforms = {
				mvMat = self.mvMat.ptr,
				colorIndex = 0,
				pos0 = {0, 0, 0},
				pos1 = {8, 8, 8},
				drawOverrideSolid = {0, 0, 0, 0},
			},
		}
		assert(math.log(paletteSize, 2) % 1 == 0)	-- make sure our palette is a power-of-two

		-- TODO maybe ditch quadSolid* and dont' use uniforms to draw quads ... and just do this with prims ... idk
		-- but quadSolid has my ellipse/border shader so ....
--DEBUG:print('mode '..infoIndex..' triSolidObj')
		info.triSolidObj = GLSceneObject{
			program = {
				version = glslVersion,
				precision = 'best',
				vertexCode = template([[
precision highp isampler2D;
precision highp usampler2D;	// needed by #version 300 es

layout(location=0) in vec3 vertex;
out vec2 pixelPos;
uniform mat4 mvMat;

//instead of a projection matrix, here I'm going to convert from framebuffer pixel coordinates to GL homogeneous coordinates.
const float frameBufferSizeX = <?=glslnumber(frameBufferSize.x)?>;
const float frameBufferSizeY = <?=glslnumber(frameBufferSize.y)?>;

void main() {
	gl_Position = mvMat * vec4(vertex, 1.);
	pixelPos = gl_Position.xy;
	gl_Position.xy *= vec2(2. / frameBufferSizeX, 2. / frameBufferSizeY);
	gl_Position.xy -= 1.;
}
]],				{
					glslnumber = glslnumber,
					frameBufferSize = frameBufferSize,
				}),
				fragmentCode = template([[
precision highp isampler2D;
precision highp usampler2D;	// needed by #version 300 es

in vec2 pixelPos;
layout(location=0) out <?=fragType?> fragColor;

uniform uint colorIndex;

uniform <?=samplerTypeForTex(self.paletteRAM.tex)?> paletteTex;
uniform vec4 drawOverrideSolid;

float sqr(float x) { return x * x; }

<?=glslCode5551?>

void main() {
]]..info.colorOutput..[[
}
]],				{
					fragType = fragTypeForTex(info.framebufferRAM.tex),
					self = self,
					samplerTypeForTex = samplerTypeForTex,
					glslCode5551 = glslCode5551,
				}),
				uniforms = {
					paletteTex = 0,
					--mvMat = self.mvMat.ptr,
				},
			},
			texs = {self.paletteRAM.tex},
			-- glUniform()'d every frame
			uniforms = {
				mvMat = self.mvMat.ptr,
				colorIndex = 0,
				drawOverrideSolid = {0, 0, 0, 0},
			},
			vertexes = {
				dim = 3,
				useVec = true,
				count = 3,
			},
			geometry = {
				mode = gl.GL_TRIANGLES,
				count = 3,
			},
		}

--DEBUG:print('mode '..infoIndex..' quadSolidObj')
		info.quadSolidObj = GLSceneObject{
			program = {
				version = glslVersion,
				precision = 'best',
				vertexCode = template([[
precision highp isampler2D;
precision highp usampler2D;	// needed by #version 300 es

layout(location=0) in vec2 vertex;
out vec2 pixelPos;
out vec2 pcv;	// unnecessary except for the sake of 'round' ...
uniform vec4 box;	//x,y,w,h
uniform mat4 mvMat;

//instead of a projection matrix, here I'm going to convert from framebuffer pixel coordinates to GL homogeneous coordinates.
const float frameBufferSizeX = <?=glslnumber(frameBufferSize.x)?>;
const float frameBufferSizeY = <?=glslnumber(frameBufferSize.y)?>;

void main() {
	pcv = box.xy + vertex * box.zw;	// TODO should this be after transform? but then you'd have to transform the box by mvmat in the fragment shader too ...
	gl_Position = mvMat * vec4(pcv, 0., 1.);
	pixelPos = gl_Position.xy;
	gl_Position.xy *= vec2(2. / frameBufferSizeX, 2. / frameBufferSizeY);
	gl_Position.xy -= 1.;
}
]],				{
					glslnumber = glslnumber,
					frameBufferSize = frameBufferSize,
				}),
				fragmentCode = template([[
precision highp isampler2D;
precision highp usampler2D;	// needed by #version 300 es

in vec2 pcv;		// framebuffer pixel coordinates before transform , so they are sprite texels
in vec2 pixelPos;	// framebuffer pixel coordaintes after transform, so they really are framebuffer coordinates

uniform vec4 box;	//x,y,w,h

layout(location=0) out <?=fragType?> fragColor;

<?=glslCode5551?>

uniform bool borderOnly;
uniform bool round;

uniform uint colorIndex;

uniform <?=samplerTypeForTex(self.paletteRAM.tex)?> paletteTex;
uniform vec4 drawOverrideSolid;

float sqr(float x) { return x * x; }

float lenSq(vec2 v) { return dot(v,v); }

void main() {
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
		vec2 delta = pcv - center;
		//if (box.w < box.z) {					// idk why I was using this?
		if (abs(delta.y) > abs(delta.x)) {		// good for doing proper ellipse borders.
			// top/bottom quadrant
			float by = radius.y * sqrt(1. - sqr(delta.x / radius.x));
			if (delta.y > by || delta.y < -by) discard;
			if (borderOnly) {
				// TODO think this through
				// calculate screen space epsilon at this point
				//float eps = abs(dFdy(pcv.y));
				// more solid for 3D
				float eps = sqrt(lenSq(dFdx(pcv))+lenSq(dFdy(pcv)));
				//float eps = length(vec2(dFdx(pcv.x), dFdy(pcv.y)));
				//float eps = max(abs(dFdx(pcv.x)),abs(dFdy(pcv.y)));
				if (delta.y < by-eps && delta.y > -by+eps) discard;
			}
		} else {
			// left/right quadrant
			float bx = radius.x * sqrt(1. - sqr(delta.y / radius.y));
			if (delta.x > bx || delta.x < -bx) discard;
			if (borderOnly) {
				// calculate screen space epsilon at this point
				//float eps = abs(dFdx(pcv.x));
				// more solid for 3D
				float eps = sqrt(lenSq(dFdx(pcv))+lenSq(dFdy(pcv)));
				//float eps = length(vec2(dFdx(pcv.x), dFdy(pcv.y)));
				//float eps = max(abs(dFdx(pcv.x)),abs(dFdy(pcv.y)));
				if (delta.x < bx-eps && delta.x > -bx+eps) discard;
			}
		}
	} else {
		if (borderOnly) {
			// calculate screen space epsilon at this point
			//vec2 eps = abs(vec2(dFdx(pcv.x), dFdy(pcv.y)));
			float eps = sqrt(lenSq(dFdx(pcv))+lenSq(dFdy(pcv)));
			//float eps = length(vec2(dFdx(pcv.x), dFdy(pcv.y)));
			//float eps = max(abs(dFdx(pcv.x)), abs(dFdy(pcv.y)));

			if (pcv.x > box.x+eps
				&& pcv.x < box.x+box.z-eps
				&& pcv.y > box.y+eps
				&& pcv.y < box.y+box.w-eps
			) discard;
		}
		// else default solid rect
	}
]]..info.colorOutput..[[
}
]],				{
					fragType = fragTypeForTex(info.framebufferRAM.tex),
					self = self,
					samplerTypeForTex = samplerTypeForTex,
					glslCode5551 = glslCode5551,
				}),
				uniforms = {
					paletteTex = 0,
					borderOnly = false,
					round = false,
					--mvMat = self.mvMat.ptr,
				},
			},
			texs = {self.paletteRAM.tex},
			geometry = self.quadGeom,
			-- glUniform()'d every frame
			uniforms = {
				mvMat = self.mvMat.ptr,
				colorIndex = 0,
				box = {0, 0, 8, 8},
				drawOverrideSolid = {0, 0, 0, 0},
			},
		}

		local spriteProgram = GLProgram{
			version = glslVersion,
			precision = 'best',
			vertexCode = template([[
precision highp isampler2D;
precision highp usampler2D;	// needed by #version 300 es

in vec2 vertex;
in vec2 texcoord;
out vec2 tcv;
out vec2 pixelPos;

uniform mat4 mvMat;

const float frameBufferSizeX = <?=glslnumber(frameBufferSize.x)?>;
const float frameBufferSizeY = <?=glslnumber(frameBufferSize.y)?>;

void main() {
	tcv = texcoord;
	gl_Position = mvMat * vec4(vertex, 0., 1.);
	pixelPos = gl_Position.xy;
	gl_Position.xy *= vec2(2. / frameBufferSizeX, 2. / frameBufferSizeY);
	gl_Position.xy -= 1.;
}
]],			{
				glslnumber = glslnumber,
				frameBufferSize = frameBufferSize,
			}),
			fragmentCode = template([[
precision highp isampler2D;
precision highp usampler2D;	// needed by #version 300 es

in vec2 tcv;
in vec2 pixelPos;

layout(location=0) out <?=fragType?> fragColor;

//For now this is an integer added to the 0-15 4-bits of the sprite tex.
//You can set the top 4 bits and it'll work just like OR'ing the high color index nibble.
//Or you can set it to low numbers and use it to offset the palette.
//Should this be high bits? or just an offset to OR? or to add?
uniform uint paletteIndex;

// Reads 4 bits from wherever shift location you provide.
uniform <?=samplerTypeForTex(self.spriteSheetRAM.tex)?> sheetTex;

// Specifies which bit to read from at the sprite.
//  0 = read sprite low nibble.
//  4 = read sprite high nibble.
//  other = ???
uniform uint spriteBit;

// specifies the mask after shifting the sprite bit
//  0x01u = 1bpp
//  0x03u = 2bpp
//  0x07u = 3bpp
//  0x0Fu = 4bpp
//  0xFFu = 8bpp
uniform uint spriteMask;

// Specifies which colorIndex to use as transparency.
// This is the value of the sprite texel post sprite bit shift & mask, but before applying the paletteIndex shift / high bits.
// If you want fully opaque then just choose an oob color index.
uniform uint transparentIndex;

uniform <?=samplerTypeForTex(self.paletteRAM.tex)?> paletteTex;

uniform vec4 drawOverrideSolid;

<?=glslCode5551?>

void main() {
<? if useSamplerUInt then ?>
	uint colorIndex = ]]
		..readTex{
			tex = self.spriteSheetRAM.tex,
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

<?=info.colorOutput?>

<? if fragType == 'uvec4' then ?>
	if (fragColor.a == 0u) discard;
<? else ?>
	if (fragColor.a < .5) discard;
<? end ?>

<? else ?>

	float colorIndexNorm = ]]
		..readTex{
			tex = self.spriteSheetRAM.tex,
			texvar = 'sheetTex',
			tc = 'tcv / vec2(textureSize(sheetTex))',
			from = 'vec2',
			to = 'vec4',
		}
..[[.r;
	uint colorIndex = uint(colorIndexNorm * 255. + .5);
	colorIndex >>= spriteBit;
	colorIndex &= spriteMask;
	if (colorIndex == transparentIndex) discard;
	colorIndex += paletteIndex;
<?=info.colorOutput?>
<? end ?>
}
]], 		{
				glslnumber = glslnumber,
				fragType = fragTypeForTex(info.framebufferRAM.tex),
				useSamplerUInt = useSamplerUInt,
				self = self,
				samplerTypeForTex = samplerTypeForTex,
				info = info,
				glslCode5551 = glslCode5551,
			}),
			uniforms = {
				sheetTex = 0,
				paletteTex = 1,
				paletteIndex = 0,
				transparentIndex = -1,
				spriteBit = 0,
				spriteMask = 0xFF,
				--mvMat = self.mvMat.ptr,
			},
		}:useNone()

		-- HMM..........
		-- this is an identical copy of spriteProgram
		-- except that the spriteBit is read from an attribute instead of a uniform
		-- how can I fix all this ...
		-- maybe I should use 1/8th steps of the x variable for the bit?
		--  or 1/2 steps for 4bpp ... same as Pico8 and Tic80
		-- and then floor() the inputs?
		-- and then ... that'd make transforms a bigger mess ...
		-- ... or maybe I should use texcoord.z as the sprite bit always ?
		-- or use a separate spriteBit attr always?
		-- ....HMMMMMMMMMMMM
		local drawTextProgram = GLProgram{
			version = glslVersion,
			precision = 'best',
			vertexCode = template([[
precision highp isampler2D;
precision highp usampler2D;	// needed by #version 300 es

in vec2 vertex;
in vec2 texcoord;
in uint spriteBitAttr;
out vec2 tcv;
out vec2 pixelPos;
flat out uint spriteBit;

uniform mat4 mvMat;

const float frameBufferSizeX = <?=glslnumber(frameBufferSize.x)?>;
const float frameBufferSizeY = <?=glslnumber(frameBufferSize.y)?>;

void main() {
	tcv = texcoord.xy;
	gl_Position = mvMat * vec4(vertex.xy, 0., 1.);
	spriteBit = spriteBitAttr;
	pixelPos = gl_Position.xy;
	gl_Position.xy *= vec2(2. / frameBufferSizeX, 2. / frameBufferSizeY);
	gl_Position.xy -= 1.;
}
]],			{
				glslnumber = glslnumber,
				frameBufferSize = frameBufferSize,
			}),
			fragmentCode = template([[
precision highp isampler2D;
precision highp usampler2D;	// needed by #version 300 es

in vec2 tcv;
in vec2 pixelPos;

// Specifies which bit to read from at the sprite.
//  0 = read sprite low nibble.
//  4 = read sprite high nibble.
//  other = ???
flat in uint spriteBit;

layout(location=0) out <?=fragType?> fragColor;

//For now this is an integer added to the 0-15 4-bits of the sprite tex.
//You can set the top 4 bits and it'll work just like OR'ing the high color index nibble.
//Or you can set it to low numbers and use it to offset the palette.
//Should this be high bits? or just an offset to OR? or to add?
uniform uint paletteIndex;

// Reads 4 bits from wherever shift location you provide.
uniform <?=samplerTypeForTex(self.spriteSheetRAM.tex)?> sheetTex;

// specifies the mask after shifting the sprite bit
//  0x01u = 1bpp
//  0x03u = 2bpp
//  0x07u = 3bpp
//  0x0Fu = 4bpp
//  0xFFu = 8bpp
uniform uint spriteMask;

// Specifies which colorIndex to use as transparency.
// This is the value of the sprite texel post sprite bit shift & mask, but before applying the paletteIndex shift / high bits.
// If you want fully opaque then just choose an oob color index.
uniform uint transparentIndex;

uniform <?=samplerTypeForTex(self.paletteRAM.tex)?> paletteTex;

uniform vec4 drawOverrideSolid;

<?=glslCode5551?>

void main() {
<? if useSamplerUInt then ?>
	uint colorIndex = ]]
		..readTex{
			tex = self.spriteSheetRAM.tex,
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

<?=info.colorOutput?>

<? if fragType == 'uvec4' then ?>
	if (fragColor.a == 0u) discard;
<? else ?>
	if (fragColor.a < .5) discard;
<? end ?>

<? else ?>

	float colorIndexNorm = ]]
		..readTex{
			tex = self.spriteSheetRAM.tex,
			texvar = 'sheetTex',
			tc = 'tcv / vec2(textureSize(sheetTex))',
			from = 'vec2',
			to = 'vec4',
		}
..[[.r;
	uint colorIndex = uint(colorIndexNorm * 255. + .5);
	colorIndex >>= spriteBit;
	colorIndex &= spriteMask;
	if (colorIndex == transparentIndex) discard;
	colorIndex += paletteIndex;
<?=info.colorOutput?>
<? end ?>
}
]], 		{
				glslnumber = glslnumber,
				fragType = fragTypeForTex(info.framebufferRAM.tex),
				useSamplerUInt = useSamplerUInt,
				self = self,
				samplerTypeForTex = samplerTypeForTex,
				info = info,
				glslCode5551 = glslCode5551,
			}),
			uniforms = {
				sheetTex = 0,
				paletteTex = 1,
				paletteIndex = 0,
				transparentIndex = -1,
				spriteBit = 0,
				spriteMask = 0xFF,
				--mvMat = self.mvMat.ptr,
			},
		}:useNone()

		info.drawTextObj = GLSceneObject{
			-- make some vertex buffers for text
			program = drawTextProgram,
			vertexes = {
				count = 6,
				dim = 2,
				useVec = true,
				usage = gl.GL_DYNAMIC_DRAW,
			},
			attrs = {
				texcoord = {
					buffer = {
						count = 6,
						dim = 2,
						useVec = true,
						usage = gl.GL_DYNAMIC_DRAW,
					},
				},
				spriteBitAttr = {
					buffer = {
						count = 6,
						ctype = 'uint8_t',
						type = gl.GL_UNSIGNED_BYTE,
						dim = 1,
						useVec = true,
						usage = gl.GL_DYNAMIC_DRAW,
					},
					type = gl.GL_UNSIGNED_BYTE,
					dim = 1,
					-- can divisor exceed the geometry # of vtxs?
					--divisor = 6,	-- two triangles = 1 quad
					--divisor = 3,
				},
			},
			geometry = {
				mode = gl.GL_TRIANGLES,	-- QUADS would be nice ...
				count = 6,
			},
		}

--DEBUG:print('mode '..infoIndex..' quadSpriteObj')
		info.quadSpriteObj = GLSceneObject{
			program = spriteProgram,
			texs = {
				self.spriteSheetRAM.tex,
				self.paletteRAM.tex,
			},
			vertexes = {
				dim = 2,
				useVec = true,
				count = 4,
				usage = gl.GL_DYNAMIC_DRAW,
			},
			attrs = {
				texcoord = {
					buffer = {
						dim = 2,
						useVec = true,
						count = 4,
						usage = gl.GL_DYNAMIC_DRAW,
					},
				},
			},
			geometry = {
				mode = gl.GL_TRIANGLE_STRIP,
				count = 4,
			},
			-- glUniform()'d every frame
			uniforms = {
				mvMat = self.mvMat.ptr,
				box = {0, 0, 8, 8},
				tcbox = {0, 0, 1, 1},
				drawOverrideSolid = {0, 0, 0, 0},
			},
		}

		info.triSpriteObj = GLSceneObject{
			program = spriteProgram,
			texs = {
				self.spriteSheetRAM.tex,
				self.paletteRAM.tex,
			},
			vertexes = {
				dim = 3,
				useVec = true,
				count = 3,
				usage = gl.GL_DYNAMIC_DRAW,
			},
			attrs = {
				texcoord = {
					buffer = {
						dim = 2,
						useVec = true,
						count = 3,
						usage = gl.GL_DYNAMIC_DRAW,
					},
				},
			},
			geometry = {
				mode = gl.GL_TRIANGLES,
				count = 3,
			},
			-- glUniform()'d every frame
			uniforms = {
				mvMat = self.mvMat.ptr,
				drawOverrideSolid = {0, 0, 0, 0},
			},
		}

--DEBUG:print('mode '..infoIndex..' quadMapObj')
		info.quadMapObj = GLSceneObject{
			program = {
				version = glslVersion,
				precision = 'best',
				vertexCode = template([[
precision highp isampler2D;
precision highp usampler2D;	// needed by #version 300 es

in vec2 vertex;
out vec2 tcv;
out vec2 pixelPos;
uniform vec4 box;		//x y w h
uniform vec4 tcbox;		//tx ty tw th
uniform mat4 mvMat;

const float frameBufferSizeX = <?=glslnumber(frameBufferSize.x)?>;
const float frameBufferSizeY = <?=glslnumber(frameBufferSize.y)?>;

void main() {
	tcv = tcbox.xy + vertex * tcbox.zw;
	vec2 pc = box.xy + vertex * box.zw;
	gl_Position = mvMat * vec4(pc, 0., 1.);
	pixelPos = gl_Position.xy;
	gl_Position.xy *= vec2(2. / frameBufferSizeX, 2. / frameBufferSizeY);
	gl_Position.xy -= 1.;
}
]],				{
					glslnumber = glslnumber,
					frameBufferSize = frameBufferSize,
				}),
				fragmentCode = template([[
precision highp isampler2D;
precision highp usampler2D;	// needed by #version 300 es

in vec2 tcv;
in vec2 pixelPos;
layout(location=0) out <?=fragType?> fragColor;

// tilemap texture
uniform uint mapIndexOffset;
uniform int draw16Sprites;	 	//0 = draw 8x8 sprites, 1 = draw 16x16 sprites
uniform <?=samplerTypeForTex(self.tilemapRAM.tex)?> tilemapTex;
uniform <?=samplerTypeForTex(self.tileSheetRAM.tex)?> tileSheetTex;
uniform <?=samplerTypeForTex(self.paletteRAM.tex)?> paletteTex;

const uint tilemapSizeX = <?=tilemapSize.x?>u;
const uint tilemapSizeY = <?=tilemapSize.y?>u;

uniform vec4 drawOverrideSolid;

<?=glslCode5551?>

void main() {
#if 0	// do it in float
	int tileSize = 1 << (3 + draw16Sprites);
	float tileSizef = float(tileSize);
	int mask = tileSize - 1;

	// convert from input normalized coordinates to tilemap texel coordinates
	// [0, tilemapSize)^2
	vec2 tcf = vec2(
		.5 + tcv.x * float(tilemapSizeX << draw16Sprites),
		.5 + tcv.y * float(tilemapSizeY << draw16Sprites)
	);
	tcf /= tileSizef;

	// convert to map texel coordinate
	// [0, tilemapSize)^2
	// mod 256 ? maybe?
	// integer part of tcf

	//read the tileIndex in tilemapTex at tcf
	//tilemapTex is R16, so red channel should be 16bpp (right?)
	// how come I don't trust that and think I'll need to switch this to RG8 ...
	int tileIndex = int(]]..readTex{
		tex = self.tilemapRAM.tex,
		texvar = 'tilemapTex',
		tc = '(floor(tcf) + .5) / vec2('..textureSize'tilemapTex'..')',
		from = 'vec2',
		to = 'uvec4',
	}..[[.r);

	//[0, 31)^2 = 5 bits for tile tex sprite x, 5 bits for tile tex sprite y
	ivec2 tileIndexTC = ivec2(
		tileIndex & 0x1F,				// tilemap bits 0..4
		(tileIndex >> 5) & 0x1F			// tilemap bits 5..9
	);
	int palHi = (tileIndex >> 10) & 0xF;	// tilemap bits 10..13

	vec2 tcfp = tcf - floor(tcf);
	if ((tileIndex & (1<<14)) != 0) tcfp.x = 1. - tcfp.x;	// tilemap bit 14
	if ((tileIndex & (1<<15)) != 0) tcfp.y = 1. - tcfp.y;	// tilemap bit 15

	// [0, spriteSize)^2
	ivec2 tileTexTC = ivec2(
		int(tcfp.x * tileSizef) ^ (tileIndexTC.x << 3),
		int(tcfp.y * tileSizef) ^ (tileIndexTC.y << 3)
	);

	// tileSheetTex is R8 indexing into our palette ...
	uint colorIndex = ]]..readTex{
		tex = self.tileSheetRAM.tex,
		texvar = 'tileSheetTex',
		tc = 'tileTexTC',
		from = 'ivec2',
		to = 'uvec4',
	}..[[.r;

#else	//do it in int

	// convert from input normalized coordinates to tilemap texel coordinates
	// [0, tilemapSize)^2
	ivec2 tci = ivec2(
		int(tcv.x * float(tilemapSizeX << draw16Sprites)),
		int(tcv.y * float(tilemapSizeY << draw16Sprites))
	);

	// convert to map texel coordinate
	// [0, tilemapSize)^2
	ivec2 tileTC = ivec2(
		(tci.x >> (3 + draw16Sprites)) & 0xFF,
		(tci.y >> (3 + draw16Sprites)) & 0xFF
	);

	//read the tileIndex in tilemapTex at tileTC
	//tilemapTex is R16, so red channel should be 16bpp (right?)
	// how come I don't trust that and think I'll need to switch this to RG8 ...
	int tileIndex = int(]]..readTex{
		tex = self.tilemapRAM.tex,
		texvar = 'tilemapTex',
		tc = 'tileTC',
		from = 'ivec2',
		to = 'uvec4',
	}..[[.r);

	//[0, 31)^2 = 5 bits for tile tex sprite x, 5 bits for tile tex sprite y
	ivec2 tileIndexTC = ivec2(
		tileIndex & 0x1F,				// tilemap bits 0..4
		(tileIndex >> 5) & 0x1F			// tilemap bits 5..9
	);
	int palHi = (tileIndex >> 10) & 0xF;	// tilemap bits 10..13
	if ((tileIndex & (1<<14)) != 0) tci.x = ~tci.x;	// tilemap bit 14
	if ((tileIndex & (1<<15)) != 0) tci.y = ~tci.y;	// tilemap bit 15

	int mask = (1 << (3 + draw16Sprites)) - 1;
	// [0, spriteSize)^2
	ivec2 tileTexTC = ivec2(
		(tci.x & mask) ^ (tileIndexTC.x << 3),
		(tci.y & mask) ^ (tileIndexTC.y << 3)
	);

	// tileSheetTex is R8 indexing into our palette ...
	uint colorIndex = ]]..readTex{
		tex = self.tileSheetRAM.tex,
		texvar = 'tileSheetTex',
		tc = 'tileTexTC',
		from = 'ivec2',
		to = 'uvec4',
	}..[[.r;

#endif


	colorIndex += uint(palHi) << 4;
]]..info.colorOutput..[[
	if (fragColor.a == <?=fragType == 'uvec4' and '0u' or '0.'?>) discard;
}
]],				{
					fragType = fragTypeForTex(info.framebufferRAM.tex),
					self = self,
					samplerTypeForTex = samplerTypeForTex,
					glslnumber = glslnumber,
					spriteSheetSize = spriteSheetSize,
					tilemapSize = tilemapSize,
					glslCode5551 = glslCode5551,
				}),
				uniforms = {
					tilemapTex = 0,
					tileSheetTex = 1,
					paletteTex = 2,
					mapIndexOffset = 0,
					--mvMat = self.mvMat.ptr,
				},
			},
			texs = {
				self.tilemapRAM.tex,
				self.tileSheetRAM.tex,
				self.paletteRAM.tex,
			},
			geometry = self.quadGeom,
			-- glUniform()'d every frame
			uniforms = {
				mvMat = self.mvMat.ptr,
				box = {0, 0, 8, 8},
				tcbox = {0, 0, 1, 1},
				drawOverrideSolid = {0, 0, 0, 0},
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
	}:unbind()

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
		- 10 bits of lookup into spriteSheetRAM
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
	self.framebufferRGB565RAM:checkDirtyGPU()
	self.framebufferIndexRAM:checkDirtyGPU()
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
	self.framebufferRGB565RAM:checkDirtyCPU()
	self.framebufferIndexRAM:checkDirtyCPU()
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
	self.framebufferRGB565RAM:updateAddr(framebufferAddr)
	self.framebufferIndexRAM:updateAddr(framebufferAddr)
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
			:unbind()
		sheetRAM.dirtyCPU = false
	end
	self.tilemapRAM.tex:bind()
		:subimage()
		:unbind()
	self.tilemapRAM.dirtyCPU = false
	self.paletteRAM.tex:bind()
		:subimage()
		:unbind()
	self.paletteRAM.dirtyCPU = false
	self.fontRAM.tex:bind()
		:subimage()
		:unbind()
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
	self:setClipRect(0, 0, 0xff, 0xff)

	-- hmm, this matident isn't working ,but if you put one in your init code then it does work ... why ...
	self:matident()
--DEBUG:print'App:resetVideo done'
end

-- flush anything from gpu to cpu
function AppVideo:checkDirtyGPU()
	for _,sheetRAM in ipairs(self.sheetRAMs) do
		sheetRAM:checkDirtyGPU()
	end
	self.tilemapRAM:checkDirtyGPU()
	self.paletteRAM:checkDirtyGPU()
	self.fontRAM:checkDirtyGPU()
	self.framebufferRAM:checkDirtyGPU()
end

function AppVideo:setDirtyCPU()
	for _,sheetRAM in ipairs(self.sheetRAMs) do
		sheetRAM.dirtyCPU = true
	end
	self.tilemapRAM.dirtyCPU = true
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
	local info = self.videoModeInfo[mode]
	if info then
		self.framebufferRAM = info.framebufferRAM
		self.blitScreenObj = info.blitScreenObj
		self.lineSolidObj = info.lineSolidObj
		self.triSolidObj = info.triSolidObj
		self.quadSolidObj = info.quadSolidObj
		self.quadSpriteObj = info.quadSpriteObj
		self.triSpriteObj = info.triSpriteObj
		self.quadMapObj = info.quadMapObj
		self.drawTextObj = info.drawTextObj
	else
		error("unknown video mode "..tostring(mode))
	end
	self.blitScreenObj.texs[1] = self.framebufferRAM.tex

	self:setFramebufferTex(self.framebufferRAM.tex)
	self.currentVideoMode = mode
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


-- convert to/from our fixed-point storage in RAM and the float matrix that the matrix library uses
function AppVideo:mvMatToRAM()
	for i=0,15 do
		self.ram.mvMat[i] = self.mvMat.ptr[i] * mvMatScale
	end
end
function AppVideo:mvMatFromRAM()
	for i=0,15 do
		self.mvMat.ptr[i] = self.ram.mvMat[i] / mvMatScale
	end
end

function AppVideo:resetFont()
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
	round
)
	self.paletteRAM:checkDirtyCPU() -- before any GPU op that uses palette...
	self.framebufferRAM:checkDirtyCPU()
	self:mvMatFromRAM()	-- TODO mvMat dirtyCPU flag?

	local sceneObj = self.quadSolidObj
	local uniforms = sceneObj.uniforms

	uniforms.mvMat = self.mvMat.ptr
	uniforms.colorIndex = math.floor(colorIndex or 0)
	uniforms.borderOnly = borderOnly or false
	uniforms.round = round or false
	if w < 0 then x,w = x+w,-w end
	if h < 0 then y,h = y+h,-h end
	settable(uniforms.box, x, y, w, h)

	local blendSolidR, blendSolidG, blendSolidB = rgba5551_to_rgba8888_4ch(self.ram.blendColor)
	settable(uniforms.drawOverrideSolid, blendSolidR/255, blendSolidG/255, blendSolidB/255, self.drawOverrideSolidA)

	sceneObj:draw()
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
	self.paletteRAM:checkDirtyCPU() -- before any GPU op that uses palette...
	self.framebufferRAM:checkDirtyCPU()
	self:mvMatFromRAM()	-- TODO mvMat dirtyCPU flag?

	local sceneObj = self.triSolidObj
	local uniforms = sceneObj.uniforms

	uniforms.mvMat = self.mvMat.ptr
	uniforms.colorIndex = math.floor(colorIndex)

	local vtxGPU = sceneObj.attrs.vertex.buffer
	local vtxCPU = vtxGPU:beginUpdate()
	vtxCPU:emplace_back():set(x1, y1, z1)
	vtxCPU:emplace_back():set(x2, y2, z2)
	vtxCPU:emplace_back():set(x3, y3, z3)
	vtxGPU:endUpdate()

	local blendSolidR, blendSolidG, blendSolidB = rgba5551_to_rgba8888_4ch(self.ram.blendColor)
	settable(uniforms.drawOverrideSolid, blendSolidR/255, blendSolidG/255, blendSolidB/255, self.drawOverrideSolidA)

	sceneObj:draw()
	self.framebufferRAM.dirtyGPU = true
	self.framebufferRAM.changedSinceDraw = true
end

function AppVideo:drawSolidTri(x1, y1, x2, y2, x3, y3, colorIndex)
	return self:drawSolidTri3D(x1, y1, 0, x2, y2, 0, x3, y3, 0, colorIndex)
end

function AppVideo:drawSolidLine3D(x1,y1,z1,x2,y2,z2,colorIndex)
	self.paletteRAM:checkDirtyCPU() -- before any GPU op that uses palette...
	self.framebufferRAM:checkDirtyCPU()
	self:mvMatFromRAM()	-- TODO mvMat dirtyCPU flag?

	local sceneObj = self.lineSolidObj
	local uniforms = sceneObj.uniforms

	uniforms.mvMat = self.mvMat.ptr
	uniforms.colorIndex = colorIndex
	settable(uniforms.pos0, x1,y1,z1)
	settable(uniforms.pos1, x2,y2,z2)

	local blendSolidR, blendSolidG, blendSolidB = rgba5551_to_rgba8888_4ch(self.ram.blendColor)
	settable(uniforms.drawOverrideSolid, blendSolidR/255, blendSolidG/255, blendSolidB/255, self.drawOverrideSolidA)

	sceneObj:draw()
	self.framebufferRAM.dirtyGPU = true
	self.framebufferRAM.changedSinceDraw = true
end

function AppVideo:drawSolidLine(x1,y1,x2,y2,colorIndex)
	return self:drawSolidLine3D(x1,y1,0,x2,y2,0,colorIndex)
end

local mvMatCopy = ffi.new('float[16]')
function AppVideo:clearScreen(colorIndex)
	gl.glDisable(gl.GL_SCISSOR_TEST)
	-- which is faster, push/pop the matrix, or reassign the uniform?
	ffi.copy(mvMatCopy, self.mvMat.ptr, ffi.sizeof(mvMatCopy))
	self.mvMat:setIdent()
	self:mvMatToRAM()	-- need this as well
	self:drawSolidRect(
		0,
		0,
		frameBufferSize.x,
		frameBufferSize.y,
		colorIndex or 0)
	gl.glEnable(gl.GL_SCISSOR_TEST)
	ffi.copy(self.mvMat.ptr, mvMatCopy, ffi.sizeof(mvMatCopy))
	self:mvMatToRAM()	-- need this as well
end

function AppVideo:setClipRect(x, y, w, h)
	-- NOTICE the ram is only useful for reading, not writing, as it won't invoke a glScissor call
	-- ... should I change that?
	packptr(4, self.ram.clipRect, x, y, w, h)
	gl.glScissor(
		self.ram.clipRect[0],
		self.ram.clipRect[1],
		self.ram.clipRect[2]+1,
		self.ram.clipRect[3]+1)
end

-- for when we blend against solid colors, these go to the shaders to output it
AppVideo.drawOverrideSolidR = 0
AppVideo.drawOverrideSolidG = 0
AppVideo.drawOverrideSolidB = 0
AppVideo.drawOverrideSolidA = 0
function AppVideo:setBlendMode(blendMode)
	if blendMode >= 8 then
		self.drawOverrideSolidA = 0
		gl.glDisable(gl.GL_BLEND)
		return
	end

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

--[[
'lower level' than 'drawQuad'
accepts a texture as arguments, so the UI/Editor can draw with textures outside of the RAM
doesn't care about tex dirty (cuz its probably a tex outside RAM)
doesn't care about framebuffer dirty (cuz its probably the editor framebuffer)
--]]
function AppVideo:drawQuadTex(
	x, y, w, h,	-- quad box
	tx, ty, tw, th,	-- texcoord bbox
	sheetTex,
	paletteTex,
	paletteIndex,
	transparentIndex,
	spriteBit,
	spriteMask
)
	paletteIndex = paletteIndex or 0
	transparentIndex = transparentIndex or -1
	spriteBit = spriteBit or 0
	spriteMask = spriteMask or 0xFF

	local sceneObj = self.quadSpriteObj
	local uniforms = sceneObj.uniforms
	sceneObj.texs[1] = sheetTex
	sceneObj.texs[2] = paletteTex

	-- using attributes runs a bit slower than using uniforms.  I can't tell without removing the 60fps cap and I'm too lazy to remove that and test it.
	local vertex = sceneObj.attrs.vertex.buffer.vec
	vertex.v[0].x = x
	vertex.v[0].y = y
	vertex.v[1].x = x+w
	vertex.v[1].y = y
	vertex.v[2].x = x
	vertex.v[2].y = y+h
	vertex.v[3].x = x+w
	vertex.v[3].y = y+h
	local texcoord = sceneObj.attrs.texcoord.buffer.vec
	texcoord.v[0].x = tx
	texcoord.v[0].y = ty
	texcoord.v[1].x = tx+tw
	texcoord.v[1].y = ty
	texcoord.v[2].x = tx
	texcoord.v[2].y = ty+th
	texcoord.v[3].x = tx+tw
	texcoord.v[3].y = ty+th

	sceneObj.attrs.vertex.buffer
		:bind()
		:updateData(0, vertex:getNumBytes())
	sceneObj.attrs.texcoord.buffer
		:bind()
		:updateData(0, texcoord:getNumBytes())
		:unbind()

	uniforms.mvMat = self.mvMat.ptr
	uniforms.paletteIndex = paletteIndex	-- user has to specify high-bits
	uniforms.transparentIndex = transparentIndex
	uniforms.spriteBit = spriteBit
	uniforms.spriteMask = spriteMask

	local blendSolidR, blendSolidG, blendSolidB = rgba5551_to_rgba8888_4ch(self.ram.blendColor)
	settable(uniforms.drawOverrideSolid, blendSolidR/255, blendSolidG/255, blendSolidB/255, self.drawOverrideSolidA)

	sceneObj:draw()
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
	spriteMask
)
	local sheetRAM = self.sheetRAMs[sheetIndex+1]
	if not sheetRAM then return end
	if sheetRAM.checkDirtyCPU then			-- some editor textures are separate of the 'hardware' and don't possess this
		sheetRAM:checkDirtyCPU()			-- before we read from the sprite tex, make sure we have most updated copy
	end
	self.paletteRAM:checkDirtyCPU() 		-- before any GPU op that uses palette...
	self.framebufferRAM:checkDirtyCPU()		-- before we write to framebuffer, make sure we have most updated copy
	self:mvMatFromRAM()	-- TODO mvMat dirtyCPU flag?

	self:drawQuadTex(
		x, y, w, h,
		tx / 256, ty / 256, tw / 256, th / 256,
		sheetRAM.tex, self.paletteRAM.tex, paletteIndex, transparentIndex, spriteBit, spriteMask)

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
	paletteIndex = paletteIndex or 0
	transparentIndex = transparentIndex or -1
	spriteBit = spriteBit or 0
	spriteMask = spriteMask or 0xFF

	local sheetRAM = self.sheetRAMs[sheetIndex+1]
	if not sheetRAM then return end
	if sheetRAM.checkDirtyCPU then			-- some editor textures are separate of the 'hardware' and don't possess this
		sheetRAM:checkDirtyCPU()			-- before we read from the sprite tex, make sure we have most updated copy
	end
	self.paletteRAM:checkDirtyCPU() 		-- before any GPU op that uses palette...
	self.framebufferRAM:checkDirtyCPU()		-- before we write to framebuffer, make sure we have most updated copy
	self:mvMatFromRAM()	-- TODO mvMat dirtyCPU flag?

	local sceneObj = self.triSpriteObj
	sceneObj.texs[1] = sheetRAM.tex
	sceneObj.texs[2] = self.paletteRAM.tex

	local vertex = sceneObj.attrs.vertex.buffer.vec
	vertex.v[0].x = x1
	vertex.v[0].y = y1
	vertex.v[0].z = z1
	vertex.v[1].x = x2
	vertex.v[1].y = y2
	vertex.v[1].z = z2
	vertex.v[2].x = x3
	vertex.v[2].y = y3
	vertex.v[2].z = z3
	local texcoord = sceneObj.attrs.texcoord.buffer.vec
	texcoord.v[0].x = u1
	texcoord.v[0].y = v1
	texcoord.v[1].x = u2
	texcoord.v[1].y = v2
	texcoord.v[2].x = u3
	texcoord.v[2].y = v3

	sceneObj.attrs.vertex.buffer
		:bind()
		:updateData(0, vertex:getNumBytes())
	sceneObj.attrs.texcoord.buffer
		:bind()
		:updateData(0, texcoord:getNumBytes())
		:unbind()
	-- ... or interleave xyzuv and do one update?

	-- which is faster?
	-- uniforms to do linear transform of a tri's coordiantes?
	-- or writing the coords to cpu and update the buffer?
	local uniforms = sceneObj.uniforms
	uniforms.mvMat = self.mvMat.ptr
	uniforms.paletteIndex = paletteIndex	-- user has to specify high-bits
	uniforms.transparentIndex = transparentIndex
	uniforms.spriteBit = spriteBit
	uniforms.spriteMask = spriteMask

	local blendSolidR, blendSolidG, blendSolidB = rgba5551_to_rgba8888_4ch(self.ram.blendColor)
	settable(uniforms.drawOverrideSolid, blendSolidR/255, blendSolidG/255, blendSolidB/255, self.drawOverrideSolidA)

	sceneObj:draw()
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
	sheetIndex
)
	sheetIndex = sheetIndex or 1
	local sheetRAM = self.sheetRAMs[sheetIndex+1]
	if not sheetRAM then return end
	sheetRAM:checkDirtyCPU()	-- TODO just use multiple sprite sheets and let the map() function pick which one
	self.paletteRAM:checkDirtyCPU() 	-- before any GPU op that uses palette...
	self.tilemapRAM:checkDirtyCPU()
	self.framebufferRAM:checkDirtyCPU()
	self:mvMatFromRAM()	-- TODO mvMat dirtyCPU flag?

	tilesWide = tilesWide or 1
	tilesHigh = tilesHigh or 1
	mapIndexOffset = mapIndexOffset or 0

	local sceneObj = self.quadMapObj
	local uniforms = sceneObj.uniforms
	sceneObj.texs[1] = self.tilemapRAM.tex
	sceneObj.texs[2] = sheetRAM.tex
	sceneObj.texs[3] = self.paletteRAM.tex

	uniforms.mvMat = self.mvMat.ptr
	uniforms.mapIndexOffset = mapIndexOffset	-- user has to specify high-bits

	settable(uniforms.tcbox,
		tileX / tonumber(spriteSheetSizeInTiles.x),
		tileY / tonumber(spriteSheetSizeInTiles.y),
		tilesWide / tonumber(spriteSheetSizeInTiles.x),
		tilesHigh / tonumber(spriteSheetSizeInTiles.y)
	)
	local draw16As0or1 = draw16Sprites and 1 or 0
	uniforms.draw16Sprites = draw16As0or1
	settable(uniforms.box,
		screenX or 0,
		screenY or 0,
		tilesWide * bit.lshift(spriteSize.x, draw16As0or1),
		tilesHigh * bit.lshift(spriteSize.y, draw16As0or1)
	)

	local blendSolidR, blendSolidG, blendSolidB = rgba5551_to_rgba8888_4ch(self.ram.blendColor)
	settable(uniforms.drawOverrideSolid, blendSolidR/255, blendSolidG/255, blendSolidB/255, self.drawOverrideSolidA)

	sceneObj:draw()

	self.framebufferRAM.dirtyGPU = true
	self.framebufferRAM.changedSinceDraw = true
end

-- TODO same inlining as I just did to :drawMenuText ...
-- draw a solid background color, then draw the text transparent
-- specify an oob bgColorIndex to draw with transparent background
-- and default x, y to the last cursor position
function AppVideo:drawText(text, x, y, fgColorIndex, bgColorIndex, scaleX, scaleY)
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
	local r,g,b,a = rgba5551_to_rgba8888_4ch(self.ram.bank[0].palette[bgColorIndex])
	if a > 0 then
		local bgw = 0
		for i=1,#text do
			local ch = text:byte(i)
			local w = scaleX * self.ram.fontWidth[ch]
			bgw = bgw + w
		end
		-- TODO the ... between drawSolidRect and drawSprite is not the same...
		self:drawSolidRect(
			x0,
			y,
			bgw,
			scaleY * spriteSize.y,
			bgColorIndex
		)
	end

-- [[ drawQuad startup
	if self.fontRAM.checkDirtyCPU then			-- some editor textures are separate of the 'hardware' and don't possess this
		self.fontRAM:checkDirtyCPU()			-- before we read from the sprite tex, make sure we have most updated copy
	end
	self.paletteRAM:checkDirtyCPU() 		-- before any GPU op that uses palette...
	self.framebufferRAM:checkDirtyCPU()		-- before we write to framebuffer, make sure we have most updated copy
	self:mvMatFromRAM()	-- TODO mvMat dirtyCPU flag?
--]]

-- draw transparent-background text
	local x = x0 + 1
	y = y + 1

	local sceneObj = self.drawTextObj
	local tex0 = self.fontRAM.tex
	local tex1 = self.paletteRAM.tex
	tex0:bind(0)
	tex1:bind(1)
	sceneObj:beginUpdate()
	local vertex = sceneObj.attrs.vertex.buffer.vec
	local texcoord = sceneObj.attrs.texcoord.buffer.vec
	local spriteBitAttr = sceneObj.attrs.spriteBitAttr.buffer.vec
	local w = spriteSize.x * scaleX
	local h = spriteSize.y * scaleY
	local texSizeInTiles = fontImageSizeInTiles		-- using separate font tex
	local tw = 1 / tonumber(texSizeInTiles.x)
	local th = 1 / tonumber(texSizeInTiles.y)
	local blendSolidR, blendSolidG, blendSolidB = rgba5551_to_rgba8888_4ch(self.ram.blendColor)
	local program = sceneObj.program

	for i=1,#text do
		local ch = text:byte(i)
		local bi = bit.band(ch, 7)		-- get the bit offset
		local by = bit.rshift(ch, 3)	-- get the byte offset
		local tx = by / tonumber(texSizeInTiles.x)

		-- using attributes runs a bit slower than using uniforms.  I can't tell without removing the 60fps cap and I'm too lazy to remove that and test it.
		local v
		v = vertex:emplace_back()
		v.x = x
		v.y = y
		v = vertex:emplace_back()
		v.x = x+w
		v.y = y
		v = vertex:emplace_back()
		v.x = x
		v.y = y+h

		v = vertex:emplace_back()
		v.x = x
		v.y = y+h
		v = vertex:emplace_back()
		v.x = x+w
		v.y = y
		v = vertex:emplace_back()
		v.x = x+w
		v.y = y+h

		v = texcoord:emplace_back()
		v.x = tx
		v.y = 0
		v = texcoord:emplace_back()
		v.x = tx+tw
		v.y = 0
		v = texcoord:emplace_back()
		v.x = tx
		v.y = th

		v = texcoord:emplace_back()
		v.x = tx
		v.y = th
		v = texcoord:emplace_back()
		v.x = tx+tw
		v.y = 0
		v = texcoord:emplace_back()
		v.x = tx+tw
		v.y = th

		spriteBitAttr:emplace_back()[0] = bi
		-- [[ TODO get divisor working
		spriteBitAttr:emplace_back()[0] = bi
		spriteBitAttr:emplace_back()[0] = bi
		spriteBitAttr:emplace_back()[0] = bi
		spriteBitAttr:emplace_back()[0] = bi
		spriteBitAttr:emplace_back()[0] = bi
		--]]

		x = x + self.ram.fontWidth[ch] * scaleX
	end

	sceneObj:endUpdate()
	local programUniforms = program.uniforms
	program:use()
	gl.glUniformMatrix4fv(programUniforms.mvMat.loc, 1, false, self.mvMat.ptr)
	gl.glUniform1i(programUniforms.sheetTex.loc, 0)
	gl.glUniform1i(programUniforms.paletteTex.loc, 1)
	gl.glUniform1ui(programUniforms.paletteIndex.loc, fgColorIndex-1)
	gl.glUniform1ui(programUniforms.transparentIndex.loc, 0)
	gl.glUniform1ui(programUniforms.spriteMask.loc, 1)
	-- this won't be there for 8bpp indexed mode:
	if programUniforms.drawOverrideSolid then
		gl.glUniform4f(programUniforms.drawOverrideSolid.loc, blendSolidR/255, blendSolidG/255, blendSolidB/255, self.drawOverrideSolidA)
	end
	sceneObj:enableAndSetAttrs()
	sceneObj.geometry:draw()
	sceneObj:disableAttrs()
	program:useNone()
	tex1:unbind(1)
	tex0:unbind(0)

-- [[ drawQuad shutdown
	self.framebufferRAM.dirtyGPU = true
	self.framebufferRAM.changedSinceDraw = true
--]]

	return x - x0
end

-- same as drawText but using the menu font and palette
function AppVideo:drawMenuText(text, x, y, fgColorIndex, bgColorIndex, scaleX, scaleY)
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

	local sceneObj = self.drawTextObj
	local tex0 = self.fontMenuTex
	local tex1 = self.paletteMenuTex
	tex0:bind(0)
	tex1:bind(1)
	sceneObj:beginUpdate()
	local vertex = sceneObj.attrs.vertex.buffer.vec
	local texcoord = sceneObj.attrs.texcoord.buffer.vec
	local spriteBitAttr = sceneObj.attrs.spriteBitAttr.buffer.vec
	local w = spriteSize.x * scaleX
	local h = spriteSize.y * scaleY
	local texSizeInTiles = fontImageSizeInTiles		-- using separate font tex
	local tw = 1 / tonumber(texSizeInTiles.x)
	local th = 1 / tonumber(texSizeInTiles.y)
	local blendSolidR, blendSolidG, blendSolidB = rgba5551_to_rgba8888_4ch(self.ram.blendColor)
	local program = sceneObj.program

	for i=1,#text do
		local ch = text:byte(i)
		local bi = bit.band(ch, 7)		-- get the bit offset
		local by = bit.rshift(ch, 3)	-- get the byte offset
		local tx = by / tonumber(texSizeInTiles.x)

		-- using attributes runs a bit slower than using uniforms.  I can't tell without removing the 60fps cap and I'm too lazy to remove that and test it.
		local v
		v = vertex:emplace_back()
		v.x = x
		v.y = y
		v = vertex:emplace_back()
		v.x = x+w
		v.y = y
		v = vertex:emplace_back()
		v.x = x
		v.y = y+h

		v = vertex:emplace_back()
		v.x = x
		v.y = y+h
		v = vertex:emplace_back()
		v.x = x+w
		v.y = y
		v = vertex:emplace_back()
		v.x = x+w
		v.y = y+h

		v = texcoord:emplace_back()
		v.x = tx
		v.y = 0
		v = texcoord:emplace_back()
		v.x = tx+tw
		v.y = 0
		v = texcoord:emplace_back()
		v.x = tx
		v.y = th

		v = texcoord:emplace_back()
		v.x = tx
		v.y = th
		v = texcoord:emplace_back()
		v.x = tx+tw
		v.y = 0
		v = texcoord:emplace_back()
		v.x = tx+tw
		v.y = th

		spriteBitAttr:emplace_back()[0] = bi
		-- [[ TODO get divisor working
		spriteBitAttr:emplace_back()[0] = bi
		spriteBitAttr:emplace_back()[0] = bi
		spriteBitAttr:emplace_back()[0] = bi
		spriteBitAttr:emplace_back()[0] = bi
		spriteBitAttr:emplace_back()[0] = bi
		--]]

		x = x + menuFontWidth * scaleX
	end

	sceneObj:endUpdate()
	local programUniforms = program.uniforms
	program:use()
	gl.glUniformMatrix4fv(programUniforms.mvMat.loc, 1, false, self.mvMat.ptr)
	gl.glUniform1i(programUniforms.sheetTex.loc, 0)
	gl.glUniform1i(programUniforms.paletteTex.loc, 1)
	gl.glUniform1ui(programUniforms.paletteIndex.loc, fgColorIndex-1)
	gl.glUniform1ui(programUniforms.transparentIndex.loc, 0)
	gl.glUniform1ui(programUniforms.spriteMask.loc, 1)
	gl.glUniform4f(programUniforms.drawOverrideSolid.loc, blendSolidR/255, blendSolidG/255, blendSolidB/255, self.drawOverrideSolidA)
	sceneObj:enableAndSetAttrs()
	sceneObj.geometry:draw()
	sceneObj:disableAttrs()
	program:useNone()
	tex1:unbind(1)
	tex0:unbind(0)

	return x - x0
end


-- matrix commands, so I don't duplicate these here in the env and in net ...
-- should I set defaults here as well?
-- I'm already setting them in env so ... nah ...

function AppVideo:matident()
	self.mvMat:setIdent()
	self:mvMatToRAM()
end

function AppVideo:mattrans(x,y,z)
	self:mvMatFromRAM()
	self.mvMat:applyTranslate(x, y, z)
	self:mvMatToRAM()
end

function AppVideo:matrot(theta, x, y, z)
	self:mvMatFromRAM()
	self.mvMat:applyRotate(theta, x, y, z)
	self:mvMatToRAM()
end

function AppVideo:matscale(x, y, z)
	self:mvMatFromRAM()
	self.mvMat:applyScale(x, y, z)
	self:mvMatToRAM()
end

function AppVideo:matortho(l, r, t, b, n, f)
	self:mvMatFromRAM()
	-- adjust from [-1,1] to [0,256]
	-- opengl ortho matrix, which expects input space to be [-1,1]
	self.mvMat:applyTranslate(128, 128)
	self.mvMat:applyScale(128, 128)
	self.mvMat:applyOrtho(l, r, t, b, n, f)
	self:mvMatToRAM()
end

function AppVideo:matfrustum(l, r, t, b, n, f)
	self:mvMatFromRAM()
--	self.mvMat:applyTranslate(128, 128)
--	self.mvMat:applyScale(128, 128)
	self.mvMat:applyFrustum(l, r, t, b, n, f)
	-- TODO Why is matortho a lhs transform to screen space but matfrustum a rhs transform to screen space? what did I do wrong?
	self.mvMat:applyTranslate(128, 128)
	self.mvMat:applyScale(128, 128)
	self:mvMatToRAM()
end

function AppVideo:matlookat(ex, ey, ez, cx, cy, cz, upx, upy, upz)
	self:mvMatFromRAM()
	-- typically y+ is up, but in the 90s console era y- is up
	-- also flip x+ since OpenGL uses a RHS but I want to preserve orientation of our renderer when looking down from above, so we use a LHS
	self.mvMat:applyScale(-1, -1, 1)
	self.mvMat:applyLookAt(ex, ey, ez, cx, cy, cz, upx, upy, upz)
	self:mvMatToRAM()
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
